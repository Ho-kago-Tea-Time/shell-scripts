# Git hosting SSH setup

Chinese version: [README.zh-CN.md](./README.zh-CN.md)

Generate or reuse an SSH key, verify the target account, register its public key, and optionally configure an SSH alias. Supported services:

- GitHub.com and self-hosted GitHub Enterprise Server (GHES).
- GitLab.com and self-managed GitLab, including installations under a Web path prefix.

## Requirements

| System | Entry point | Dependencies |
| --- | --- | --- |
| Windows | `windows/Setup-GitSsh.ps1` | Windows PowerShell 5.1 or PowerShell 7, OpenSSH Client (`ssh-keygen`) |
| macOS / Linux | `unix/setup-git-ssh.sh` | Bash 3.2+, OpenSSH `ssh-keygen`, `curl`, `jq` |

GitHub additionally uses `gh` unless a token environment variable is explicitly supplied. GitLab requires a personal access token with the `api` scope. Dependencies are checked, not automatically installed. Run as your normal user; administrator/root access is unnecessary. macOS users may need to install `jq` separately.

## GitHub

First log in and grant public-key permissions (once per account/host):

```text
gh auth login --hostname github.com
gh auth refresh --hostname github.com --scopes read:public_key,write:public_key
```

When logging in, skip gh's own SSH key generation/upload if offered; this script manages that step. For multiple accounts, refresh the intended active account before running the script. The script itself obtains credentials using `gh auth token --hostname HOST --user ACCOUNT`, verifies `/user`, and does not switch the active gh account or change Git protocol settings.

From the repository root on Windows:

```powershell
.\git\windows\Setup-GitSsh.ps1 -Account YOUR_ACCOUNT -ConfigureSsh
```

On macOS/Linux:

```bash
bash git/unix/setup-git-ssh.sh --account YOUR_ACCOUNT --configure-ssh
```

For GHES, log in to that hostname and add the Web URL:

```powershell
.\git\windows\Setup-GitSsh.ps1 -Provider github -ServerUrl https://github.example.com -Account YOUR_ACCOUNT -ConfigureSsh
```

```bash
bash git/unix/setup-git-ssh.sh --provider github \
  --server-url https://github.example.com --account YOUR_ACCOUNT --configure-ssh
```

GitHub.com uses `https://api.github.com`; GHES uses `SERVER_URL/api/v3`. Custom GitHub Enterprise Cloud `*.ghe.com` domains are outside this first version's API mapping.

## GitLab

Provide a token using an environment variable. These examples prompt without storing the token in shell history.

Windows:

```powershell
$gitSshToken = Read-Host 'GitLab token' -AsSecureString
$env:GITLAB_TOKEN = [Net.NetworkCredential]::new('', $gitSshToken).Password
.\git\windows\Setup-GitSsh.ps1 -Provider gitlab -Account YOUR_ACCOUNT -ConfigureSsh
Remove-Item Env:GITLAB_TOKEN
```

macOS/Linux:

```bash
read -r -s -p 'GitLab token: ' GITLAB_TOKEN
printf '\n'
export GITLAB_TOKEN
bash git/unix/setup-git-ssh.sh --provider gitlab --account YOUR_ACCOUNT --configure-ssh
unset GITLAB_TOKEN
```

The default Web URL is `https://gitlab.com`. A self-managed instance can use a different Web port, Web path, SSH hostname, and SSH port:

```powershell
.\git\windows\Setup-GitSsh.ps1 `
  -Provider gitlab -ServerUrl https://git.example.com:8443/team `
  -Account YOUR_ACCOUNT -TokenEnv WORK_GITLAB_TOKEN `
  -SshHost ssh.example.com -SshPort 2222 `
  -ConfigureSsh -SshAlias gitlab-work
```

```bash
bash git/unix/setup-git-ssh.sh \
  --provider gitlab --server-url https://git.example.com:8443/team \
  --account YOUR_ACCOUNT --token-env WORK_GITLAB_TOKEN \
  --ssh-host ssh.example.com --ssh-port 2222 \
  --configure-ssh --ssh-alias gitlab-work
```

Here `WORK_GITLAB_TOKEN` must already contain the token. The API URL becomes `https://git.example.com:8443/team/api/v4`; the SSH port remains independent of the Web port. Instance URLs require HTTPS and a DNS/IPv4 host. Install your private CA into the appropriate client trust store when necessary; certificate validation is always enabled. HTTP redirects are rejected.

## Parameters

