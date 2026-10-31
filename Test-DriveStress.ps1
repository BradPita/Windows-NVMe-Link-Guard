#requires -Version 5.1
<#
.SYNOPSIS
    硬盘顺序读写压力测试：写入 → 强制落盘 → 读回校验 → 自动清理。

.DESCRIPTION
    - 以 8 MB 块顺序写入随机数据，使用 WriteThrough 绕过系统缓存，真实压到盘上
    - 结束时 Flush 强制落盘，确保数据真的进了 NAND（也才能暴露延迟写失败）
    - 读回并计算 SHA256，与写入时对比，验证数据没有损坏
    - 统计写/读速度、单块最大延迟（卡顿会体现在这里）
    - 检查测试期间是否出现 NTFS 事件 50 / 140
    - 删除测试文件（除非加 -KeepFile）

    做散热稳定性测试：-Rounds 3~5，连续压 3~5 轮。

.PARAMETER Drive
    目标盘符，默认 I。

.PARAMETER SizeGB
    每轮写入的数据量（GB），默认 20。

.PARAMETER Rounds
    轮数，默认 1。

.PARAMETER BlockMB
    单次写入块大小（MB），默认 8。

.PARAMETER TestRoot
    测试文件存放目录。默认 <盘符>:\_dsh_stress。

.PARAMETER KeepFile
    保留测试文件（默认写完校验后就删除）。

.PARAMETER SkipVerify
    跳过读回校验（只测写入，速度快一倍）。

.EXAMPLE
    .\Test-DriveStress.ps1 -Drive F -SizeGB 20 -Rounds 3

.EXAMPLE
    # 快速版：只写 5 GB 不做校验
    .\Test-DriveStress.ps1 -Drive F -SizeGB 5 -SkipVerify
#>
[CmdletBinding()]
param(
    [string]$Drive = 'I',
    [double]$SizeGB = 20,
    [int]$Rounds = 1,
    [int]$BlockMB = 8,
    [string]$TestRoot = '',
    [switch]$KeepFile,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
$drv = $Drive.TrimEnd(':').ToUpper()
if (-not $TestRoot) { $TestRoot = "$($drv):\_dsh_stress" }
$TestRoot = [System.IO.Path]::GetFullPath($TestRoot)

function Get-FreeGB {
    param([string]$Letter)
    $d = New-Object System.IO.DriveInfo($Letter)
    return [math]::Round($d.AvailableFreeSpace / 1GB, 1)
}

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host "==== $Text ====" -ForegroundColor Cyan
}

# ---------------------------------------------------------------- 前置检查

$di = $null
try { $di = New-Object System.IO.DriveInfo($drv) } catch { throw "盘符无效：$($drv):" }
if (-not $di.IsReady) { throw "$($drv): 当前不可用。" }
if ($drv -eq 'C') { Write-Host '警告：正在测试系统盘 C:，请确认没有重要程序在跑。' -ForegroundColor Yellow }

$totalGB = $SizeGB * $Rounds
$free = Get-FreeGB $drv
if ($free -lt ($totalGB + 5)) {
    throw ("空间不足：需要约 {0} GB（含 5 GB 余量），$($drv): 只剩 {1} GB。" -f $totalGB, $free)
}

Write-Head "目标：$($drv):  每轮 $SizeGB GB × $Rounds 轮 = 约 $totalGB GB"
Write-Host "测试目录：$TestRoot"
Write-Host "可用空间：$free GB"

if (-not (Test-Path -LiteralPath $TestRoot)) {
    $null = New-Item -ItemType Directory -Path $TestRoot -Force
}

# ---------------------------------------------------------------- 测试

$bufSize = $BlockMB * 1MB
$results = New-Object System.Collections.Generic.List[object]

