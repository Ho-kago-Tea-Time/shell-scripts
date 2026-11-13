# Thin offline entry point. The complete implementation lives in agents-md-setup.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$forward = @($args)
$skillDir = $env:AGENT_GUIDANCE_SKILL_DIR
if ($forward.Count -gt 0 -and $forward[0] -eq '--skill-dir') {
    if ($forward.Count -lt 2) { throw '--skill-dir requires a skill directory.' }
    $skillDir = $forward[1]
    if ($forward.Count -gt 2) { $forward = @($forward[2..($forward.Count - 1)]) } else { $forward = @() }
}
$nodeHome = $HOME
for ($i = 0; $i -lt $forward.Count; $i++) {
    if ($forward[$i] -eq '--home' -and ($i + 1) -lt $forward.Count) { $nodeHome = $forward[$i + 1] }
}
if (-not $skillDir) {
    $registry = Join-Path $nodeHome '.agents/agents-md-setup.skill-path'
    if (Test-Path -LiteralPath $registry -PathType Leaf) {
        $skillDir = [IO.File]::ReadAllText($registry).TrimEnd("`r", "`n")
    } else { $skillDir = Join-Path $nodeHome '.agents/skills/agents-md-setup' }
}
$generator = Join-Path $skillDir 'scripts/generate.mjs'
if (-not (Test-Path -LiteralPath $generator -PathType Leaf)) {
    throw 'agents-md-setup not found. Use --skill-dir <local-skill-directory> before the command, or set AGENT_GUIDANCE_SKILL_DIR. No downloads performed.'
}
$node = (Get-Command node -CommandType Application -ErrorAction Stop).Source
& $node $generator @forward
exit $LASTEXITCODE
