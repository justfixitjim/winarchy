# winarchy theme: apply one colour theme to everything at once.
#
#   theme.ps1 <id>            apply themes\<id>.json (for example tokyo-night)
#   theme.ps1 -Next           apply the next theme in the list
#   theme.ps1 -List           list themes (* marks the current one)
#   theme.ps1 -NextBackground show the current theme's next wallpaper
#   theme.ps1 -Background 2    show the current theme's third wallpaper
#   theme.ps1 -Restore        put back the Windows, Terminal and VS Code settings from before the first theme
#
# Targets: glazewm (window borders), bar (Zebar), menu (winarchy menu), windows (dark or light
# mode and accent colour), wallpaper (your own pictures in ~\.glzr\winarchy\backgrounds\<id>,
# then ones drawn from the theme's colours), firefox (browser toolbars, tabs and new tab page,
# through userChrome.css; takes effect when Firefox restarts), terminal (Windows Terminal colour scheme and a
# foot-like look: no tabs or title bar, Nerd Font, padding, no scrollbar), vscode (colour theme,
# installing its extension if needed). Pick with -Only or -Skip, or set "themeSkip" in
# ~\.glzr\winarchy\settings.json, for example "themeSkip": ["vscode"].
param(
    [Parameter(Position = 0)][string]$Name,
    [switch]$Next,
    [switch]$List,
    [switch]$Restore,
    [string[]]$Only = @(),
    [string[]]$Skip = @(),
    # Write the files but don't restart the bar or reload GlazeWM (used by install.ps1).
    [switch]$NoReload,
    # Report failures only in the console, not in a message box.
    [switch]$NoPopup,
    [switch]$NextBackground,
    # Show the current theme's wallpaper number N (counting from 0), as the menu's picker does.
    [int]$Background = -1
)
$ErrorActionPreference = 'Stop'

$root = Join-Path $env:USERPROFILE '.glzr\winarchy'
$themesDir = Join-Path $root 'themes'
$currentPath = Join-Path $root 'theme.json'
$stateDir = Join-Path $env:LOCALAPPDATA 'winarchy'   # generated wallpapers (a cache)
# The backup lives beside the theme, not in AppData, which packaged apps see a private copy of.
$backupPath = Join-Path $root 'theme-backup.json'
$logPath = Join-Path $root 'theme.log'
$oldBackup = Join-Path $stateDir 'theme-backup.json'
if (-not (Test-Path $backupPath) -and (Test-Path $oldBackup)) { Move-Item $oldBackup $backupPath }
$utf8 = New-Object Text.UTF8Encoding $false
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

function Read-Text($p) { [IO.File]::ReadAllText($p, $utf8) }
function Write-Text($p, $t) { [IO.File]::WriteAllText($p, $t, $utf8) }
function Log($msg) {
    Write-Host $msg
    Add-Content -Path $logPath -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg) -Encoding UTF8
}

# JSON with comments and trailing commas (Windows Terminal, VS Code) -> plain JSON.
function ConvertFrom-Jsonc([string]$text) {
    $sb = New-Object Text.StringBuilder
    $i = 0; $n = $text.Length; $inStr = $false
    $comma = -1   # where the last comma went, until something other than space follows it
    while ($i -lt $n) {
        $c = $text[$i]
        if ($inStr) {
            [void]$sb.Append($c)
            if ($c -eq '\' -and $i + 1 -lt $n) { [void]$sb.Append($text[$i + 1]); $i += 2; continue }
            if ($c -eq '"') { $inStr = $false }
            $i++; continue
        }
        if ($c -eq '"') { $inStr = $true; $comma = -1; [void]$sb.Append($c); $i++; continue }
        if ($c -eq '/' -and $i + 1 -lt $n -and $text[$i + 1] -eq '/') {
            while ($i -lt $n -and $text[$i] -ne "`n") { $i++ }
            continue
        }
        if ($c -eq '/' -and $i + 1 -lt $n -and $text[$i + 1] -eq '*') {
            $end = $text.IndexOf('*/', $i + 2)
            $i = if ($end -lt 0) { $n } else { $end + 2 }
            continue
        }
        if (-not [char]::IsWhiteSpace($c)) {
            # A trailing comma (before } or ]) is dropped. Commas inside strings never get here.
            if (($c -eq '}' -or $c -eq ']') -and $comma -ge 0) { [void]$sb.Remove($comma, 1) }
            $comma = if ($c -eq ',') { $sb.Length } else { -1 }
        }
        [void]$sb.Append($c); $i++
    }
    $plain = $sb.ToString()
    if (-not $plain.Trim()) { $plain = '{}' }
    return $plain | ConvertFrom-Json
}

# Registry DWORDs come back as Int32 or larger types; Set-ItemProperty wants the Int32 bit pattern.
function ConvertTo-Dword($v) { [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]([int64]$v -band 0xFFFFFFFFL)), 0) }

