# Git 托管平台 SSH 配置

英文版：[README.md](./README.md)

生成或复用 SSH 密钥、校验目标账号、上传公钥，并按需配置 SSH 别名。支持：

- GitHub.com，以及自建 GitHub Enterprise Server（GHES）。
- GitLab.com，以及自建 GitLab，包括部署在 Web 子路径下的实例。

## 环境要求

| 系统 | 入口 | 依赖 |
| --- | --- | --- |
| Windows | `windows/Setup-GitSsh.ps1` | Windows PowerShell 5.1 或 PowerShell 7、OpenSSH Client（`ssh-keygen`） |
| macOS / Linux | `unix/setup-git-ssh.sh` | Bash 3.2+、OpenSSH `ssh-keygen`、`curl`、`jq` |

GitHub 默认还需要 `gh`，也可以显式指定 Token 环境变量。GitLab 使用具有 `api` scope 的个人访问令牌。脚本只检查依赖，不自动安装；使用普通用户运行即可，不需要管理员/root 权限。macOS 可能需要额外安装 `jq`。

## GitHub

首次针对对应账号和主机登录，并授予公钥权限：

```text
gh auth login --hostname github.com
gh auth refresh --hostname github.com --scopes read:public_key,write:public_key
```

如果登录过程询问是否由 gh 生成/上传 SSH 密钥，跳过该步骤，交由本脚本处理。多账号环境下，刷新权限前先确认 gh 当前账号。脚本本身通过 `gh auth token --hostname HOST --user ACCOUNT` 选择凭据，并校验 `/user` 返回的实际身份，不切换 gh 全局 active account，也不改 Git 协议设置。

在仓库根目录执行，Windows：

```powershell
.\git\windows\Setup-GitSsh.ps1 -Account YOUR_ACCOUNT -ConfigureSsh
```

macOS / Linux：

```bash
bash git/unix/setup-git-ssh.sh --account YOUR_ACCOUNT --configure-ssh
```

自建 GHES 先通过 gh 登录对应主机，再指定实例 Web 地址：

```powershell
.\git\windows\Setup-GitSsh.ps1 -Provider github -ServerUrl https://github.example.com -Account YOUR_ACCOUNT -ConfigureSsh
```

```bash
bash git/unix/setup-git-ssh.sh --provider github \
  --server-url https://github.example.com --account YOUR_ACCOUNT --configure-ssh
```

GitHub.com 使用 `https://api.github.com`，GHES 使用 `SERVER_URL/api/v3`。首版暂不处理 GitHub Enterprise Cloud 的自定义 `*.ghe.com` 域名映射。

## GitLab

通过环境变量提供 Token。以下示例使用隐藏输入，避免把 Token 写进命令历史。

Windows：

```powershell
$gitSshToken = Read-Host 'GitLab token' -AsSecureString
$env:GITLAB_TOKEN = [Net.NetworkCredential]::new('', $gitSshToken).Password
.\git\windows\Setup-GitSsh.ps1 -Provider gitlab -Account YOUR_ACCOUNT -ConfigureSsh
Remove-Item Env:GITLAB_TOKEN
```

macOS / Linux：

```bash
read -r -s -p 'GitLab token: ' GITLAB_TOKEN
printf '\n'
export GITLAB_TOKEN
bash git/unix/setup-git-ssh.sh --provider gitlab --account YOUR_ACCOUNT --configure-ssh
unset GITLAB_TOKEN
```

默认 Web 地址为 `https://gitlab.com`。自建实例可以分别指定 Web 地址、Web 子路径、SSH 主机和端口：

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

运行前，应将 Token 放入 `WORK_GITLAB_TOKEN` 环境变量。这里 API 地址为 `https://git.example.com:8443/team/api/v4`；SSH 端口独立于 Web 端口。实例地址必须使用 HTTPS 和 DNS/IPv4 主机名；使用私有 CA 时，将 CA 安装到对应客户端信任库。脚本始终校验证书，不跟随 HTTP 重定向。

## 参数

