# OpenClaw Windows 安装脚本

在本仓库独立保存官方脚本，避免安装器随 OpenClaw 源码仓库切换分支而变化。当前直接使用 [windows/upstream/install.ps1](./windows/upstream/install.ps1)，与上游逐字节一致，无本地功能修改，也不在运行时重新下载安装器。

英文说明：[README.md](./README.md)。来源、固定提交和摘要见 [SOURCE.json](./windows/upstream/SOURCE.json)，上游 MIT 许可证见 [LICENSE](./windows/upstream/LICENSE)。作者为 OpenClaw 项目贡献者，许可证版权声明为 OpenClaw Foundation；原脚本没有单独的作者声明，原有注释完整保留。

## 从已有本地仓库安装

需要 Windows PowerShell 5.1 或 PowerShell 7，以及可用的 Git 和网络。安装器会检查 Node.js 版本、目标仓库的 `engines.node` 和 SQLite 能力，必要时安装或更新 Node；不要因为本机有 Node 就假定无需变更运行环境。

先由我们准备好完整的 OpenClaw 本地仓库、切到自己的分支，并检查当前提交与工作区。下面的路径和分支名都是占位示例；自行替换。在 `shell-scripts` 根目录运行：

```powershell
git -C 'C:\src\openclaw' switch YOUR_BRANCH
git -C 'C:\src\openclaw' status --short --branch
git -C 'C:\src\openclaw' rev-parse HEAD
```

确认源码版本和维护窗口、备份等运维准备完成后，实际安装命令是：

```powershell
& .\openclaw\windows\upstream\install.ps1 `
    -InstallMethod git `
    -GitDir 'C:\src\openclaw' `
    -NoGitUpdate `
    -NoOnboard
```

安装器可以从 OpenClaw 源码目录外运行；也可以用它的绝对路径调用。`-GitDir` 应指向已有提交、包含 `.git` 的仓库根目录，优先使用普通 checkout。路径缺失时，上游即使带 `-NoGitUpdate` 仍可能克隆官方仓库，因此必须先确认目标已经存在且是我们的分支。安装器不验证分支、remote 或 HEAD 是否符合预期。

| 参数 | 本次收录版本的实际行为 |
| --- | --- |
| `-InstallMethod git` | 使用 `-GitDir` 下当前源码安装。默认方法是 npm，必须显式选择 git。 |
| `-Tag` | 不参与 Git 安装流程的分支、tag 或 commit 选择；不要用它选择源码版本。官网示例和脚本中的一条提示包含 `-InstallMethod git -Tag main`，但此快照的 Git 流程并不读取 `Tag`。 |
| `-NoGitUpdate` | 仅跳过 Git 更新/`pull --rebase`；不跳过依赖安装、锁文件修改、编译或其他安装动作。 |
| `-NoOnboard` | 仅跳过首次交互设置，不跳过 Doctor 或 Gateway 服务处理。 |
| `-DryRun` | 预览参数，提前返回；不证明目标仓库、依赖或实际安装可成功。前置逻辑仍会解析临时目录并设置当前进程的 TEMP/TMP，故不把它当作零副作用验证。 |

实际安装会使用仓库声明的 pnpm（缺失版本声明时可退回 latest），执行带 `--no-frozen-lockfile` 的依赖安装、`ui:build`、`build`；安装失败会删除目标仓库的 `node_modules` 后重试一次。构建可能执行仓库及依赖的生命周期脚本并改写锁文件、构建产物。随后安装 `%USERPROFILE%\.local\bin\openclaw.cmd` 启动器并可能修改用户 PATH；如检测到旧 npm 安装，在 Git 替代安装通过验证后退役旧包。已加载 Gateway 服务会被 `gateway install --force` 更新并重启；Git 安装会调用 `doctor --fix --non-interactive` 迁移配置。上述参数组合不是纯编译命令，也不是仅预览；此安装器没有跳过 Doctor 或服务刷新的开关。

## 收录边界与差异

