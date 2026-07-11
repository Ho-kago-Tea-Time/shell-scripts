# Shell Scripts

Reusable shell scripts and system automation helpers.

Chinese version: [README.zh-CN.md](./README.zh-CN.md)

## Scripts

- [docker/docker-manager.sh](./docker/docker-manager.sh): install and uninstall Docker Engine, Docker Buildx, and Docker Compose plugin on Ubuntu today, with adapter-based room for other mainstream Linux distributions.
- [windows/openssh/Configure-RestrictedOpenSsh.ps1](./windows/openssh/Configure-RestrictedOpenSsh.ps1): install and configure Windows OpenSSH Server with an administrator public key and a restricted firewall allowlist.

## Layout

```text
docker/
  docker-manager.sh
  README.md
  README.zh-CN.md
  DEVELOPMENT.md
  DEVELOPMENT.zh-CN.md
windows/
  openssh/
    OpenSshServerTools.psm1
    Configure-RestrictedOpenSsh.ps1
    README.md
    README.zh-CN.md
```

## Development

This repository is configured for Git and is intended to use Entire for local agent-session context capture. Do not commit generated local settings or temporary files.

Before committing shell scripts, run:

```bash
bash -n docker/docker-manager.sh
```
