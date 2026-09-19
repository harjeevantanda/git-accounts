#!/usr/bin/env bash
#
# setup-git-accounts.sh
#
# Automates the steps from https://github.com/hstanda/git-accounts
# ("Setup Multiple Git Accounts with Directories on a Single Machine")
# for as many accounts as you list in a config file.
#
# For each account it will:
#   1. Generate an SSH key                    (ssh-keygen)
#   2. Add it to the SSH agent                 (ssh-add)
#   3. Show you the public key to upload       (manual step — GitHub/GitLab/etc.)
#   4. Add/update a Host block in ~/.ssh/config
#   5. Test the SSH connection                 (ssh -T <host_alias>)
#   6. Write a per-account git identity file   (~/.gitconfig-<alias>)
#   7. Add/update an includeIf block in ~/.gitconfig scoped to that
#      account's working directory
#
# then (8) print everything back out so you can verify it.
#
# Usage:
#   ./setup-git-accounts.sh <config-file> [options]
#
# Run with --help for options. See git-accounts.conf for the
# config file format.

set -euo pipefail

# --- requirements -----------------------------------------------------------

if ((BASH_VERSINFO[0] < 4)); then
  # macOS ships bash 3.2; re-exec under a newer bash (e.g. Homebrew) if present.
  for newer in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$newer" ]] && "$newer" -c '((BASH_VERSINFO[0] >= 4))' 2>/dev/null; then
      exec "$newer" "$0" "$@"
    fi
  done
  echo "ERROR: this script needs bash 4+ (for associative arrays); found ${BASH_VERSION}." >&2
  echo "       On macOS: brew install bash" >&2
  exit 1
fi

IS_DARWIN=false
[[ "$(uname -s)" == "Darwin" ]] && IS_DARWIN=true

for bin in ssh-keygen ssh-agent ssh-add ssh git; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: required command not found: $bin" >&2; exit 1; }
done

# --- globals -----------------------------------------------------------------

CONFIG_FILE=""
DRY_RUN=false
ASSUME_YES=false
FORCE_KEYGEN=false
SKIP_SSH_TEST=false

declare -a ALIASES=()
declare -A ACC_EMAIL ACC_NAME ACC_KEYFILE ACC_KEYTYPE ACC_HOSTALIAS ACC_HOSTNAME ACC_WORKDIR ACC_PASSPHRASE

# --- helpers -------------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }

log() { echo "$*"; }

usage() {
  cat <<'EOF'
Usage: setup-git-accounts.sh <config-file> [options]

Reads a config file describing one or more Git accounts and walks through
all the steps from https://github.com/hstanda/git-accounts to set each one
up on this machine: SSH key generation, ssh-agent, ~/.ssh/config, a
per-account git identity file, and a ~/.gitconfig includeIf block scoped to
that account's working directory.

Options:
  -c, --config FILE   Path to the config file (same as the positional arg)
  -n, --dry-run        Print what would be done without changing anything
  -y, --yes            Don't pause waiting for you to upload each public key
      --force-keygen   Regenerate SSH keys even if the key file already exists
      --skip-ssh-test  Skip the "ssh -T <host_alias>" connectivity test step
  -h, --help           Show this help

Examples:
  ./setup-git-accounts.sh git-accounts.conf
  ./setup-git-accounts.sh git-accounts.conf --dry-run
  ./setup-git-accounts.sh git-accounts.conf --yes --skip-ssh-test

See git-accounts.conf for the config file format. Re-running the
script is safe: it updates its own blocks in ~/.ssh/config and ~/.gitconfig
in place instead of duplicating them, and skips key generation for keys that
already exist (unless --force-keygen is given).
EOF
}

expand_tilde() {
  local p="$1"
  case "$p" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "${HOME}${p:1}" ;;
    *) printf '%s' "$p" ;;
  esac
}

# Remove any previously-written block for this alias, then append a fresh one.
# Keeps re-runs idempotent instead of piling up duplicate Host/includeIf blocks.
upsert_block() {
  local file="$1" marker="$2" content="$3"
  local start="# >>> git-accounts:${marker} >>>"
  local end="# <<< git-accounts:${marker} <<<"

  touch "$file"
  awk -v start="$start" -v end="$end" '
    $0==start {skip=1; next}
    $0==end   {skip=0; next}
    skip==1   {next}
    {print}
  ' "$file" > "${file}.tmp.$$"
  mv "${file}.tmp.$$" "$file"

  {
    echo "$start"
    printf '%s\n' "$content"
    echo "$end"
  } >> "$file"
}

