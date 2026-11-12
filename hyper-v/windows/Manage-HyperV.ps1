#requires -Version 5.1
<#
.SYNOPSIS
Manages local Hyper-V virtual machines and checkpoints.
.DESCRIPTION
Uses exact VM/checkpoint names. All changes support -WhatIf and prompt for
confirmation by default; use -Confirm:$false for unattended operation.
Stop and Restart use guest shutdown, without forcing power off.
.EXAMPLE
.\Manage-HyperV.ps1 -Action List
.EXAMPLE
.\Manage-HyperV.ps1 -Action Start -VMName 'demo-vm'
.EXAMPLE
.\Manage-HyperV.ps1 -Action Checkpoint -VMName 'demo-vm' -CheckpointName 'before-update'
.EXAMPLE
.\Manage-HyperV.ps1 -Action RestoreCheckpoint -VMName 'demo-vm' -CheckpointName 'before-update' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('List', 'Start', 'Stop', 'Restart', 'Save', 'TurnOff',
        'Checkpoint', 'ListCheckpoints', 'RestoreCheckpoint', 'RemoveCheckpoint')]
    [string] $Action = 'List',

    [ValidateNotNullOrEmpty()]
    [string] $VMName,

    [ValidateNotNullOrEmpty()]
    [string] $CheckpointName,

    [guid] $CheckpointId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Action -ne 'List' -and [string]::IsNullOrWhiteSpace($VMName)) {
    throw '-VMName is required for this action. Use -Action List to find the Hyper-V display name.'
}
if ($PSBoundParameters.ContainsKey('VMName') -and [string]::IsNullOrWhiteSpace($VMName)) {
    throw '-VMName must not be blank.'
}
$selectCheckpoint = $Action -in @('RestoreCheckpoint', 'RemoveCheckpoint')
$hasName = $PSBoundParameters.ContainsKey('CheckpointName')
$hasId = $PSBoundParameters.ContainsKey('CheckpointId')
if ($hasName -and [string]::IsNullOrWhiteSpace($CheckpointName)) {
    throw '-CheckpointName must not be blank.'
}
if ($hasName -and $Action -notin @('Checkpoint', 'RestoreCheckpoint', 'RemoveCheckpoint')) {
    throw '-CheckpointName is only valid for Checkpoint, RestoreCheckpoint or RemoveCheckpoint.'
}
if ($hasId -and -not $selectCheckpoint) {
    throw '-CheckpointId is only valid for RestoreCheckpoint or RemoveCheckpoint.'
}
if ($selectCheckpoint -and ($hasName -eq $hasId)) {
    throw 'Specify exactly one of -CheckpointName or -CheckpointId.'
}

try {
    Import-Module Hyper-V -ErrorAction Stop
} catch {
    throw "Cannot load the Hyper-V PowerShell module. Run on a Windows Hyper-V host with the management tools installed. $($_.Exception.Message)"
}

# Resolve locally and literally: wildcard-like names must never select a fleet.
$vms = @(Get-VM -ErrorAction Stop)
if ($PSBoundParameters.ContainsKey('VMName')) {
    $vms = @($vms | Where-Object { $_.Name -eq $VMName })
    if ($vms.Count -ne 1) {
        throw "Expected exactly one VM named '$VMName'; found $($vms.Count). Use -Action List."
    }
}
if ($Action -eq 'List') {
    $vms | Sort-Object Name | Select-Object Name, State, Status, CPUUsage, MemoryAssigned, Uptime, Id
    return
}
$vm = $vms[0]

if ($Action -in @('ListCheckpoints', 'Checkpoint', 'RestoreCheckpoint', 'RemoveCheckpoint')) {
    $checkpoints = @(Get-VMSnapshot -VM $vm -ErrorAction Stop)
    if ($Action -eq 'ListCheckpoints') {
        $checkpoints | Sort-Object CreationTime | Select-Object VMName, Name, CreationTime, SnapshotType, Id, ParentSnapshotId
        return
    }
    if ($Action -eq 'Checkpoint') {
        if (-not $hasName) {
            $CheckpointName = 'checkpoint-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
        }
        if (@($checkpoints | Where-Object { $_.Name -eq $CheckpointName }).Count -gt 0) {
            throw "Checkpoint '$CheckpointName' already exists. Choose another name."
        }
    } else {
        $matches = @($checkpoints | Where-Object {
            if ($hasId) { $_.Id -eq $CheckpointId } else { $_.Name -eq $CheckpointName }
        })
        if ($matches.Count -ne 1) {
            throw "Expected exactly one checkpoint on '$($vm.Name)'; found $($matches.Count). Use ListCheckpoints and select -CheckpointId if names repeat."
        }
        $checkpoint = $matches[0]
    }
}

$target = "VM '$($vm.Name)' ($($vm.Id))"
$operation = $Action
switch ($Action) {
    'Stop' { $operation = 'Shut down through the guest OS' }
    'Restart' {
        if ([string]$vm.State -ne 'Running') {
            throw 'Restart requires a Running VM. Use Start for an Off or Saved VM.'
        }
        $operation = 'Shut down through the guest OS, then start'
    }
    'TurnOff' { $operation = 'Immediately cut power; unsaved data may be lost' }
    'Checkpoint' { $operation = "Create checkpoint '$CheckpointName' using the VM checkpoint configuration" }
    'RestoreCheckpoint' {
        $target += "; checkpoint '$($checkpoint.Name)' ($($checkpoint.Id))"
        $operation = 'Restore checkpoint; discard changes since this checkpoint (no safety checkpoint is created)'
    }
    'RemoveCheckpoint' {
        $target += "; checkpoint '$($checkpoint.Name)' ($($checkpoint.Id))"
        $operation = 'Delete this checkpoint only; keep current VM data and child checkpoints'
    }
}
if (-not $PSCmdlet.ShouldProcess($target, $operation)) { return }

switch ($Action) {
    'Start' { Start-VM -VM $vm -Confirm:$false -ErrorAction Stop }
    'Stop' { Stop-VM -VM $vm -Confirm:$false -ErrorAction Stop }
    'Restart' {
        Stop-VM -VM $vm -Confirm:$false -ErrorAction Stop
        $vm = Get-VM -Id $vm.Id -ErrorAction Stop
        if ([string]$vm.State -ne 'Off') {
            throw "Guest shutdown did not finish (state: $($vm.State)). VM was not started or forcibly powered off."
        }
        Start-VM -VM $vm -Confirm:$false -ErrorAction Stop
    }
    'Save' { Stop-VM -VM $vm -Save -Confirm:$false -ErrorAction Stop }
    'TurnOff' { Stop-VM -VM $vm -TurnOff -Confirm:$false -ErrorAction Stop }
    'Checkpoint' {
        Checkpoint-VM -VM $vm -SnapshotName $CheckpointName -Confirm:$false -ErrorAction Stop
        Get-VMSnapshot -VM $vm -ErrorAction Stop | Where-Object { $_.Name -eq $CheckpointName }
        return
    }
    'RestoreCheckpoint' { Restore-VMSnapshot -VMSnapshot $checkpoint -Confirm:$false -ErrorAction Stop }
    'RemoveCheckpoint' { Remove-VMSnapshot -VMSnapshot $checkpoint -Confirm:$false -ErrorAction Stop }
}
Get-VM -Id $vm.Id -ErrorAction Stop
