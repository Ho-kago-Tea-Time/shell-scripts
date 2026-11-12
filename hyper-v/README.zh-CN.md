# Hyper-V 虚拟机与快照管理

[English](./README.md)

在 **Windows Hyper-V 宿主机**上运行 `windows/Manage-HyperV.ps1`，需要 Hyper-V PowerShell 管理模块，以及管理员或 Hyper-V Administrators 组权限。支持 Windows PowerShell 5.1 和 PowerShell 7（需能加载 Hyper-V 模块）。

默认只列出虚拟机。`VMName` 是 Hyper-V 管理器中的显示名称，不是 SSH 别名或来宾系统的 `.local` 主机名；先运行 `List` 获取名称。脚本只管理当前宿主机，每次修改一台虚拟机，名称按完整字符串匹配。

在仓库根目录打开 PowerShell：

```powershell
# 列表 / 启动 / 正常关机 / 正常关机后启动
.\hyper-v\windows\Manage-HyperV.ps1
.\hyper-v\windows\Manage-HyperV.ps1 -Action Start -VMName 'demo-vm'
.\hyper-v\windows\Manage-HyperV.ps1 -Action Stop -VMName 'demo-vm'
.\hyper-v\windows\Manage-HyperV.ps1 -Action Restart -VMName 'demo-vm'

# 保存运行状态；之后用 Start 恢复
.\hyper-v\windows\Manage-HyperV.ps1 -Action Save -VMName 'demo-vm'

# 创建 / 列出检查点（快照）；省略名称时自动生成时间戳名称
.\hyper-v\windows\Manage-HyperV.ps1 -Action Checkpoint -VMName 'demo-vm' -CheckpointName 'before-update'
.\hyper-v\windows\Manage-HyperV.ps1 -Action ListCheckpoints -VMName 'demo-vm' | Format-Table

# 先预演，再去掉 -WhatIf 执行
.\hyper-v\windows\Manage-HyperV.ps1 -Action RestoreCheckpoint -VMName 'demo-vm' -CheckpointName 'before-update' -WhatIf
.\hyper-v\windows\Manage-HyperV.ps1 -Action RemoveCheckpoint -VMName 'demo-vm' -CheckpointName 'before-update' -WhatIf

# 重名时从 ListCheckpoints 取 Id，替换示例 GUID；名称和 ID 二选一
.\hyper-v\windows\Manage-HyperV.ps1 -Action RestoreCheckpoint -VMName 'demo-vm' -CheckpointId '00000000-0000-0000-0000-000000000001' -WhatIf

# 强制断电：仅在明确需要时使用
.\hyper-v\windows\Manage-HyperV.ps1 -Action TurnOff -VMName 'demo-vm' -WhatIf
```

所有修改操作默认询问确认，支持 `-WhatIf` 预演；无人值守时可显式使用 `-Confirm:$false`。列表返回 PowerShell 对象，可接 `Format-Table`、`ConvertTo-Json` 等。

`Stop` 和 `Restart` 通过来宾系统正常关机，不传 `-Force`，失败时直接报错。`Restart` 只接受 Running 状态，关机成功且状态为 Off 后才启动；它不使用硬重启命令。来宾系统需要支持 Hyper-V 关机集成服务。`TurnOff` 相当于拔电源，可能丢失未保存数据。[微软 Stop-VM 文档](https://learn.microsoft.com/en-us/powershell/module/hyper-v/stop-vm)

创建检查点沿用虚拟机现有的检查点配置，不修改生产/标准检查点设置。恢复会丢弃检查点之后的变化，脚本不会自动创建恢复前快照，也不会主动启动恢复后的虚拟机。删除只针对选中的检查点，不请求删除整个子树，不回滚当前数据；不要手动删除 `.avhdx` 文件。检查点不能替代独立备份。[微软检查点文档](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/checkpoints)

## 验证

```powershell
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\hyper-v\tests\Test-HyperVManager.ps1
pwsh -NoProfile -NonInteractive -File .\hyper-v\tests\Test-HyperVManager.ps1
```

测试在独立模块作用域中替换 Hyper-V 命令，不加载真实 Hyper-V 模块、不连接虚拟机，验证目标选择、预演、正常关机与快照操作的边界。上面的执行策略参数仅作用于该测试进程，不修改系统策略；若管理脚本也被执行策略阻止，可用同样的 `powershell -NoProfile -ExecutionPolicy Bypass -File` 前缀运行脚本。真实环境可先执行 `List`、`ListCheckpoints` 和带 `-WhatIf` 的命令。
