<#
    winarchy: Screen recording toggle (Omarchy's "Trigger > Capture > Screenrecord").
    Run once to start recording the monitor under the mouse; run again to stop (Super+Shift+R).
    While recording, a red tray icon shows; the bar turns it into a REC timer, and clicking
    it also stops the recording.
    Saves to Videos\Screen recordings\winarchy-<date>.mp4 and shows it in Explorer.
    Uses the GPU encoder (NVENC) when there is one, otherwise x264. No audio.
#>
. "$PSScriptRoot\common.ps1"

$stateDir = Join-Path $env:LOCALAPPDATA 'winarchy'
$state = Join-Path $stateDir 'recording.json'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

function Stop-Recording($rec) {
    $proc = Get-Process -Id $rec.pid -ErrorAction SilentlyContinue
    if ($proc -and $proc.ProcessName -eq 'ffmpeg') {
        # Ctrl+C lets ffmpeg finish the mp4 properly (a hard kill leaves it unplayable).
        [Winarchy.Native]::FreeConsole() | Out-Null
        if ([Winarchy.Native]::AttachConsole([uint32]$rec.pid)) {
            [Winarchy.Native]::SetConsoleCtrlHandler([IntPtr]::Zero, $true) | Out-Null
            [Winarchy.Native]::GenerateConsoleCtrlEvent(0, 0) | Out-Null
            if (-not $proc.WaitForExit(10000)) { $proc.Kill() }
            [Winarchy.Native]::FreeConsole() | Out-Null
            [Winarchy.Native]::SetConsoleCtrlHandler([IntPtr]::Zero, $false) | Out-Null
        } else {
            $proc.Kill()
        }
    }
    Remove-Item $state -ErrorAction SilentlyContinue
    # The recording is a fragmented MP4, playable even if ffmpeg was cut off. Repackage
    # it as a regular MP4 (a fast stream copy, no re-encode) so every app can open it.
    if ((Test-Path $rec.temp) -and (Get-Item $rec.temp).Length -gt 0) {
        Start-Sleep -Milliseconds 500
        # The last frame is usually cut off; ffmpeg warns about it on stderr, which must
        # not count as a failure here.
        $ErrorActionPreference = 'Continue'
        & (Get-Ffmpeg) -hide_banner -loglevel fatal -y -i $rec.temp -c copy -movflags +faststart $rec.file 2>$null
        $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -eq 0 -and (Test-Path $rec.file)) { Remove-Item $rec.temp -ErrorAction SilentlyContinue }
        else { Move-Item $rec.temp $rec.file -Force }
    }
    if (Test-Path $rec.file) {
        Show-InExplorer $rec.file
        Show-Note 'Recording saved' (Split-Path $rec.file -Leaf)
    } else {
        Show-Note 'Recording stopped' 'No file was written.'
    }
}

# Already recording? Then this run stops it.
if (Test-Path $state) {
    Stop-Recording (Get-Content $state -Raw | ConvertFrom-Json)
    exit
}

# Start: capture the monitor under the mouse, in physical pixels.
[Winarchy.Native]::SetProcessDpiAwarenessContext([IntPtr]::new(-4)) | Out-Null
$screen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).Bounds
$w = $screen.Width - ($screen.Width % 2)
$h = $screen.Height - ($screen.Height % 2)

$dir = Join-Path ([Environment]::GetFolderPath('MyVideos')) 'Screen recordings'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$file = Join-Path $dir ('winarchy-' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') + '.mp4')
$temp = [IO.Path]::ChangeExtension($file, '.recording.mp4')

$ff = Get-Ffmpeg
$capture = @('-hide_banner', '-loglevel', 'error', '-f', 'gdigrab', '-framerate', '30', '-draw_mouse', '1',
    '-offset_x', $screen.X, '-offset_y', $screen.Y, '-video_size', "${w}x$h", '-i', 'desktop')
$encoders = @(
    @('-c:v', 'h264_nvenc', '-preset', 'p4', '-cq', '23'),
    @('-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '23'))

$proc = $null
foreach ($enc in $encoders) {
    $argList = $capture + $enc + @('-pix_fmt', 'yuv420p', '-movflags', '+frag_keyframe+empty_moov+default_base_moof', '-g', '60', "`"$temp`"")
    $proc = Start-Process $ff -ArgumentList $argList -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 1500
    if (-not $proc.HasExited) { break }   # this encoder works on this PC
    $proc = $null
}
# If what we started is a shim, the real recorder is its child; track that one instead.
if ($proc) {
    $child = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($proc.Id) AND Name='ffmpeg.exe'" | Select-Object -First 1
    if ($child) { $proc = Get-Process -Id $child.ProcessId }
}
if (-not $proc) {
    Show-Note 'Recording failed' 'ffmpeg could not start a recording on this PC.'
    exit 1
}

@{ pid = $proc.Id; file = $file; temp = $temp } | ConvertTo-Json | Set-Content $state -Encoding UTF8

# Stay running with a red tray icon until the recording stops. The bar shows this icon as a
# REC timer. Clicking it stops the recording here; pressing the hotkey again runs a second
# copy of this script, which stops ffmpeg, and this copy then sees it exit and cleans up.
$bmp = New-Object System.Drawing.Bitmap 16, 16
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(235, 70, 70))), 2, 2, 12, 12)
$g.Dispose()
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
$tray.Text = 'winarchy recording - click to stop'   # the bar looks for this text
$tray.Visible = $true
$tray.ShowBalloonTip(3000, 'Recording', 'Recording this screen. Press Super+Shift+R or click REC in the bar to stop.', [System.Windows.Forms.ToolTipIcon]::None)

$script:stopping = $false
$tray.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left -or $script:stopping) { return }
    $script:stopping = $true
    $tray.Visible = $false
    try { if (Test-Path $state) { Stop-Recording (Get-Content $state -Raw | ConvertFrom-Json) } }
    finally { [System.Windows.Forms.Application]::ExitThread() }
})
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({ if (-not $script:stopping -and $proc.HasExited) { [System.Windows.Forms.Application]::ExitThread() } })
$timer.Start()
[System.Windows.Forms.Application]::Run()
$timer.Dispose()
$tray.Visible = $false
$tray.Dispose()
