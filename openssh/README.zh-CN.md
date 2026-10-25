# SSH 服务端初始化

在**被登录的目标机**上运行，完成 SSH 服务启用、公钥授权和访问白名单配置。需要已经能通过本地控制台、远程桌面等方式进入目标机并执行管理员命令；脚本不负责从客户端引导部署。

| 目标系统 | 入口 | 权限与范围 |
| --- | --- | --- |
| Windows | [windows/Configure-RestrictedOpenSsh.ps1](windows/Configure-RestrictedOpenSsh.ps1) | 管理员 PowerShell；管理员账户公钥；Windows 防火墙白名单 |
| macOS | [unix/configure-restricted-openssh.sh](unix/configure-restricted-openssh.sh) | `sudo`、系统 Bash 3.2+；系统自带 Remote Login；现有非 root 账户 |
| Ubuntu / Debian | 同上 | `sudo`、Bash、systemd、`ssh-keygen`、util-linux（`runuser`）；缺少服务端时用 apt 安装 `openssh-server`；现有非 root 账户 |

Linux 当前仅覆盖 Ubuntu/Debian，普通容器和没有 systemd 的 WSL 不支持。macOS 不需要 Homebrew OpenSSH。

## 1. 在客户端准备密钥

已有专用密钥可以复用；只把 **`.pub` 公钥文件**复制到目标机，私钥留在客户端。

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_demo -C demo@example.com
```

Windows 客户端可在 PowerShell 中使用 `ssh-keygen`，将输出路径换成 `$HOME\.ssh\id_ed25519_demo`。此工具不会代替客户端生成密钥。

## 2. 在目标机初始化

以下示例均从仓库根目录执行，地址和公钥使用占位值。

### Windows

在目标 Windows 的**管理员 PowerShell**中执行：

```powershell
.\openssh\windows\Configure-RestrictedOpenSsh.ps1 `
    -LocalAddress '192.0.2.10' `
    -RemoteAddress '192.0.2.1', '192.0.2.2' `
    -PublicKey 'ssh-ed25519 AAAA... admin@example.invalid'
```

`LocalAddress` 是目标机接受 SSH 的本地地址，`RemoteAddress` 是允许连接的客户端来源地址，两者都支持多个 IP。`PublicKey` 为客户端公钥的完整内容。

相同的 `RuleName` 会先被删除再按本次参数创建，因此再次执行会**替换**防火墙白名单；未再次传入的地址不再被允许。内置的 `OpenSSH-Server-In-TCP` 规则会保持禁用，以防它绕过白名单。

[Configure-RestrictedOpenSsh.ps1](windows/Configure-RestrictedOpenSsh.ps1) 是一键入口，调用 [OpenSshServerTools.psm1](windows/OpenSshServerTools.psm1) 中的可复用函数：

| 函数 | 参数 | 功能 |
| --- | --- | --- |
| `Ensure-OpenSshServer` | 无 | 安装、设为自动启动并启动 `sshd` |
| `Set-OpenSshFirewallAllowRule` | `LocalAddress`、`RemoteAddress`、可选 `RuleName` | 设置 SSH 防火墙白名单 |
| `Add-AdminSshAuthorizedKey` | `PublicKey` | 幂等添加管理员公钥，并将密钥文件 ACL 限制为 Administrators 和 SYSTEM |
| `Restart-OpenSshServerSafely` | 无 | 先以 `sshd -t` 校验配置，再重启服务 |
| `Test-OpenSshServer` | 可选 `RuleName` | 查看服务、22 端口监听和规则白名单状态 |

此入口使用的 `administrators_authorized_keys` 仅适用于管理员账户。普通账户应使用其个人目录中的 `%USERPROFILE%\.ssh\authorized_keys`。

### macOS / Ubuntu / Debian

在目标机终端中执行：

```bash
# 先预览；不需要 sudo，不安装软件、不写配置、不启动服务。
bash openssh/unix/configure-restricted-openssh.sh \
  --user demo \
  --local-address 192.0.2.10 \
  --remote-address 192.0.2.1 \
  --public-key-file ./client.pub \
  --dry-run

# 确认参数后执行。
sudo bash openssh/unix/configure-restricted-openssh.sh \
  --user demo \
  --local-address 192.0.2.10 \
  --remote-address 192.0.2.1 \
  --public-key-file ./client.pub
```

所有地址都是文档示例，运行时替换为实际地址：

| 参数 | 含义 |
| --- | --- |
| `--user` | 目标机已有的非 root 登录账户；不会创建账户或授予 sudo 权限 |
| `--local-address` | 目标机允许接受 SSH 登录的本地 IP；支持重复传参、IPv4/IPv6，不接受域名或 CIDR |
| `--remote-address` | 允许连接的客户端来源 IP 或 CIDR 网络；支持重复传参，例如 `198.51.100.0/24`、`2001:db8:1::/64` |
| `--public-key-file` | 客户端公钥文件；恰好一条普通 OpenSSH 公钥，不接受私钥或带 `authorized_keys` 选项的行 |
| `--dry-run` | 校验参数和公钥后输出计划；账户、现有配置、服务及权限冲突在实际执行时检查 |

CIDR 必须使用网络地址，例如 `192.0.2.0/24`，不能写 `192.0.2.1/24`。IPv6 使用十六进制形式，不接受带接口 scope ID 或嵌入点分 IPv4 的地址。

macOS 使用系统自带的 `Remote Login`。首次由命令启用时，`systemsetup` 可能要求运行终端拥有“完全磁盘访问权限”；也可以先在“系统设置 → 通用 → 共享 → 远程登录”中手动打开，再运行脚本。如果“允许访问”选择了“仅这些用户”，还需要包含 `--user` 指定的账户。脚本不会调整这个系统账户列表。

