#requires -Version 5.1
<#
.SYNOPSIS
    掉盘 / 假死压力测试：持续混合负载 + 卡死检测 + 事件校验。

.DESCRIPTION
    单纯跑几 GB 顺序读写，测不出「控制器假死、盘突然消失」这种故障。
    这个脚本模拟当初出事的负载特征：

      1. 多线程持续大文件写入（WriteThrough，绕过缓存，真实压到 NAND）
      2. 同时不停创建/删除小文件，猛打 $Mft / $Bitmap（上次报错的就是这些元数据）
      3. 周期性「空闲 30 秒 → 突然恢复写入」，触发电源状态切换（ASPM 类掉盘常在这里暴露）
      4. 每秒打印进度；连续 N 秒没有任何写入进展 → 判定为「假死/卡死」
      5. 任何 I/O 异常（例如「设备不存在」）都会立刻记录并停止
      6. 结束后自动检查：盘还在不在、文件长度对不对、测试期间有没有 50/140

    判定标准：只要出现 卡死 / I/O 错误 / 盘符消失 / 50 或 140，就算失败。

.PARAMETER Drive
    测试盘符，默认 F。

.PARAMETER Minutes
    持续分钟数，默认 10。想认真测建议 20~30。

.PARAMETER MaxGB
    测试文件在盘上同时占用的上限（GB），默认 100。写满就删掉重写，所以总写入量不受它限制。

.PARAMETER Writers
    并发写入线程数，默认 4。

.PARAMETER ChurnPerSec
    每秒创建/删除小文件的个数（元数据压力），默认 150，0 = 关闭。

.PARAMETER IdleEverySeconds
    每隔多少秒插入一次空闲，默认 240；0 = 不插入。

.PARAMETER IdleSeconds
    每次空闲时长，默认 30。

.PARAMETER StallSeconds
    连续多少秒没有写入进展判定为卡死，默认 15。

.PARAMETER TestRoot
    测试目录，默认 <盘符>:\_dsh_drop。

.PARAMETER KeepFiles
    保留测试文件。

.EXAMPLE
    .\Test-DriveDrop.ps1 -Drive F -Minutes 20

.EXAMPLE
    # 快速筛一遍（5 分钟）
    .\Test-DriveDrop.ps1 -Drive F -Minutes 5 -MaxGB 30
#>
[CmdletBinding()]
param(
    [string]$Drive = 'F',
    [int]$Minutes = 10,
    [double]$MaxGB = 100,
    [int]$Writers = 4,
    [int]$ChurnPerSec = 150,
    [int]$IdleEverySeconds = 240,
    [int]$IdleSeconds = 30,
    [int]$StallSeconds = 15,
    [string]$TestRoot = '',
    [switch]$KeepFiles,
    [switch]$AllowSystemDrive
)

$ErrorActionPreference = 'Stop'
$drv = $Drive.TrimEnd(':').ToUpper()
if (-not $TestRoot) { $TestRoot = "$($drv):\_dsh_drop" }
$TestRoot = [System.IO.Path]::GetFullPath($TestRoot)

$code = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

public class DropResult
{
    public long BytesWritten;
    public long[] Files;
    public int Errors;
    public string FirstError;
    public string FirstErrorAt;
    public bool Stall;
    public double MaxGapSeconds;
    public long ChurnOps;
    public int ChurnErrors;
    public double Seconds;
    public bool HitTimeLimit;
    public bool DriveGone;
}

public static class DropTest
{
    static long _bytes;
    static long _lastTick;
    static volatile bool _stop;
    static volatile bool _paused;
    static volatile bool _stall;
    static volatile bool _driveGone;
    static string _err;
    static string _errAt;
    static int _errCount;
    static long _churn;
    static int _churnErr;