- 2026-11-04 核对：[官网入口](https://openclaw.ai/install.ps1) 返回 HTTP 200，无跳转；与 [固定源码提交](https://github.com/openclaw/openclaw/blob/6210f1275c4f7b30bb72fbbc28ef59874ea444cf/scripts/install.ps1) 内容完全一致，104073 字节，SHA-256 为 `39854b15b78039ae7d36d523ba57bb9f13c1b8900684d87371f79a277642f217`。
- 核对时 main 的固定提交是 `6210f1275c4f7b30bb72fbbc28ef59874ea444cf`；该文件最近变更提交是 `6c4a948c3049f379007fc7702faf42f3cea8558f`。两处固定源码与官网下载副本均核对过摘要。内容一致不代表知道官网部署提交。
- 本地对安装器的差异为零；新增的来源记录、说明和离线验证由本仓库维护。`.gitattributes` 对脚本和许可证禁用换行转换，以保持下载字节和摘要。
- 静态核对未发现安装器依赖旁边的 `.ps1`、模块或源码相对路径，无需再收录运行时配套文件。生成的网络超时常量已内嵌；注释中的生成器是上游维护工具，不是执行依赖。运行时仍需要目标 OpenClaw 仓库的 `package.json`、包管理配置及构建脚本等完整源码，也需要下载工具链和依赖，不能把它当作离线安装包。
- 这是安装器快照；安装器提交不等于待安装的 OpenClaw 版本，也没有固定工具链或依赖下载内容。应用源码版本由我们事先选择的本地分支/HEAD 决定。

## 安全验证

在 `shell-scripts` 根目录运行以下离线检查；它只比对脚本、许可证的 SHA-256、字节数并做 PowerShell AST 解析，绝不执行或 dot-source 安装器：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\openclaw\tests\Test-InstallerSnapshot.ps1
pwsh -NoProfile -File .\openclaw\tests\Test-InstallerSnapshot.ps1
```

`-ExecutionPolicy Bypass` 仅对这个验证进程生效，不修改持久执行策略。首次收录在 Windows PowerShell 5.1.22621.6133 和 PowerShell 7.6.5 上通过上述检查；经审查 `-Help` 的提前返回位置后，也在两个独立的 `-NoProfile` 进程中验证了帮助输出。没有运行实际安装、Doctor、PATH 写入或 Gateway 服务命令；没有验证真实构建与升级。

## 以后人工同步或定制

1. 保留当前 `upstream/` 基线。先将新候选下载到仓库外临时目录（例如 `$HOME\tmp`），只下载，不执行。对 main 先解析完整提交 SHA，再下载该 SHA 下的 `scripts/install.ps1` 和 `LICENSE`，同时另存官网入口的副本；不要仅保存会移动的 main/latest 链接。
2. 记录日期、最终 URL、固定提交、文件最近变更提交、Git blob、字节数和 SHA-256。比较官网和固定源码；若不一致，分别保存两份候选及各自摘要并查清来源，明确选用哪份，不能声称二者相同或凭相似内容推断部署提交。
3. 用 `git diff --no-index -- <旧文件> <候选文件>` 人工审查（退出码 1 表示有差异）。重点看 Git 选择与更新逻辑、依赖/锁文件/Node 要求、下载地址、PATH、旧安装处理、Doctor、服务处理和新引入的配套依赖，同时检查许可证。脚本帮助与文档也要重新核对。
4. 审查后按原始字节替换 `upstream/install.ps1` 和必要的许可证，更新 `SOURCE.json` 及本说明；在 5.1 和 7 中重新离线解析。在重新确认 `-Help` 路径安全后，才以独立进程检查帮助。不要把真正安装当作验证的一部分。
5. 将来确有直接安装需求时，再从基线创建 `windows/install.ps1` 定制副本，并另记补丁目的、上游基线和差异；保留 `upstream/` 原样便于三方比较。当前直接安装已有源码的需求已由原版满足，不创建重复副本或自动更新包装。

提交或推送属于后续单独操作，须遵守仓库的 Entire 发布要求。
