#!/usr/bin/env bash
# Thin offline entry point. The complete implementation lives in agents-md-setup.
set -euo pipefail
skill_dir=${AGENT_GUIDANCE_SKILL_DIR:-}
if [[ ${1:-} == --skill-dir ]]; then
  [[ $# -ge 2 ]] || { printf '%s\n' '--skill-dir requires a skill directory.' >&2; exit 1; }
  skill_dir=$2
  shift 2
fi
node_home=$HOME
forward=("$@")
for ((i=0; i<${#forward[@]}; i++)); do
  if [[ ${forward[i]} == --home && $((i+1)) -lt ${#forward[@]} ]]; then
    node_home=${forward[i+1]}
  fi
done
# Git Bash accepts Windows registry values through cygpath; macOS/Linux need none.
as_shell_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s\n' "$1"; fi
}
node_home=$(as_shell_path "$node_home")
if [[ -z $skill_dir ]]; then
  registry=$node_home/.agents/agents-md-setup.skill-path
  if [[ -f $registry ]]; then
    IFS= read -r skill_dir < "$registry" || [[ -n $skill_dir ]]
    skill_dir=${skill_dir%$'\r'}
  else skill_dir=$node_home/.agents/skills/agents-md-setup
  fi
fi
skill_dir=$(as_shell_path "$skill_dir")
generator=$skill_dir/scripts/generate.mjs
[[ -f $generator ]] || {
  printf '%s\n' 'agents-md-setup not found. Use --skill-dir <local-skill-directory> before the command, or set AGENT_GUIDANCE_SKILL_DIR. No downloads performed.' >&2
  exit 1
}
exec node "$generator" "$@"
