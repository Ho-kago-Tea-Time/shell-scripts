# Docker Manager 脚本

`docker-manager.sh` 用于在 Linux 上通过 Docker 官方软件源安装和卸载 Docker Engine。默认会安装 Docker Compose，安装方式是官方推荐的 `docker-compose-plugin` 包；如果不需要 Compose，可以传 `--without-compose` 关闭。

设计说明、adapter 行为和开发 FAQ 见 [DEVELOPMENT.zh-CN.md](./DEVELOPMENT.zh-CN.md)。

当前脚本优先服务 Ubuntu，但结构上采用 adapter 方式，方便后续扩展到其他发行版：

- 参数解析和主流程放在入口层。
- 发行版检测选择 `apt` 或 `rpm` adapter。
- 包管理器差异封装在 adapter 函数里。
- 添加新发行版时，主要补发行版映射和包管理器行为。

## 支持的 adapter

一等支持目标：

- Ubuntu
- Debian
- Fedora
- CentOS
- RHEL

兼容 fallback：

- Ubuntu 衍生发行版使用 Docker 的 Ubuntu 仓库 adapter，并给出提示。
- 非 Ubuntu 的 Debian 衍生发行版使用 Docker 的 Debian 仓库 adapter，并给出提示。
- Rocky Linux、AlmaLinux、Oracle Linux 使用 CentOS adapter，并给出提示。

如果是衍生发行版，并且自动识别出来的仓库 suite 不正确，可以传 `--distro` 和/或 `--codename`。

## 使用方式

```bash
chmod +x ./docker-manager.sh
sudo ./docker-manager.sh install
```

安装 Docker Engine，但不安装 Docker Compose：

```bash
sudo ./docker-manager.sh install --without-compose
```

安装并把 sudo 调用者加入 `docker` 用户组：

```bash
sudo ./docker-manager.sh install --add-current-user
```

卸载 Docker 包，但保留镜像、容器和卷数据：

```bash
sudo ./docker-manager.sh uninstall
```

卸载并删除 Docker/containerd 数据：

```bash
sudo ./docker-manager.sh uninstall --purge-data
```

只预览将要执行的命令，不修改系统：

```bash
./docker-manager.sh install --dry-run
```

## 说明

- 脚本使用 Docker 官方仓库安装方式，不使用 convenience script。
- 卸载时默认保留 `/var/lib/docker` 和 `/var/lib/containerd` 下的数据。
- `--add-current-user` 参考 Docker 官方 post-install 建议，但 `docker` 组拥有近似 root 的 Docker daemon 权限，只应授予可信用户。
- `--run-hello-world` 可用于官方容器 smoke test；普通验证只检查 `docker --version` 和 `docker compose version`。

