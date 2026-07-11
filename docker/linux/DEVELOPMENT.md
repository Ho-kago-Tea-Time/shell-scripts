# Docker Manager 开发手册

中文版本: [DEVELOPMENT.zh-CN.md](./DEVELOPMENT.zh-CN.md)

这份文档记录 `docker-manager.sh` 开发过程中确认过的设计问题、边界情况和常见疑问。`README.md` 偏用户使用说明，本文件偏维护和二次开发说明。

## 官方文档依据

脚本当前按 Docker 官方包管理器安装方式实现，而不是使用 convenience script。

- Ubuntu Engine 安装: <https://docs.docker.com/engine/install/ubuntu/>
- Debian Engine 安装: <https://docs.docker.com/engine/install/debian/>
- Linux post-install: <https://docs.docker.com/engine/install/linux-postinstall/>
- Compose plugin 安装: <https://docs.docker.com/compose/install/linux/>
- Compose 卸载: <https://docs.docker.com/compose/install/uninstall/>

Ubuntu 和 Debian 的 Docker apt 仓库地址不是同一个：

```text
Ubuntu: https://download.docker.com/linux/ubuntu
Debian: https://download.docker.com/linux/debian
```

它们在各自 Engine 安装文档的 `Install using the apt repository` 章节中，位于 `Add the repository to Apt sources` 代码块的 `URIs:` 行。

## 设计结构

脚本按以下流程组织：

```text
parse args -> detect distro -> select adapter -> run install/uninstall action
```

主要设计点：

- 入口只负责参数、权限、系统识别和动作分发。
- 发行版差异收敛到 adapter 中，目前是 `apt` 和 `rpm`。
- Ubuntu、Debian、Fedora、CentOS、RHEL 是一等支持目标。
- Ubuntu 衍生发行版使用 Docker 的 Ubuntu 仓库 adapter。
- 非 Ubuntu 的 Debian 衍生发行版使用 Docker 的 Debian 仓库 adapter。
- Rocky Linux、AlmaLinux、Oracle Linux 暂按 CentOS-compatible 路径处理。

Ubuntu 确实属于 Debian family，但 Docker 官方仓库路径中 Ubuntu 和 Debian 是两个独立目标，所以脚本里需要分开处理。

## 默认安装包

默认安装包如下：

```text
docker-ce
docker-ce-cli
containerd.io
docker-buildx-plugin
docker-compose-plugin
```

对应含义：

- `docker-ce`: Docker Engine 本体。
- `docker-ce-cli`: `docker` 命令行。
- `containerd.io`: 容器运行时。
- `docker-buildx-plugin`: 增强镜像构建插件，提供 `docker buildx`。
- `docker-compose-plugin`: Compose v2 插件，提供 `docker compose`。

`docker-compose-plugin` 默认安装，但可以通过 `--without-compose` 关闭。

## Docker Buildx plugin 是什么

`docker-buildx-plugin` 安装后提供：

```bash
docker buildx
```

它是 `docker build` 的增强版，底层使用 BuildKit。常见用途：

```bash
docker buildx build -t my-app .
docker buildx build --platform linux/amd64,linux/arm64 -t my-app .
docker buildx ls
```

它适合：

- 构建本地 Dockerfile 镜像。
- 做多架构镜像，例如同时发布 amd64 和 arm64。
- 使用更高级的构建缓存。
- 配合 Compose 或 CI/CD 做镜像构建。

如果只是运行现成镜像，例如 `docker run nginx` 或 `docker compose up -d`，短期可能不会直接用到它。但它是 Docker 官方当前推荐安装集合的一部分。

## Compose plugin 说明

当前默认安装的是 Compose v2 插件：

```bash
docker compose version
```

不是旧式独立二进制：

```bash
docker-compose
```

如果用户传：

```bash
sudo ./docker-manager.sh install --without-compose
```

脚本不会安装 `docker-compose-plugin`。

卸载时默认也会卸载 `docker-compose-plugin`。如果用户希望保留 Compose 插件，可以传：

```bash
sudo ./docker-manager.sh uninstall --without-compose
```

## --add-current-user 的用途

安装 Docker 后，如果普通用户没有加入 `docker` 组，每次运行 Docker 通常需要：

```bash
sudo docker ps
sudo docker compose up -d
```

传入：

```bash
sudo ./docker-manager.sh install --add-current-user
```

脚本会把 sudo 调用者加入 `docker` 组。这样重新登录后可以直接运行：