# ConvertTo-Json in PowerShell 5.1 pads with huge indents; re-indent to 4 spaces.
function Format-Json($obj) {
    $json = ConvertTo-Json -InputObject $obj -Depth 32
    $out = New-Object Text.StringBuilder
    $level = 0; $inStr = $false; $esc = $false
    foreach ($line in $json -split "`r?`n") {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t[0] -eq '}' -or $t[0] -eq ']') { $level-- }
        [void]$out.Append(('    ' * [Math]::Max($level, 0)) + ($t -replace '^("(?:[^"\\]|\\.)*"):\s+', '$1: ') + "`n")
        foreach ($ch in $t.ToCharArray()) {
            if ($esc) { $esc = $false; continue }
            if ($ch -eq '\') { $esc = $true; continue }
            if ($ch -eq '"') { $inStr = -not $inStr; continue }
            if (-not $inStr) { if ($ch -eq '{' -or $ch -eq '[') { $level++ } elseif ($ch -eq '}' -or $ch -eq ']') { $level-- } }
        }
        if ($t[0] -eq '}' -or $t[0] -eq ']') { $level++ }
    }
    return $out.ToString()
}

function Set-Prop($obj, $name, $value) {
    if ($obj.PSObject.Properties[$name]) { $obj.$name = $value }
    else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

function Get-Themes {
    Get-ChildItem $themesDir -Filter *.json | Sort-Object Name | ForEach-Object {
        $t = Read-Text $_.FullName | ConvertFrom-Json
        [pscustomobject]@{ Id = $_.BaseName; Name = $t.name; Theme = $t }
    }
}

function Get-CurrentId {
    if (Test-Path $currentPath) { try { return (Read-Text $currentPath | ConvertFrom-Json).id } catch {} }
    return 'tokyo-night'
}

# --- Backup (first run only), so -Restore and uninstall can put things back -----------
$regValues = @(
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', 'AppsUseLightTheme'),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', 'SystemUsesLightTheme'),
    @('HKCU:\Software\Microsoft\Windows\DWM', 'AccentColor'),
    @('HKCU:\Software\Microsoft\Windows\DWM', 'ColorizationColor'),
    @('HKCU:\Software\Microsoft\Windows\DWM', 'ColorizationAfterglow'),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent', 'AccentColorMenu'),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent', 'StartColorMenu'),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent', 'AccentPalette'),
    @('HKCU:\Control Panel\Desktop', 'AutoColorization'),
    @('HKCU:\Control Panel\Desktop', 'Wallpaper'),
    @('HKCU:\Control Panel\Desktop', 'WallpaperStyle'),
    @('HKCU:\Control Panel\Desktop', 'TileWallpaper')
)
$vscodeSettings = Join-Path $env:APPDATA 'Code\User\settings.json'
$terminalSettings = @(
    "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
    "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
    "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
) | Where-Object { Test-Path $_ }

function Save-Backup {
    # Each Terminal's settings are saved before winarchy first changes them, also when that
    # Terminal is installed after the first theme.
    foreach ($ts in $terminalSettings) { if ((Test-Path $ts) -and -not (Test-Path "$ts.winarchy-backup")) { Copy-Item $ts "$ts.winarchy-backup" } }
    if (Test-Path $backupPath) { return }
    $reg = foreach ($rv in $regValues) {
        $item = Get-ItemProperty -Path $rv[0] -Name $rv[1] -ErrorAction SilentlyContinue
        $v = if ($item) { $item.($rv[1]) } else { $null }
        if ($v -is [array]) { @{ Path = $rv[0]; Name = $rv[1]; Kind = 'Binary'; Value = [Convert]::ToBase64String([byte[]]$v) } }  # binary values arrive as object[]
        elseif ($v -is [string]) { @{ Path = $rv[0]; Name = $rv[1]; Kind = 'String'; Value = $v } }
        elseif ($null -ne $v) { @{ Path = $rv[0]; Name = $rv[1]; Kind = 'DWord'; Value = (ConvertTo-Dword $v) } }
        else { @{ Path = $rv[0]; Name = $rv[1]; Kind = 'None'; Value = $null } }
    }
    $vs = $null
    if (Test-Path $vscodeSettings) {
        try { $p = (ConvertFrom-Jsonc (Read-Text $vscodeSettings)).PSObject.Properties['workbench.colorTheme']; if ($p) { $vs = $p.Value } } catch {}
    }
    Write-Text $backupPath ((@{ Registry = @($reg); VSCodeTheme = $vs } | ConvertTo-Json -Depth 5) + "`n")
}