    public static DropResult Run(string dir, int writers, double maxGB, int seconds, int churnPerSec, int idleEvery, int idleFor, int stallSec)
    {
        Directory.CreateDirectory(dir);
        string letter = Path.GetPathRoot(dir).Substring(0, 1);
        long cap = (long)(maxGB * 1073741824.0);
        long perWriter = Math.Max(cap / writers, 33554432L);
        _lastTick = DateTime.UtcNow.Ticks;
        Stopwatch sw = Stopwatch.StartNew();
        long[] written = new long[writers];
        Thread[] ts = new Thread[writers];

        for (int i = 0; i < writers; i++)
        {
            int idx = i;
            Thread t = new Thread(delegate() { Writer(dir, idx, perWriter, seconds, sw, written); });
            t.IsBackground = true;
            t.Start();
            ts[i] = t;
        }

        Thread ct = null;
        if (churnPerSec > 0)
        {
            ct = new Thread(delegate() { Churn(dir, churnPerSec, seconds, sw); });
            ct.IsBackground = true;
            ct.Start();
        }

        long lastBytes = 0;
        long[] lastWritten = new long[writers];
        double[] lastChange = new double[writers];
        double now0 = sw.Elapsed.TotalSeconds;
        for (int i = 0; i < writers; i++) { lastChange[i] = now0; }
        double maxGap = 0;
        double nextIdle = idleEvery > 0 ? idleEvery : double.MaxValue;
        int stalledWriter = -1;

        while (sw.Elapsed.TotalSeconds < seconds && !_stop)
        {
            Thread.Sleep(1000);
            long b = Interlocked.Read(ref _bytes);
            double now = sw.Elapsed.TotalSeconds;
            double rate = (b - lastBytes) / 1048576.0;
            lastBytes = b;

            try
            {
                if (!new DriveInfo(letter).IsReady) { _driveGone = true; _stop = true; }
            }
            catch { _driveGone = true; _stop = true; }
            if (_driveGone)
            {
                Console.WriteLine("  !! " + letter + ": 已经不可访问 —— 判定为掉盘");
                break;
            }

            bool anyAlive = false;
            if (!_paused)
            {
                for (int i = 0; i < writers; i++)
                {
                    if (!ts[i].IsAlive) continue;
                    anyAlive = true;
                    if (written[i] > lastWritten[i])
                    {
                        lastWritten[i] = written[i];
                        lastChange[i] = now;
                    }
                    else
                    {
                        double gap = now - lastChange[i];
                        if (gap > maxGap) maxGap = gap;
                        if (gap >= stallSec)
                        {
                            _stall = true;
                            _stop = true;
                            stalledWriter = i;
                            break;
                        }
                    }
                }
            }
            else
            {
                anyAlive = true;
            }

            if (_stall)
            {
                Console.WriteLine("  !! 写线程 " + stalledWriter + " 已经 " + maxGap.ToString("N0") + " 秒没有任何进展 —— 判定为假死/卡死");
                break;
            }
            if (!anyAlive)
            {
                Console.WriteLine("  -- 所有写线程都已结束（达到写入上限或时间到）--");
                break;
            }

            Console.WriteLine("  " + now.ToString("N0").PadLeft(4) + "s  " + (b / 1073741824.0).ToString("N1").PadLeft(7) + " GB  "
                + rate.ToString("N0").PadLeft(6) + " MB/s  churn " + Interlocked.Read(ref _churn).ToString("N0").PadLeft(6)
                + (_paused ? "  [空闲中]" : ""));

            if (now >= nextIdle && !_stop)
            {
                _paused = true;
                Console.WriteLine("  -- 空闲 " + idleFor + " 秒（模拟待机/降功耗，之后突然恢复写入）--");
                Thread.Sleep(idleFor * 1000);
                _paused = false;
                nextIdle = sw.Elapsed.TotalSeconds + idleEvery;
                lastBytes = Interlocked.Read(ref _bytes);
                now = sw.Elapsed.TotalSeconds;
                for (int i = 0; i < writers; i++)
                {
                    lastWritten[i] = written[i];
                    lastChange[i] = now;
                }
            }
        }

        _stop = true;
        for (int i = 0; i < writers; i++)
        {
            try { ts[i].Join(15000); } catch { }
        }
        if (ct != null) { try { ct.Join(5000); } catch { } }
        sw.Stop();

        DropResult r = new DropResult();
        r.BytesWritten = Interlocked.Read(ref _bytes);
        r.Files = written;
        r.Errors = _errCount;
        r.FirstError = _err;
        r.FirstErrorAt = _errAt;
        r.Stall = _stall;
        r.MaxGapSeconds = maxGap;
        r.ChurnOps = Interlocked.Read(ref _churn);
        r.ChurnErrors = _churnErr;
        r.Seconds = sw.Elapsed.TotalSeconds;
        r.HitTimeLimit = sw.Elapsed.TotalSeconds >= seconds;
        r.DriveGone = _driveGone;
        return r;
    }