# --- config parsing ------------------------------------------------------------
#
# Simple INI-style format:
#   [alias]
#   key = value
#   ...
# Lines starting with # or ; are comments; blank lines are ignored. Inline
# comments are not supported, so values (e.g. passphrases) may contain # or ;.

parse_config() {
  local file="$1" current="" lineno=0 raw_line line key val

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    lineno=$((lineno + 1))
    line="$(printf '%s' "$raw_line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$line" || "$line" == \#* || "$line" == \;* ]] && continue

    if [[ "$line" =~ ^\[([A-Za-z0-9_.-]+)\]$ ]]; then
      current="${BASH_REMATCH[1]}"
      ALIASES+=("$current")
      continue
    fi

    [[ -n "$current" ]] || die "config error at line $lineno: '$raw_line' found before any [section]"

    if [[ "$line" =~ ^([A-Za-z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      case "$key" in
        email)      ACC_EMAIL[$current]="$val" ;;
        name)       ACC_NAME[$current]="$val" ;;
        key_file)   ACC_KEYFILE[$current]="$val" ;;
        key_type)   ACC_KEYTYPE[$current]="$val" ;;
        host_alias) ACC_HOSTALIAS[$current]="$val" ;;
        hostname)   ACC_HOSTNAME[$current]="$val" ;;
        work_dir)   ACC_WORKDIR[$current]="$val" ;;
        passphrase) ACC_PASSPHRASE[$current]="$val" ;;
        *) echo "warning: unknown key '$key' in section [$current] (line $lineno), ignoring" >&2 ;;
      esac
    else
      die "config error at line $lineno: cannot parse '$raw_line'"
    fi
  done < "$file"

  local a
  for a in "${ALIASES[@]}"; do
    [[ -n "${ACC_EMAIL[$a]:-}" ]]      || die "section [$a]: missing 'email'"
    [[ -n "${ACC_NAME[$a]:-}" ]]       || die "section [$a]: missing 'name'"
    [[ -n "${ACC_KEYFILE[$a]:-}" ]]    || die "section [$a]: missing 'key_file'"
    [[ -n "${ACC_HOSTALIAS[$a]:-}" ]]  || die "section [$a]: missing 'host_alias'"
    [[ -n "${ACC_HOSTNAME[$a]:-}" ]]   || die "section [$a]: missing 'hostname'"
    [[ -n "${ACC_WORKDIR[$a]:-}" ]]    || die "section [$a]: missing 'work_dir'"
    ACC_PASSPHRASE[$a]="${ACC_PASSPHRASE[$a]:-}"

    # Normalize key_type: default to ed25519, and accept the public-key
    # algorithm names (ssh-rsa, ssh-ed25519, ...) people often use by mistake
    # in place of the ssh-keygen -t value (rsa, ed25519, ...).
    local kt="${ACC_KEYTYPE[$a]:-ed25519}"
    case "$kt" in
      ssh-rsa)                   kt="rsa" ;;
      ssh-ed25519)                kt="ed25519" ;;
      ssh-dss)                    kt="dsa" ;;
      ecdsa-sha2-*)                kt="ecdsa" ;;
    esac
    case "$kt" in
      rsa|ed25519|ed25519-sk|dsa|ecdsa|ecdsa-sk) ;;
      *) die "section [$a]: unsupported key_type '${ACC_KEYTYPE[$a]}' (use rsa or ed25519)" ;;
    esac
    ACC_KEYTYPE[$a]="$kt"
  done
}

# --- argument parsing ------------------------------------------------------------

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--config) CONFIG_FILE="${2:-}"; shift 2 ;;
      -n|--dry-run) DRY_RUN=true; shift ;;
      -y|--yes) ASSUME_YES=true; shift ;;
      --force-keygen) FORCE_KEYGEN=true; shift ;;
      --skip-ssh-test) SKIP_SSH_TEST=true; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) die "unknown option: $1 (see --help)" ;;
      *)
        if [[ -z "$CONFIG_FILE" ]]; then
          CONFIG_FILE="$1"
        else
          die "unexpected argument: $1"
        fi
        shift
        ;;
    esac
  done
}

