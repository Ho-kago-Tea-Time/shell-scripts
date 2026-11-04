# Offline validation only. Never execute or dot-source the installer.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$upstreamDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'windows/upstream'
$source = Get-Content -LiteralPath (Join-Path $upstreamDir 'SOURCE.json') -Raw | ConvertFrom-Json
$installerPath = Join-Path $upstreamDir 'install.ps1'

foreach ($artifact in @($source.script, $source.license_file)) {
    $path = Join-Path $upstreamDir $artifact.file
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($actual -ne $artifact.sha256) {
        throw "SHA-256 mismatch: $($artifact.file). Review upstream changes before updating SOURCE.json."
    }
    Write-Output "PASS SHA-256: $($artifact.file)"
}
if ((Get-Item -LiteralPath $installerPath).Length -ne $source.script.bytes) {
    throw 'Installer byte count differs from SOURCE.json.'
}

$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    $installerPath, [ref]$tokens, [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw (($parseErrors | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
}
Write-Output "PASS PowerShell $($PSVersionTable.PSVersion) parse; installer was not executed."
