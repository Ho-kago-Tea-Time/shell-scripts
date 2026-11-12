# Shell Scripts

这个仓库用于存放可复用的 Shell 脚本和系统自动化辅助工具。

## 脚本

- [docker/linux/docker-manager.sh](./docker/linux/docker-manager.sh): 安装和卸载 Docker Engine、Docker Buildx 与 Docker Compose plugin。当前优先支持 Ubuntu，同时通过 adapter 结构预留了兼容其他主流 Linux 发行版的空间。
- [openssh/](./openssh/README.zh-CN.md)：初始化 Windows、macOS、Ubuntu/Debian 的 SSH 服务端、公钥及访问白名单。
- [git/](./git/README.zh-CN.md)：生成或复用 SSH 密钥，并添加到 GitHub、GitLab 官方站或自建实例；提供 Windows 和 macOS/Linux 入口，可选配置 SSH 别名。
- [openclaw/](./openclaw/README.zh-CN.md)：固定收录官方 Windows 安装脚本，记录来源，并说明如何从已有本地源码仓库安装。
- [hyper-v/](./hyper-v/README.zh-CN.md)：管理本机 Hyper-V 虚拟机启停、保存状态和检查点（快照），支持预演与确认。

## 目录结构

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

## 开发

这个仓库已经初始化为 Git 仓库，并计划配合 Entire 捕获本地 agent session 上下文。不要提交本地生成的设置文件或临时文件。

提交 Shell 脚本前，先运行：

```bash
bash -n docker/linux/docker-manager.sh
bash -n git/unix/setup-git-ssh.sh
bash -n openssh/unix/configure-restricted-openssh.sh
bash openssh/tests/test-configure-restricted-openssh.sh
```
