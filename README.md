# Shell Scripts

Reusable shell scripts and system automation helpers.

Chinese version: [README.zh-CN.md](./README.zh-CN.md)

## Scripts

- [docker/linux/docker-manager.sh](./docker/linux/docker-manager.sh): install and uninstall Docker Engine, Docker Buildx, and Docker Compose plugin on Ubuntu today, with adapter-based room for other mainstream Linux distributions.
- [openssh/windows/Configure-RestrictedOpenSsh.ps1](./openssh/windows/Configure-RestrictedOpenSsh.ps1): install and configure Windows OpenSSH Server with an administrator public key and a restricted firewall allowlist.
- [git/](./git/README.md): create/reuse SSH keys and register them with GitHub or GitLab (official or self-hosted), with Windows and macOS/Linux entry points and optional SSH aliases.

## Layout

```text
git/
  windows/Setup-GitSsh.ps1
  unix/setup-git-ssh.sh
  tests/
  README.md
  README.zh-CN.md
docker/
  linux/
    docker-manager.sh
    README.md
    README.zh-CN.md
    DEVELOPMENT.md
    DEVELOPMENT.zh-CN.md
openssh/
  windows/
    OpenSshServerTools.psm1
    Configure-RestrictedOpenSsh.ps1
    README.md
    README.zh-CN.md
```

## Development

This repository is configured for Git and is intended to use Entire for local agent-session context capture. Do not commit generated local settings or temporary files.

Before committing shell scripts, run:

```bash
bash -n docker/linux/docker-manager.sh
bash -n git/unix/setup-git-ssh.sh
```
