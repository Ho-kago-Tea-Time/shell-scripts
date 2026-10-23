# Shell Scripts

这个仓库用于存放可复用的 Shell 脚本和系统自动化辅助工具。

## 脚本

- [docker/linux/docker-manager.sh](./docker/linux/docker-manager.sh): 安装和卸载 Docker Engine、Docker Buildx 与 Docker Compose plugin。当前优先支持 Ubuntu，同时通过 adapter 结构预留了兼容其他主流 Linux 发行版的空间。
- [openssh/windows/Configure-RestrictedOpenSsh.ps1](./openssh/windows/Configure-RestrictedOpenSsh.ps1): 安装并配置 Windows OpenSSH Server、管理员公钥及限制来源的防火墙白名单。
- [git/](./git/README.zh-CN.md)：生成或复用 SSH 密钥，并添加到 GitHub、GitLab 官方站或自建实例；提供 Windows 和 macOS/Linux 入口，可选配置 SSH 别名。

## 目录结构

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

## 开发

这个仓库已经初始化为 Git 仓库，并计划配合 Entire 捕获本地 agent session 上下文。不要提交本地生成的设置文件或临时文件。

提交 Shell 脚本前，先运行：

```bash
bash -n docker/linux/docker-manager.sh
bash -n git/unix/setup-git-ssh.sh
```