Add-Type -Namespace Winarchy -Name Native -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern bool SystemParametersInfo(uint action, uint param, string value, uint flags);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
function Send-ColorChange {
    $r = [UIntPtr]::Zero
    foreach ($area in 'ImmersiveColorSet', 'WindowsThemeElement') {
        [void][Winarchy.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, $area, 2, 1000, [ref]$r)
    }
}

# --- Wallpapers -----------------------------------------------------------------------------
function Set-Wallpaper([string]$path, [switch]$KeepStyle) {
    if (-not $KeepStyle) {
        Set-ItemProperty 'HKCU:\Control Panel\Desktop' WallpaperStyle '10' -Type String   # fill
        Set-ItemProperty 'HKCU:\Control Panel\Desktop' TileWallpaper '0' -Type String
    }
    # SPI_SETDESKWALLPAPER, saved to the profile and broadcast.
    if (-not [Winarchy.Native]::SystemParametersInfo(0x14, 0, $path, 3)) { throw "Windows refused the wallpaper $path" }
}

function ConvertTo-Color([string]$hex, [int]$alpha = 255) {
    $h = $hex.TrimStart('#')
    [Drawing.Color]::FromArgb($alpha, [Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16))
}

# Three wallpapers drawn from the theme's colours, at the main screen's resolution (cached).
function New-ThemeBackgrounds($id, $theme) {
    Add-Type -AssemblyName System.Drawing, System.Windows.Forms
    [void][Winarchy.Native]::SetProcessDPIAware()
    $screen = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $w = [Math]::Max($screen.Width, 1280); $h = [Math]::Max($screen.Height, 720)
    $dir = Join-Path $stateDir 'backgrounds'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $themeFile = Join-Path $themesDir "$id.json"
    $c = $theme.colors; $tc = $theme.terminal
    $out = @()
    foreach ($style in 'glow', 'bands', 'grid') {
        $file = Join-Path $dir ("{0}-{1}-{2}x{3}.png" -f $id, $style, $w, $h)
        $out += $file
        if ((Test-Path $file) -and (Get-Item $file).LastWriteTime -gt (Get-Item $themeFile).LastWriteTime) { continue }
        $bmp = New-Object Drawing.Bitmap $w, $h
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $rect = New-Object Drawing.Rectangle 0, 0, $w, $h
        $base = New-Object Drawing.Drawing2D.LinearGradientBrush $rect, (ConvertTo-Color $c.background), (ConvertTo-Color $c.surface), 90
        $g.FillRectangle($base, $rect)
        switch ($style) {
            'glow' {
                foreach ($spot in @(@(0.78, 0.72, 0.9, $c.accent, 70), @(0.15, 0.2, 0.6, $tc.magenta, 40))) {
                    $d = [int]($w * $spot[2])
                    $path = New-Object Drawing.Drawing2D.GraphicsPath
                    $path.AddEllipse([int]($w * $spot[0] - $d / 2), [int]($h * $spot[1] - $d / 2), $d, $d)
                    $pg = New-Object Drawing.Drawing2D.PathGradientBrush $path
                    $pg.CenterColor = ConvertTo-Color $spot[3] $spot[4]
                    $pg.SurroundColors = @([Drawing.Color]::FromArgb(0, 0, 0, 0))
                    $pg.SetSigmaBellShape(1.0, 1.0)   # soft falloff, no visible edge
                    $g.FillPath($pg, $path)
                }
            }
            'bands' {
                $colors = @($tc.blue, $tc.magenta, $tc.cyan, $tc.green, $tc.yellow, $tc.red)
                $g.TranslateTransform($w * 0.6, $h * 0.5); $g.RotateTransform(-28)
                $bw = [int]($h * 0.07)
                for ($k = 0; $k -lt $colors.Count; $k++) {
                    $brush = New-Object Drawing.SolidBrush (ConvertTo-Color $colors[$k] 46)
                    $g.FillRectangle($brush, -$w * 1.5, ($k - 3) * $bw * 1.25, $w * 3, $bw)
                }
                $g.ResetTransform()
            }
            'grid' {
                $step = [int]($h / 36); $r = [Math]::Max(2, [int]($step / 9))
                $dot = New-Object Drawing.SolidBrush (ConvertTo-Color $c.muted 90)
                $hot = New-Object Drawing.SolidBrush (ConvertTo-Color $c.accent 200)
                $rnd = New-Object Random ($id.GetHashCode())
                for ($y = $step; $y -lt $h; $y += $step) {
                    for ($x = $step; $x -lt $w; $x += $step) {
                        $b = if ($rnd.Next(60) -eq 0) { $hot } else { $dot }
                        $g.FillEllipse($b, $x - $r, $y - $r, 2 * $r, 2 * $r)
                    }
                }
            }
        }
        $g.Dispose()
        $bmp.Save($file, [Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    }
    return $out
}

function Get-Backgrounds($id, $theme) {
    $list = @()
    $own = Join-Path $root "backgrounds\$id"
    if (Test-Path $own) {
        $list += @(Get-ChildItem $own -File | Where-Object { $_.Extension -match '^\.(jpe?g|png|bmp)$' } | Sort-Object Name | ForEach-Object { $_.FullName })
    }
    $list += @(New-ThemeBackgrounds $id $theme)
    return $list
}

# --- Firefox: chrome\winarchy.css, imported from userChrome.css / userContent.css -----------
function Get-FirefoxProfiles {
    $base = Join-Path $env:APPDATA 'Mozilla\Firefox'
    $ini = Join-Path $base 'profiles.ini'
    if (-not (Test-Path $ini)) { return @() }
    $profiles = @(); $path = $null; $rel = $true
    foreach ($line in (Get-Content $ini) + '[end]') {
        if ($line -match '^\[') {
            if ($path) { $profiles += $(if ($rel) { Join-Path $base ($path -replace '/', '\') } else { $path }) }
            $path = $null; $rel = $true
        }
        elseif ($line -match '^Path=(.+)$') { $path = $Matches[1] }
        elseif ($line -match '^IsRelative=0') { $rel = $false }
    }
    # Only profiles that have been used (others are leftovers and background-task profiles).
    return @($profiles | Where-Object { (Test-Path (Join-Path $_ 'prefs.js')) -and $_ -notmatch 'MozillaBackgroundTask' })
}

$ffPref = 'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true); // winarchy'

function Add-FirstLine($file, $line) {
    $text = if (Test-Path $file) { Read-Text $file } else { '' }
    if ($text -notmatch [regex]::Escape($line)) { Write-Text $file ($line + "`n" + $text) }
}
function Remove-WinarchyLines($file) {
    if (-not (Test-Path $file)) { return }
    $rest = @((Read-Text $file) -split "`r?`n" | Where-Object { $_ -notmatch '/[/*] winarchy' })
    if (-not ($rest -join '').Trim()) { Remove-Item $file } else { Write-Text $file (($rest -join "`n").TrimEnd() + "`n") }
}

if ($Restore) {
    foreach ($prof in Get-FirefoxProfiles) {
        $chrome = Join-Path $prof 'chrome'
        Remove-WinarchyLines (Join-Path $chrome 'userChrome.css')
        Remove-WinarchyLines (Join-Path $chrome 'userContent.css')
        Remove-Item (Join-Path $chrome 'winarchy.css'), (Join-Path $chrome 'winarchy-content.css') -ErrorAction SilentlyContinue
        Remove-WinarchyLines (Join-Path $prof 'user.js')
        if ((Test-Path $chrome) -and -not (Get-ChildItem $chrome)) { Remove-Item $chrome }
    }

    if (-not (Test-Path $backupPath)) { Log 'Firefox restored; nothing else to restore.'; return }
    $b = Read-Text $backupPath | ConvertFrom-Json
    foreach ($r in $b.Registry) {
        if ($r.Kind -eq 'None') { Remove-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction SilentlyContinue; continue }
        if (-not (Test-Path $r.Path)) { New-Item -Path $r.Path -Force | Out-Null }
        $v = if ($r.Kind -eq 'Binary') { [Convert]::FromBase64String($r.Value) } elseif ($r.Kind -eq 'String') { [string]$r.Value } else { ConvertTo-Dword $r.Value }
        Set-ItemProperty -Path $r.Path -Name $r.Name -Value $v -Type $r.Kind
    }
    Send-ColorChange
    $wp = $b.Registry | Where-Object { $_.Name -eq 'Wallpaper' }
    if ($wp -and $wp.Kind -eq 'String') { Set-Wallpaper $wp.Value -KeepStyle }
    foreach ($ts in $terminalSettings) { if (Test-Path "$ts.winarchy-backup") { Move-Item "$ts.winarchy-backup" $ts -Force } }
    if (Test-Path $vscodeSettings) {
        $vs = ConvertFrom-Jsonc (Read-Text $vscodeSettings)
        $now = $vs.PSObject.Properties['workbench.colorTheme']
        if (($now -and $now.Value) -ne $b.VSCodeTheme) {
            if ($b.VSCodeTheme) { Set-Prop $vs 'workbench.colorTheme' $b.VSCodeTheme } else { $vs.PSObject.Properties.Remove('workbench.colorTheme') }
            Write-Text $vscodeSettings (Format-Json $vs)
        }
    }
    Remove-Item $backupPath
    Log 'Restored the Windows, wallpaper, Terminal, VS Code and Firefox settings from before winarchy themes.'
    return
}

$themes = @(Get-Themes)
if ($NextBackground -or $Background -ge 0) {
    $state = Read-Text $currentPath | ConvertFrom-Json
    $th = ($themes | Where-Object { $_.Id -eq $state.id } | Select-Object -First 1).Theme
    $bgs = @(Get-Backgrounds $state.id $th)
    $i = if ($Background -ge 0) { $Background % $bgs.Count } else { ([int]$state.background + 1) % $bgs.Count }
    Save-Backup
    Set-Wallpaper $bgs[$i]
    Set-Prop $state 'background' $i
    Write-Text $currentPath (($state | ConvertTo-Json -Depth 5) + "`n")
    Log "Background $($i + 1) of $($bgs.Count): $(Split-Path $bgs[$i] -Leaf)"
    return
}
if ($List) {
    $cur = Get-CurrentId
    foreach ($t in $themes) { '{0} {1,-18} {2}' -f $(if ($t.Id -eq $cur) { '*' } else { ' ' }), $t.Id, $t.Name }
    return
}
if ($Next) {
    $cur = Get-CurrentId
    $i = [array]::IndexOf(@($themes.Id), $cur)
    $Name = $themes[($i + 1) % $themes.Count].Id
}
if (-not $Name) { throw 'Give a theme id (theme.ps1 -List shows them), -Next, or -Restore.' }
$pick = $themes | Where-Object { $_.Id -eq $Name -or $_.Name -eq $Name } | Select-Object -First 1
if (-not $pick) { throw "No theme called '$Name'. Themes: $($themes.Id -join ', ')" }
$t = $pick.Theme
$c = $t.colors

# Targets to apply.
$settingsPath = Join-Path $root 'settings.json'
if (Test-Path $settingsPath) {
    try { $s = Read-Text $settingsPath | ConvertFrom-Json; if ($s.themeSkip) { $Skip += @($s.themeSkip) } } catch {}
}
$Skip = @($Skip | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLower() })
$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLower() })
function Want($target) { ($Only.Count -eq 0 -or $Only -contains $target) -and -not ($Skip -contains $target) }

Log "Theme: $($t.name)"
$errors = @()
function Try-Target($target, [scriptblock]$block) {
    if (-not (Want $target)) { return }
    try { & $block } catch { $script:errors += "${target}: $($_.Exception.Message)"; Log "  ${target}: FAILED - $($_.Exception.Message) [$($_.InvocationInfo.ScriptLineNumber)]" }
}

# Remember the choice (the winarchy menu reads its colours from here).
$cur = [ordered]@{ id = $pick.Id; name = $t.name; mode = $t.mode; background = 0; colors = $c }
Write-Text $currentPath (($cur | ConvertTo-Json -Depth 5) + "`n")
if (Want 'menu') { Log '  menu: next time it opens' }

# GlazeWM and Zebar: per-user copy (install.ps1 -User) first, then Program Files.
function Get-GlzrPath([string]$Relative) {
    $user = Join-Path $env:LOCALAPPDATA "Programs\glzr.io\$Relative"
    if (Test-Path $user) { return $user }
    return Join-Path $env:ProgramFiles "glzr.io\$Relative"
}

Try-Target 'glazewm' {
    $cfg = Join-Path $env:USERPROFILE '.glzr\glazewm\config.yaml'
    if (-not (Test-Path $cfg)) { throw 'GlazeWM config not found' }
    $y = Read-Text $cfg
    $pat = "(?s)({0}:\s*\r?\n\s*border:\s*\r?\n\s*enabled:[^\n]*\n\s*color:\s*)'[^']*'"
    $new = [regex]::Replace($y, ($pat -f 'focused_window'), "`$1'$($c.accent)'")
    $new = [regex]::Replace($new, ($pat -f 'other_windows'), "`$1'$($c.border_inactive)'")
    if ($new -ne $y) { Write-Text $cfg $new }
    if (-not $NoReload -and (Get-Process glazewm -ErrorAction SilentlyContinue)) {
        & (Get-GlzrPath "GlazeWM\cli\glazewm.exe") command wm-reload-config | Out-Null
    }
    Log '  glazewm: borders'
}

Try-Target 'bar' {
    $pack = Join-Path $env:USERPROFILE '.glzr\zebar\winarchy'
    if (-not (Test-Path $pack)) { throw 'winarchy Zebar pack not found' }
    $css = ":root {`n" + (@(
        "  --wa-bg: $($c.background);", "  --wa-fg: $($c.foreground);", "  --wa-muted: $($c.muted);",
        "  --wa-accent: $($c.accent);", "  --wa-red: $($c.red);", "  --wa-green: $($c.green);", "  --wa-yellow: $($c.yellow);"
    ) -join "`n") + "`n}`n"
    Write-Text (Join-Path $pack 'theme.css') $css
    if (-not $NoReload -and (Get-Process zebar -ErrorAction SilentlyContinue)) {
        Get-Process zebar | Stop-Process -Force
        # Wait until Zebar and its web views have gone, then a little longer: a Zebar started
        # within about a second of the last one exiting often can't load its bar (it shows the
        # web view's grey "can't reach this page" strip). 2 s was always enough in testing.
        for ($i = 0; $i -lt 40; $i++) {
            $alive = [bool](Get-Process zebar -ErrorAction SilentlyContinue) -or [bool](Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -match 'zebar' })
            if (-not $alive) { break }
            Start-Sleep -Milliseconds 250
        }
        Start-Sleep -Seconds 3
        Start-Process (Get-GlzrPath "Zebar\zebar.exe")
    }
    Log '  bar: colours'
}

Try-Target 'windows' {
    Save-Backup
    $light = [int]($t.mode -eq 'light')
    $pers = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    Set-ItemProperty $pers AppsUseLightTheme $light -Type DWord
    Set-ItemProperty $pers SystemUsesLightTheme $light -Type DWord

    # Accent colour: Windows stores it as ABGR, plus a palette of 8 shades (RGBA).
    $hex = $c.accent.TrimStart('#')
    $r = [Convert]::ToInt32($hex.Substring(0, 2), 16); $g = [Convert]::ToInt32($hex.Substring(2, 2), 16); $bl = [Convert]::ToInt32($hex.Substring(4, 2), 16)
    function Shade($f) {
        if ($f -ge 0) { @([int]($r + (255 - $r) * $f), [int]($g + (255 - $g) * $f), [int]($bl + (255 - $bl) * $f)) }
        else { @([int]($r * (1 + $f)), [int]($g * (1 + $f)), [int]($bl * (1 + $f))) }
    }
    function Abgr($rgb) { ConvertTo-Dword (0xFF000000L + ($rgb[2] -shl 16) + ($rgb[1] -shl 8) + $rgb[0]) }
    $shades = @(0.6, 0.4, 0.2, 0, -0.2, -0.4, -0.6, -0.3) | ForEach-Object { , (Shade $_) }
    $palette = New-Object byte[] 32
    for ($k = 0; $k -lt 8; $k++) { $palette[$k * 4] = $shades[$k][0]; $palette[$k * 4 + 1] = $shades[$k][1]; $palette[$k * 4 + 2] = $shades[$k][2] }
    $accentKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'
    if (-not (Test-Path $accentKey)) { New-Item -Path $accentKey -Force | Out-Null }
    Set-ItemProperty $accentKey AccentPalette $palette -Type Binary
    Set-ItemProperty $accentKey AccentColorMenu (Abgr $shades[3]) -Type DWord
    Set-ItemProperty $accentKey StartColorMenu (Abgr $shades[5]) -Type DWord
    $argb = ConvertTo-Dword (0xC4000000L + ($r -shl 16) + ($g -shl 8) + $bl)
    $dwm = 'HKCU:\Software\Microsoft\Windows\DWM'
    Set-ItemProperty $dwm AccentColor (Abgr $shades[3]) -Type DWord
    Set-ItemProperty $dwm ColorizationColor $argb -Type DWord
    Set-ItemProperty $dwm ColorizationAfterglow $argb -Type DWord
    Set-ItemProperty 'HKCU:\Control Panel\Desktop' AutoColorization 0 -Type DWord  # don't pick the accent from the wallpaper
    Send-ColorChange
    Log "  windows: $($t.mode) mode, accent $($c.accent)"
}

Try-Target 'wallpaper' {
    Save-Backup
    $bgs = @(Get-Backgrounds $pick.Id $t)
    Set-Wallpaper $bgs[0]
    Log "  wallpaper: $(Split-Path $bgs[0] -Leaf) (1 of $($bgs.Count); menu > Appearance > Next background)"
}

Try-Target 'firefox' {
    $profiles = @(Get-FirefoxProfiles)
    if (-not $profiles) { Log '  firefox: not installed, skipped'; return }
    $tc = $t.terminal
    $v = [ordered]@{
        '--toolbox-bgcolor' = $c.surface; '--toolbox-bgcolor-inactive' = $c.surface; '--toolbox-textcolor' = $c.foreground
        '--lwt-accent-color' = $c.surface; '--lwt-accent-color-inactive' = $c.surface; '--lwt-text-color' = $c.foreground
        '--toolbar-bgcolor' = $c.background; '--toolbar-color' = $c.foreground
        '--toolbar-field-background-color' = $c.surface; '--toolbar-field-color' = $c.foreground; '--toolbar-field-border-color' = $c.border_inactive
        '--toolbar-field-focus-background-color' = $c.surface; '--toolbar-field-focus-color' = $c.foreground; '--toolbar-field-focus-border-color' = $c.accent
        '--lwt-toolbar-field-highlight' = $c.selection; '--lwt-toolbar-field-highlight-text' = $c.foreground
        '--tab-selected-bgcolor' = $c.background; '--tab-selected-textcolor' = $c.foreground
        '--tab-loading-fill' = $c.accent; '--tab-line-color' = $c.accent; '--lwt-tab-line-color' = $c.accent
        '--toolbarbutton-icon-fill' = $c.foreground; '--toolbarbutton-icon-fill-attention' = $c.accent
        '--arrowpanel-background' = $c.background; '--arrowpanel-color' = $c.foreground; '--arrowpanel-border-color' = $c.border_inactive
        '--panel-separator-color' = $c.border_inactive; '--chrome-content-separator-color' = $c.border_inactive
        '--sidebar-background-color' = $c.surface; '--sidebar-text-color' = $c.foreground; '--sidebar-border-color' = $c.border_inactive
        '--urlbarView-highlight-background' = $c.selection; '--urlbarView-highlight-color' = $c.foreground
        '--focus-outline-color' = $c.accent; '--color-accent-primary' = $c.accent; '--button-primary-bgcolor' = $c.accent
    }
    $decl = ($v.GetEnumerator() | ForEach-Object { "  $($_.Key): $($_.Value) !important;" }) -join "`n"
    $chromeCss = "/* winarchy theme: $($pick.Id). Written by winarchy's theme.ps1 - change themes instead of editing. */`n" +
        ":root, :root:-moz-lwtheme {`n$decl`n}`n#navigator-toolbox { background-color: $($c.surface) !important; }`n"
    $contentCss = "/* winarchy theme: $($pick.Id). Written by winarchy's theme.ps1. */`n" +
        "@-moz-document url(`"about:newtab`"), url(`"about:home`"), url(`"about:privatebrowsing`") {`n" +
        "  :root, body {`n    --newtab-background-color: $($c.background) !important;`n    --newtab-background-color-secondary: $($c.surface) !important;`n" +
        "    --newtab-text-primary-color: $($c.foreground) !important;`n    --newtab-primary-action-background: $($c.accent) !important;`n" +
        "    background-color: $($c.background) !important;`n    color: $($c.foreground) !important;`n  }`n}`n"
    foreach ($prof in $profiles) {
        $chrome = Join-Path $prof 'chrome'
        New-Item -ItemType Directory -Force -Path $chrome | Out-Null
        Write-Text (Join-Path $chrome 'winarchy.css') $chromeCss
        Write-Text (Join-Path $chrome 'winarchy-content.css') $contentCss
        Add-FirstLine (Join-Path $chrome 'userChrome.css') '@import url("winarchy.css"); /* winarchy */'
        Add-FirstLine (Join-Path $chrome 'userContent.css') '@import url("winarchy-content.css"); /* winarchy */'
        $userJs = Join-Path $prof 'user.js'
        $js = if (Test-Path $userJs) { Read-Text $userJs } else { '' }
        if ($js -notmatch [regex]::Escape($ffPref)) { Write-Text $userJs ($js.TrimEnd() + $(if ($js.Trim()) { "`n" } else { '' }) + $ffPref + "`n") }
    }
    $running = [bool](Get-Process firefox -ErrorAction SilentlyContinue)
    Log "  firefox: $($profiles.Count) profile(s)$(if ($running) { ' - restart Firefox to see it' })"
}

# Omarchy-style terminal font: the first of these Nerd Fonts that's installed (install.ps1 adds
# JetBrainsMono Nerd Font). Asking for each is faster than listing every installed font.
$termFont = $null
if (Want 'terminal') {
    Add-Type -AssemblyName System.Drawing
    # NFM = Nerd Font Mono: icons one cell wide, best in a terminal.
    foreach ($f in 'JetBrainsMono NFM', 'JetBrainsMono NF', 'JetBrainsMono Nerd Font Mono', 'JetBrainsMono Nerd Font', 'CaskaydiaMono NFM', 'CaskaydiaMono Nerd Font', 'Cascadia Mono NF') {
        $font = New-Object System.Drawing.Font($f, 10)
        $hit = $font.Name -eq $f
        $font.Dispose()
        if ($hit) { $termFont = $f; break }
    }
}

Try-Target 'terminal' {
    if (-not $terminalSettings -and (Get-AppxPackage Microsoft.WindowsTerminal -ErrorAction SilentlyContinue)) {
        # Terminal writes settings.json the first time it opens, so a fresh install has none yet.
        # Start one; Terminal adds its profiles and defaults to it on first launch.
        $dir = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $new = Join-Path $dir 'settings.json'
        Write-Text $new "{`n    `"`$schema`": `"https://aka.ms/terminal-profiles-schema`",`n    `"profiles`": { `"defaults`": {}, `"list`": [] },`n    `"schemes`": []`n}`n"
        $terminalSettings = $script:terminalSettings = @($new)
    }
    if (-not $terminalSettings) { Log '  terminal: Windows Terminal not found, skipped'; return }
    Save-Backup
    $tc = $t.terminal
    foreach ($ts in $terminalSettings) {
        $j = ConvertFrom-Jsonc (Read-Text $ts)
        $scheme = [ordered]@{ name = 'winarchy' }
        foreach ($p in $tc.PSObject.Properties) { $scheme[$p.Name] = $p.Value }
        $schemes = @(@($j.schemes) | Where-Object { $_ -and $_.name -ne 'winarchy' }) + @([pscustomobject]$scheme)
        Set-Prop $j 'schemes' $schemes
        if (-not $j.profiles) { Set-Prop $j 'profiles' ([pscustomobject]@{ defaults = [pscustomobject]@{}; list = @() }) }
        if ($j.profiles -is [array]) { throw 'old-style profiles list; set colorScheme to "winarchy" by hand' }
        if (-not $j.profiles.defaults) { Set-Prop $j.profiles 'defaults' ([pscustomobject]@{}) }
        $d = $j.profiles.defaults
        Set-Prop $d 'colorScheme' 'winarchy'
        # Like Omarchy's terminal: just the text, with room around it. GlazeWM manages the windows
        # and herdr the panes, so the tab row and title bar go (focus mode; Ctrl+Shift+T still opens
        # tabs, Ctrl+Tab switches them).
        Set-Prop $d 'padding' '14'
        Set-Prop $d 'scrollbarState' 'hidden'
        Set-Prop $d 'bellStyle' 'none'
        Set-Prop $d 'cursorShape' 'filledBox'
        if ($termFont) { Set-Prop $d 'font' ([pscustomobject]@{ face = $termFont; size = 11 }) }
        Set-Prop $j 'launchMode' 'focus'
        # A Terminal theme in the same colours, for its menus, command palette and any tab row.
        $c = $t.colors
        $wtTheme = [pscustomobject]@{
            name   = 'winarchy'
            window = [pscustomobject]@{ applicationTheme = $(if ($t.mode -eq 'light') { 'light' } else { 'dark' }); useMica = $false }
            tabRow = [pscustomobject]@{ background = $c.surface; unfocusedBackground = $c.surface }
            tab    = [pscustomobject]@{ background = 'terminalBackground'; unfocusedBackground = $c.surface; showCloseButton = 'hover' }
        }
        Set-Prop $j 'themes' (@(@($j.themes) | Where-Object { $_ -and $_.name -ne 'winarchy' }) + @($wtTheme))
        Set-Prop $j 'theme' 'winarchy'
        Write-Text $ts (Format-Json $j)
    }
    Log ('  terminal: colour scheme "winarchy", focus mode' + $(if ($termFont) { ", $termFont" } else { ' (no Nerd Font found; font left as is)' }))
}

Try-Target 'vscode' {
    if (-not $t.vscode -or -not $t.vscode.theme) { return }
    $code = Get-Command code -ErrorAction SilentlyContinue
    if (-not $code -and -not (Test-Path $vscodeSettings)) { Log '  vscode: not installed, skipped'; return }
    Save-Backup
    if ($code -and $t.vscode.extension) {
        $have = & $code.Source --list-extensions 2>$null
        if (-not ($have -contains $t.vscode.extension)) {
            & $code.Source --install-extension $t.vscode.extension 2>&1 | Out-Null
            Log "  vscode: installed $($t.vscode.extension)"
        }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $vscodeSettings) | Out-Null
    $vs = if (Test-Path $vscodeSettings) { ConvertFrom-Jsonc (Read-Text $vscodeSettings) } else { [pscustomobject]@{} }
    Set-Prop $vs 'workbench.colorTheme' $t.vscode.theme
    Write-Text $vscodeSettings (Format-Json $vs)
    Log "  vscode: $($t.vscode.theme)"
}

if ($errors.Count -and -not $NoPopup) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show("Theme $($t.name) applied, except:`n`n$($errors -join "`n")", 'winarchy theme')
}
