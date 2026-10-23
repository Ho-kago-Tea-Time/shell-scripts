# Offline tests with real Windows OpenSSH keys and a simulated REST transport.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$targetScript = Join-Path $repo 'git/windows/Setup-GitSsh.ps1'
$root = Join-Path $repo ('.tools/git-ssh-powershell-tests.' + [guid]::NewGuid().ToString('N'))
[void] [IO.Directory]::CreateDirectory($root)
$previousToken = [Environment]::GetEnvironmentVariable('GIT_SSH_TEST_TOKEN')
$env:GIT_SSH_TEST_TOKEN = 'test-secret'
$script:passed = 0
$script:state = $null

function Invoke-RestMethod {
    param($Uri, $Method, $Headers, $MaximumRedirection, $TimeoutSec, $ErrorAction, $Verbose, $Debug, $ContentType, $Body)
    try {
    if ($Headers.Authorization -cne 'Bearer test-secret') { throw 'Wrong authorization header.' }
    if ($MaximumRedirection -ne 0) { throw 'Redirects must be disabled.' }
    $mock = $global:GitSshTestState
    if (-not $Uri.StartsWith($mock.ApiUrl + '/', [StringComparison]::Ordinal)) { throw "Unexpected API base: $Uri" }
    $endpoint = $Uri.Substring($mock.ApiUrl.Length)
    $mock.Requests.Add("$Method $endpoint")
    if ($Method -eq 'GET' -and $endpoint -eq '/user') {
        return [pscustomobject] @{ login = $mock.Account; username = $mock.Account }
    }
    if ($Method -eq 'GET' -and $endpoint.StartsWith('/user/keys?')) {
        if ($mock.FailList) { throw 'Simulated permission failure.' }
        if ($mock.Paginate -and $endpoint.EndsWith('page=1')) {
            return ,@(0..99 | ForEach-Object { [pscustomobject] @{ key = "ssh-ed25519 FAKE$_" } })
        }
        return ,@($mock.Keys)
    }
    if ($Method -eq 'POST' -and $endpoint -eq '/user/keys') {
        $payload = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        $mock.Uploads.Add($payload)
        if ($mock.FailUpload) { throw 'Simulated upload failure.' }
        $mock.Keys = @($payload)
        return $payload
    }
    throw "Unexpected endpoint: $Method $endpoint"
    } catch { $global:GitSshTransportFailure = $_.Exception.Message; throw }
}

