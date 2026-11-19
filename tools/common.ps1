# Shared helpers for winarchy's media tools. Dot-source it: . "$PSScriptRoot\common.ps1"
# Keep this file ASCII-only (Windows PowerShell 5.1 reads scripts as ANSI).

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type -Name Native -Namespace Winarchy -MemberDefinition @'
[DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
[DllImport("kernel32.dll")] public static extern bool FreeConsole();
[DllImport("kernel32.dll")] public static extern bool AttachConsole(uint pid);
[DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
[DllImport("kernel32.dll")] public static extern bool GenerateConsoleCtrlEvent(uint evt, uint group);
'@

# Programs can be found even when this process started before they were installed
# (its PATH is stale until you sign out and back in).
# Real install locations are tried before PATH: package managers often put a small
# "shim" exe on PATH that launches the real one as a child, which breaks stopping a
# recording cleanly.
function Find-Program([string]$Name, [string[]]$Patterns) {
    foreach ($p in $Patterns) {
        $hit = Get-ChildItem $p -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-Ffmpeg {
    $exe = Find-Program 'ffmpeg' @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Gyan.FFmpeg*\*\bin\ffmpeg.exe",
        "$env:ProgramFiles\ffmpeg\bin\ffmpeg.exe",
        "$env:ProgramData\chocolatey\lib\ffmpeg*\tools\ffmpeg\bin\ffmpeg.exe",
        "$env:USERPROFILE\scoop\apps\ffmpeg\current\bin\ffmpeg.exe")
    if (-not $exe) { throw 'ffmpeg is not installed. Install it with: winget install Gyan.FFmpeg' }
    return $exe
}

function Get-Magick {
    $exe = Find-Program 'magick' @("$env:ProgramFiles\ImageMagick-*\magick.exe")
    if (-not $exe) { throw 'ImageMagick is not installed. Install it with: winget install ImageMagick.ImageMagick' }
    return $exe
}

function Get-ZXing {
    $dll = Join-Path $PSScriptRoot 'zxing.dll'
    if (-not (Test-Path $dll)) { throw "zxing.dll is missing from $PSScriptRoot. Re-run the winarchy installer." }
    Add-Type -Path $dll
}

# A Windows notification (balloon) that stays a few seconds, then cleans up.
function Show-Note([string]$Title, [string]$Text, [int]$Seconds = 4) {
    $icon = New-Object System.Windows.Forms.NotifyIcon
    $icon.Icon = [System.Drawing.SystemIcons]::Information
    $icon.Visible = $true
    $icon.ShowBalloonTip($Seconds * 1000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]::None)
    Start-Sleep -Seconds $Seconds
    $icon.Dispose()
}

# Opens Windows' snipping overlay and returns the snipped region as a Bitmap, or $null
# if you cancel. Watches the clipboard instead of clearing it, so nothing is lost.
function Get-ScreenSnip([int]$TimeoutSeconds = 60) {
    $before = [Winarchy.Native]::GetClipboardSequenceNumber()
    Start-Process 'ms-screenclip:'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        if ([Winarchy.Native]::GetClipboardSequenceNumber() -ne $before -and [System.Windows.Forms.Clipboard]::ContainsImage()) {
            return [System.Drawing.Bitmap][System.Windows.Forms.Clipboard]::GetImage()
        }
    }
    return $null
}

# A single-keypress numbered menu in the terminal: returns the chosen item, or $null on Esc.
function Read-Choice([string]$Title, [object[]]$Options, [scriptblock]$Label = { $_ }) {
    Write-Host ''
    Write-Host "  $Title" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $text = & $Label $Options[$i]
        Write-Host ("   {0}  {1}" -f ($i + 1), $text)
    }
    Write-Host '   Esc  cancel' -ForegroundColor DarkGray
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Escape') { return $null }
        $n = [int]$k.KeyChar - [int][char]'0'
        if ($n -ge 1 -and $n -le $Options.Count) { return $Options[$n - 1] }
    }
}

# "C:\x\clip.mov" + "1080p" + "mp4" -> "C:\x\clip-1080p.mp4" (never overwrites).
function Get-OutputPath([string]$Source, [string]$Tag, [string]$Ext) {
    $dir = Split-Path $Source -Parent
    $base = [IO.Path]::GetFileNameWithoutExtension($Source)
    $out = Join-Path $dir "$base-$Tag.$Ext"
    $n = 2
    while (Test-Path $out) { $out = Join-Path $dir "$base-$Tag-$n.$Ext"; $n++ }
    return $out
}

function Show-InExplorer([string]$Path) { Start-Process explorer.exe "/select,`"$Path`"" }
