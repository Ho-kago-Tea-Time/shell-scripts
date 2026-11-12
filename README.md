# Shell Scripts

Reusable shell scripts and system automation helpers.

Chinese version: [README.zh-CN.md](./README.zh-CN.md)

## Scripts

- [docker/linux/docker-manager.sh](./docker/linux/docker-manager.sh): install and uninstall Docker Engine, Docker Buildx, and Docker Compose plugin on Ubuntu today, with adapter-based room for other mainstream Linux distributions.
- [openssh/](./openssh/README.md): initialize SSH servers, public keys, and access allowlists on Windows, macOS, and Ubuntu/Debian.
- [git/](./git/README.md): create/reuse SSH keys and register them with GitHub or GitLab (official or self-hosted), with Windows and macOS/Linux entry points and optional SSH aliases.
- [openclaw/](./openclaw/README.md): pinned, unmodified official Windows installer, provenance, and instructions for installing an existing source checkout.
- [hyper-v/](./hyper-v/README.md): manage local Hyper-V VM power, saved states, and checkpoints with previews and confirmation.

## Layout

```text
hyper-v/
  windows/Manage-HyperV.ps1
  tests/Test-HyperVManager.ps1
  README.md
  README.zh-CN.md
openclaw/
  windows/upstream/install.ps1
  windows/upstream/LICENSE
  windows/upstream/SOURCE.json
  tests/Test-InstallerSnapshot.ps1
  README.md
  README.zh-CN.md
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
  README.md
  README.zh-CN.md
  unix/configure-restricted-openssh.sh
  tests/test-configure-restricted-openssh.sh
  windows/
    OpenSshServerTools.psm1
    Configure-RestrictedOpenSsh.ps1
```

## Development

This repository is configured for Git and is intended to use Entire for local agent-session context capture. Do not commit generated local settings or temporary files.

Before committing shell scripts, run:

```bash
bash -n docker/linux/docker-manager.sh
bash -n git/unix/setup-git-ssh.sh
bash -n openssh/unix/configure-restricted-openssh.sh
bash openssh/tests/test-configure-restricted-openssh.sh
```