| Bash | PowerShell | Default / meaning |
| --- | --- | --- |
| `--provider` | `-Provider` | `github`; supports `github`, `gitlab` |
| `--server-url` | `-ServerUrl` | `https://github.com` or `https://gitlab.com`; supply the Web base URL, not the API URL |
| `--account` | `-Account` | Required expected username; must match the authenticated account |
| `--token-env` | `-TokenEnv` | Environment variable name, not the token itself; GitLab default `GITLAB_TOKEN`; GitHub default uses `gh` |
| `--type` | `-Type` | `ed25519`; also `rsa` or `ecdsa` |
| `--bits` | `-Bits` | RSA: 2048/3072/4096, default 4096; ECDSA: 256/384/521, default 256; invalid for Ed25519 |
| `--key-path` | `-KeyPath` | `~/.ssh/id_TYPE_PROVIDER_INSTANCE_ACCOUNT`; INSTANCE includes hostname, custom Web port/path, with separators sanitized |
| `--title` | `-Title` | `COMPUTER-ACCOUNT`, shown on the hosting service |
| `--comment` | `-Comment` | `ACCOUNT@COMPUTER`, written in the public key |
| `--no-passphrase` | `-NoPassphrase` | Create without a passphrase; default is ssh-keygen's interactive prompt |
| `--configure-ssh` | `-ConfigureSsh` | Configure an alias; off by default |
| `--ssh-alias` | `-SshAlias` | Official site: `PROVIDER-ACCOUNT`; custom: `PROVIDER-INSTANCE-ACCOUNT` |
| `--ssh-config-path` | `-SshConfigPath` | `~/.ssh/config`; optional separate config file |
| `--ssh-host` | `-SshHost` | Web hostname |
| `--ssh-port` | `-SshPort` | 22 |
| `--ssh-user` | `-SshUser` | `git` |
| `--dry-run` | `-DryRun` | Offline plan; no credential reads, network requests, or file writes |

For RSA, for example:

```powershell
.\git\windows\Setup-GitSsh.ps1 -Account YOUR_ACCOUNT -Type rsa -Bits 4096 -ConfigureSsh
```

```bash
bash git/unix/setup-git-ssh.sh --account YOUR_ACCOUNT --type rsa --bits 4096 --configure-ssh
```

The server may restrict algorithms or key lifetimes; its policy takes precedence. The script reports API rejection without silently selecting a different algorithm.

## Reuse, configuration, and failures

Identity and public-key-list access are checked before key creation. Existing private keys are never replaced: their public key is derived and compared with any existing `.pub` file. A missing `.pub` file is reconstructed. The requested algorithm is always checked; bit count is checked when explicitly supplied. Existing keys retain their passphrase and comment. An encrypted private key may prompt again when its public key is derived. No ssh-agent service or OS keychain settings are changed.

Public keys are compared by algorithm and key data across all pages, ignoring comments. A registered key is skipped; an expired or signing-only GitLab match requires manual correction. New GitLab keys use `usage_type=auth`. A failed upload retains the key pair for a later retry and does not add an SSH config block.

`-ConfigureSsh` / `--configure-ssh` adds a marked block at the beginning of the config, preserving existing content and preceding `Host *` defaults. An identical managed block is reused. Existing explicit aliases, including multi-name `Host` lines and ordinary/globbed `Include` files, cause a conflict instead of being overwritten. Include paths using environment/token expansion or other users' home directories require manual config editing. Includes in conditional sections are checked conservatively too. Existing wildcard rules and `Match` sections can still add options such as additional `IdentityFile` entries; review the resulting configuration if using those features.

Example:

The managed block also ends with `Host *` to preserve the scope of any original global options that follow it.

```sshconfig
Host gitlab-work
    HostName ssh.example.com
    Port 2222
    User git
    IdentityFile "/home/you/.ssh/id_ed25519_gitlab_git.example.com_8443_team_YOUR_ACCOUNT"
    IdentitiesOnly yes
```

Use the alias in SSH and Git commands:

```bash
ssh -T gitlab-work
git clone gitlab-work:GROUP/REPO.git
```

For a separate config file, use `ssh -F PATH` and configure Git to use it, or include that file from your main config. Without `--configure-ssh`, the script prints an explicit `ssh -i ...` test command. Tests are never run automatically: first-contact server host-key verification remains interactive. Git remote URLs are not rewritten. Tokens are not written to files or included in HTTP command arguments.

## Offline development tests

From the repository root:

```powershell
.\git\tests\Test-Setup-GitSsh.ps1
```

```bash
bash -n git/unix/setup-git-ssh.sh
bash git/tests/test-setup-git-ssh.sh
```

Tests use real temporary OpenSSH key pairs under `.tools/` and simulated API/gh transports. They do not access user credentials, the user's SSH directory, or hosting services. Run the PowerShell tests on Windows. Bash tests require `jq` and OpenSSH. Actual macOS/Linux and live-server integration should be verified separately in the target environment.

API references: [GitHub user SSH keys](https://docs.github.com/en/rest/users/keys), [GitLab user SSH keys](https://docs.gitlab.com/api/user_keys/).
