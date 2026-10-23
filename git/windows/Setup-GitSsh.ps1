<#
.SYNOPSIS
Creates/reuses an SSH key and registers it with GitHub or GitLab.
.DESCRIPTION
Supports github.com, GitHub Enterprise Server, gitlab.com, and self-managed GitLab.
Use -DryRun for an offline plan. Run Get-Help ./Setup-GitSsh.ps1 -Detailed for parameters.
Requires Windows PowerShell 5.1 or PowerShell 7 and OpenSSH ssh-keygen.
.EXAMPLE
.\Setup-GitSsh.ps1 -Account Finasia -ConfigureSsh
.EXAMPLE
.\Setup-GitSsh.ps1 -Provider gitlab -ServerUrl https://git.example.com -Account fancier -TokenEnv GITLAB_TOKEN -Type rsa -Bits 4096 -ConfigureSsh
#>
[CmdletBinding()]
param(
    [ValidateSet('github', 'gitlab')][string] $Provider = 'github',
    [string] $ServerUrl,
    [string] $Account,
    [string] $TokenEnv,
    [ValidateSet('ed25519', 'rsa', 'ecdsa')][string] $Type = 'ed25519',
    [int] $Bits,
    [string] $KeyPath,
    [string] $Title,
    [string] $Comment,
    [switch] $NoPassphrase,
    [switch] $ConfigureSsh,
    [string] $SshConfigPath,
    [string] $SshAlias,
    [string] $SshHost,
    [int] $SshPort = 22,
    [string] $SshUser = 'git',
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Do not expose credentials if the caller enabled PowerShell script tracing.
Set-PSDebug -Off
$Provider = $Provider.ToLowerInvariant()
$Type = $Type.ToLowerInvariant()
$utf8 = New-Object System.Text.UTF8Encoding($false)
$bitsExplicit = $PSBoundParameters.ContainsKey('Bits')

function Write-Info([string] $Message) { Write-Host "[INFO] $Message" }

function Invoke-Native {
    param([string] $FilePath, [string[]] $Arguments, [switch] $CaptureOutput, [switch] $QuietError)
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = (Get-Command $FilePath -CommandType Application -ErrorAction Stop).Source
    $start.UseShellExecute = $false
    if ($null -ne $start.PSObject.Properties['ArgumentList']) {
        foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    } else {
        # Windows PowerShell 5.1: preserve empty arguments and quoted Windows paths.
        $quoted = foreach ($argument in $Arguments) {
            $escaped = [regex]::Replace($argument, '(\\*)"', '$1$1\"')
            $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
            '"' + $escaped + '"'
        }
        $start.Arguments = $quoted -join ' '
    }
    $start.RedirectStandardOutput = $CaptureOutput.IsPresent
    $start.RedirectStandardError = $QuietError.IsPresent
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    try {
        [void] $process.Start()
        # gh errors are short; async read also prevents pipe-buffer deadlocks.
        if ($QuietError) { $errorTask = $process.StandardError.ReadToEndAsync() }
        if ($CaptureOutput) { $output = $process.StandardOutput.ReadToEnd() }
        $process.WaitForExit()
        if ($QuietError) { [void] $errorTask.GetAwaiter().GetResult() }
        if ($process.ExitCode -ne 0) { throw "$FilePath failed (exit $($process.ExitCode))." }
        if ($CaptureOutput) { return $output.Trim() }
    } finally { $process.Dispose() }
}

function Write-Utf8File([string] $Path, [string] $Text) {
    # CreateNew is intentionally used for keys: never truncate an existing file.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $bytes = $utf8.GetBytes($Text); $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
}

function Protect-PrivateKey([string] $Path) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = Get-Acl -LiteralPath $Path
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]) -ne $identity) {
        throw "Private key must be owned by the current Windows user: $Path"
    }
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void] $acl.RemoveAccessRuleSpecific($rule) }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')))
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($system, 'FullControl', 'Allow')))
    # Persist only the changed access section; Set-Acl may also request audit privileges.
    if ($PSVersionTable.PSEdition -eq 'Desktop') { [IO.File]::SetAccessControl($Path, $acl) }
    else { [IO.FileSystemAclExtensions]::SetAccessControl((New-Object IO.FileInfo($Path)), $acl) }
}

function Assert-RegularPath([string] $Path) {
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Expected a regular file, not a directory or link: $Path"
        }
    }
}

