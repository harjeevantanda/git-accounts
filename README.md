# Setup Multiple Git Accounts with Directories on a Single Machine
## Introduction
- Multiple projects for each git account
- Each  git account is assigned to one directory
- Add multiple projects to a designated directory
- Once set simple git commands in each directory with no extra arguments are needed
- Any Git repository should work ( I have tested on GitHub and GitLab )
- I am adding examples of two git accounts
- these commands are executed on Linux; macOS notes are included where they differ

## Setup summary
- [Set up SSH keys for multiple accounts](#step-1-create-ssh-keys)
- [Add keys to the SSH agent](#step-2-add-keys-to-the-ssh-agent)
- [Add SSH keys to your Git account](#step-3-add-ssh-keys-to-your-git-account)
- [Configure SSH for multiple accounts](#step-4-configure-ssh-for-multiple-accounts)
- [Test SSH connection](#step-5-test-ssh-connection)
- [Configure Git user details](#step-6-configure-git-user-details)
- [Update global Git configuration](#step-7-update-global-git-configuration)
- [Verify configurations and file names](#step-8-verify-configurations-and-file-names)
- [Linux Troubleshoot](#linux-troubleshoot)

## Prerequisites
- Basic knowledge of Git and command-line interface (CLI)
- Git installed on your machine
- The .ssh directory is at the root directory for the logged-in user
- knowledge using the command line 
- terminal editor used here is [nano](https://help.ubuntu.com/community/Nano) if using Ubuntu Nano is part of the standard Ubuntu installation, and should be on your system already

### Step 1: Create SSH Keys
Navigate to the SSH directory:
```bash
cd ~/.ssh
```
Create keys for both accounts
```bash
ssh-keygen -t rsa -C "git-personal-email@gmail.com" -f "git-personal-ssh-file-name"
ssh-keygen -t rsa -C "git-office-email@gmail.com" -f "git-office-ssh-file-name"
```
- `git-personal-ssh-file-name` is SSH key names
- `git-personal-email@gmail.com` is an email on the git repository account

### Step 2: Add Keys to the SSH Agent
Before adding the key, ensure the SSH agent is running. You can start it with
```bash
eval "$(ssh-agent -s)"
```
Add the Private Key to the SSH Agent
```bash
ssh-add ~/.ssh/git-personal-ssh-file-name
ssh-add ~/.ssh/git-office-ssh-file-name
```
- `ssh-add` This is the command used to add SSH private keys to the SSH authentication agent.
- The SSH agent keeps your private key secure and uses it to authenticate connections without exposing the key.
- Once the key is added, you won’t need to enter the passphrase for each SSH connection.

### Step 3: Add SSH Keys to Your Git Account
Print key content on the terminal with the cat command
```bash
cat ~/.ssh/git-personal-ssh-file-name.pub
cat ~/.ssh/git-office-ssh-file-name.pub
```
- Copy the content of the public key file and add it to your respective Git account (GitHub, GitLab, etc.). Refer to [GitHub's documentation](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account) for instructions.
- Make sure you are adding keys to the correct account

### Step 4: Configure SSH for Multiple Accounts
The ~/.ssh/config file is used to configure per-user SSH client settings. By creating entries in this file, you can specify various SSH options and settings for different hosts or groups of hosts, making it easier to manage multiple SSH connections.
- Edit or create the SSH config file (~/.ssh/config):
- on executing cat command `cat ~/.ssh/config` config file should look like this

#### create/update ~/.ssh/config file
```bash
# GitHub Account 1
Host github-account-1
   HostName github.com
   User git
   IdentityFile ~/.ssh/git-personal-ssh-file-name
   IdentitiesOnly yes

# GitHub Account 2
Host github-account-2
   HostName github.com
   User git
   IdentityFile ~/.ssh/git-office-ssh-file-name
   IdentitiesOnly yes
```
- `Host`:  is the alias you will use when making an SSH connection to this GitHub account.
- `HostName`: is the repository cloud base URL.
- `IdentityFile`: Specifies the file containing the private key to use for authentication. This points to the specific SSH key file for each GitHub account (~/.ssh/git-personal-ssh-file-name for the first account and ~/.ssh/git-office-ssh-file-name for the second).
- `User`: Specifies the username to use when logging in. For GitHub, this is typically git.
- `IdentitiesOnly`: When set to yes, this option ensures that only the specified IdentityFile (and not any other identities in the agent) will be used for authentication.
- if does not exist create the file in the .ssh directory
- in this file, we are assigning a GitHub account to its SSH key
- For example `gitHub-account-1` is being assigned to `git-personal-ssh-file-name` key which was created in Step 1

### Step 5: Test SSH Connection
```bash
ssh -T github-account-1
ssh -T github-account-2
```
- `ssh`: This command is used to initiate an SSH (Secure Shell) connection to a remote host.
- `-T`: This option disables pseudo-terminal allocation. It is typically used when you want to execute a command on the remote server without opening an interactive shell.
- `github-account-1`: This is the alias defined in your ~/.ssh/config file. It specifies which host configuration to use for this connection.

### Step 6: Configure Git User Details
- Here we are creating two configuration files for each git account
- Config files for this example
```bash
nano ~/.gitconfig-personal
```
content of the `.gitconfig-personal` file should look like this
```bash
[user]
   name = personal
   email = git-personal-email@gmail.com
[core]
   sshCommand = "ssh -i ~/.ssh/git-personal-ssh-file-name -o IdentitiesOnly=yes"
```
```bash
nano ~/.gitconfig-office
```
content of the `.gitconfig-office` file should look like this
```bash
[user]
   name = office
   email = git-office-email@gmail.com
[core]
   sshCommand = "ssh -i ~/.ssh/git-office-ssh-file-name -o IdentitiesOnly=yes"
```
- The [user] section sets the global Git username and email address.    These settings are used for commits and other Git operations.
- [core] Sets the SSH command that Git should use when connecting to remote repositories.
   The -i option specifies the identity file (private SSH key) for authentication.
   ~/.ssh/git-personal-ssh-file-name is the SSH private key file path for the specific GitHub account (git-personal).
  
### Step 7: Update Global Git Configuration
This configuration is used to conditionally include other configuration files based on the directory of the Git repository you're working in.

Edit the global Git configuration file (~/.gitconfig):

```bash
nano ~/.gitconfig
```

```bash
[includeIf "gitdir:~/Desktop/personal-work-directory/"]
   path = ~/.gitconfig-personal


[includeIf "gitdir:~/Desktop/office-work-directory/"]
   path = ~/.gitconfig-office
```
IMPORTANT
- `Desktop/personal-work-directory/` is the path to the respective repository for each git account
- The `.gitconfig` file is in the root directory for personal
- `.gitconfig-personal` config path for personal

### Step 8: Verify configurations and file names
```bash
cat ~/.gitconfig
cat ~/.ssh/config
cat ~/.gitconfig-personal
cat ~/.gitconfig-office
ls -la ~/.ssh/
```

### macOS notes
- Persist keys across reboots: `ssh-add --apple-use-keychain ~/.ssh/git-personal-ssh-file-name`, and add these lines under each `Host` block in `~/.ssh/config`:
```bash
   AddKeysToAgent yes
   IgnoreUnknown UseKeychain
   UseKeychain yes
```
- `setup-git-accounts.sh` needs bash 4+; macOS ships 3.2. Run `brew install bash` (the script re-execs itself under Homebrew bash automatically).

### Linux Troubleshoot
- ERROR: “ssh: Could not resolve hostname github.com: Temporary failure in name resolution”
   Solution/Command (Linux): “sudo systemctl restart systemd-resolved”
- Initial the ssh-agent
   Solution/Command: eval "$(ssh-agent -s)"
- Test the connection to the host added on the config file
   ssh -T github-account-1
   ssh -T github-account-2
- Permissions 0644 for `personal-public-key-name` are too open. It is required that your private key files are NOT accessible by others.
   chmod 600 ~/.ssh/office-private-key-name
- When creating multiple files it's possible to miss the names and location of the file. Check all file names and content following step 8
- reload the agent 
```bash
   ssh-add -D
   ssh-add ~/.ssh/github-personal
```