```bash
docker ps
docker compose up -d
```

实现细节：

- 优先使用 `SUDO_USER`，避免把 `root` 当成目标用户。
- 如果没有 `SUDO_USER`，回退到当前 `USER`。
- 加组后需要重新登录，或临时执行 `newgrp docker`。

安全注意：`docker` 组基本等价于 root 权限，只应授予可信用户。

## dry-run 行为

`--dry-run` 用于预览命令，不修改系统：

```bash
./docker-manager.sh install --dry-run
```

dry-run 会打印类似：

```text
[DRY-RUN] env DEBIAN_FRONTEND=noninteractive apt-get update
[DRY-RUN] env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
[DRY-RUN] docker --version
[DRY-RUN] docker compose version
```

注意：dry-run 没有真正安装 Docker，所以验证阶段也只打印将要执行的验证命令，不应检查当前系统里是否已经存在 `docker` 命令。

## apt source 幂等和冲突处理

Ubuntu/Debian adapter 会写入：

```text
/etc/apt/sources.list.d/docker.sources
```

标准内容类似：

```text
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: jammy
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
```

脚本会扫描这些位置，查找是否已经存在 `download.docker.com/linux`：

```text
/etc/apt/sources.list
/etc/apt/sources.list.d/*.list
/etc/apt/sources.list.d/*.sources
```

处理规则如下。

### 已经是 docker.sources

如果已经存在：

```text
/etc/apt/sources.list.d/docker.sources
```

脚本认为这是自己管理的 Docker 源文件。

- 内容已经正确：提示 `is already up to date`，保持不动。
- 内容不一致：覆盖刷新成脚本期望的标准配置。

这样不会额外生成第二份 Docker 源，避免 apt 重复源。

### 旧 docker.* 源文件

如果发现旧文件，例如：

```text
/etc/apt/sources.list.d/docker.list
```

并且里面包含：

```text
download.docker.com/linux
```

脚本会先备份成：

```text
/etc/apt/sources.list.d/docker.list.bak.20260707123045
```

然后再写新的：

```text
/etc/apt/sources.list.d/docker.sources
```

备份文件不再以 `.list` 或 `.sources` 结尾，apt 不会继续加载它。这样可以避免同一个 Docker 仓库被配置两次，或出现 `Signed-By` 冲突。

### Docker 源混在 sources.list 中

如果 Docker 源混在系统主源文件里：

```text
/etc/apt/sources.list
```

脚本会报错并停止。原因是这个文件通常还有 Ubuntu 官方源、镜像源、PPA 或其他手动源，自动修改风险较高。

用户应手动打开：

```bash
sudo nano /etc/apt/sources.list
```

把 Docker 那一行注释或删除，例如：

```text
# deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu jammy stable
```

然后重新运行安装脚本。

## 卸载行为

默认卸载只移除包，不删除 Docker 数据：

```bash
sudo ./docker-manager.sh uninstall
```

保留的数据包括：

```text
/var/lib/docker
/var/lib/containerd
```

如果需要彻底清理：

```bash
sudo ./docker-manager.sh uninstall --purge-data
```

如果需要保留 Docker apt/yum repo 文件：

```bash
sudo ./docker-manager.sh uninstall --keep-repo
```

## 常用开发检查

语法检查：

```bash
bash -n ./docker-manager.sh
```

Ubuntu dry-run：

```bash
./docker-manager.sh install --dry-run
```

不安装 Compose 的 dry-run：

```bash
./docker-manager.sh install --dry-run --without-compose
```

Debian adapter dry-run：

```bash
./docker-manager.sh install --dry-run --distro debian --codename bookworm --without-compose --no-enable --no-verify
```

Fedora adapter dry-run：

```bash
./docker-manager.sh install --dry-run --distro fedora --without-compose --no-enable --no-verify
```

真实安装推荐命令：

```bash
sudo ./docker-manager.sh install --add-current-user
```

安装后重新登录 SSH，或执行：

```bash
newgrp docker
```

然后验证：

```bash
docker --version
docker compose version
docker ps
```

## 在虚拟机上使用

从 Windows 主机传到虚拟机：

```powershell
scp .\docker-manager.sh fancier-hpv-u22:~/code/scripts/docker-manager.sh
```

在虚拟机中：

```bash
cd ~/code/scripts
chmod +x docker-manager.sh
./docker-manager.sh install --dry-run
sudo ./docker-manager.sh install --add-current-user
```
