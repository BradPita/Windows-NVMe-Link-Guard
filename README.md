# Windows-NVMe-Link-Guard

> Windows 下的 NVMe / PCIe 链路稳定性监控与压测工具包  
> *Monitor, stress-test and diagnose NVMe / PCIe link instability on Windows.*

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![Platform](https://img.shields.io/badge/Windows-10%20%7C%2011-lightgrey)
![License](https://img.shields.io/badge/License-MIT-green)

---

## 为什么会有这个项目

一块 NVMe 盘在持续写入一段时间后会“消失”：资源管理器打不开、程序报错、事件日志里出现 `{Delayed Write Failed}`，重启后又恢复。用 `chkdsk /scan` 检查却是干净的——因为**文件系统没坏，是 PCIe 链路在出错**。

这类故障的早期信号不是“盘掉了”，而是 **WHEA 17（PCIe AER 可纠正错误）**：链路在不断重传、纠错，积累到一定程度才升级成设备消失。普通监控只看“盘在不在”，等到发现时已经晚了。

本项目就是从一次真实的掉盘排查里长出来的：**最终定位到根因是一根 M.2 延长排线**（直插后 30 分钟写入 2 TB，AER 从 39 条/10 分钟降到 0）。

---

## 它能做什么

| 能力 | 脚本 | 说明 |
|---|---|---|
| 后台监控 | `FDriveMonitor.ps1` | 监控 NTFS 事件 50/140 + WHEA 17，异常写日志（默认静默，不打扰） |
| 掉盘压测 | `Test-DriveDrop.ps1` | 多线程持续写入 + 元数据冲击 + 空闲唤醒，检测卡死/掉盘/AER |
| 读写校验 | `Test-DriveStress.ps1` | 顺序读写 + SHA256 回读校验，测速度与数据完整性 |
| 链路快照 | `Check-LinkHealth.ps1` | 一键输出 AER 按天统计、链路速率/宽度、盘状态 |

---

## 快速开始

```powershell
git clone https://github.com/<your-name>/Windows-NVMe-Link-Guard.git
cd Windows-NVMe-Link-Guard

# 以管理员身份运行：注册后台监控（登录后 30 秒 + 每 2 分钟）
powershell -ExecutionPolicy Bypass -File .\Install-FDriveMonitor.ps1 -Drive F
```

> 把 `-Drive F` 换成你的盘符。安装脚本会把监控注册成计划任务，并通过 `wscript` 静默启动，不产生任何窗口。

看一眼当前状态：

```powershell
powershell -ExecutionPolicy Bypass -File .\Check-LinkHealth.ps1
```

```
==== F: 链路健康快照  2026-01-01 12:00:00 ====
  WHEA 17（PCIe AER） 近 7 天 : 0 条   今天: 0 条
  WHEA 47（内存）     : 0 条
  NTFS 50/140（24h）  : 0 条
  链路速率/宽度       : Gen3 x4   (上限 Gen3 x4)
  盘状态              : 正常，可用 896.5 GB
```

> 示例输出。`WHEA 17` 不为 0 就说明链路在报可纠正错误，值得排查。

---

## 四个工具

### 1. 后台监控 `FDriveMonitor.ps1`

监控两类信号：

- `Ntfs` **50**：`{Delayed Write Failed}`，写入失败、数据已丢失
- `Microsoft-Windows-Ntfs` **140**：事务日志无法刷新，可能发生损坏
- `Microsoft-Windows-WHEA-Logger` **17**（PCI Express）：AER 可纠正错误，**掉盘前兆**

默认 **静默**：只写日志，不弹窗。通知规则：

| 信号 | 触发条件 | 记录 |
|---|---|---|
| 50 / 140 | 出现新事件 | `ALERT`，10 分钟内不重复 |
| WHEA 17 | 60 分钟内 ≥ 10 条 | `ALERT 链路错误`，120 分钟内不重复 |

```powershell
# 手动跑一次检查
.\FDriveMonitor.ps1

# 看报告
.\FDriveMonitor.ps1 -Summary

# 需要弹窗时（默认不弹）
.\FDriveMonitor.ps1 -AlertMode Window

# 灵敏度
.\FDriveMonitor.ps1 -WheaThreshold 5 -WheaWindowMinutes 30
```

日志与状态：`FDriveMonitor.log`、`FDriveMonitor.state.json`。

### 2. 掉盘压测 `Test-DriveDrop.ps1`

单纯跑几 GB 顺序读写，测不出“控制器假死”。这个脚本模拟真实故障场景：

- 4 线程 × 8 MB 块持续写入（`WriteThrough`，绕过系统缓存）
- 每秒约 150 个小文件创建 + 删除，猛打 `$Mft` / `$Bitmap`
- 每 4 分钟插入 30 秒空闲，再突然恢复写入（触发电源状态切换）
- **每个写线程独立监控进度**，连续 15 秒没推进 → 判定假死
- 每秒检查盘符是否还在 → 掉盘立即记录
- 结束后核对测试期间的 WHEA 17 / NTFS 50/140

```powershell
.\Test-DriveDrop.ps1 -Drive F -Minutes 30 -MaxGB 100
```

判定标准：**卡死 / I/O 错误 / 盘符消失 / 50 或 140 / 期间出现 AER**，任一命中即不通过。

### 3. 读写校验 `Test-DriveStress.ps1`

顺序写入随机数据 → `Flush` 强制落盘 → 读回计算 SHA256 → 对比。用来测速度与数据完整性。

```powershell
.\Test-DriveStress.ps1 -Drive F -SizeGB 20 -Rounds 3
```

### 4. 链路快照 `Check-LinkHealth.ps1`

输出 AER 按天统计、最近一次错误、NTFS 事件、链路速率/宽度、盘状态。适合换硬件/改 BIOS 前后对比。

```powershell
.\Check-LinkHealth.ps1 -Save    # 追加一行到 LinkHealth.csv
```

---

## 工作原理

| 事件 | 来源 | 含义 |
|---|---|---|
| 50 | `Ntfs` | 延迟写失败（数据丢失） |
| 140 | `Microsoft-Windows-Ntfs` | 事务日志刷新失败（可能损坏） |
| 17 | `WHEA-Logger` | PCIe AER 可纠正错误 |
| 129 / 11 | `stornvme` | NVMe 控制器重置 / 控制器错误 |
| 51 | `disk` | 分页操作时设备错误 |

**为什么盯 AER**：链路错误是可纠正的，会先出现；它不阻断 I/O，但频率上升意味着信号完整性在恶化。等到 `50/140` 出现时，数据已经开始丢了。

**为什么压测要混元数据操作**：真实故障里最先挂的往往是 `$Mft`、`$Bitmap` 这类元数据写入——纯大文件顺序写反而不容易复现。

---

## 目录结构

```
Windows-NVMe-Link-Guard/
├── FDriveMonitor.ps1          # 后台监控（静默，事件 50/140 + WHEA 17）
├── Show-FDriveAlert.ps1       # 可选弹窗（仅 -AlertMode Window 时使用）
├── Install-FDriveMonitor.ps1  # 安装/卸载计划任务（生成 Run-Monitor.vbs）
├── Run-Monitor.vbs            # wscript 静默启动器（无控制台窗口）
├── Test-DriveDrop.ps1         # 掉盘/假死压测（含 AER 统计）
├── Test-DriveStress.ps1       # 顺序读写 + SHA256 校验
├── Check-LinkHealth.ps1       # 链路健康快照
└── README.md
```

运行后会生成（已加入 `.gitignore`）：`FDriveMonitor.log`、`FDriveMonitor.state.json`、`last-alert.txt`、`LinkHealth.csv`。

---

## 参数速查

**FDriveMonitor.ps1**

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Drive` | `F` | 盘符 |
| `-LookbackHours` | 72 | 首次基线回看窗口 |
| `-AlertMode` | `LogOnly` | `LogOnly` / `Window` |
| `-WheaThreshold` | 10 | 多少条 AER 记一次告警 |
| `-WheaWindowMinutes` | 60 | AER 统计窗口 |
| `-WheaAlertThrottleMinutes` | 120 | 链路告警去重间隔 |
| `-Summary` / `-Force` / `-Init` | — | 报告 / 演示 / 重建基线 |

**Test-DriveDrop.ps1**

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Minutes` | 10 | 持续时长（建议 20~30） |
| `-MaxGB` | 100 | 盘上同时占用上限（写满自动删掉重写） |
| `-Writers` | 4 | 并发写线程 |
| `-ChurnPerSec` | 150 | 每秒小文件创建/删除数 |
| `-StallSeconds` | 15 | 无进展多久判定卡死 |

**Install-FDriveMonitor.ps1**

| 参数 | 说明 |
|---|---|
| `-Method Task` | 计划任务（推荐，需管理员） |
| `-Method Startup` | 启动文件夹（免管理员） |
| `-Uninstall` | 卸载 |
| `-IntervalMinutes` | 检查间隔，默认 2 |

---

## 常见问题

**Q：会不会一直弹窗打扰我？**  
不会。默认 `LogOnly`，只写日志；计划任务通过 `wscript` 启动，连控制台窗口都不会出现。

**Q：怎么确认后台任务在跑？**  
任务计划程序里看 `F Drive Health Monitor` 的「上次运行时间」；或看日志里有没有新的 `ALERT`。

**Q：日志在哪？**  
脚本同目录的 `FDriveMonitor.log`，超过 5 MB 自动轮转。

**Q：怎么卸载？**

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-FDriveMonitor.ps1 -Uninstall
```

**Q：压测会弄坏数据吗？**  
只在 `F:\_dsh_drop`（或 `-TestRoot` 指定目录）写临时文件，通过后自动删除，失败时保留用于取证。**不要对系统盘做掉盘压测。**

**Q：为什么读不到链路速率/宽度？**  
`Get-PnpDeviceProperty` 需要管理员权限；也可以直接用 HWiNFO64 看。

---

## 限制

- 仅支持 Windows + PowerShell 5.1 及以上。
- 只覆盖“操作系统可见”的信号，不读取 SMART 温度/寿命。
- 监控依赖计划任务，电脑关机/睡眠期间的事件会在下次登录后补报。
- 它是诊断工具，不是修复工具，也不能替代备份。

## License

MIT