function New-Case([string] $Name) {
    Remove-Variable -Name GitSshTransportFailure -Scope Global -ErrorAction SilentlyContinue
    $directory = Join-Path $root $Name
    [void] [IO.Directory]::CreateDirectory($directory)
    $script:state = @{
        Directory = $directory; Key = (Join-Path $directory 'key'); Config = (Join-Path $directory 'config')
        ApiUrl = 'https://api.github.com'; Account = 'demo'; Keys = @(); FailList = $false
        FailUpload = $false; Paginate = $false
        Requests = (New-Object 'System.Collections.Generic.List[string]')
        Uploads = (New-Object 'System.Collections.Generic.List[object]')
    }
    $global:GitSshTestState = $script:state
}
function Run-Script([hashtable] $Options = @{}, [switch] $ExpectError) {
    $arguments = @{
        Account = 'demo'; KeyPath = $script:state.Key; SshConfigPath = $script:state.Config
        TokenEnv = 'GIT_SSH_TEST_TOKEN'; NoPassphrase = $true
    }
    foreach ($key in $Options.Keys) { $arguments[$key] = $Options[$key] }
    $failed = $false
    try { & $targetScript @arguments *> (Join-Path $root 'output') }
    catch { $failed = $true; $script:lastFailure = $_.Exception.Message + "`n" + $_.ScriptStackTrace }
    $output = [IO.File]::ReadAllText((Join-Path $root 'output'))
    if ($output.Contains('test-secret')) { throw 'Credential leaked in output.' }
    if ($ExpectError -and -not $failed) { throw 'Expected failure.' }
    if (-not $ExpectError -and $failed) {
        if (Test-Path variable:global:GitSshTransportFailure) { Write-Host "Transport double: $global:GitSshTransportFailure" }
        throw "Unexpected failure: $script:lastFailure`n$output"
    }
}
function Assert([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Pass([string] $Message) { $script:passed++; Write-Host "PASS: $Message" }
function New-TestKey([string] $Path, [string] $Algorithm = 'ed25519') {
    # Test keys are deliberately unencrypted. This avoids legacy PowerShell's empty native-argument conversion.
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = (Get-Command ssh-keygen -CommandType Application).Source
    $start.UseShellExecute = $false
    $start.Arguments = '-q -t ' + $Algorithm + ' -N "" -f "' + $Path + '"'
    $process = [Diagnostics.Process]::Start($start)
    $process.WaitForExit()
    if ($process.ExitCode) { throw 'Fixture key generation failed.' }
    $process.Dispose()
}

try {
    New-Case dry
    Run-Script @{ DryRun = $true; ConfigureSsh = $true }
    Assert (-not (Test-Path -LiteralPath $state.Key) -and -not (Test-Path -LiteralPath $state.Config) -and $state.Requests.Count -eq 0) 'Dry run had side effects.'
    Pass 'Offline dry run without key/config/API changes'

    New-Case 'github space'
    Run-Script @{ ConfigureSsh = $true; Comment = 'demo comment with spaces'; Title = 'Desktop title' }
    Assert ((Test-Path -LiteralPath $state.Key) -and (Test-Path -LiteralPath "$($state.Key).pub")) 'Keys missing.'
    $before = [IO.File]::ReadAllText($state.Key)
    Run-Script @{ ConfigureSsh = $true }
    Assert ($state.Uploads.Count -eq 1) 'Duplicate upload.'
    Assert (@(Select-String -LiteralPath $state.Config -Pattern '^Host github-demo$').Count -eq 1) 'Duplicate config block.'
    Assert ([IO.File]::ReadAllText($state.Key) -ceq $before) 'Private key changed.'
    Pass 'Real Ed25519 generation, paths with spaces, and idempotent GitHub rerun'

    New-Case enterprise
    $state.ApiUrl = 'https://github.example.com/api/v3'
    Run-Script @{ ServerUrl = 'https://github.example.com' }
    Pass 'GitHub Enterprise Server API mapping'

    New-Case gitlab
    $state.ApiUrl = 'https://git.example.com:8443/team/api/v4'
    $gitlab = @{ Provider = 'gitlab'; ServerUrl = 'https://git.example.com:8443/team'; ConfigureSsh = $true; SshPort = 2222; SshHost = 'ssh.example.com'; SshUser = 'vcs' }
    Run-Script $gitlab
    Assert ($state.Uploads[0].usage_type -eq 'auth') 'GitLab key must be for authentication.'
    $config = [IO.File]::ReadAllText($state.Config)
    Assert ($config.Contains('Port 2222') -and $config.Contains('HostName ssh.example.com') -and $config.Contains('User vcs')) 'SSH overrides missing.'
    $state.Paginate = $true
    Run-Script $gitlab
    Assert (@($state.Requests | Where-Object { $_ -like '*page=2' }).Count -eq 1 -and $state.Uploads.Count -eq 1) 'Pagination duplicated key.'
    Pass 'Self-managed GitLab path/port, SSH overrides, auth-only payload, and pagination'

    New-Case official-gitlab
    $state.ApiUrl = 'https://gitlab.com/api/v4'
    Run-Script @{ Provider = 'gitlab' }
    Pass 'GitLab.com default API'

    New-Case wrong-account
    $state.Account = 'another-account'
    Run-Script @{} -ExpectError
    Assert (-not (Test-Path -LiteralPath $state.Key) -and $state.Uploads.Count -eq 0) 'Wrong identity created keys.'
    Pass 'Account mismatch fails before creating keys'

    New-Case permission
    $state.FailList = $true
    Run-Script @{} -ExpectError
    Assert (-not (Test-Path -LiteralPath $state.Key)) 'Permission failure created keys.'
    Pass 'Permission failure precedes key creation'

    New-Case conflict
    [IO.File]::WriteAllText($state.Config, "Host other github-demo`n    User git`n")
    Run-Script @{ ConfigureSsh = $true } -ExpectError
    Assert ($state.Requests.Count -eq 0 -and -not (Test-Path -LiteralPath $state.Key)) 'Config conflict detected too late.'
    Pass 'Multi-name Host conflict fails offline'

    New-Case include-conflict
    $includePath = Join-Path $state.Directory 'included file'
    [IO.File]::WriteAllText($includePath, "Host github-demo`n    User git`n")
    [IO.File]::WriteAllText($state.Config, "Include `"$includePath`"`n")
    Run-Script @{ ConfigureSsh = $true } -ExpectError
    Assert ($state.Requests.Count -eq 0) 'Included alias conflict detected too late.'
    Pass 'Quoted Include file is checked for alias conflicts'

    New-Case wildcard-default
    [IO.File]::WriteAllText($state.Config, "ServerAliveInterval 37`nHost *`n    User fallback`n")
    Run-Script @{ ConfigureSsh = $true }
    $text = [IO.File]::ReadAllText($state.Config)
    Assert ($text.StartsWith('# BEGIN setup-git-ssh github-demo') -and $text.Contains('User fallback')) 'Specific Host must precede preserved wildcard defaults.'
    if (Get-Command ssh -CommandType Application -ErrorAction SilentlyContinue) {
        $effectiveAlias = & ssh -G -F $state.Config github-demo 2>$null
        $effectiveOther = & ssh -G -F $state.Config unrelated.example.com 2>$null
        Assert ($effectiveAlias -contains 'user git') 'Managed User lost precedence.'
        Assert ($effectiveOther -contains 'serveraliveinterval 37') 'Original global settings lost their scope.'
    }
    Pass 'Specific Host is prepended without removing wildcard defaults'

    New-Case mismatched-public
    New-TestKey $state.Key
    $other = Join-Path $state.Directory other
    New-TestKey $other
    [IO.File]::Copy("$other.pub", "$($state.Key).pub", $true)
    Run-Script @{} -ExpectError
    Assert ($state.Uploads.Count -eq 0) 'Mismatched public key uploaded.'
    Pass 'Public/private mismatch is rejected'

    New-Case missing-public
    New-TestKey $state.Key
    [IO.File]::Delete("$($state.Key).pub")
    Run-Script
    Assert (Test-Path -LiteralPath "$($state.Key).pub") 'Public key not recovered.'
    Pass 'Recover missing public key from private key'

    New-Case rsa
    Run-Script @{ Type = 'rsa'; Bits = 2048 }
    Run-Script @{ Type = 'rsa'; Bits = 4096 } -ExpectError
    Run-Script @{ Type = 'ed25519' } -ExpectError
    Pass 'RSA generation and algorithm/bit-count mismatch validation'

    New-Case ecdsa
    Run-Script @{ Type = 'ecdsa'; Bits = 384 }
    Pass 'ECDSA P-384 generation'

    New-Case retry
    $state.FailUpload = $true
    Run-Script @{ ConfigureSsh = $true } -ExpectError
    Assert ((Test-Path -LiteralPath $state.Key) -and (Test-Path -LiteralPath "$($state.Key).pub") -and -not (Test-Path -LiteralPath $state.Config)) 'Upload failure did not retain only keys.'
    $state.FailUpload = $false
    Run-Script @{ ConfigureSsh = $true }
    Pass 'Failed upload retains keys for retry'

    New-Case validation
    Run-Script @{ Type = 'ed25519'; Bits = 256 } -ExpectError
    Run-Script @{ Type = 'rsa'; Bits = 1024 } -ExpectError
    Run-Script @{ ServerUrl = 'http://git.example.com' } -ExpectError
    Run-Script @{ ServerUrl = 'https://user:password@git.example.com' } -ExpectError
    Run-Script @{ SshPort = 0 } -ExpectError
    Assert ($state.Requests.Count -eq 0) 'Invalid inputs made API requests.'
    Pass 'Invalid input validation is offline'

    New-Case signing-only
    $state.ApiUrl = 'https://gitlab.com/api/v4'
    New-TestKey $state.Key
    $state.Keys = @([pscustomobject] @{ key = [IO.File]::ReadAllText("$($state.Key).pub").Trim(); usage_type = 'signing'; expires_at = $null })
    Run-Script @{ Provider = 'gitlab' } -ExpectError
    Assert ($state.Uploads.Count -eq 0) 'Signing-only key caused an upload.'
    Pass 'GitLab signing-only duplicate is rejected'

    New-Case expired
    $state.ApiUrl = 'https://gitlab.com/api/v4'
    New-TestKey $state.Key
    $state.Keys = @([pscustomobject] @{ key = [IO.File]::ReadAllText("$($state.Key).pub").Trim(); usage_type = 'auth'; expires_at = '2000-01-01T00:00:00.000Z' })
    Run-Script @{ Provider = 'gitlab' } -ExpectError
    Assert ($state.Uploads.Count -eq 0) 'Expired key caused upload.'
    Pass 'Expired GitLab duplicate is rejected'

    Write-Host "`n$passed offline PowerShell scenarios passed on $($PSVersionTable.PSVersion)."
} finally {
    [Environment]::SetEnvironmentVariable('GIT_SSH_TEST_TOKEN', $previousToken)
    Remove-Variable -Name GitSshTestState, GitSshTransportFailure -Scope Global -ErrorAction SilentlyContinue
    # Resolve and verify the generated test directory before any recursive removal.
    $resolvedRoot = [IO.Path]::GetFullPath($root)
    $toolsRoot = [IO.Path]::GetFullPath((Join-Path $repo '.tools')) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedRoot.StartsWith($toolsRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