| Bash | PowerShell | 默认值 / 含义 |
| --- | --- | --- |
| `--provider` | `-Provider` | 默认 `github`；支持 `github`、`gitlab` |
| `--server-url` | `-ServerUrl` | `https://github.com` 或 `https://gitlab.com`；传 Web 基础地址，不传 API 地址 |
| `--account` | `-Account` | 必填，预期用户名；必须匹配凭据对应的实际账号 |
| `--token-env` | `-TokenEnv` | Token 所在的环境变量名，不是 Token 内容；GitLab 默认 `GITLAB_TOKEN`，GitHub 默认使用 gh |
| `--type` | `-Type` | 默认 `ed25519`，另支持 `rsa`、`ecdsa` |
| `--bits` | `-Bits` | RSA：2048/3072/4096，默认 4096；ECDSA：256/384/521，默认 256；Ed25519 不接受此参数 |
| `--key-path` | `-KeyPath` | `~/.ssh/id_TYPE_PROVIDER_INSTANCE_ACCOUNT`；INSTANCE 包含域名、自定义 Web 端口/路径，分隔符经过清理 |
| `--title` | `-Title` | 默认 `计算机名-账号`，平台中显示的公钥标题 |
| `--comment` | `-Comment` | 默认 `账号@计算机名`，公钥备注 |
| `--no-passphrase` | `-NoPassphrase` | 创建无口令密钥；默认由 ssh-keygen 交互询问口令 |
| `--configure-ssh` | `-ConfigureSsh` | 配置 SSH 别名，默认关闭 |
| `--ssh-alias` | `-SshAlias` | 官方站默认 `平台-账号`；自建默认 `平台-实例-账号` |
| `--ssh-config-path` | `-SshConfigPath` | 默认 `~/.ssh/config`，可指定独立配置文件 |
| `--ssh-host` | `-SshHost` | 默认 Web 地址中的主机名 |
| `--ssh-port` | `-SshPort` | 默认 22 |
| `--ssh-user` | `-SshUser` | 默认 `git` |
| `--dry-run` | `-DryRun` | 离线展示计划，不读凭据、不请求网络、不写文件 |

例如创建 RSA 密钥：

```powershell
.\git\windows\Setup-GitSsh.ps1 -Account YOUR_ACCOUNT -Type rsa -Bits 4096 -ConfigureSsh
```

```bash
bash git/unix/setup-git-ssh.sh --account YOUR_ACCOUNT --type rsa --bits 4096 --configure-ssh
```

服务端可能限制算法或密钥有效期，以实例策略为准。被拒绝时脚本报错，不静默切换算法。

## 重复运行、配置和失败处理

创建密钥前先验证身份及查询公钥列表的权限。已有私钥不会被替换：脚本从私钥导出公钥，与已有 `.pub` 文件比对；`.pub` 缺失时自动恢复。始终校验算法，显式指定 `bits` 时还会校验位数。已有密钥的口令和备注保持原样；加密私钥在导出公钥时可能再次询问口令。脚本不修改 ssh-agent 服务或系统钥匙串设置。

遍历公钥列表的全部分页，按算法与密钥主体查重，忽略备注。已注册则跳过上传；GitLab 中已过期或仅用于签名的同一密钥需要手动处理。新 GitLab 公钥设为 `usage_type=auth`。上传失败保留本地密钥对，修复授权后可以重跑；失败时不添加 SSH 配置。

`ConfigureSsh` 在配置文件开头添加带标记的配置块，保留原内容，并放在 `Host *` 默认设置之前。相同配置块会复用；已有同名显式别名会报错，包括多个名称共用的 Host 行和普通/通配符 Include 文件。Include 路径含环境变量、Token 展开或其他用户家目录时，需手动编辑配置；条件块中的 Include 也会保守检查。原有通配符规则和 Match 块仍可能添加额外选项（如其他 IdentityFile），使用这些高级配置时应核对最终结果。

例如：

实际生成的管理块末尾还会添加 `Host *`，确保后面原有的全局选项继续作用于全部主机。

```sshconfig
Host gitlab-work
    HostName ssh.example.com
    Port 2222
    User git
    IdentityFile "/home/you/.ssh/id_ed25519_gitlab_git.example.com_8443_team_YOUR_ACCOUNT"
    IdentitiesOnly yes
```

连接和克隆时使用别名：

```bash
ssh -T gitlab-work
git clone gitlab-work:GROUP/REPO.git
```

指定独立配置文件时，使用 `ssh -F PATH`，并相应配置 Git，或在主配置中 Include 此文件。未指定 `configure-ssh` 时，脚本输出带 `ssh -i ...` 的测试命令。脚本不自动连接 SSH：首次连接的主机公钥确认由用户完成，也不改写 Git remote URL。Token 不写入文件、不放进 HTTP 命令行参数。

## 离线开发测试

在仓库根目录运行：

```powershell
.\git\tests\Test-Setup-GitSsh.ps1
```

```bash
bash -n git/unix/setup-git-ssh.sh
bash git/tests/test-setup-git-ssh.sh
```

测试在 `.tools/` 下生成真实的临时 OpenSSH 密钥对，并模拟 API/gh；不访问用户凭据、用户 SSH 目录或真实托管平台。PowerShell 测试需在 Windows 上执行；Bash 测试需要 `jq` 和 OpenSSH。实际 macOS/Linux 及真实服务器集成仍需在对应环境中验证。

接口文档：[GitHub 用户 SSH 公钥](https://docs.github.com/en/rest/users/keys)、[GitLab 用户 SSH 公钥](https://docs.gitlab.com/api/user_keys/)。
