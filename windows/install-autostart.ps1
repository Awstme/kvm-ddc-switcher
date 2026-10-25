# install-autostart.ps1 - 注册/卸载 kvm-watch 的登录自启计划任务
#
# 用法（普通权限即可）：
#   powershell -ExecutionPolicy Bypass -File .\install-autostart.ps1
#   powershell -ExecutionPolicy Bypass -File .\install-autostart.ps1 -Uninstall
#
# 任务在用户登录时以交互会话启动（DDC 需要桌面会话），
# 允许电池供电、不限运行时长、异常退出最多重启 3 次。

param([switch]$Uninstall)

$ErrorActionPreference = "Stop"
$DIR = $PSScriptRoot
$TASK_NAME = "kvm-watch"
$SCRIPT = Join-Path $DIR "kvm-watch.ps1"

if (-not (Test-Path -LiteralPath $SCRIPT)) {
    throw "kvm-watch.ps1 not found next to this installer: $SCRIPT"
}

if ($Uninstall) {
    Stop-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false -ErrorAction Stop
    Write-Host ("uninstalled: " + $TASK_NAME)
    exit 0
}

# 用当前登录身份的规范名（ssh 会话里 $env:USERDOMAIN 可能是不存在的 WORKGROUP）
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
Stop-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction -Execute "powershell.exe" -WorkingDirectory $DIR `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $SCRIPT + '"')
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -StartWhenAvailable `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive

Register-ScheduledTask -TaskName $TASK_NAME -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName $TASK_NAME
Write-Host ("installed & started: " + $TASK_NAME + " -> " + $SCRIPT)
Write-Host ("state: " + (Get-ScheduledTask -TaskName $TASK_NAME).State)
