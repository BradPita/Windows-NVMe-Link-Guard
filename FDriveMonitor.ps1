#requires -Version 5.1
<#
.SYNOPSIS
    监控指定卷的 NTFS 事件 50 / 140，发现异常时弹出置顶提醒。

.DESCRIPTION
    读取系统日志中的两类事件：
      - Ntfs / 50                        ：{Delayed Write Failed} 写入失败，数据已丢失
      - Microsoft-Windows-Ntfs / 140     ：无法把数据刷新到事务日志，可能发生损坏
    以及 PCIe 链路错误：
      - WHEA-Logger / 17（PCI Express）  ：可纠正错误（AER），掉盘前的前兆

    默认静默：只写日志、不弹窗，适合计划任务后台运行。
    需要弹窗时显式加 -AlertMode Window。
    首次运行会建立基线，并把窗口内的历史事件作为“历史提醒”记录一次。

.PARAMETER Drive
    要监控的盘符，默认 F。

.PARAMETER LookbackHours
    每次检查向回看多少小时，默认 72。

.PARAMETER AlertMode
    LogOnly = 只写日志，不弹窗（默认，适合后台任务）
    Window  = 弹出置顶提醒窗口（手动运行时用）

.EXAMPLE
    .\FDriveMonitor.ps1
    单次检查（计划任务每 2 分钟调用一次）。

.EXAMPLE
    .\FDriveMonitor.ps1 -Watch
    常驻循环检查，每 30 秒一次。

.EXAMPLE
    .\FDriveMonitor.ps1 -Summary
    打印最近 72 小时的报告，不提醒、不改状态。

.EXAMPLE
    .\FDriveMonitor.ps1 -Force
    立即用最近的 50/140 事件演示一次提醒。
#>
[CmdletBinding()]
param(
    [string]$Drive = 'F',
    [int]$LookbackHours = 72,
    [string]$StatePath,
    [string]$LogPath,
    [string]$ProbeFile = '',
    [ValidateSet('Window', 'LogOnly')]
    [string]$AlertMode = 'LogOnly',
    [int]$AlertThrottleMinutes = 10,
    [int]$AlertAutoCloseSeconds = 600,
    [int]$WheaThreshold = 10,
    [int]$WheaWindowMinutes = 60,
    [int]$WheaAlertThrottleMinutes = 120,
    [switch]$Watch,
    [int]$IntervalSeconds = 30,
    [switch]$Init,
    [switch]$Force,
    [switch]$Summary,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$Drv = $Drive.TrimEnd(':').ToUpper()
if (-not $StatePath) { $StatePath = Join-Path $PSScriptRoot 'FDriveMonitor.state.json' }
if (-not $LogPath) { $LogPath = Join-Path $PSScriptRoot 'FDriveMonitor.log' }
$StatePath = [System.IO.Path]::GetFullPath($StatePath)
$LogPath = [System.IO.Path]::GetFullPath($LogPath)

# ---------------------------------------------------------------- 基础函数

function Write-MonitorLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt 5MB)) {
            Move-Item -LiteralPath $LogPath -Destination ($LogPath + '.old') -Force
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch { }
    if (-not $Quiet) { Write-Host $line }
}

function Read-MonitorState {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8
        if (-not $raw) { return $null }
        return ($raw | ConvertFrom-Json)
    }
    catch {
        Write-MonitorLog "读取状态文件失败：$($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Save-MonitorState {
    param($State)
    try {
        $State | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $StatePath -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-MonitorLog "写入状态文件失败：$($_.Exception.Message)" 'WARN'
    }
}