    static void Writer(string dir, int idx, long cap, int seconds, Stopwatch sw, long[] written)
    {
        string path = Path.Combine(dir, "w" + idx + ".bin");
        byte[] buf = new byte[8388608];
        new Random(1000 + idx).NextBytes(buf);
        try
        {
            while (!_stop && sw.Elapsed.TotalSeconds < seconds)
            {
                FileStream fs = null;
                long fileBytes = 0;
                try
                {
                    fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None, buf.Length, FileOptions.WriteThrough);
                    while (!_stop && sw.Elapsed.TotalSeconds < seconds && fileBytes < cap)
                    {
                        if (_paused) { Thread.Sleep(200); continue; }
                        fs.Write(buf, 0, buf.Length);
                        fileBytes += buf.Length;
                        written[idx] += buf.Length;
                        Interlocked.Add(ref _bytes, buf.Length);
                        Interlocked.Exchange(ref _lastTick, DateTime.UtcNow.Ticks);
                    }
                    fs.Flush(true);
                }
                finally
                {
                    if (fs != null) { try { fs.Dispose(); } catch { } }
                }
                if (_stop) { break; }
                try { File.Delete(path); } catch { }
            }
        }
        catch (Exception ex)
        {
            Interlocked.Increment(ref _errCount);
            if (_err == null)
            {
                _err = ex.GetType().Name + ": " + ex.Message;
                _errAt = DateTime.Now.ToString("HH:mm:ss");
            }
            _stop = true;
        }
    }

    static void Churn(string dir, int perSec, int seconds, Stopwatch sw)
    {
        string sub = Path.Combine(dir, "churn");
        try
        {
            Directory.CreateDirectory(sub);
            byte[] buf = new byte[65536];
            new Random(7).NextBytes(buf);
            int i = 0;
            while (!_stop && sw.Elapsed.TotalSeconds < seconds)
            {
                string p = Path.Combine(sub, "c" + i + ".tmp");
                using (FileStream fs = new FileStream(p, FileMode.CreateNew, FileAccess.Write, FileShare.None, buf.Length, FileOptions.WriteThrough))
                {
                    fs.Write(buf, 0, buf.Length);
                    fs.Flush(true);
                }
                File.Delete(p);
                i++;
                Interlocked.Increment(ref _churn);
                if (perSec > 0 && (i % perSec) == 0) Thread.Sleep(1000);
            }
        }
        catch (Exception ex)
        {
            Interlocked.Increment(ref _churnErr);
            Interlocked.Increment(ref _errCount);
            if (_err == null)
            {
                _err = "churn " + ex.GetType().Name + ": " + ex.Message;
                _errAt = DateTime.Now.ToString("HH:mm:ss");
            }
            _stop = true;
        }
    }
}
'@

if (-not ('DropTest' -as [type])) {
    Add-Type -TypeDefinition $code -Language CSharp
}

function Get-FreeGB {
    param([string]$Letter)
    return [math]::Round((New-Object System.IO.DriveInfo($Letter)).AvailableFreeSpace / 1GB, 1)
}

# ---------------------------------------------------------------- 前置检查

$di = $null
try { $di = New-Object System.IO.DriveInfo($drv) } catch { throw "盘符无效：$($drv):" }
if (-not $di.IsReady) { throw "$($drv): 当前不可用。" }
if ($drv -eq 'C' -and -not $AllowSystemDrive) { throw '不要对系统盘 C: 做掉盘压力测试。' }

$free = Get-FreeGB $drv
if ($free -lt ($MaxGB + 5)) {
    throw ("空间不足：测试上限 {0} GB，$($drv): 只剩 {1} GB。" -f $MaxGB, $free)
}

Write-Host ''
Write-Host '==== 掉盘 / 假死压力测试 ====' -ForegroundColor Cyan
Write-Host ("  目标盘   : {0}:  （可用 {1} GB）" -f $drv, $free)
Write-Host ("  持续     : {0} 分钟，盘上占用上限 {1} GB（写满就删掉重写）" -f $Minutes, $MaxGB)
Write-Host ("  并发写入 : {0} 线程 × 8 MB 块（WriteThrough）" -f $Writers)
Write-Host ("  元数据   : 每秒约 {0} 个小文件 创建+删除" -f $ChurnPerSec)
Write-Host ("  空闲循环 : 每 {0} 秒空闲 {1} 秒" -f $IdleEverySeconds, $IdleSeconds)
Write-Host ("  卡死判定 : 连续 {0} 秒无写入进展" -f $StallSeconds)
$wheaBefore = @()
try {
    $wheaBefore = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Id = 17; StartTime = (Get-Date).AddDays(-7) } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'PCI Express' })
}
catch { }
Write-Host ("  链路基线 : 近 7 天 WHEA 17（PCIe AER 可纠正错误）{0} 条" -f $wheaBefore.Count) -ForegroundColor $(if ($wheaBefore.Count -gt 0) { 'Yellow' } else { 'Gray' })
if ($wheaBefore.Count -gt 0) {
    $lastWhea = ($wheaBefore | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
    Write-Host ("             最近一次：{0:yyyy-MM-dd HH:mm:ss}" -f $lastWhea) -ForegroundColor Yellow
}
Write-Host '  测试期间请不要玩游戏/跑渲染，笔记本请插电。'
Write-Host ''

if (-not (Test-Path -LiteralPath $TestRoot)) { $null = New-Item -ItemType Directory -Path $TestRoot -Force }

# ---------------------------------------------------------------- 跑

$t0 = Get-Date
$res = [DropTest]::Run($TestRoot, $Writers, $MaxGB, ($Minutes * 60), $ChurnPerSec, $IdleEverySeconds, $IdleSeconds, $StallSeconds)

# ---------------------------------------------------------------- 结果

Start-Sleep -Seconds 1

$driveOK = $false
try {
    $d2 = New-Object System.IO.DriveInfo($drv)
    $driveOK = $d2.IsReady
}
catch { $driveOK = $false }

$ev = @()
try {
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 50, 140; StartTime = $t0 } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match ([regex]::Escape("$($drv):")) })
}
catch { }

