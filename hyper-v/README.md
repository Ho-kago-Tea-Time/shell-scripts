# Hyper-V VM and checkpoint management

[中文说明](./README.zh-CN.md)

Run `windows/Manage-HyperV.ps1` on the **Windows Hyper-V host**, with the Hyper-V PowerShell management module installed and administrator or Hyper-V Administrators permissions. Supports Windows PowerShell 5.1 and PowerShell 7 when the Hyper-V module can be loaded.

The default action lists local VMs. `VMName` is the display name in Hyper-V Manager, not an SSH alias or guest hostname. Use `List` to discover it. Names are matched literally; each change targets one VM on the local host.

From the repository root:

```powershell
.\hyper-v\windows\Manage-HyperV.ps1
.\hyper-v\windows\Manage-HyperV.ps1 -Action Start -VMName 'demo-vm'
.\hyper-v\windows\Manage-HyperV.ps1 -Action Stop -VMName 'demo-vm'
.\hyper-v\windows\Manage-HyperV.ps1 -Action Restart -VMName 'demo-vm'
.\hyper-v\windows\Manage-HyperV.ps1 -Action Save -VMName 'demo-vm'

# Omit CheckpointName to generate a timestamp name.
.\hyper-v\windows\Manage-HyperV.ps1 -Action Checkpoint -VMName 'demo-vm' -CheckpointName 'before-update'
.\hyper-v\windows\Manage-HyperV.ps1 -Action ListCheckpoints -VMName 'demo-vm' | Format-Table

# Preview first; remove -WhatIf to execute.
.\hyper-v\windows\Manage-HyperV.ps1 -Action RestoreCheckpoint -VMName 'demo-vm' -CheckpointName 'before-update' -WhatIf
.\hyper-v\windows\Manage-HyperV.ps1 -Action RemoveCheckpoint -VMName 'demo-vm' -CheckpointName 'before-update' -WhatIf

# For duplicate names, copy an Id from ListCheckpoints and replace this example.
.\hyper-v\windows\Manage-HyperV.ps1 -Action RestoreCheckpoint -VMName 'demo-vm' -CheckpointId '00000000-0000-0000-0000-000000000001' -WhatIf
.\hyper-v\windows\Manage-HyperV.ps1 -Action TurnOff -VMName 'demo-vm' -WhatIf
```

All changes prompt for confirmation and support `-WhatIf`. Explicitly pass `-Confirm:$false` for unattended use. Output consists of PowerShell objects suitable for `Format-Table` or `ConvertTo-Json`.

`Stop` and `Restart` use guest shutdown without `-Force`; errors stop execution. `Restart` requires a Running VM and starts it only after shutdown completes with state Off. Guest shutdown integration must be available. `TurnOff` cuts power immediately and may lose unsaved data. [Microsoft Stop-VM documentation](https://learn.microsoft.com/en-us/powershell/module/hyper-v/stop-vm)

Checkpoint creation follows the VM's existing checkpoint settings. Restore discards subsequent changes, creates no safety checkpoint, and does not explicitly start the restored VM. Removal selects only one checkpoint, without deleting its subtree or rolling back current data. Never manually delete `.avhdx` files. Checkpoints do not replace independent backups. [Microsoft checkpoint documentation](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/checkpoints)

## Validation

```powershell
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\hyper-v\tests\Test-HyperVManager.ps1
pwsh -NoProfile -NonInteractive -File .\hyper-v\tests\Test-HyperVManager.ps1
```

The tests substitute Hyper-V commands in an isolated module scope. They never load the real Hyper-V module or access VMs, and cover targeting, previews, graceful shutdown, and checkpoint boundaries. The execution policy argument applies only to that test process and does not change system policy. If policy also blocks the manager, invoke it with the same `powershell -NoProfile -ExecutionPolicy Bypass -File` prefix. For live validation, begin with `List`, `ListCheckpoints`, and `-WhatIf` commands.
