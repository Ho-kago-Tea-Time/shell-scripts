Set-StrictMode -Version Latest

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This command must be run from an elevated PowerShell session.'
    }
}

function Ensure-OpenSshServer {
    <#
    .SYNOPSIS
    Installs and starts the Windows OpenSSH server.
    #>
    [CmdletBinding()]
    param()

    Assert-Administrator

    $capabilityName = 'OpenSSH.Server~~~~0.0.1.0'
    $capability = Get-WindowsCapability -Online -Name $capabilityName -ErrorAction Stop

    if ($capability.State -ne 'Installed') {
        Add-WindowsCapability -Online -Name $capabilityName -ErrorAction Stop | Out-Null
    }

    Set-Service -Name sshd -StartupType Automatic -ErrorAction Stop

    if ((Get-Service -Name sshd -ErrorAction Stop).Status -ne 'Running') {
        Start-Service -Name sshd -ErrorAction Stop
    }

    Get-Service -Name sshd
}

function Set-OpenSshFirewallAllowRule {
    <#
    .SYNOPSIS
    Replaces the SSH firewall allowlist with the supplied addresses.

    .DESCRIPTION
    Multiple local and remote addresses are stored in one firewall rule. Calling
    this function again with the same RuleName removes that rule first, so the
    previous allowlist is not retained.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $LocalAddress,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $RemoteAddress,

        [ValidateNotNullOrEmpty()]
        [string] $RuleName = 'Restricted-OpenSSH-Allowlist'
    )

    Assert-Administrator

    # The inbox rule permits SSH more broadly. Disable it before applying the
    # dedicated allowlist rule below.
    Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue

    # Deliberately replace the rule: omitted addresses must no longer be allowed.
    Remove-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue

    New-NetFirewallRule `
        -Name $RuleName `
        -DisplayName "SSH allowlist: $($RemoteAddress -join ', ')" `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort 22 `
        -LocalAddress $LocalAddress `
        -RemoteAddress $RemoteAddress `
        -Profile Any `
        -ErrorAction Stop
}

function Set-AdministratorsAuthorizedKeysAcl {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    # Disable inheritance and remove all existing access rules. Windows OpenSSH
    # requires administrators_authorized_keys to be writable only by the local
    # Administrators group and SYSTEM.
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($accessRule in @($acl.Access)) {
        [void] $acl.RemoveAccessRuleAll($accessRule)
    }

    foreach ($sidValue in 'S-1-5-32-544', 'S-1-5-18') {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
        $accessRule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void] $acl.AddAccessRule($accessRule)
    }

    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Add-AdminSshAuthorizedKey {
    <#
    .SYNOPSIS
    Adds a public key to the administrator OpenSSH key file without duplicates.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^ssh-(ed25519|rsa|ecdsa)\s+')]
        [string] $PublicKey
    )

    Assert-Administrator

    $sshDirectory = Join-Path $env:ProgramData 'ssh'
    $authorizedKeys = Join-Path $sshDirectory 'administrators_authorized_keys'

    New-Item -ItemType Directory -Path $sshDirectory -Force -ErrorAction Stop | Out-Null
    New-Item -ItemType File -Path $authorizedKeys -Force -ErrorAction Stop | Out-Null

    if (-not (Select-String -LiteralPath $authorizedKeys -SimpleMatch $PublicKey -Quiet)) {
        Add-Content -LiteralPath $authorizedKeys -Value $PublicKey -Encoding ascii -ErrorAction Stop
    }

    Set-AdministratorsAuthorizedKeysAcl -Path $authorizedKeys
}

function Restart-OpenSshServerSafely {
    <#
    .SYNOPSIS
    Validates sshd_config and restarts the OpenSSH server only when valid.
    #>
    [CmdletBinding()]
    param()

    Assert-Administrator

    $sshd = Join-Path $env:WINDIR 'System32\OpenSSH\sshd.exe'
    & $sshd -t
    if ($LASTEXITCODE -ne 0) {
        throw 'OpenSSH configuration validation failed; sshd was not restarted.'
    }

    Restart-Service -Name sshd -ErrorAction Stop
    Get-Service -Name sshd
}

function Test-OpenSshServer {
    <#
    .SYNOPSIS
    Returns the current OpenSSH service, listener, and allowlist rule state.
    #>
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()]
        [string] $RuleName = 'Restricted-OpenSSH-Allowlist'
    )

    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    $rule = Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
    $addressFilter = if ($rule) { $rule | Get-NetFirewallAddressFilter } else { $null }

    [pscustomobject]@{
        ServiceStatus = if ($service) { $service.Status } else { 'NotInstalled' }
        IsListening   = [bool](Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue)
        RuleEnabled   = if ($rule) { $rule.Enabled } else { $false }
        LocalAddress  = if ($addressFilter) { $addressFilter.LocalAddress -join ', ' } else { $null }
        RemoteAddress = if ($addressFilter) { $addressFilter.RemoteAddress -join ', ' } else { $null }
    }
}

Export-ModuleMember -Function Ensure-OpenSshServer, Set-OpenSshFirewallAllowRule, Add-AdminSshAuthorizedKey, Restart-OpenSshServerSafely, Test-OpenSshServer