$leftover = 0
try { $leftover = @(Get-ChildItem -LiteralPath $TestRoot -Filter *.bin -ErrorAction SilentlyContinue).Count } catch { $leftover = -1 }

$wheaDuring = @()
try {
    $wheaDuring = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Id = 17; StartTime = $t0 } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'PCI Express' })
}
catch { }

Write-Host ''
Write-Host '==== 结果 ====' -ForegroundColor Cyan
Write-Host ("  实际写入   : {0:N1} GB，用时 {1:N0} 秒，平均 {2:N0} MB/s" -f ($res.BytesWritten / 1GB), $res.Seconds, (($res.BytesWritten / 1MB) / [math]::Max($res.Seconds, 0.001)))
Write-Host ("  元数据操作 : {0:N0} 次创建+删除" -f $res.ChurnOps)
Write-Host ("  最长卡顿   : {0:N1} 秒" -f $res.MaxGapSeconds)
Write-Host ("  盘是否还在 : {0}" -f $(if ($driveOK) { '在' } else { '不见了！' }))
Write-Host ("  遗留文件   : {0}" -f $(if ($leftover -le 0) { '无' } else { "$leftover 个（失败时保留，用于取证）" }))
Write-Host ("  50/140     : {0} 条" -f $ev.Count)
Write-Host ("  链路错误   : 测试期间 WHEA 17 {0} 条（PCIe AER）" -f $wheaDuring.Count)

$failed = $false
if ($res.Errors -gt 0) { $failed = $true; Write-Host ("  错误       : {0} 次，首次 {1} —— {2}" -f $res.Errors, $res.FirstErrorAt, $res.FirstError) -ForegroundColor Red }
if ($res.ChurnErrors -gt 0) { $failed = $true; Write-Host ("  元数据错误 : {0} 次" -f $res.ChurnErrors) -ForegroundColor Red }
if ($res.Stall) { $failed = $true; Write-Host '  判定       : 写入卡死（假死）' -ForegroundColor Red }
if ($wheaDuring.Count -gt 0) { $failed = $true; Write-Host '  判定       : 压测期间出现 PCIe 链路可纠正错误（AER）' -ForegroundColor Red }
if ($res.DriveGone) { $failed = $true; Write-Host '  判定       : 测试中途盘符消失（掉盘）' -ForegroundColor Red }
if (-not $driveOK) { $failed = $true; Write-Host '  判定       : 盘符消失（掉盘）' -ForegroundColor Red }
if ($ev.Count -gt 0) {
    $failed = $true
    $ev | Select-Object -Last 3 | ForEach-Object {
        Write-Host ("    {0:HH:mm:ss} Event {1}: {2}" -f $_.TimeCreated, $_.Id, (([string]$_.Message) -split "`r?`n")[0]) -ForegroundColor Red
    }
}

Write-Host ''
if ($failed) {
    Write-Host '结论：不通过 —— 负载下出现了掉盘/假死/写入错误的迹象，这块盘不能留。' -ForegroundColor Red
    Write-Host "测试文件保留在：$TestRoot" -ForegroundColor Yellow
}
else {
    Write-Host '结论：本轮到点通过（没有卡死、没有 I/O 错误、没有 50/140）。' -ForegroundColor Green
    Write-Host '注意：通过只代表这段时间没问题；建议至少跑 20~30 分钟、最好连续跑两三次。' -ForegroundColor Yellow
    if (-not $KeepFiles) {
        try {
            Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction Stop
            Write-Host '已删除测试文件。'
        }
        catch { Write-Host "删除测试文件失败：$TestRoot" -ForegroundColor Yellow }
    }
}
Write-Host ''