# 取窗口内与目标盘相关的 50/140 事件
function Get-MonitorEvents {
    param([string]$DriveLetter, [int]$Hours)
    $start = (Get-Date).AddHours(-[math]::Abs($Hours))
    $events = @()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 50, 140; StartTime = $start } -ErrorAction SilentlyContinue)
    }
    catch { $events = @() }
    if ($events.Count -eq 0) { return @() }

    $esc = [regex]::Escape($DriveLetter.TrimEnd(':') + ':')
    $hit = $events | Where-Object {
        $_.ProviderName -in @('Ntfs', 'Microsoft-Windows-Ntfs') -and
        $_.Id -in @(50, 140) -and
        ($_.Message -match $esc)
    }
    return @($hit | Sort-Object TimeCreated)
}

# 从事件文本里抽出受影响的文件路径
function Get-AffectedPaths {
    param($Events, [string]$DriveLetter)
    $rx = [regex]('(?i)(?<![A-Za-z0-9])' + [regex]::Escape($DriveLetter.TrimEnd(':') + ':\') + '[^\s"'',;]+')
    # 中文日志格式：Windows 无法保存文件 <路径> 的所有数据
    $rxCn = [regex]('(?i)文件\s+(.+?)\s+的所有数据')
    $paths = foreach ($e in $Events) {
        $msg = [string]$e.Message
        $cn = $rxCn.Matches($msg)
        if ($cn.Count -gt 0) {
            foreach ($m in $cn) { $m.Groups[1].Value.Trim() }
        }
        else {
            foreach ($m in $rx.Matches($msg)) { $m.Value }
        }
    }
    return @($paths | Sort-Object -Unique)
}

# 在独立作业里做一次只读探测（避免盘挂死时卡住主流程）
function Test-DriveResponsive {
    param([string]$DriveLetter, [string]$ProbeFile, [int]$TimeoutSeconds = 15)

    $sb = {
        param($letter, $pf)
        try {
            $root = "${letter}:\"
            $null = [System.IO.Directory]::GetFileSystemEntries($root)

            $target = $pf
            if (-not $target -or -not [System.IO.File]::Exists($target)) {
                $target = $null
                $aigc = [System.IO.Path]::Combine($root, 'AIGC')
                if ([System.IO.Directory]::Exists($aigc)) {
                    $files = [System.IO.Directory]::GetFiles($aigc)
                    if ($files.Count -eq 0) {
                        foreach ($d in @([System.IO.Directory]::GetDirectories($aigc) | Select-Object -First 5)) {
                            $files = [System.IO.Directory]::GetFiles($d)
                            if ($files.Count -gt 0) { break }
                        }
                    }
                    if ($files.Count -gt 0) { $target = $files[0] }
                }
            }

            if ($target) {
                $fs = $null
                try {
                    $fs = [System.IO.File]::Open($target, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    $buf = New-Object byte[] 4096
                    $n = $fs.Read($buf, 0, 4096)
                    return "OK|读取 $n 字节：$target"
                }
                finally { if ($fs) { $fs.Dispose() } }
            }
            return 'OK|目录可枚举，但没找到可读文件'
        }
        catch {
            return 'FAIL|' + $_.Exception.Message
        }
    }

    try {
        $job = Start-Job -ScriptBlock $sb -ArgumentList $DriveLetter, $ProbeFile
        if (Wait-Job -Job $job -Timeout $TimeoutSeconds) {
            $out = (@(Receive-Job -Job $job) -join ' ').Trim()
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            if (-not $out) { return 'FAIL|探测没有返回结果' }
            return $out
        }
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        return "TIMEOUT|$TimeoutSeconds 秒内没有响应"
    }
    catch {
        return 'FAIL|' + $_.Exception.Message
    }
}

function Format-ProbeResult {
    param([string]$Probe)
    if ($Probe -match '^OK\|(.*)$') { return "正常（$($Matches[1])）" }
    if ($Probe -match '^FAIL\|(.*)$') { return "读取失败：$($Matches[1])" }
    if ($Probe -match '^TIMEOUT\|(.*)$') { return "无响应：$($Matches[1])" }
    return [string]$Probe
}

# 取最近 N 分钟的 PCIe AER 可纠正错误（WHEA 17）
function Get-WheaEvents {
    param([int]$Minutes = 60)
    $start = (Get-Date).AddMinutes(-[math]::Abs($Minutes))
    try {
        return @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Id = 17; StartTime = $start } -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match 'PCI Express' })
    }
    catch { return @() }
}

# 链路错误检查：窗口内条数达到阈值才记一条 ALERT（带节流），从不弹窗
function Invoke-WheaCheck {
    param($State)
    $ev = @(Get-WheaEvents -Minutes $WheaWindowMinutes)
    if ($ev.Count -lt $WheaThreshold) { return $false }

    $now = Get-Date
    if ($State.LastWheaAlertUtc) {
        try {
            $last = [datetime]::Parse([string]$State.LastWheaAlertUtc)
            if (($now - $last).TotalMinutes -lt $WheaAlertThrottleMinutes) { return $false }
        }
        catch { }
    }

    $lastEv = ($ev | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
    Write-MonitorLog ("ALERT 链路错误：最近 {0} 分钟出现 {1} 条 WHEA 17（PCIe AER），最近一次 {2:yyyy-MM-dd HH:mm:ss}" -f $WheaWindowMinutes, $ev.Count, $lastEv) 'ALERT'
    $State | Add-Member -NotePropertyName LastWheaAlertUtc -NotePropertyValue $now.ToString('o') -Force
    return $true
}

function Show-AlertWindow {
    param([string]$Title, [string]$Body, [int]$AutoCloseSeconds = 600)
    $alertScript = Join-Path $PSScriptRoot 'Show-FDriveAlert.ps1'
    if (-not (Test-Path -LiteralPath $alertScript)) {
        Write-MonitorLog "找不到提醒窗口脚本：$alertScript" 'WARN'
        return $false
    }
    $textFile = Join-Path $PSScriptRoot 'last-alert.txt'
    try {
        Set-Content -LiteralPath $textFile -Value $Body -Encoding UTF8 -ErrorAction Stop
    }
    catch { }

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argLine = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$alertScript`" -TextFile `"$textFile`" -Title `"$Title`" -AutoCloseSeconds $AutoCloseSeconds"
    if ($LogPath) { $argLine += " -LogPath `"$LogPath`"" }
    try {
        Start-Process -FilePath $psExe -ArgumentList $argLine -WindowStyle Hidden -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Write-MonitorLog "启动提醒窗口失败：$($_.Exception.Message)" 'WARN'
        return $false
    }
}

# ---------------------------------------------------------------- 提醒

function Send-MonitorAlert {
    param(
        [object[]]$Events,
        [switch]$Historical,
        [int]$ReportedTotal = 0
    )
    if (-not $Events -or $Events.Count -eq 0) { return }

    $c50 = @($Events | Where-Object { $_.Id -eq 50 }).Count
    $c140 = @($Events | Where-Object { $_.Id -eq 140 }).Count
    $first = ($Events | Select-Object -First 1).TimeCreated
    $last = ($Events | Select-Object -Last 1).TimeCreated
    $paths = @(Get-AffectedPaths -Events $Events -DriveLetter $Drv)
    $probeText = Format-ProbeResult (Test-DriveResponsive -DriveLetter $Drv -ProbeFile $ProbeFile)

    $total = if ($ReportedTotal -gt 0) { $ReportedTotal } else { $Events.Count }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("盘符        : $($Drv):")
    $lines.Add(("时间        : {0:yyyy-MM-dd HH:mm:ss} ~ {1:yyyy-MM-dd HH:mm:ss}" -f $first, $last))
    $lines.Add("事件        : 50(写入失败) $c50 条 / 140(事务日志无法刷新) $c140 条")
    if ($total -gt $Events.Count) {
        $lines.Add("说明        : 窗口内共 $total 条，这里只列最近 $($Events.Count) 条")
    }
    if ($paths.Count -gt 0) {
        $shown = @($paths | Select-Object -First 3)
        $lines.Add("涉及文件    : " + ($shown -join ' ; '))
        if ($paths.Count -gt 3) { $lines.Add("              … 共 $($paths.Count) 个文件") }
    }
    $lines.Add("当前探测    : $probeText")
    $lines.Add("")
    $lines.Add("建议        : 立即停止向 $($Drv): 写入；先把重要数据拷到其他盘；")
    $lines.Add("              若读取失败/无响应，直接断电重启后再试，不要反复重试。")
    $body = ($lines -join "`r`n")

    if ($Historical) {
        $title = "$($Drv): 盘曾有写入异常（历史 $total 条）"
    }
    else {
        $title = "$($Drv): 盘写入异常（$($Events.Count) 条新事件）"
    }

    Write-MonitorLog "ALERT $title | $($body -replace "`r`n", ' | ')" 'ALERT'
    if (-not $Quiet) { Write-Host $body -ForegroundColor Yellow }

    if ($AlertMode -eq 'Window') {
        $null = Show-AlertWindow -Title $title -Body $body -AutoCloseSeconds $AlertAutoCloseSeconds
    }
}

# ---------------------------------------------------------------- 检查主流程

function Invoke-MonitorCheck {
    $events = @(Get-MonitorEvents -DriveLetter $Drv -Hours $LookbackHours)
    $state = Read-MonitorState
    $dirty = $false

    $maxId = 0
    if ($events.Count -gt 0) {
        $maxId = [int64](($events | Measure-Object -Property RecordId -Maximum).Maximum)
    }

    # 首次运行 / 手动重建基线
    if ($Init -or $null -eq $state) {
        if ($events.Count -gt 0) {
            $sample = @($events | Select-Object -Last 20)
            Send-MonitorAlert -Events $sample -Historical -ReportedTotal $events.Count
        }
        $state = [pscustomobject]@{
            LastRecordId     = $maxId
            LastAlertUtc     = $null
            LastWheaAlertUtc = $null
            InstalledUtc     = (Get-Date).ToString('o')
            Drive            = $Drv
        }
        $dirty = $true
        Write-MonitorLog "已建立监控基线：$($Drv): 最后 RecordId=$maxId；窗口内历史事件 $($events.Count) 条"
        $null = Invoke-WheaCheck -State $state
        Save-MonitorState $state
        return
    }

    # 演示 / 手动测试：忽略基线，直接提醒最近 5 条，不改状态
    if ($Force) {
        $sample = @($events | Select-Object -Last 5)
        if ($sample.Count -eq 0) {
            Write-MonitorLog "Force 测试：最近 $LookbackHours 小时内没有 50/140 事件，无法演示。" 'WARN'
            return
        }
        Send-MonitorAlert -Events $sample
        return
    }

    # 链路错误（WHEA 17 / PCIe AER）：只记日志，不弹窗
    if (Invoke-WheaCheck -State $state) { $dirty = $true }

    # NTFS 50/140
    $new = @($events | Where-Object { [int64]$_.RecordId -gt [int64]$state.LastRecordId })
    if ($new.Count -eq 0) {
        if ($maxId -gt [int64]$state.LastRecordId) {
            $state.LastRecordId = $maxId
            $dirty = $true
        }
    }
    else {
        $now = Get-Date
        $throttled = $false
        if ($state.LastAlertUtc) {
            try {
                $lastAlert = [datetime]::Parse([string]$state.LastAlertUtc)
                if (($now - $lastAlert).TotalMinutes -lt $AlertThrottleMinutes) { $throttled = $true }
            }
            catch { }
        }

        if ($throttled) {
            Write-MonitorLog "新增 $($new.Count) 条 50/140，处于 $AlertThrottleMinutes 分钟提醒间隔内，仅记录。" 'WARN'
        }
        else {
            Send-MonitorAlert -Events $new
            $state.LastAlertUtc = $now.ToString('o')
        }

        $state.LastRecordId = $maxId
        $dirty = $true
    }

    if ($dirty) { Save-MonitorState $state }
}

# ---------------------------------------------------------------- 报告

function Show-Summary {
    $events = @(Get-MonitorEvents -DriveLetter $Drv -Hours $LookbackHours)
    Write-Host ''
    Write-Host "== $($Drv): 盘 NTFS 事件 50/140（最近 $LookbackHours 小时）==" -ForegroundColor Cyan

    $di = $null
    try { $di = New-Object System.IO.DriveInfo($Drv) } catch { }
    if ($di -and $di.IsReady) {
        Write-Host ("卷          : {0} / {1}，可用 {2:N1} GB，共 {3:N1} GB" -f $di.VolumeLabel, $di.DriveFormat, ($di.AvailableFreeSpace / 1GB), ($di.TotalSize / 1GB))
    }
    else {
        Write-Host '卷          : 当前不可用/未就绪' -ForegroundColor Yellow
    }

    if ($events.Count -eq 0) {
        Write-Host '事件        : 无（窗口内没有 50/140）' -ForegroundColor Green
    }
    else {
        $c50 = @($events | Where-Object { $_.Id -eq 50 }).Count
        $c140 = @($events | Where-Object { $_.Id -eq 140 }).Count
        Write-Host ("事件        : 共 {0} 条（50: {1} / 140: {2}）" -f $events.Count, $c50, $c140) -ForegroundColor Red
        Write-Host ("时间范围    : {0:yyyy-MM-dd HH:mm:ss} ~ {1:yyyy-MM-dd HH:mm:ss}" -f $events[0].TimeCreated, $events[-1].TimeCreated)

        Write-Host '按天统计    :'
        $events | Group-Object { $_.TimeCreated.ToString('yyyy-MM-dd') } | Sort-Object Name | ForEach-Object {
            Write-Host ("  {0}  {1} 条" -f $_.Name, $_.Count)
        }

        Write-Host '最近 5 条   :'
        $events | Select-Object -Last 5 | ForEach-Object {
            $msg = (([string]$_.Message) -split "`r?`n")[0]
            Write-Host ("  {0:HH:mm:ss}  Event {1}  {2}" -f $_.TimeCreated, $_.Id, $msg)
        }

        $paths = @(Get-AffectedPaths -Events $events -DriveLetter $Drv)
        if ($paths.Count -gt 0) {
            Write-Host ("涉及文件    : 共 {0} 个，例如：" -f $paths.Count)
            $paths | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" }
        }
    }

    $whea = @(Get-WheaEvents -Minutes ($LookbackHours * 60))
    if ($whea.Count -gt 0) {
        $lastW = ($whea | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
        Write-Host ("链路错误    : WHEA 17（PCIe AER）{0} 条，最近 {1:yyyy-MM-dd HH:mm:ss}" -f $whea.Count, $lastW) -ForegroundColor Yellow
    }
    else {
        Write-Host '链路错误    : 无（WHEA 17 = 0）' -ForegroundColor Green
    }

    Write-Host ("当前探测    : " + (Format-ProbeResult (Test-DriveResponsive -DriveLetter $Drv -ProbeFile $ProbeFile)))
    Write-Host ''
}

# ---------------------------------------------------------------- 入口

try {
    if ($Summary) {
        Show-Summary
        return
    }

    if ($Watch) {
        Write-MonitorLog "启动常驻监控：$($Drv): 每 $IntervalSeconds 秒检查一次（Ctrl+C 退出）"
        while ($true) {
            try { Invoke-MonitorCheck }
            catch { Write-MonitorLog "检查出错：$($_.Exception.Message)" 'ERROR' }
            Start-Sleep -Seconds ([math]::Max(5, $IntervalSeconds))
        }
    }
    else {
        Invoke-MonitorCheck
    }
}
catch {
    Write-MonitorLog "致命错误：$($_.Exception.Message)" 'ERROR'
    exit 1
}
