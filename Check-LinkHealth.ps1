#requires -Version 5.1
<#
.SYNOPSIS
    F 盘链路健康快照：PCIe 速率/宽度 + AER 可纠正错误 + NTFS 事件。

.DESCRIPTION
    换转接卡、换插槽、改 BIOS 前后各跑一次，直接对比数字，不用凭感觉。

    输出：
      - WHEA 17（PCIe AER 可纠正错误）：近 N 天总数、按天分布、最近一次时间
      - WHEA 47（内存可纠正错误）
      - NTFS 50/140（写入失败 / 事务日志无法刷新）
      - 当前 PCIe 链路速率与宽度（需要管理员权限）
      - 盘的可用空间

.PARAMETER Drive
    盘符，默认 F。

.PARAMETER PciMatch
    PCI 设备 InstanceId 的匹配串，留空时自动找第一个 NVMe 控制器（需要管理员权限）。
    多块 NVMe 时可显式指定，例如 -PciMatch 'PCI\VEN_144D&DEV_A808*'。

.PARAMETER Days
    回看天数，默认 7。

.PARAMETER Save
    追加一行到 LinkHealth.csv，方便横向对比。

.EXAMPLE
    .\Check-LinkHealth.ps1

.EXAMPLE
    .\Check-LinkHealth.ps1 -Save
#>
[CmdletBinding()]
param(
    [string]$Drive = 'F',
    [string]$PciMatch = '',
    [int]$Days = 7,
    [switch]$Save
)

$ErrorActionPreference = 'Continue'
$drv = $Drive.TrimEnd(':').ToUpper()
$now = Get-Date

# ------------------------------------------------ WHEA 17（PCIe AER）
$w17 = @()
try {
    $w17 = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Id = 17; StartTime = $now.AddDays(-$Days) } -ErrorAction SilentlyContinue)
}
catch { }
$pcie = @($w17 | Where-Object { $_.Message -match 'PCI Express' })
$today = @($pcie | Where-Object { $_.TimeCreated.Date -eq $now.Date })
$lastW = if ($pcie.Count -gt 0) { ($pcie | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated } else { $null }
$byDay = @($pcie | Group-Object { $_.TimeCreated.ToString('MM-dd') } | Sort-Object Name)

# ------------------------------------------------ WHEA 47（内存）
$w47 = @()
try {
    $w47 = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Id = 47; StartTime = $now.AddDays(-$Days) } -ErrorAction SilentlyContinue)
}
catch { }

# ------------------------------------------------ NTFS 50/140
$ntfs = @()
try {
    $ntfs = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 50, 140; StartTime = $now.AddDays(-1) } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match ([regex]::Escape("$($drv):")) })
}
catch { }

# ------------------------------------------------ PCIe 链路速率/宽度
$link = @{}
$pciOk = $false
try {
    if ($PciMatch) {
        $pci = Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Where-Object { $_.InstanceId -like $PciMatch } |
            Select-Object -First 1
    }
    else {
        # 未指定时自动找第一个 NVMe 控制器（PCI\VEN_* 且描述含 NVM）
        $pci = Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Where-Object { $_.InstanceId -like 'PCI\*' -and $_.FriendlyName -match 'NVM' } |
            Select-Object -First 1
    }
    if ($pci) {
        $pciOk = $true
        foreach ($k in 'CurrentLinkSpeed', 'CurrentLinkWidth', 'MaxLinkSpeed', 'MaxLinkWidth') {
            $val = 'n/a'
            try {
                $val = (Get-PnpDeviceProperty -InstanceId $pci.InstanceId -KeyName "DEVPKEY_PciDevice_$k" -ErrorAction Stop).Data
            }
            catch { }
            $link[$k] = $val
        }
    }
}
catch { }

# ------------------------------------------------ 盘
$ready = $false
$free = 'n/a'
try {
    $di = New-Object System.IO.DriveInfo($drv)
    $ready = $di.IsReady
    if ($ready) { $free = [math]::Round($di.AvailableFreeSpace / 1GB, 1) }
}
catch { }

# ------------------------------------------------ 输出
Write-Host ''
Write-Host ("==== {0}: 链路健康快照  {1:yyyy-MM-dd HH:mm:ss} ====" -f $drv, $now) -ForegroundColor Cyan

$color = if ($today.Count -eq 0) { 'Green' } else { 'Yellow' }
Write-Host ("  WHEA 17（PCIe AER） 近 {0} 天 : {1} 条   今天: {2} 条" -f $Days, $pcie.Count, $today.Count) -ForegroundColor $color
if ($byDay.Count -gt 0) {
    $line = ($byDay | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join '  '
    Write-Host ("    按天: $line")
}
if ($lastW) { Write-Host ("    最近一次: {0:yyyy-MM-dd HH:mm:ss}" -f $lastW) }

Write-Host ("  WHEA 47（内存）     : {0} 条" -f $w47.Count)
Write-Host ("  NTFS 50/140（24h）  : {0} 条" -f $ntfs.Count)

if ($pciOk) {
    $curS = $link['CurrentLinkSpeed']; $maxS = $link['MaxLinkSpeed']
    $curW = $link['CurrentLinkWidth']; $maxW = $link['MaxLinkWidth']
    $degraded = ($curS -ne $maxS) -or ($curW -ne $maxW)
    $lc = if ($degraded) { 'Red' } else { 'Green' }
    Write-Host ("  链路速率/宽度       : Gen{0} x{1}   (上限 Gen{2} x{3})" -f $curS, $curW, $maxS, $maxW) -ForegroundColor $lc
    if ($degraded) { Write-Host '    !! 链路已降级，检查转接卡/插槽接触' -ForegroundColor Red }
}
else {
    Write-Host '  链路速率/宽度       : 读取失败（需要管理员权限，或用 HWiNFO64 查看）' -ForegroundColor DarkGray
}

Write-Host ("  盘状态              : {0}，可用 {1} GB" -f $(if ($ready) { '正常' } else { '不可用' }), $free)
Write-Host ''

if ($Save) {
    $csv = Join-Path $PSScriptRoot 'LinkHealth.csv'
    $row = [pscustomobject]@{
        Time        = $now.ToString('yyyy-MM-dd HH:mm:ss')
        Drive       = $drv
        Whea17Days  = $pcie.Count
        Whea17Today = $today.Count
        Whea47      = $w47.Count
        Ntfs50_140  = $ntfs.Count
        LinkSpeed   = if ($pciOk) { $link['CurrentLinkSpeed'] } else { '' }
        LinkWidth   = if ($pciOk) { $link['CurrentLinkWidth'] } else { '' }
        FreeGB      = $free
    }
    if (-not (Test-Path -LiteralPath $csv)) {
        $row | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    }
    else {
        $row | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8 -Append
    }
    Write-Host "已追加到：$csv" -ForegroundColor DarkGray
    Write-Host ''
}