for ($round = 1; $round -le $Rounds; $round++) {
    Write-Head "第 $round / $Rounds 轮"

    $file = Join-Path $TestRoot ("stress_{0:yyyyMMdd_HHmmss}_r{1}.bin" -f (Get-Date), $round)
    $totalBytes = [int64]($SizeGB * 1GB)
    $t0 = Get-Date

    # ---------- 写 ----------
    $buf = New-Object byte[] $bufSize
    $rng = New-Object System.Random(1000 + $round)
    $rng.NextBytes($buf)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = $null
    $written = [int64]0
    $maxWriteMs = 0
    $swTotal = [System.Diagnostics.Stopwatch]::StartNew()
    $swTick = [System.Diagnostics.Stopwatch]::StartNew()
    $lastWritten = [int64]0

    try {
        $fs = New-Object System.IO.FileStream($file, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, $bufSize, [System.IO.FileOptions]::WriteThrough)
        while ($written -lt $totalBytes) {
            $toWrite = [int][math]::Min([int64]$bufSize, $totalBytes - $written)
            $swBlock = [System.Diagnostics.Stopwatch]::StartNew()
            $fs.Write($buf, 0, $toWrite)
            $swBlock.Stop()
            if ($swBlock.ElapsedMilliseconds -gt $maxWriteMs) { $maxWriteMs = [int]$swBlock.ElapsedMilliseconds }

            [void]$sha.TransformBlock($buf, 0, $toWrite, $null, 0)
            $written += $toWrite

            if ($swTick.Elapsed.TotalSeconds -ge 2) {
                $deltaMB = ($written - $lastWritten) / 1MB
                $speed = $deltaMB / $swTick.Elapsed.TotalSeconds
                Write-Host ("  写入 {0,6:N1} / {1:N1} GB   {2,7:N0} MB/s   已用 {3,5:N1}s" -f ($written / 1GB), $SizeGB, $speed, $swTotal.Elapsed.TotalSeconds)
                $lastWritten = $written
                $swTick.Restart()
            }
        }
        $fs.Flush($true)          # 强制落盘
        $fs.Dispose(); $fs = $null
    }
    finally {
        if ($fs) { $fs.Dispose() }
    }

    $swTotal.Stop()
    [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
    $writeHash = [System.BitConverter]::ToString($sha.Hash).Replace('-', '')
    $sha.Dispose()
    $writeSpeed = ($written / 1MB) / [math]::Max($swTotal.Elapsed.TotalSeconds, 0.001)

    Write-Host ("  写入完成：{0:N1} GB，{1:N0} MB/s，单块最大 {2} ms" -f ($written / 1GB), $writeSpeed, $maxWriteMs) -ForegroundColor Green

    # ---------- 读回校验 ----------
    $readOK = $null
    $readSpeed = $null
    $maxReadMs = 0
    $readHash = ''
    if (-not $SkipVerify) {
        $sha2 = [System.Security.Cryptography.SHA256]::Create()
        $fr = $null
        $read = [int64]0
        $swRead = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $fr = New-Object System.IO.FileStream($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read, $bufSize, [System.IO.FileOptions]::SequentialScan)
            $rbuf = New-Object byte[] $bufSize
            while (($n = $fr.Read($rbuf, 0, $bufSize)) -gt 0) {
                $swBlock = [System.Diagnostics.Stopwatch]::StartNew()
                [void]$sha2.TransformBlock($rbuf, 0, $n, $null, 0)
                $swBlock.Stop()
                if ($swBlock.ElapsedMilliseconds -gt $maxReadMs) { $maxReadMs = [int]$swBlock.ElapsedMilliseconds }
                $read += $n
            }
            $fr.Dispose(); $fr = $null
        }
        finally { if ($fr) { $fr.Dispose() } }
        $swRead.Stop()
        [void]$sha2.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $readHash = [System.BitConverter]::ToString($sha2.Hash).Replace('-', '')
        $sha2.Dispose()
        $readSpeed = ($read / 1MB) / [math]::Max($swRead.Elapsed.TotalSeconds, 0.001)
        $readOK = ($readHash -eq $writeHash)
        $color = if ($readOK) { 'Green' } else { 'Red' }
        Write-Host ("  读回校验：{0:N0} MB/s，SHA256 {1}" -f $readSpeed, $(if ($readOK) { '一致 ✔' } else { '不一致 ✘' })) -ForegroundColor $color
    }

    # ---------- 检查测试期间的事件 ----------
    $ev = @()
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 50, 140; StartTime = $t0 } -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match ([regex]::Escape("$($drv):")) })
    }
    catch { }

    $results.Add([pscustomobject]@{
            Round     = $round
            WriteMBs  = [math]::Round($writeSpeed, 0)
            ReadMBs   = if ($readSpeed) { [math]::Round($readSpeed, 0) } else { $null }
            MaxWriteMs = $maxWriteMs
            MaxReadMs = $maxReadMs
            Verified  = $readOK
            Events50_140 = $ev.Count
        })

    if ($ev.Count -gt 0) {
        Write-Host "  !! 测试期间出现 $($ev.Count) 条事件 50/140：" -ForegroundColor Red
        $ev | Select-Object -Last 3 | ForEach-Object {
            Write-Host ("     {0:HH:mm:ss}  Event {1}  {2}" -f $_.TimeCreated, $_.Id, (([string]$_.Message) -split "`r?`n")[0]) -ForegroundColor Red
        }
    }
    else {
        Write-Host '  测试期间无 50/140 事件。' -ForegroundColor Green
    }

    # ---------- 清理 ----------
    if ($KeepFile) {
        Write-Host "  保留文件：$file" -ForegroundColor Yellow
    }
    else {
        try {
            Remove-Item -LiteralPath $file -Force -ErrorAction Stop
            Write-Host '  已删除测试文件。'
        }
        catch {
            Write-Host "  删除失败（$($_.Exception.Message)）：$file" -ForegroundColor Yellow
        }
    }
}

# ---------------------------------------------------------------- 汇总

Write-Head '汇总'
$results | Format-Table -AutoSize

$bad = @($results | Where-Object { ($_.Verified -eq $false) -or ($_.Events50_140 -gt 0) })
if ($bad.Count -gt 0) {
    Write-Host '结论：出现校验失败或 50/140 事件，这块盘不稳定，建议直接换/退。' -ForegroundColor Red
}
else {
    Write-Host '结论：本轮压力测试通过（读写正常、校验一致、无 50/140）。' -ForegroundColor Green
}
Write-Host ''
Write-Host "剩余空间：$(Get-FreeGB $drv) GB"