macOS 和 Linux 都会在配置校验前生成缺失的服务端主机密钥；已有主机密钥保持不变。

## Unix 白名单行为与配置保留

Unix 入口在 `/etc/ssh/sshd_config` 末尾维护一个带标记的 `Match` / `DenyUsers` 配置块：**只有选定用户，从指定来源连接指定目标地址，才可能通过 SSH 认证**。这会限制整台机器的 SSH 登录，其他账户也会被拒绝；已有 SSH 会话不会被自动断开。

这是 SSH 认证层的限制，**不是 Windows 版本的网络层防火墙白名单**。Unix 版本不修改 UFW、nftables 或 macOS PF；不合条件的客户端仍可能建立 TCP 连接，但无法通过认证。已有防火墙、路由器及云安全组仍需允许 SSH 流量。SSH 端口、监听器、密码登录策略及原有的其他 SSH 限制保持原样；不会强制仅公钥认证。

- 公钥写入目标用户的 `~/.ssh/authorized_keys`，保留原内容，按普通公钥的类型和密钥主体去重。设置 `.ssh` 为 `700`、授权文件为 `600`；已有目录和授权文件必须由目标用户拥有，否则停止并要求先修正所有权。遇到符号链接会拒绝执行。
- 用户目录中的快照、写入、权限设置和失败回滚都以目标用户身份执行，避免路径在检查后被替换时产生 root 权限写入；公钥通过临时文件替换。Linux 使用 `runuser`，macOS 使用 `sudo` 降权。若路径在运行中被替换导致无法安全恢复，会报告恢复失败，不以 root 强行写入该路径。
- 重复执行会替换整个托管白名单块，遗漏的用户/地址不再获准登录。之前添加的公钥保留在文件中；如更换账户或密钥，需要自行清理不再使用的公钥。
- 读取主配置及递归 `Include` 文件，已有 `DenyUsers` 时停止，避免已有 `Match` 规则覆盖新白名单。支持普通路径和 glob Include；含空格、复杂转义等路径或过深/循环 Include 要先手动协调。
- 在服务启用/重启前执行 `sshd -t`，并通过 `sshd -T -C` 检查所给地址组合的公钥认证与授权文件路径。现有策略仍可能限制账户、认证方式、来源子网等；脚本不会绕过这些限制。自定义 `AuthorizedKeysFile` 未包含标准路径时停止。
- 写入或服务激活失败时恢复本次运行前的主配置和授权文件；Linux 会尽量恢复原服务启用/运行状态。软件包安装、生成的主机密钥、创建的 `/run/sshd` 不回滚。安装 Debian 软件包时临时用 `policy-rc.d` 禁止自动启动，配置验证后才启动 SSH；已有该策略文件时要求先按现有策略安装服务端。
- 配置变更使用 `/etc/ssh/.restricted-openssh.lock` 防止脚本并发执行。进程被强制终止或机器断电后的遗留锁需要确认没有运行中的脚本再清理。

首次配置建议保留控制台，直到客户端真实登录成功。允许列表使用数值地址；如果 DHCP 地址变化，需要更新配置。客户端可使用稳定的 `.local` 主机名；将来源放宽为可信网段意味着该网段内所有设备均进入来源白名单。

## 3. 在客户端配置别名并登录

本次入口只配置服务端。客户端可手动在 `~/.ssh/config` 添加（Windows 对应 `$HOME\.ssh\config`）：

```sshconfig
Host demo-pc
    HostName demo-pc.local
    User demo
    Port 22
    IdentityFile ~/.ssh/id_ed25519_demo
    IdentitiesOnly yes
```

将 `HostName` 换成可解析的目标主机名或 IP；如果目标使用其他端口，相应调整 `Port`。然后在客户端运行：

```bash
ssh demo-pc
```

## 验证与维护

```bash
bash -n openssh/unix/configure-restricted-openssh.sh
bash openssh/tests/test-configure-restricted-openssh.sh
```

测试使用隔离临时目录和服务替身，覆盖 IPv4/IPv6/CIDR、Include 冲突、重复执行、公钥保留、失败回滚、macOS 主机密钥准备，以及写入和回滚时替换文件/目录符号链接的场景。有 `/usr/sbin/sshd` 时还会使用真实 `sshd -t/-T` 检查白名单；不会安装软件、启停系统 SSH 或修改防火墙。通过 `sudo` 运行测试时，用户文件操作会降权为原 sudo 调用者，可验证实际权限切换；所有测试文件仍位于隔离临时目录。

已在 Ubuntu 上验证真实 OpenSSH 配置解析；macOS 的 Remote Login 权限、服务激活及实际远程登录仍需在目标 Mac 上验证。需要撤销 Unix 白名单时，在控制台移除 `sshd_config` 中从 `# BEGIN shell-scripts restricted-openssh` 到对应 `# END` 的整个托管块，校验配置后重启 Linux SSH 服务；macOS 新连接会读取恢复后的配置。删除托管块会解除该工具施加的登录限制。

参考：[OpenSSH sshd_config](https://man.openbsd.org/sshd_config)、[Ubuntu OpenSSH Server](https://ubuntu.com/server/docs/how-to/security/openssh-server/)、[Apple Remote Login](https://support.apple.com/guide/mac-help/allow-a-remote-computer-to-access-your-mac-mchlp1066/mac)、[Apple systemsetup](https://support.apple.com/guide/remote-desktop/about-systemsetup-apd95406b8d/mac)。
