#requires -Version 5.1
<#
.SYNOPSIS
    F 盘监控的提醒窗口（由 FDriveMonitor.ps1 自动调用，一般不用手动运行）。

.DESCRIPTION
    读取提醒正文文本文件，显示一个置顶窗口；可打开日志、可自动关闭。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TextFile,
    [string]$Title = 'F 盘监控提醒',
    [string]$LogPath = '',
    [int]$AutoCloseSeconds = 600
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$body = ''
try {
    if (Test-Path -LiteralPath $TextFile) {
        $body = Get-Content -LiteralPath $TextFile -Raw -Encoding UTF8
    }
}
catch { $body = "（读取提醒内容失败：$($_.Exception.Message)）" }

try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }

$fontName = 'Microsoft YaHei UI'
try {
    $probe = New-Object System.Drawing.Font($fontName, 9)
    $probe.Dispose()
}
catch { $fontName = 'Segoe UI' }

$form = New-Object System.Windows.Forms.Form
$form.Text = $Title
$form.TopMost = $true
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MinimizeBox = $false
$form.MaximizeBox = $false
$form.ClientSize = New-Object System.Drawing.Size(620, 420)
$form.BackColor = [System.Drawing.Color]::FromArgb(255, 248, 240)

$header = New-Object System.Windows.Forms.Label
$header.Text = "⚠ $Title"
$header.Font = New-Object System.Drawing.Font($fontName, 12, [System.Drawing.FontStyle]::Bold)
$header.ForeColor = [System.Drawing.Color]::FromArgb(170, 30, 30)
$header.AutoSize = $true
$header.Location = New-Object System.Drawing.Point(14, 12)
$form.Controls.Add($header)

$box = New-Object System.Windows.Forms.TextBox
$box.Multiline = $true
$box.ReadOnly = $true
$box.ScrollBars = 'Vertical'
$box.Font = New-Object System.Drawing.Font($fontName, 10)
$box.Location = New-Object System.Drawing.Point(16, 48)
$box.Size = New-Object System.Drawing.Size(588, 300)
$box.Text = $body
$form.Controls.Add($box)

$btnLog = New-Object System.Windows.Forms.Button
$btnLog.Text = '打开日志'
$btnLog.Size = New-Object System.Drawing.Size(100, 32)
$btnLog.Location = New-Object System.Drawing.Point(300, 364)
$btnLog.Enabled = [bool]$LogPath
$btnLog.Add_Click({
        if ($script:LogPath -and (Test-Path -LiteralPath $script:LogPath)) {
            Start-Process notepad.exe -ArgumentList "`"$($script:LogPath)`""
        }
    })
$form.Controls.Add($btnLog)

$btnOk = New-Object System.Windows.Forms.Button
$btnOk.Text = '我知道了'
$btnOk.Size = New-Object System.Drawing.Size(100, 32)
$btnOk.Location = New-Object System.Drawing.Point(420, 364)
$btnOk.DialogResult = 'OK'
$form.Controls.Add($btnOk)
$form.AcceptButton = $btnOk

$countdown = New-Object System.Windows.Forms.Label
$countdown.AutoSize = $true
$countdown.Font = New-Object System.Drawing.Font($fontName, 8)
$countdown.ForeColor = [System.Drawing.Color]::Gray
$countdown.Location = New-Object System.Drawing.Point(16, 372)
$form.Controls.Add($countdown)

$script:remaining = $AutoCloseSeconds
$countdown.Text = "窗口将在 $($script:remaining) 秒后自动关闭"

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 1000
$script:timer.Add_Tick({
        $script:remaining--
        if ($script:remaining -le 0) {
            $script:timer.Stop()
            $form.Close()
        }
        else {
            $countdown.Text = "窗口将在 $($script:remaining) 秒后自动关闭"
        }
    })
$script:timer.Start()

$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()

$script:timer.Stop()
$form.Dispose()