# --- ssh-agent -------------------------------------------------------------------

ensure_agent() {
  if $DRY_RUN; then
    log "[dry-run] would ensure an ssh-agent is running"
    return 0
  fi
  local rc=0
  ssh-add -l >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 2 ]]; then
    log "No ssh-agent reachable, starting one..."
    eval "$(ssh-agent -s)" >/dev/null
  fi
}

# --- step functions ----------------------------------------------------------------

step1_keygen() {
  local a="$1" key_path
  key_path="$HOME/.ssh/${ACC_KEYFILE[$a]}"

  if $DRY_RUN; then
    log "[dry-run] would ensure ~/.ssh exists (700) and generate a ${ACC_KEYTYPE[$a]} key at $key_path (if missing)"
    return 0
  fi

  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  if [[ -f "$key_path" ]] && ! $FORCE_KEYGEN; then
    log "[skip] SSH key already exists: $key_path (use --force-keygen to regenerate)"
    return 0
  fi

  ssh-keygen -t "${ACC_KEYTYPE[$a]}" -C "${ACC_EMAIL[$a]}" -f "$key_path" -N "${ACC_PASSPHRASE[$a]}" >/dev/null
  chmod 600 "$key_path"
  chmod 644 "${key_path}.pub"
  log "Generated key: $key_path"
}

step2_agent_add() {
  local a="$1" key_path out
  key_path="$HOME/.ssh/${ACC_KEYFILE[$a]}"

  if $DRY_RUN; then
    log "[dry-run] would run: ssh-add $key_path"
    return 0
  fi

  local -a add_cmd=(ssh-add)
  # On macOS, store the passphrase in the keychain so the key survives reboots.
  $IS_DARWIN && add_cmd+=(--apple-use-keychain)

  if ! out=$("${add_cmd[@]}" "$key_path" 2>&1); then
    log "warning: ssh-add failed for $key_path: $out"
  else
    log "$out"
  fi
}

step3_show_pubkey() {
  local a="$1" pub
  pub="$HOME/.ssh/${ACC_KEYFILE[$a]}.pub"

  echo
  echo "----- Public key for '$a' — add this to your ${ACC_HOSTNAME[$a]} account -----"
  if [[ -f "$pub" ]]; then
    cat "$pub"
  else
    echo "(dry-run: not generated yet)"
  fi
  echo "---------------------------------------------------------------------------------"

  if ! $ASSUME_YES && ! $DRY_RUN; then
    read -r -p "Press Enter once '$a' key is added to ${ACC_HOSTNAME[$a]} (or Ctrl+C to stop here)... " _ || true
  fi
}

step4_ssh_config() {
  local a="$1" block
  block="Host ${ACC_HOSTALIAS[$a]}
    HostName ${ACC_HOSTNAME[$a]}
    User git
    IdentityFile ~/.ssh/${ACC_KEYFILE[$a]}
    IdentitiesOnly yes"
  if $IS_DARWIN; then
    block+="
    AddKeysToAgent yes
    IgnoreUnknown UseKeychain
    UseKeychain yes"
  fi

  if $DRY_RUN; then
    log "[dry-run] would upsert this block into ~/.ssh/config:"
    echo "$block"
    return 0
  fi

  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  upsert_block "$HOME/.ssh/config" "$a" "$block"
  chmod 600 "$HOME/.ssh/config"
  log "Updated ~/.ssh/config (Host ${ACC_HOSTALIAS[$a]})"
}

step5_test_connection() {
  local a="$1" output rc=0

  if $SKIP_SSH_TEST || $DRY_RUN; then
    log "[skip] ssh connectivity test for '$a'"
    return 0
  fi

  log "Testing: ssh -T ${ACC_HOSTALIAS[$a]}"
  output=$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "${ACC_HOSTALIAS[$a]}" 2>&1) || rc=$?
  echo "$output"
  log "(exit code $rc — most git hosts refuse an interactive shell even on a successful login, so a non-zero code here is normal; check the message above for a greeting/auth confirmation.)"
}

