<#
.SYNOPSIS
Configures restricted OpenSSH access for a Windows VM.

.EXAMPLE
.\Configure-RestrictedOpenSsh.ps1 `
    -LocalAddress '192.0.2.10' `
    -RemoteAddress '192.0.2.1', '192.0.2.2' `
    -PublicKey 'ssh-ed25519 AAAA... admin@example.invalid'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]] $LocalAddress,

    [Parameter(Mandatory)]
    [string[]] $RemoteAddress,

    [Parameter(Mandatory)]
    [string] $PublicKey,

    [string] $RuleName = 'Restricted-OpenSSH-Allowlist'
)

$modulePath = Join-Path $PSScriptRoot 'OpenSshServerTools.psm1'
Import-Module $modulePath -Force -ErrorAction Stop

Ensure-OpenSshServer
Set-OpenSshFirewallAllowRule `
    -LocalAddress $LocalAddress `
    -RemoteAddress $RemoteAddress `
    -RuleName $RuleName
Add-AdminSshAuthorizedKey -PublicKey $PublicKey
Restart-OpenSshServerSafely

Write-Host "SSH_USER=$env:USERNAME"
Test-OpenSshServer -RuleName $RuleName
