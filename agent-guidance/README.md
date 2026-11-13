# Agent guidance

Offline Windows and macOS/Linux entry points for the independently installable `agents-md-setup` skill. Requires Node.js >= 18. The skill owns the complete generator, templates and tests; these launchers only locate and call it.

Chinese: [README.zh-CN.md](./README.zh-CN.md)

## Locate, install, initialize

Choose an existing local skill directory containing `SKILL.md`, `scripts/generate.mjs` and `assets/`. It can be from a skills checkout or a separately installed package. No assumption about sibling repositories and no remote download or update.

```powershell
# --skill-dir must precede the generator command. Other arguments pass through.
.\windows\Invoke-AgentGuidance.ps1 --skill-dir "C:\demo\skills\agents-md-setup" install
.\windows\Invoke-AgentGuidance.ps1 --skill-dir "C:\demo\skills\agents-md-setup" install --apply --review "HASH_FROM_PREVIEW"
.\windows\Invoke-AgentGuidance.ps1 init
.\windows\Invoke-AgentGuidance.ps1 preview
.\windows\Invoke-AgentGuidance.ps1 apply --review "HASH_FROM_PREVIEW"
```

```bash
bash unix/agent-guidance.sh --skill-dir "$HOME/code/skills/skills/agents-md-setup" install
bash unix/agent-guidance.sh --skill-dir "$HOME/code/skills/skills/agents-md-setup" install --apply --review "HASH_FROM_PREVIEW"
bash unix/agent-guidance.sh init
bash unix/agent-guidance.sh preview
bash unix/agent-guidance.sh apply --review "HASH_FROM_PREVIEW"
```

`install` previews a complete offline copy to `~/.agents/skills/agents-md-setup` and local registration in `~/.agents/agents-md-setup.skill-path`. Apply only after reviewing it. Use `--destination DIR` to select another install location. For Claude skill discovery use a skill installer mapping or explicitly install into `~/.claude/skills/agents-md-setup`. The generator also works directly without installation.

Lookup order: leading `--skill-dir DIR`, `AGENT_GUIDANCE_SKILL_DIR`, local `~/.agents/agents-md-setup.skill-path`, then `~/.agents/skills/agents-md-setup`. A stale explicit/registered path fails with instructions; it never fetches a replacement. `--home DIR` also selects the lookup home, useful for isolated tests. To upgrade, select a newer local source with `--skill-dir` and run install preview/apply again. The launchers do not contain generation or installation logic.

`init` creates `~/.agents/agents-md-setup.custom.md` only when absent. Edit it for the current node before preview/apply. To migrate, prepare local Markdown outside repositories and use `init --from FILE`; existing custom is retained. Public rules live in the skill's `assets/AGENTS.base.md`. Keep real hostnames, usernames and private paths only in local custom.

Output is a short notice, all public rules, then all local Markdown. Codex uses actual `CODEX_HOME/AGENTS.md`, defaulting to `~/.codex/AGENTS.md`. Claude uses a native import in `~/.claude/CLAUDE.md`, retaining other content. Overrides are reported and retained; a nonempty `AGENTS.override.md` blocks apply unless acknowledged with `--allow-override`. Outputs that are symlinks require manual inspection. Every replacement requires a matching preview hash and first backs up original bytes beside the file. Repeated identical generation does not write. Keep backups and JSON previews private.

The skill handles task interpretation and checks, with its specialized code/resources. This repository contains independently runnable common scripts. Existing repo-setup, Git SSH and Entire tools keep their own roles; no relocation is required.

## Offline verification

```powershell
$env:AGENT_GUIDANCE_TEST_SKILL_DIR = 'C:\demo\skills\agents-md-setup'
node --test tests/entrypoints.test.mjs
```

```bash
AGENT_GUIDANCE_TEST_SKILL_DIR="$HOME/code/skills/skills/agents-md-setup" node --test tests/entrypoints.test.mjs
bash -n unix/agent-guidance.sh
```

Tests use isolated homes and run each locally available shell; missing shells are explicitly skipped. Windows also checks Git Bash when available. This does not substitute for running the Unix entry point on native macOS/Linux.
