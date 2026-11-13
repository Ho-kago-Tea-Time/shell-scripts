# 代理指令

为可独立安装的 `agents-md-setup` 技能提供 Windows、macOS/Linux 离线入口。依赖 Node.js >= 18。完整生成器、模板和测试随技能维护；这里仅定位并调用。英文命令示例见 [README.md](./README.md)。

## 安装与使用

选择本地已有技能目录（含 `SKILL.md`、`scripts/generate.mjs`、`assets/`），既可以来自 skills 源码仓库，也可以是独立安装副本。两个仓库不必相邻，不会联网下载或静默更新。

```powershell
.\windows\Invoke-AgentGuidance.ps1 --skill-dir "C:\demo\skills\agents-md-setup" install
.\windows\Invoke-AgentGuidance.ps1 --skill-dir "C:\demo\skills\agents-md-setup" install --apply --review "预览校验值"
.\windows\Invoke-AgentGuidance.ps1 init
# 按当前节点实际情况编辑 ~/.agents/agents-md-setup.custom.md，然后：
.\windows\Invoke-AgentGuidance.ps1 preview
.\windows\Invoke-AgentGuidance.ps1 apply --review "预览校验值"
```

```bash
bash unix/agent-guidance.sh --skill-dir "$HOME/code/skills/skills/agents-md-setup" install
bash unix/agent-guidance.sh --skill-dir "$HOME/code/skills/skills/agents-md-setup" install --apply --review "预览校验值"
bash unix/agent-guidance.sh init
# 编辑本机 custom 后：
bash unix/agent-guidance.sh preview
bash unix/agent-guidance.sh apply --review "预览校验值"
```

- `--skill-dir DIR` 必须位于生成器命令之前；其它参数原样传给生成器。
- 定位顺序：显式 `--skill-dir` → `AGENT_GUIDANCE_SKILL_DIR` → 本地 `~/.agents/agents-md-setup.skill-path` → `~/.agents/skills/agents-md-setup`。失效路径直接报错，不拉远端。`--home DIR` 同时切换定位目录，便于隔离验证。
- `install` 默认只预览；匹配校验值后才应用。完整技能默认复制到 `~/.agents/skills/agents-md-setup`，并登记本地绝对路径；可用 `--destination DIR` 指定其它位置。Claude 技能发现可用技能安装工具映射，或显式安装到 `~/.claude/skills/agents-md-setup`。升级时显式选本地新版，再预览和安装；保留节点 custom。
- `init` 只在 custom 不存在时创建示例。迁移时在仓库之外准备本机 Markdown，用 `init --from FILE` 初始化。已有 custom 始终保留。
- 公共规则维护在技能的 `assets/AGENTS.base.md`；本机路径、账号、主机信息只放本地 custom。生成结果按“简短说明 + 公共全文 + 本机全文”合并，不解析章节或变量。
- Codex 使用实际 `CODEX_HOME/AGENTS.md`，默认 `~/.codex/AGENTS.md`；Claude 的 `~/.claude/CLAUDE.md` 使用原生导入并保留其它用户内容。
- 每次替换都要先查看差异，并提供匹配的预览校验值；手工修改、输入变化后需重新预览。原文件原始字节备份到旁边的 `*.bak-*`。相同结果不写文件。
- 检测并保留 `AGENTS.override.md`；非空时默认阻止应用，明确保留遮蔽才用 `--allow-override`。遇到输出符号链接会停止，先检查其用途。备份、JSON 预览含本地信息，不要提交。

skills 负责理解任务、选择参数、流程编排和检查，专用代码与资源随技能发布。shell-scripts 用于可独立运行的常用脚本。repo-setup、Git SSH 工具、Entire 检查器维持原职责，不搬迁、不复制另一份实现。

## 离线验证

设置 `AGENT_GUIDANCE_TEST_SKILL_DIR` 为独立技能目录，再运行 `node --test tests/entrypoints.test.mjs`；Unix 入口另用 `bash -n unix/agent-guidance.sh` 检查语法。测试仅操作隔离 home，缺少对应 shell 时明确跳过；Windows 可运行 Git Bash，但不能替代原生 macOS/Linux 验证。