if ($Account -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') { throw 'A valid -Account is required.' }
switch ($Type) {
    ed25519 { if ($bitsExplicit) { throw 'Ed25519 does not accept -Bits.' } }
    rsa {
        if (-not $bitsExplicit) { $Bits = 4096 }
        if ($Bits -notin 2048, 3072, 4096) { throw 'RSA bits: 2048, 3072, 4096.' }
    }
    ecdsa {
        if (-not $bitsExplicit) { $Bits = 256 }
        if ($Bits -notin 256, 384, 521) { throw 'ECDSA bits: 256, 384, 521.' }
    }
}
if (-not $ServerUrl) { $ServerUrl = "https://$Provider.com" }
$ServerUrl = $ServerUrl.TrimEnd('/')
if ($ServerUrl -cnotmatch '^https://([a-zA-Z0-9][a-zA-Z0-9.-]*)(:([0-9]+))?(/[a-zA-Z0-9._~/-]*)?$') {
    throw 'Server URL must be HTTPS with a DNS/IPv4 host and optional port/path; no credentials, query, or fragment.'
}
$serverUri = [uri] $ServerUrl
if (-not $serverUri.IsAbsoluteUri -or $serverUri.Port -lt 1 -or $serverUri.Port -gt 65535) { throw 'Invalid HTTPS URL/port.' }
$instance = ($ServerUrl.Substring(8).ToLowerInvariant() -replace '[^a-z0-9._-]', '_')
if ($Provider -eq 'github' -and $ServerUrl -ceq 'https://github.com') { $apiUrl = 'https://api.github.com' }
elseif ($Provider -eq 'github') { $apiUrl = "$ServerUrl/api/v3" }
else { $apiUrl = "$ServerUrl/api/v4" }
if (-not $SshHost) { $SshHost = $serverUri.DnsSafeHost }
if ($SshHost -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.:-]*$') { throw 'Invalid SSH hostname.' }
if ($SshUser -notmatch '^[a-zA-Z0-9_][a-zA-Z0-9._-]*$') { throw 'Invalid SSH user.' }
if ($SshPort -lt 1 -or $SshPort -gt 65535) { throw 'SSH port must be 1..65535.' }
if (-not $SshAlias) {
    if ($ServerUrl -ceq "https://$Provider.com") { $SshAlias = "$Provider-$Account" }
    else { $SshAlias = "$Provider-$instance-$Account" }
}
if ($SshAlias -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') { throw 'Invalid SSH alias; use letters, numbers, dot, underscore, or hyphen.' }
if (-not $KeyPath) { $KeyPath = Join-Path $HOME ".ssh/id_${Type}_${Provider}_${instance}_${Account}" }
elseif ($KeyPath -match '^~[/\\]') { $KeyPath = Join-Path $HOME $KeyPath.Substring(2) }
$KeyPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($KeyPath)
if (-not $Title) { $Title = "$env:COMPUTERNAME-$Account" }
if (-not $Comment) { $Comment = "$Account@$env:COMPUTERNAME" }
foreach ($value in @($KeyPath, $Title, $Comment)) {
    if ($value -match '[\r\n]') { throw 'Paths, titles, and comments must be single-line values.' }
}
if ($TokenEnv -and $TokenEnv -notmatch '^[a-zA-Z_][a-zA-Z0-9_]*$') { throw 'Invalid token environment variable name.' }
if ($Provider -eq 'gitlab' -and -not $TokenEnv) { $TokenEnv = 'GITLAB_TOKEN' }
if (-not $SshConfigPath) { $SshConfigPath = Join-Path $HOME '.ssh/config' }
elseif ($SshConfigPath -match '^~[/\\]') { $SshConfigPath = Join-Path $HOME $SshConfigPath.Substring(2) }
$configPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SshConfigPath)
if ($configPath -match '[\r\n]') { throw 'Config path must be a single-line value.' }
$identityPath = $KeyPath.Replace('\', '/').Replace('"', '\"').Replace('%', '%%')
$block = @"
# BEGIN setup-git-ssh $SshAlias
Host $SshAlias
    HostName $SshHost
    Port $SshPort
    User $SshUser
    IdentityFile "$identityPath"
    IdentitiesOnly yes
Host *
# END setup-git-ssh $SshAlias
"@ -replace "`r`n", "`n"

function Assert-IncludedConfigAliases {
    param([string] $Path, [int] $Depth, [System.Collections.Generic.HashSet[string]] $Visited)
    if ($Depth -gt 32) { throw 'Too many nested SSH Include directives.' }
    if (-not $Visited.Add([IO.Path]::GetFullPath($Path))) { return }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $clean = ($line -split '#', 2)[0].Trim()
        if ($clean -notmatch '^(Host|Include)(?:\s+|=)(.+)$') { continue }
        $keyword = $Matches[1]
        $values = [regex]::Matches($Matches[2], '"([^"]*)"|(\S+)')
        foreach ($valueMatch in $values) {
            $value = $valueMatch.Value.Trim('"')
            if ($keyword -ieq 'Host' -and $Depth -gt 0 -and $value -ieq $SshAlias) {
                throw "SSH alias '$SshAlias' already exists in included file: $Path"
            }
            if ($keyword -ine 'Include') { continue }
            if ($value -match '[$%]') { throw 'Include paths using environment/token expansion require manual SSH config editing.' }
            if ($value -match '^~[/\\]') { $pattern = Join-Path $HOME $value.Substring(2) }
            elseif ($value.StartsWith('~')) { throw 'Include paths for other home directories require manual SSH config editing.' }
            elseif ([IO.Path]::IsPathRooted($value)) { $pattern = $value }
            else { $pattern = Join-Path (Join-Path $HOME '.ssh') $value }
            if (Test-Path -LiteralPath $pattern -PathType Leaf) { $included = @(Get-Item -LiteralPath $pattern -Force) }
            else { $included = @(Get-Item -Path $pattern -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer }) }
            foreach ($item in $included) { Assert-IncludedConfigAliases $item.FullName ($Depth + 1) $Visited }
        }
    }
}

function Test-SshConfig {
    if (-not $ConfigureSsh) { return $false }
    Assert-RegularPath $configPath
    if (-not (Test-Path -LiteralPath $configPath)) { return $false }
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    Assert-IncludedConfigAliases $configPath 0 $visited
    $text = [IO.File]::ReadAllText($configPath).Replace("`r`n", "`n")
    $marker = [regex]::Escape($SshAlias)
    $pattern = '(?m)^# BEGIN setup-git-ssh ' + $marker + '\n[\s\S]*?^# END setup-git-ssh ' + $marker + '(?=\n|$)'
    $blocks = [regex]::Matches($text, $pattern)
    if ($blocks.Count -gt 1 -or ($blocks.Count -eq 1 -and $blocks[0].Value -cne $block)) {
        throw "Managed SSH alias '$SshAlias' differs; choose -SshAlias or edit $configPath manually."
    }
    $remaining = [regex]::Replace($text, $pattern, '')
    if ($remaining -match ('(?m)^# (BEGIN|END) setup-git-ssh ' + $marker + '$')) { throw 'Incomplete managed SSH block.' }
    foreach ($line in ($remaining -split "`n")) {
        $clean = ($line -split '#', 2)[0].Trim()
        if ($clean -match '^Host(?:\s+|=)(.+)$') {
            foreach ($name in ($Matches[1] -split '\s+')) {
                if ($name.Trim('"') -ieq $SshAlias) { throw "SSH alias '$SshAlias' already exists; choose -SshAlias or edit $configPath manually." }
            }
        }
    }
    return ($blocks.Count -eq 1)
}

[void] (Test-SshConfig)
Assert-RegularPath $KeyPath
Assert-RegularPath "$KeyPath.pub"
if ((Test-Path -LiteralPath "$KeyPath.pub") -and -not (Test-Path -LiteralPath $KeyPath)) { throw 'Public key exists without the private key; choose another -KeyPath.' }
Write-Info "Provider: $Provider; server: $ServerUrl; expected account: $Account"
Write-Info "Key: $KeyPath; algorithm: $Type"
if ($DryRun) {
    if (Test-Path -LiteralPath $KeyPath) { Write-Info 'Would validate and reuse the existing private key.' }
    else { Write-Info 'Would generate a new key.' }
    Write-Info "Would verify identity, list keys, and upload if absent using $apiUrl."
    if ($ConfigureSsh) { Write-Host $block }
    return
}
if ($env:OS -ne 'Windows_NT') { throw 'Use git/unix/setup-git-ssh.sh on macOS/Linux.' }
if (-not (Get-Command ssh-keygen -CommandType Application -ErrorAction SilentlyContinue)) { throw 'Install the Windows OpenSSH Client (ssh-keygen) and rerun.' }
$token = $null
try {
    if ($TokenEnv) {
        $token = [Environment]::GetEnvironmentVariable($TokenEnv)
        if (-not $token) { throw "Environment variable $TokenEnv is empty." }
    } else {
        try { $token = Invoke-Native gh @('auth', 'token', '--hostname', $serverUri.Authority, '--user', $Account) -CaptureOutput -QuietError }
        catch { throw "No usable gh credential for $Account on $($serverUri.Authority). Install gh and run: gh auth login --hostname $($serverUri.Authority), or use -TokenEnv NAME." }
    }
    if (-not $token -or $token -match '[\s"\\]') { throw 'Token is empty or contains unsupported whitespace/quote/backslash characters.' }
    # TLS 1.2 is needed by GitHub when running under Windows PowerShell 5.1.
    $oldTls = [Net.ServicePointManager]::SecurityProtocol
    [Net.ServicePointManager]::SecurityProtocol = $oldTls -bor [Net.SecurityProtocolType]::Tls12

    function Invoke-GitApi {
        param([string] $Method, [string] $Endpoint, [hashtable] $Body)
        $request = @{
            Uri = "$apiUrl$Endpoint"; Method = $Method
            Headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
            MaximumRedirection = 0; TimeoutSec = 60; ErrorAction = 'Stop'
            Verbose = $false; Debug = $false
        }
        if ($Body) { $request.ContentType = 'application/json; charset=utf-8'; $request.Body = $utf8.GetBytes(($Body | ConvertTo-Json -Compress)) }
        try { return ,(Invoke-RestMethod @request) }
        catch {
            $status = 'connection/TLS error'
            if ($null -ne $_.Exception.PSObject.Properties['Response'] -and $null -ne $_.Exception.Response) {
                $status = [int] $_.Exception.Response.StatusCode
            }
            throw "API $Method $Endpoint failed ($status). Check URL, trusted TLS, account, permissions, and key policy. GitHub needs read:public_key/write:public_key; GitLab PAT needs api. Local keys are retained."
        }
    }

    $user = Invoke-GitApi GET /user
    if ($Provider -eq 'github') { $actual = $user.login } else { $actual = $user.username }
    if (-not $actual -or $actual -ine $Account) { throw "Credential belongs to '$actual', expected '$Account'. No key was created or uploaded." }
    Write-Info "Verified account: $actual"
    $remoteKeys = New-Object 'System.Collections.Generic.List[object]'
    $page = 1
    do {
        $response = Invoke-GitApi GET "/user/keys?per_page=100&page=$page"
        if ($response -isnot [array]) { throw 'Unexpected public-key list response (expected an array).' }
        $keys = @($response)
        foreach ($key in $keys) {
            if ($null -eq $key -or $null -eq $key.PSObject.Properties['key'] -or $key.key -isnot [string]) { throw 'Unexpected public-key list response.' }
            $remoteKeys.Add($key)
        }
        $page++
    } while ($keys.Count -eq 100)

    if (-not (Test-Path -LiteralPath $KeyPath)) {
        $parent = Split-Path -Parent $KeyPath
        [void] [IO.Directory]::CreateDirectory($parent)
        $stage = Join-Path $parent ('.setup-git-ssh.' + [guid]::NewGuid().ToString('N'))
        [void] [IO.Directory]::CreateDirectory($stage)
        $stagedKey = Join-Path $stage 'key'
        try {
            $arguments = @('-q', '-t', $Type, '-f', $stagedKey, '-C', $Comment)
            if ($Bits) { $arguments += @('-b', "$Bits") }
            if ($NoPassphrase) { $arguments += @('-N', '') }
            Invoke-Native ssh-keygen $arguments
            Protect-PrivateKey $stagedKey
            # File.Move on .NET Framework refuses existing destinations.
            [IO.File]::Move($stagedKey, $KeyPath)
            [IO.File]::Move("$stagedKey.pub", "$KeyPath.pub")
        } finally {
            # Delete only the two known generated files and the now-empty staging directory.
            foreach ($generated in @($stagedKey, "$stagedKey.pub")) {
                if ([IO.File]::Exists($generated)) { [IO.File]::Delete($generated) }
            }
            if ([IO.Directory]::Exists($stage)) { [IO.Directory]::Delete($stage) }
        }
    }
    Protect-PrivateKey $KeyPath
    $derived = Invoke-Native ssh-keygen @('-y', '-f', $KeyPath) -CaptureOutput
    $parts = $derived -split '\s+'
    if ($parts.Count -lt 2) { throw 'Invalid derived public key.' }
    $normalized = "$($parts[0]) $($parts[1])"
    $validType = switch ($Type) {
        ed25519 { $parts[0] -ceq 'ssh-ed25519' }
        rsa { $parts[0] -ceq 'ssh-rsa' }
        ecdsa { $parts[0] -cmatch '^ecdsa-sha2-nistp(256|384|521)$' }
    }
    if (-not $validType) { throw "Existing private key is not $Type; choose another -KeyPath or -Type." }
    if (Test-Path -LiteralPath "$KeyPath.pub") {
        $lines = @([IO.File]::ReadAllLines("$KeyPath.pub") | Where-Object { $_.Trim() })
        if ($lines.Count -ne 1) { throw 'Public key file must contain exactly one key.' }
        $publicParts = $lines[0].Trim() -split '\s+'
        if ($publicParts.Count -lt 2 -or "$($publicParts[0]) $($publicParts[1])" -cne $normalized) { throw 'Public key does not match the private key; no key was uploaded.' }
    } else { Write-Utf8File "$KeyPath.pub" "$normalized $Comment`n" }
    $fingerprint = Invoke-Native ssh-keygen @('-lf', "$KeyPath.pub", '-E', 'sha256') -CaptureOutput
    $actualBits = [int] ($fingerprint -split '\s+')[0]
    if ($bitsExplicit -and $actualBits -ne $Bits) { throw "Existing private key has $actualBits bits, requested $Bits." }
    $matching = @($remoteKeys | Where-Object {
        $remoteParts = $_.key.Trim() -split '\s+'
        $remoteParts.Count -ge 2 -and "$($remoteParts[0]) $($remoteParts[1])" -ceq $normalized
    })
    if ($matching.Count) {
        if ($Provider -eq 'gitlab') {
            $usable = @($matching | Where-Object {
                $signingOnly = $null -ne $_.PSObject.Properties['usage_type'] -and $_.usage_type -eq 'signing'
                $expired = $null -ne $_.PSObject.Properties['expires_at'] -and $_.expires_at -and ([datetimeoffset] $_.expires_at).UtcDateTime -le [datetime]::UtcNow
                -not $signingOnly -and -not $expired
            })
            if (-not $usable.Count) { throw 'Matching GitLab key is signing-only or expired; update it manually.' }
        }
        Write-Info 'Public key already registered; upload skipped.'
    } else {
        $body = @{ title = $Title; key = [IO.File]::ReadAllText("$KeyPath.pub").Trim() }
        if ($Provider -eq 'gitlab') { $body.usage_type = 'auth' }
        [void] (Invoke-GitApi POST /user/keys $body)
        Write-Info 'Public key added successfully.'
    }
    if ($ConfigureSsh) {
        if (-not (Test-SshConfig)) {
            [void] [IO.Directory]::CreateDirectory((Split-Path -Parent $configPath))
            $original = ''
            if ([IO.File]::Exists($configPath)) { $original = [IO.File]::ReadAllText($configPath) }
            $configStage = $configPath + '.tmp.' + [guid]::NewGuid().ToString('N')
            try {
                # Specific values must precede existing Host * defaults.
                Write-Utf8File $configStage "$block`n`n$original"
                if ([IO.File]::Exists($configPath)) { [IO.File]::Replace($configStage, $configPath, [NullString]::Value) }
                else { [IO.File]::Move($configStage, $configPath) }
            } finally { if ([IO.File]::Exists($configStage)) { [IO.File]::Delete($configStage) } }
            Write-Info "SSH alias configured: $SshAlias"
        } else { Write-Info "SSH alias already configured: $SshAlias" }
    }
    Write-Info "Fingerprint: $fingerprint"
    if ($ConfigureSsh) {
        Write-Host "Test: ssh -T $SshAlias"
        Write-Host "Clone: git clone ${SshAlias}:OWNER/REPO.git"
    } else { Write-Host "Test: ssh -T -o IdentitiesOnly=yes -i `"$KeyPath`" -p $SshPort $SshUser@$SshHost" }
} finally {
    $token = $null
    if (Test-Path variable:oldTls) { [Net.ServicePointManager]::SecurityProtocol = $oldTls }
}