step6_git_identity_config() {
  local a="$1" cfg key_path
  cfg="$HOME/.gitconfig-${a}"
  key_path="$HOME/.ssh/${ACC_KEYFILE[$a]}"

  if $DRY_RUN; then
    log "[dry-run] would write $cfg with user.name=${ACC_NAME[$a]}, user.email=${ACC_EMAIL[$a]}"
    return 0
  fi

  cat > "$cfg" <<EOF
[user]
    name = ${ACC_NAME[$a]}
    email = ${ACC_EMAIL[$a]}
[core]
    sshCommand = "ssh -i ${key_path} -o IdentitiesOnly=yes"
EOF
  log "Wrote $cfg"
}

step7_includeif() {
  local a="$1" work_dir block
  work_dir="$(expand_tilde "${ACC_WORKDIR[$a]}")"
  [[ "$work_dir" == */ ]] || work_dir="${work_dir}/"

  if $DRY_RUN; then
    log "[dry-run] would mkdir -p '$work_dir' and add an includeIf block for it to ~/.gitconfig -> ~/.gitconfig-${a}"
    return 0
  fi

  if [[ -d "$work_dir" ]]; then
    log "[skip] work_dir already exists: $work_dir"
  else
    mkdir -p "$work_dir"
    log "Created work_dir: $work_dir"
  fi

  block="[includeIf \"gitdir:${work_dir}\"]
    path = ~/.gitconfig-${a}"
  upsert_block "$HOME/.gitconfig" "$a" "$block"
  log "Updated ~/.gitconfig includeIf for '$a' -> $work_dir"
}

step8_verify() {
  echo
  echo "==================== Verification ===================="
  echo "--- ~/.ssh/config ---"
  [[ -f "$HOME/.ssh/config" ]] && cat "$HOME/.ssh/config" || echo "(not created)"

  echo
  echo "--- ~/.gitconfig ---"
  [[ -f "$HOME/.gitconfig" ]] && cat "$HOME/.gitconfig" || echo "(not created)"

  local a
  for a in "${ALIASES[@]}"; do
    echo
    echo "--- ~/.gitconfig-$a ---"
    [[ -f "$HOME/.gitconfig-$a" ]] && cat "$HOME/.gitconfig-$a" || echo "(not created)"
  done

  echo
  echo "--- ~/.ssh listing ---"
  ls -la "$HOME/.ssh" 2>/dev/null || echo "(no ~/.ssh directory)"

  echo
  echo "--- Public keys ---"
  for a in "${ALIASES[@]}"; do
    local pub="$HOME/.ssh/${ACC_KEYFILE[$a]}.pub"
    echo
    echo "# $a (${ACC_HOSTNAME[$a]})"
    if [[ -f "$pub" ]]; then
      cat "$pub"
    else
      echo "(not generated: $pub)"
    fi
  done
}

print_troubleshooting() {
  cat <<'EOF'

Troubleshooting (from https://github.com/hstanda/git-accounts):
  - "ssh: Could not resolve hostname ...: Temporary failure in name resolution"
      -> sudo systemctl restart systemd-resolved
  - ssh-agent not running / keys not found
      -> eval "$(ssh-agent -s)"
  - Re-test a connection
      -> ssh -T <host_alias>
  - "Permissions ... are too open" for a private key
      -> chmod 600 ~/.ssh/<key_file>
  - Reload the agent from scratch
      -> ssh-add -D && ssh-add ~/.ssh/<key_file>
EOF
}

# --- main ------------------------------------------------------------------------

main() {
  parse_args "$@"

  if [[ -z "$CONFIG_FILE" ]]; then
    usage
    exit 1
  fi
  [[ -f "$CONFIG_FILE" ]] || die "config file not found: $CONFIG_FILE"

  parse_config "$CONFIG_FILE"
  [[ ${#ALIASES[@]} -gt 0 ]] || die "no [account] sections found in $CONFIG_FILE"

  log "Found ${#ALIASES[@]} account(s): ${ALIASES[*]}"
  $DRY_RUN && log "(dry-run mode: no changes will be made)"

  ensure_agent

  local a
  for a in "${ALIASES[@]}"; do
    echo
    echo "==================== Account: $a ===================="
    step1_keygen "$a"
    step2_agent_add "$a"
    step3_show_pubkey "$a"
    step4_ssh_config "$a"
    step5_test_connection "$a"
    step6_git_identity_config "$a"
    step7_includeif "$a"
  done

  step8_verify
  print_troubleshooting

  echo
  log "Done. ${#ALIASES[@]} account(s) configured from $CONFIG_FILE."
}

main "$@"
