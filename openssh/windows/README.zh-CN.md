# Windows OpenSSH 访问控制

这个目录提供 Windows VM 的 OpenSSH Server 安装、管理员公钥和 SSH 防火墙白名单配置。所有写操作都必须在**管理员 PowerShell**中执行。

## 文件

- `OpenSshServerTools.psm1`：可复用 PowerShell 模块。
- `Configure-RestrictedOpenSsh.ps1`：调用模块的一键配置入口。

## 一键配置

```powershell
.\Configure-RestrictedOpenSsh.ps1 `
    -LocalAddress '192.0.2.10' `
    -RemoteAddress '192.0.2.1', '192.0.2.2' `
    -PublicKey 'ssh-ed25519 AAAA... admin@example.invalid'
```

相同的 `RuleName` 会先被删除再按本次参数创建，因此第二次调用会**替换**白名单；未再次传入的地址不再被允许。内置的 `OpenSSH-Server-In-TCP` 规则会保持禁用，以防它绕过白名单。

## 模块函数

| 函数 | 参数 | 功能 |
| --- | --- | --- |
| `Ensure-OpenSshServer` | 无 | 安装、设为自动启动并启动 `sshd`。 |
| `Set-OpenSshFirewallAllowRule` | `LocalAddress`、`RemoteAddress`、可选 `RuleName` | 以一个规则设置 SSH 白名单；前两个参数均支持多个 IP。 |
| `Add-AdminSshAuthorizedKey` | `PublicKey` | 幂等添加管理员公钥，并将密钥文件 ACL 限制为 Administrators 和 SYSTEM。 |
| `Restart-OpenSshServerSafely` | 无 | 先以 `sshd -t` 校验配置，再重启服务。 |
| `Test-OpenSshServer` | 可选 `RuleName` | 查看服务、22 端口监听和规则白名单状态。 |

`administrators_authorized_keys` 仅适用于管理员账户。普通账户应使用其个人目录中的 `%USERPROFILE%\.ssh\authorized_keys`。
