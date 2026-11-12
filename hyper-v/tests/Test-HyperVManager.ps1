#requires -Version 5.1
# Offline behavioral tests: all Hyper-V commands are replaced inside this module.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$managerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'windows/Manage-HyperV.ps1'
$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    $managerPath, [ref]$tokens, [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) { throw ($parseErrors -join [Environment]::NewLine) }

if (Get-Variable -Name HyperVManagerTestState -Scope Global -ErrorAction SilentlyContinue) {
    throw 'HyperVManagerTestState already exists; run tests in a fresh PowerShell process.'
}
$global:HyperVManagerTestState = @{}
$sandbox = New-Module -Name HyperVManagerOfflineTests -ScriptBlock {
    param($ManagerPath)
    $global:HyperVManagerTestState.ManagerPath = $ManagerPath
    $global:HyperVManagerTestState.Passed = 0

    function Import-Module {
        [CmdletBinding()]
        param([string] $Name)
        if ($Name -ne 'Hyper-V') { throw "Unexpected import: $Name" }
    }
    function Get-VM {
        [CmdletBinding()]
        param([guid] $Id)
        if ($PSBoundParameters.ContainsKey('Id')) {
            return $global:HyperVManagerTestState.VMs | Where-Object { $_.Id -eq $Id }
        }
        $global:HyperVManagerTestState.VMs
    }
    function Get-VMSnapshot {
        [CmdletBinding()]
        param($VM)
        $global:HyperVManagerTestState.Snapshots | Where-Object { $_.VMId -eq $VM.Id }
    }
    function Start-VM {
        [CmdletBinding(SupportsShouldProcess)]
        param($VM)
        $global:HyperVManagerTestState.Calls.Add(@{ Command = 'Start'; VM = $VM.Id })
        $VM.State = 'Running'
    }
    function Stop-VM {
        [CmdletBinding(SupportsShouldProcess)]
        param($VM, [switch] $Save, [switch] $TurnOff, [switch] $Force)
        if ($Force) { throw 'Graceful shutdown must not use Force.' }
        $global:HyperVManagerTestState.Calls.Add(@{ Command = 'Stop'; VM = $VM.Id; Save = [bool]$Save; TurnOff = [bool]$TurnOff })
        if ($global:HyperVManagerTestState.StopFails) { throw 'Simulated guest shutdown failure.' }
        if (-not $global:HyperVManagerTestState.StopStalls) {
            if ($Save) { $VM.State = 'Saved' } else { $VM.State = 'Off' }
        }
    }
    function Checkpoint-VM {
        [CmdletBinding(SupportsShouldProcess)]
        param($VM, [string] $SnapshotName)
        $global:HyperVManagerTestState.Calls.Add(@{ Command = 'Checkpoint'; VM = $VM.Id; Name = $SnapshotName })
    }
    function Restore-VMSnapshot {
        [CmdletBinding(SupportsShouldProcess)]
        param($VMSnapshot)
        $global:HyperVManagerTestState.Calls.Add(@{ Command = 'Restore'; Snapshot = $VMSnapshot.Id })
    }
    function Remove-VMSnapshot {
        [CmdletBinding(SupportsShouldProcess)]
        param($VMSnapshot, [switch] $IncludeAllChildSnapshots)
        if ($IncludeAllChildSnapshots) { throw 'Must not delete the checkpoint subtree.' }
        $global:HyperVManagerTestState.Calls.Add(@{ Command = 'Remove'; Snapshot = $VMSnapshot.Id })
    }
    function Reset-Fixture {
        $global:HyperVManagerTestState.Calls = New-Object 'System.Collections.Generic.List[object]'
        $global:HyperVManagerTestState.StopFails = $false
        $global:HyperVManagerTestState.StopStalls = $false
        $global:HyperVManagerTestState.VMs = @(
            [pscustomobject]@{ Name = 'demo-vm'; Id = [guid]::NewGuid(); State = 'Running'; Status = 'OK'; CPUUsage = 0; MemoryAssigned = 0; Uptime = [timespan]::Zero },
            [pscustomobject]@{ Name = 'other-vm'; Id = [guid]::NewGuid(); State = 'Off'; Status = 'OK'; CPUUsage = 0; MemoryAssigned = 0; Uptime = [timespan]::Zero }
        )
        $global:HyperVManagerTestState.Snapshots = @(
            [pscustomobject]@{ Name = 'before-update'; Id = [guid]::NewGuid(); VMId = $global:HyperVManagerTestState.VMs[0].Id; VMName = 'demo-vm'; CreationTime = Get-Date; SnapshotType = 'Standard'; ParentSnapshotId = [guid]::Empty },
            [pscustomobject]@{ Name = 'before-update'; Id = [guid]::NewGuid(); VMId = $global:HyperVManagerTestState.VMs[1].Id; VMName = 'other-vm'; CreationTime = Get-Date; SnapshotType = 'Standard'; ParentSnapshotId = [guid]::Empty }
        )
    }
    function Invoke-Manager {
        param([hashtable] $Arguments = @{})
        & $global:HyperVManagerTestState.ManagerPath @Arguments -Confirm:$false
    }
    function Assert-True {
        param([bool] $Condition, [string] $Message)
        if (-not $Condition) { throw "FAIL: $Message" }
        $global:HyperVManagerTestState.Passed++
    }
    function Assert-Rejected {
        param([hashtable] $Arguments, [string] $Expected)
        $caught = $null
        try { $null = Invoke-Manager $Arguments } catch { $caught = $_ }
        Assert-True ($null -ne $caught) "Expected rejection: $Expected"
        Assert-True ($caught.Exception.Message -like "*$Expected*") "Unexpected error: $caught"
        Assert-True ($global:HyperVManagerTestState.Calls.Count -eq 0) 'Rejected input must not modify any VM.'
    }

    function Invoke-Tests {
        Reset-Fixture
        $listed = @(Invoke-Manager)
        Assert-True ($listed.Count -eq 2 -and $global:HyperVManagerTestState.Calls.Count -eq 0) 'Default action must only list VMs.'
        Assert-Rejected @{ Action = 'Stop' } '-VMName is required'
        Assert-Rejected @{ Action = 'Stop'; VMName = '*' } 'found 0'
        Assert-Rejected @{ Action = 'Start'; VMName = 'missing' } 'found 0'
        Assert-Rejected @{ Action = 'List'; CheckpointName = 'unused' } 'only valid'
        Assert-Rejected @{ Action = 'Checkpoint'; VMName = 'demo-vm'; CheckpointName = ' ' } 'must not be blank'
        foreach ($action in @('RestoreCheckpoint', 'RemoveCheckpoint')) {
            Assert-Rejected @{ Action = $action; VMName = 'demo-vm' } 'exactly one of'
            Assert-Rejected @{ Action = $action; VMName = 'demo-vm'; CheckpointName = '*'; CheckpointId = [guid]::NewGuid() } 'exactly one of'
            Assert-Rejected @{ Action = $action; VMName = 'demo-vm'; CheckpointName = '*' } 'found 0'
            Assert-Rejected @{ Action = $action; VMName = 'demo-vm'; CheckpointId = $global:HyperVManagerTestState.Snapshots[1].Id } 'found 0'
        }

        foreach ($action in @('Start', 'Stop', 'Restart', 'Save', 'TurnOff', 'Checkpoint', 'RestoreCheckpoint', 'RemoveCheckpoint')) {
            Reset-Fixture
            $arguments = @{ Action = $action; VMName = 'demo-vm'; WhatIf = $true }
            if ($action -in @('RestoreCheckpoint', 'RemoveCheckpoint')) { $arguments.CheckpointName = 'before-update' }
            $null = Invoke-Manager $arguments
            Assert-True ($global:HyperVManagerTestState.Calls.Count -eq 0) "WhatIf must prevent $action."
        }

        Reset-Fixture
        $global:HyperVManagerTestState.VMs[1].Name = 'demo-vm'
        Assert-Rejected @{ Action = 'Start'; VMName = 'demo-vm' } 'found 2'

        Reset-Fixture
        $duplicate = $global:HyperVManagerTestState.Snapshots[0].PSObject.Copy()
        $duplicate.Id = [guid]::NewGuid()
        $global:HyperVManagerTestState.Snapshots += $duplicate
        Assert-Rejected @{ Action = 'RestoreCheckpoint'; VMName = 'demo-vm'; CheckpointName = 'before-update' } 'found 2'
        Assert-Rejected @{ Action = 'RemoveCheckpoint'; VMName = 'demo-vm'; CheckpointName = 'before-update' } 'found 2'
        $null = Invoke-Manager @{ Action = 'RemoveCheckpoint'; VMName = 'demo-vm'; CheckpointId = $duplicate.Id }
        Assert-True ($global:HyperVManagerTestState.Calls.Count -eq 1 -and $global:HyperVManagerTestState.Calls[0].Snapshot -eq $duplicate.Id) 'ID must select exactly one checkpoint.'

        Reset-Fixture
        Assert-Rejected @{ Action = 'Checkpoint'; VMName = 'demo-vm'; CheckpointName = 'before-update' } 'already exists'
        $null = Invoke-Manager @{ Action = 'Checkpoint'; VMName = 'demo-vm' }
        Assert-True ($global:HyperVManagerTestState.Calls.Count -eq 1 -and $global:HyperVManagerTestState.Calls[0].Name -like 'checkpoint-*') 'Generate a checkpoint name.'

        foreach ($action in @('Start', 'Stop', 'Save', 'TurnOff', 'Restart', 'Checkpoint', 'RestoreCheckpoint', 'RemoveCheckpoint')) {
            Reset-Fixture
            $arguments = @{ Action = $action; VMName = 'demo-vm' }
            if ($action -in @('Checkpoint', 'RestoreCheckpoint', 'RemoveCheckpoint')) { $arguments.CheckpointName = 'selected' }
            if ($action -ne 'Checkpoint') { $global:HyperVManagerTestState.Snapshots[0].Name = 'selected' }
            $null = Invoke-Manager $arguments
            $expectedCount = 1
            if ($action -eq 'Restart') { $expectedCount = 2 }
            Assert-True ($global:HyperVManagerTestState.Calls.Count -eq $expectedCount) "Call count for $action."
            foreach ($call in $global:HyperVManagerTestState.Calls) {
                if ($call.ContainsKey('VM')) { Assert-True ($call.VM -eq $global:HyperVManagerTestState.VMs[0].Id) "VM target for $action." }
                if ($call.ContainsKey('Snapshot')) { Assert-True ($call.Snapshot -eq $global:HyperVManagerTestState.Snapshots[0].Id) "Checkpoint target for $action." }
            }
            if ($action -eq 'Restart') {
                Assert-True ($global:HyperVManagerTestState.Calls[0].Command -eq 'Stop' -and $global:HyperVManagerTestState.Calls[1].Command -eq 'Start') 'Restart must shut down before starting.'
            }
            if ($action -in @('Stop', 'Save', 'TurnOff', 'Restart')) {
                Assert-True ($global:HyperVManagerTestState.Calls[0].Save -eq ($action -eq 'Save')) 'Save switch routing.'
                Assert-True ($global:HyperVManagerTestState.Calls[0].TurnOff -eq ($action -eq 'TurnOff')) 'TurnOff switch routing.'
            }
        }

        foreach ($failure in @('StopFails', 'StopStalls')) {
            Reset-Fixture
            $global:HyperVManagerTestState[$failure] = $true
            $caught = $null
            try { $null = Invoke-Manager @{ Action = 'Restart'; VMName = 'demo-vm' } } catch { $caught = $_ }
            Assert-True ($null -ne $caught) "Restart must report $failure."
            Assert-True ($global:HyperVManagerTestState.Calls.Count -eq 1 -and $global:HyperVManagerTestState.Calls[0].Command -eq 'Stop') 'Failed shutdown must not start or force off the VM.'
        }
        Reset-Fixture
        $global:HyperVManagerTestState.VMs[0].State = 'Off'
        Assert-Rejected @{ Action = 'Restart'; VMName = 'demo-vm' } 'requires a Running VM'

        Reset-Fixture
        $listed = @(Invoke-Manager @{ Action = 'ListCheckpoints'; VMName = 'demo-vm' })
        Assert-True ($listed.Count -eq 1 -and $listed[0].Id -eq $global:HyperVManagerTestState.Snapshots[0].Id) 'List checkpoints only for the selected VM.'
        Write-Output "PASS: $($global:HyperVManagerTestState.Passed) assertions; PowerShell $($PSVersionTable.PSVersion); no real Hyper-V commands executed."
    }
} -ArgumentList $managerPath

try { & $sandbox { Invoke-Tests } } finally {
    Remove-Module $sandbox -ErrorAction SilentlyContinue
    Remove-Variable -Name HyperVManagerTestState -Scope Global
}
