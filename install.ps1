<#
.SYNOPSIS
    Installs winarchy: Omarchy-style, keyboard-driven tiling for Windows 11.

.DESCRIPTION
    - Installs GlazeWM (+ Zebar bar), Windows Terminal and Handy (dictation) with winget.
    - Builds winarchy.exe and winarchy-daemon.exe from source with the C# compiler
      that ships with Windows (nothing prebuilt is downloaded).
    - Writes the GlazeWM config (workspaces laid out for your monitors) and the menu,
      backing up anything it replaces.
    - Starts GlazeWM now and at every sign-in.

    Safe to re-run: it upgrades in place.

.EXAMPLE
    irm https://raw.githubusercontent.com/justfixitjim/winarchy/main/install.ps1 | iex

.EXAMPLE
    .\install.ps1 -KeepConfig -KeepTaskbar
#>
[CmdletBinding()]
param(
    # Don't overwrite an existing GlazeWM config or menu.json.
    [switch]$KeepConfig,
    # Leave the Windows taskbar visible.
    [switch]$KeepTaskbar,
    # Let a lone Super key tap open the Start menu as usual.
    [switch]$KeepStartMenu,
    # Don't install or upgrade apps with winget.
    [switch]$SkipApps,
    # Show the bar's temperature in Celsius instead of Fahrenheit.
    [switch]$Celsius,
    # Don't install Handy (local dictation: hold Right Ctrl to talk).
    [switch]$NoDictation,
    # Also install PowerToys (winarchy's own launcher replaces its Command Palette).
    [switch]$WithPowerToys,
    # Skip the media tools' dependencies (ffmpeg, ImageMagick).
    [switch]$NoMediaTools,
    # Leave Windows Terminal's look alone (no theme colours, focus mode or Nerd Font).
    [switch]$KeepTerminal,
    # Don't install herdr (terminal workspace for running several AI coding agents).
    [switch]$NoHerdr,
    # Windows VPN connection for the bar's VPN button (default: the first one found).
    # Pass -VpnName none to hide the button.
    [string]$VpnName
)

$ErrorActionPreference = 'Stop'
$Repo = 'justfixitjim/winarchy'

# --- Bootstrap: when run as "irm ... | iex" there is no checkout, so fetch one. ---
$here = $PSScriptRoot
if (-not $here -or -not (Test-Path (Join-Path $here 'src\winarchy.cs'))) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $tmp = Join-Path $env:TEMP ('winarchy-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    Write-Host "==> Downloading $Repo" -ForegroundColor Cyan
    Invoke-WebRequest "https://github.com/$Repo/archive/refs/heads/main.zip" -OutFile "$tmp\repo.zip" -UseBasicParsing
    Expand-Archive "$tmp\repo.zip" -DestinationPath $tmp
    $root = Get-ChildItem $tmp -Directory | Select-Object -First 1
    $forward = @()
    foreach ($k in $PSBoundParameters.Keys) { $forward += "-$k" }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root.FullName 'install.ps1') @forward
    return
}

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Note($msg) { Write-Host "    $msg" }
function Write-Utf8($path, $text) { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false)) }
# Runs a native command without PowerShell 5.1 turning its stderr into a terminating error.
function Quiet([scriptblock]$Block) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $Block 2>$null | Out-Null } finally { $ErrorActionPreference = $old }
}

$glzr      = Join-Path $env:USERPROFILE '.glzr'
$dest      = Join-Path $glzr 'winarchy'
$configDir = Join-Path $glzr 'glazewm'
$glazeExe  = Join-Path $env:ProgramFiles 'glzr.io\GlazeWM\glazewm.exe'
$glazeCli  = Join-Path $env:ProgramFiles 'glzr.io\GlazeWM\cli\glazewm.exe'
$zebarExe  = Join-Path $env:ProgramFiles 'glzr.io\Zebar\zebar.exe'
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'

if ([Environment]::OSVersion.Version.Build -lt 22000) {
    Write-Warning 'winarchy is built for Windows 11. Continuing, but some parts may not work.'
}

# --- 1. Apps ---------------------------------------------------------------------
if (-not $SkipApps) {
    Step 'Installing apps with winget'
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'winget is missing. Install "App Installer" from the Microsoft Store, then re-run.'
    }
    $apps = @(
        @{ Id = 'glzr-io.glazewm';           Name = 'GlazeWM';          Present = { Test-Path $glazeExe } },
        @{ Id = 'glzr-io.zebar';             Name = 'Zebar';            Present = { Test-Path $zebarExe } },
        @{ Id = 'Microsoft.WindowsTerminal'; Name = 'Windows Terminal'; Present = { Test-Path "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe" } }
    )
    if (-not $NoMediaTools) {
        $apps += @{ Id = 'Gyan.FFmpeg'; Name = 'ffmpeg (media tools)'; Present = {
            [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue) -or [bool](Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Gyan.FFmpeg*\*\bin\ffmpeg.exe" -ErrorAction SilentlyContinue) } }
        $apps += @{ Id = 'ImageMagick.ImageMagick'; Name = 'ImageMagick (media tools)'; Present = {
            [bool](Get-ChildItem "$env:ProgramFiles\ImageMagick-*\magick.exe" -ErrorAction SilentlyContinue) } }
    }
    if (-not $KeepTerminal) {
        # Omarchy-style terminal font, with the icon glyphs terminal tools use.
        $apps += @{ Id = 'DEVCOM.JetBrainsMonoNerdFont'; Name = 'JetBrainsMono Nerd Font (terminal)'; Present = {
            $keys = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts', 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
            [bool](Get-ItemProperty $keys -ErrorAction SilentlyContinue | ForEach-Object { $_.PSObject.Properties.Name } | Where-Object { $_ -like 'JetBrainsMono N*' }) } }
    }
    if ($WithPowerToys) {
        $apps += @{ Id = 'Microsoft.PowerToys'; Name = 'PowerToys'; Present = { [bool](Get-AppxPackage -Name 'Microsoft.CommandPalette' -ErrorAction SilentlyContinue) } }
    }
    if (-not $NoDictation) {
        $apps += @{ Id = 'cjpais.Handy'; Name = 'Handy (dictation)'; Present = { Test-Path "$env:LOCALAPPDATA\Handy\handy.exe" } }
    }
    foreach ($app in $apps) {
        if (& $app.Present) { Note "$($app.Name): already installed"; continue }
        Note "$($app.Name): installing (approve the UAC prompt if one appears)"
        Quiet { winget install --id $app.Id -e --accept-source-agreements --accept-package-agreements --disable-interactivity }
        if (-not (& $app.Present)) { Write-Warning "$($app.Name) did not install cleanly (winget exit code $LASTEXITCODE)." }
    }

    # herdr: a terminal workspace for running several AI coding agents side by side, with each
    # agent's state (working, blocked, idle) in a sidebar. It isn't in winget (stable), so this
    # uses its official installer: per-user, no admin, checks the download's SHA-256 and adds
    # itself to your user PATH. Update later with: herdr update
    if (-not $NoHerdr) {
        $herdrExe = Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin\herdr.exe'
        if ((Test-Path $herdrExe) -or (Get-Command herdr -ErrorAction SilentlyContinue)) { Note 'herdr: already installed' }
        else {
            Note 'herdr: installing (official installer from herdr.dev)'
            $herdrInstaller = Join-Path $env:TEMP 'winarchy-herdr-install.ps1'
            & curl.exe -fsSL https://herdr.dev/install.ps1 -o $herdrInstaller
            if ($LASTEXITCODE -eq 0) { Quiet { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $herdrInstaller -Channel stable } }
            Remove-Item $herdrInstaller -ErrorAction SilentlyContinue
            if (-not (Test-Path $herdrExe)) { Write-Warning 'herdr did not install. See https://herdr.dev/docs/windows-beta/' }
        }
    }
}
if (-not (Test-Path $glazeExe)) { throw "GlazeWM is not installed at $glazeExe. Re-run without -SkipApps." }

# --- 2. Stop anything already running -----------------------------------------------
Step 'Stopping running winarchy / GlazeWM'
if (Get-Process glazewm -ErrorAction SilentlyContinue) {
    Quiet { & $glazeCli command wm-exit }
    for ($i = 0; $i -lt 20 -and (Get-Process glazewm -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
}
$daemon = Join-Path $dest 'winarchy-daemon.exe'
if (Test-Path $daemon) { & $daemon --stop; Start-Sleep -Milliseconds 800 }
Get-Process winarchy, winarchy-daemon, winarchy-top, winarchy-audio, winarchy-menu, winarchy-autotile -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300

# --- 3. Build the helpers ----------------------------------------------------------
Step "Building helpers into $dest"
New-Item -ItemType Directory -Force -Path $dest, $configDir | Out-Null
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw ".NET Framework C# compiler not found at $csc" }
$common = @('/nologo', '/codepage:65001', '/optimize+', '/target:winexe')
& $csc @common "/out:$dest\winarchy.exe" /r:System.Windows.Forms.dll /r:System.Drawing.dll `
    /r:System.Web.Extensions.dll /r:Microsoft.CSharp.dll /r:System.Core.dll /r:System.Data.dll `
    "$here\src\winarchy.cs" "$here\src\toggles.cs" "$here\src\quiethours.cs" "$here\src\safefile.cs"
if ($LASTEXITCODE) { throw 'Building winarchy.exe failed.' }
& $csc @common "/out:$dest\winarchy-daemon.exe" /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll `
    "$here\src\daemon.cs" "$here\src\safefile.cs"
if ($LASTEXITCODE) { throw 'Building winarchy-daemon.exe failed.' }
# Process stats for the bar and its process panel (a console program: Zebar reads its output).
& $csc /nologo /codepage:65001 /optimize+ /target:exe "/out:$dest\winarchy-top.exe" "$here\src\top.cs" "$here\src\quiethours.cs"
if ($LASTEXITCODE) { throw 'Building winarchy-top.exe failed.' }
# Per-app volume and the default device for the audio panel (also a console program).
& $csc /nologo /codepage:65001 /optimize+ /target:exe "/out:$dest\winarchy-audio.exe" "$here\src\audio.cs"
if ($LASTEXITCODE) { throw 'Building winarchy-audio.exe failed.' }
Copy-Item "$here\README.md" $dest -Force

# Media tools (Trigger > Transcode / Capture, Setup > Network > Wi-Fi QR).
$toolsDir = Join-Path $dest 'tools'
New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
Copy-Item "$here\tools\*.ps1" $toolsDir -Force
# ZXing.Net (Apache-2.0) reads and writes QR codes. Pinned version, checked by hash.
$zxing = Join-Path $toolsDir 'zxing.dll'
if (-not (Test-Path $zxing)) {
    $nupkg = Join-Path $env:TEMP 'winarchy-zxing.0.16.9.nupkg'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest 'https://www.nuget.org/api/v2/package/ZXing.Net/0.16.9' -OutFile $nupkg -UseBasicParsing
    if ((Get-FileHash $nupkg -Algorithm SHA256).Hash -ne '00254ACAAEA069262E6B103D23F1A934E953D503EA43AFE2965272718388F32E') {
        Remove-Item $nupkg; throw 'ZXing.Net download failed its checksum.'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($nupkg)
    try { $entry = $zip.Entries | Where-Object FullName -eq 'lib/net48/zxing.dll'
          [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $zxing, $true) }
    finally { $zip.Dispose(); Remove-Item $nupkg }
    Note 'downloaded ZXing.Net 0.16.9 (QR codes)'
}

# Explorer right-click: "Convert with winarchy" on pictures and videos (Windows 11 lists it
# under "Show more options"). Per-user; uninstall.ps1 removes it. Same types as transcode.ps1.
if (-not $NoMediaTools) {
    $convertExt = 'jpg', 'jpeg', 'png', 'webp', 'avif', 'heic', 'heif', 'gif', 'bmp', 'tif', 'tiff',
        'mp4', 'mov', 'mkv', 'webm', 'avi', 'wmv', 'm4v', 'flv', 'mpg', 'mpeg', '3gp'
    $convertCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$toolsDir\transcode.ps1`" -FromExplorer `"%1`""
    foreach ($e in $convertExt) {
        $key = "HKCU:\Software\Classes\SystemFileAssociations\.$e\shell\winarchy.convert"
        New-Item -Path "$key\command" -Force | Out-Null
        Set-ItemProperty -Path $key -Name '(default)' -Value 'Convert with winarchy'
        Set-ItemProperty -Path $key -Name 'MultiSelectModel' -Value 'Single'   # one file at a time
        Set-ItemProperty -Path "$key\command" -Name '(default)' -Value $convertCmd
    }
    Note 'Explorer right-click: Convert with winarchy (pictures and videos)'
}

# Files from the pre-release layout.
foreach ($old in 'winarchy-menu.exe', 'winarchy-autotile.exe', 'build.ps1', 'src') {
    $p = Join-Path $dest $old
    if (Test-Path $p) { Remove-Item $p -Recurse -Force }
}

# --- 4. Settings -----------------------------------------------------------------------
$settingsPath = Join-Path $dest 'settings.json'
$settings = [ordered]@{ hideTaskbar = $true; blockStartMenu = $true; autotile = $true }
if (Test-Path $settingsPath) {
    $existing = Get-Content $settingsPath -Raw | ConvertFrom-Json
    foreach ($p in $existing.PSObject.Properties) { $settings[$p.Name] = $p.Value }
}
if ($KeepTaskbar) { $settings.hideTaskbar = $false }
if ($KeepStartMenu) { $settings.blockStartMenu = $false }
Write-Utf8 $settingsPath (($settings | ConvertTo-Json) + "`n")
Note "settings.json: hideTaskbar=$($settings.hideTaskbar) blockStartMenu=$($settings.blockStartMenu) autotile=$($settings.autotile)"

# --- 5. Menu and GlazeWM config -----------------------------------------------------
function Install-File($source, $target, $content) {
    if (Test-Path $target) {
        $current = [IO.File]::ReadAllText($target)
        if ($current -eq $content) { Note "$target is up to date"; return }
        if ($KeepConfig) { Note "keeping your $target (-KeepConfig)"; return }
        Copy-Item $target "$target.bak-$stamp"
        Note "backed up $target -> $(Split-Path -Leaf $target).bak-$stamp"
    }
    Write-Utf8 $target $content
    Note "wrote $target"
}

Step 'Writing the menu and GlazeWM config'
Install-File "$here\config\menu.json" (Join-Path $dest 'menu.json') ([IO.File]::ReadAllText("$here\config\menu.json"))

# Workspaces: primary monitor gets 1-5, the others (left to right) share 6-9.
Add-Type -AssemblyName System.Windows.Forms
$screens = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X }, { $_.Bounds.Y })
$lines = New-Object System.Collections.Generic.List[string]
if ($screens.Count -le 1) {
    1..9 | ForEach-Object { $lines.Add("  - name: '$_'") }
} else {
    $primary = [array]::IndexOf($screens, ($screens | Where-Object Primary | Select-Object -First 1))
    $others = @(0..($screens.Count - 1) | Where-Object { $_ -ne $primary })
    1..5 | ForEach-Object { $lines.Add("  - name: '$_'"); $lines.Add("    bind_to_monitor: $primary") }
    $n = 6
    for ($i = 0; $i -lt $others.Count -and $n -le 9; $i++) {
        $share = [math]::Ceiling((10 - $n) / ($others.Count - $i))
        for ($j = 0; $j -lt $share -and $n -le 9; $j++, $n++) {
            $lines.Add("  - name: '$n'"); $lines.Add("    bind_to_monitor: $($others[$i])")
        }
    }
}
Note ("{0} monitor(s) found; primary is monitor {1}" -f $screens.Count, [math]::Max(0, [array]::IndexOf($screens, ($screens | Where-Object Primary | Select-Object -First 1))))
$template = [IO.File]::ReadAllText("$here\config\glazewm.yaml")
$config = $template.Replace('{{WORKSPACES}}', ($lines -join "`n"))
Install-File "$here\config\glazewm.yaml" (Join-Path $configDir 'config.yaml') $config

# --- 6. Zebar bar ------------------------------------------------------------------------
Step 'Installing the winarchy top bar (Zebar)'
$zebarDir = Join-Path $glzr 'zebar'
$pack = Join-Path $zebarDir 'winarchy'
New-Item -ItemType Directory -Force -Path $pack | Out-Null
Copy-Item "$here\config\zebar\*" $pack -Recurse -Force   # includes vendor\ (libraries and icon font)
$unit = 'F'; if ($Celsius) { $unit = 'C' }
# The bar's logo button runs winarchy.exe; Zebar only allows a program whose path in the
# HTML exactly matches the one whitelisted in zpack.json, so both get the same string.
$winarchyPath = (Join-Path $dest 'winarchy.exe').Replace('\', '/')
$topPath = (Join-Path $dest 'winarchy-top.exe').Replace('\', '/')
$barHtml = Join-Path $pack 'bar.html'
# VPN button: the PC's own VPN connection (Settings > Network > VPN), never a hard-coded name.
if (-not $VpnName) {
    $vpn = @(Get-VpnConnection -ErrorAction SilentlyContinue) + @(Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue) |
        Where-Object { $_ } | Select-Object -First 1
    if ($vpn) { $VpnName = $vpn.Name }
}
if ($VpnName -eq 'none') { $VpnName = '' }
# Which phonebook holds it: per-user first, then all-user (Windows' sign-in dialog needs it).
$vpnPbk = ''
foreach ($pbk in "$env:APPDATA\Microsoft\Network\Connections\Pbk\rasphone.pbk",
                 "$env:ProgramData\Microsoft\Network\Connections\Pbk\rasphone.pbk") {
    if ($VpnName -and (Test-Path $pbk) -and (Select-String -Path $pbk -SimpleMatch "[$VpnName]" -Quiet)) { $vpnPbk = $pbk; break }
}
Note $(if ($VpnName) { "VPN button: $VpnName" } else { 'VPN button: hidden (no Windows VPN connection found)' })
$jsVpn = $VpnName.Replace('\', '\\').Replace("'", "\'")
$audioPath = (Join-Path $dest 'winarchy-audio.exe').Replace('\', '/')
# Paths the pages and zpack.json need. Zebar only runs a program whose path in the page exactly
# matches the one allowed in zpack.json, so both get the same string.
$paths = [ordered]@{
    '{{WINARCHY_EXE}}'  = $winarchyPath
    '{{TOP_EXE}}'       = $topPath
    '{{AUDIO_EXE}}'     = $audioPath
    '{{AGENTS_PS1}}'    = (Join-Path $toolsDir 'agents.ps1')
    '{{NETWORK_PS1}}'   = (Join-Path $toolsDir 'network.ps1')
    '{{BLUETOOTH_PS1}}' = (Join-Path $toolsDir 'bluetooth.ps1')
}
foreach ($page in Get-ChildItem $pack -Filter *.html) {
    $text = [IO.File]::ReadAllText($page.FullName)
    foreach ($k in $paths.Keys) { $text = $text.Replace($k, $paths[$k].Replace('\', '\\').Replace("'", "\'")) }
    $text = $text.Replace("const TEMP_UNIT = 'F';", "const TEMP_UNIT = '$unit';")
    if ($page.Name -eq 'bar.html') { $text = $text.Replace('{{VPN_NAME}}', $jsVpn).Replace('{{VPN_PBK}}', $vpnPbk.Replace('\', '\\').Replace("'", "\'")) }
    Write-Utf8 $page.FullName $text
}
$zpack = Join-Path $pack 'zpack.json'
$text = [IO.File]::ReadAllText($zpack)
foreach ($k in $paths.Keys) { $text = $text.Replace($k, $paths[$k].Replace('\', '\\').Replace('"', '\"')) }
Write-Utf8 $zpack $text
Note "temperature in degrees $unit"
$zebarSettings = Join-Path $zebarDir 'settings.json'
$wantStartup = '[{"pack":"winarchy","widget":"bar","preset":"default"}]'
if (Test-Path $zebarSettings) {
    $zs = Get-Content $zebarSettings -Raw | ConvertFrom-Json
    if ((ConvertTo-Json -InputObject @($zs.startupConfigs) -Compress) -ne $wantStartup) {
        Copy-Item $zebarSettings "$zebarSettings.bak-$stamp"
        Note "backed up $zebarSettings -> settings.json.bak-$stamp"
    }
    $zs | Add-Member -NotePropertyName startupConfigs -Force `
        -NotePropertyValue @([pscustomobject]@{ pack = 'winarchy'; widget = 'bar'; preset = 'default' })
} else {
    $zs = [pscustomobject]@{
        '$schema' = 'https://github.com/glzr-io/zebar/raw/v3.3.1/resources/settings-schema.json'
        startupConfigs = @([pscustomobject]@{ pack = 'winarchy'; widget = 'bar'; preset = 'default' })
    }
}
Write-Utf8 $zebarSettings (($zs | ConvertTo-Json -Depth 5) + "`n")

# Colour themes (Super+Ctrl+Shift+Space). Re-apply the current one (Tokyo Night on a new
# install) to winarchy's own pieces and Windows Terminal; Windows itself and VS Code change only
# when you pick one.
$themesDir = Join-Path $dest 'themes'
New-Item -ItemType Directory -Force -Path $themesDir | Out-Null
Copy-Item "$here\themes\*.json" $themesDir -Force
$themeId = 'tokyo-night'
$themeJson = Join-Path $dest 'theme.json'
if (Test-Path $themeJson) { try { $themeId = (Get-Content $themeJson -Raw | ConvertFrom-Json).id } catch {} }
if (-not (Test-Path (Join-Path $themesDir "$themeId.json"))) { $themeId = 'tokyo-night' }
Quiet { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $toolsDir 'theme.ps1') $themeId -Only 'glazewm,bar,menu' -NoReload -NoPopup }
Note "Theme: $themeId"
if (-not $KeepTerminal) {
    # Foot-like Windows Terminal: theme colours, no tabs or title bar, Nerd Font, padding.
    # The first change saves your old settings; uninstall.ps1 puts them back.
    Quiet { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $toolsDir 'theme.ps1') $themeId -Only 'terminal' -NoReload -NoPopup }
    Note 'Windows Terminal: theme colours, focus mode (no tabs or title bar), Nerd Font'
}

# --- 7. Dictation: Handy push-to-talk on Right Ctrl ----------------------------------------
# Handy (https://github.com/cjpais/Handy) is free, open source and transcribes on your PC. It
# writes settings_store.json during its first-run setup. Once that exists, this puts
# push-to-talk on Right Ctrl (unless you already picked your own key) and makes Handy
# start hidden at sign-in. Omarchy uses Right Alt, but on Windows a held Right Alt also
# reaches the focused app and opens its menus; Right Ctrl does nothing on its own.

# Edits Handy's settings file; returns what changed (empty if nothing needed changing).
function Update-HandySettings([string]$Path) {
    $store = Get-Content $Path -Raw | ConvertFrom-Json
    $s = $store.settings
    $changed = @()
    if ($s.bindings.transcribe.current_binding -eq $s.bindings.transcribe.default_binding) {
        $s.bindings.transcribe.current_binding = 'ctrl_right'
        $s | Add-Member -NotePropertyName shortcut_activation -NotePropertyValue 'push_to_talk' -Force
        $changed += 'push-to-talk on Right Ctrl'
    }
    if (-not $s.autostart_enabled) {
        $s | Add-Member -NotePropertyName autostart_enabled -NotePropertyValue $true -Force
        $s | Add-Member -NotePropertyName start_hidden -NotePropertyValue $true -Force
        $changed += 'starts hidden at sign-in'
    }
    if ($changed.Count) { Write-Utf8 $Path (($store | ConvertTo-Json -Depth 20) + "`n") }
    return $changed
}

$handyExe = Join-Path $env:LOCALAPPDATA 'Handy\handy.exe'
$handySettings = Join-Path $env:APPDATA 'com.pais.handy\settings_store.json'
$handyNeedsSetup = $false
if (-not $NoDictation -and (Test-Path $handyExe)) {
    Step 'Setting up dictation (Handy)'
    if (Test-Path $handySettings) {
        # Handy rewrites its settings on exit, so close it while editing, then reopen it
        # (it registers its own sign-in entry when it starts with autostart enabled).
        $wasRunning = [bool](Get-Process handy -ErrorAction SilentlyContinue)
        Get-Process handy -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 1
        Copy-Item $handySettings "$handySettings.bak-$stamp"
        $changed = Update-HandySettings $handySettings
        if ($changed.Count) { Note ('Handy: ' + ($changed -join ', ')) } else {
            Remove-Item "$handySettings.bak-$stamp"
            $key = (Get-Content $handySettings -Raw | ConvertFrom-Json).settings.bindings.transcribe.current_binding
            Note "Handy is already set up (push-to-talk: $key); leaving it"
        }
        if ($changed.Count -or $wasRunning) { Start-Process $handyExe }
    } else {
        $handyNeedsSetup = $true
        Note 'Handy has not been set up yet (see the note at the end)'
    }
}

# --- 8. Start at sign-in, then start now ----------------------------------------------
Step 'Starting GlazeWM (and at every sign-in)'
$startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'GlazeWM.lnk'
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($startup)
$lnk.TargetPath = $glazeExe
$lnk.WorkingDirectory = $env:USERPROFILE
$lnk.Save()
Note "startup shortcut: $startup"
Start-Process $glazeExe
Start-Sleep -Seconds 3
if (Get-Process glazewm -ErrorAction SilentlyContinue) { Note 'GlazeWM is running' } else { Write-Warning 'GlazeWM did not start; see ~\.glzr\glazewm\errors.log' }

Write-Host ''
Write-Host 'winarchy is installed.' -ForegroundColor Green
Write-Host '  Super+Space      launcher: apps, windows, settings, maths'
Write-Host '  Super+Alt+Space  menu: search and arrow to anything'
Write-Host '  Super+K          every keybinding'
Write-Host '  Super+Shift+P    pause tiling if you need to get out of the way'
Write-Host "  Customise: $configDir\config.yaml and $dest\menu.json"
if ($handyNeedsSetup) {
    Write-Host ''
    Write-Host 'Dictation: open Handy from Super+Space and finish its setup (pick a model, allow the'
    Write-Host 'microphone), then re-run this installer to put push-to-talk on Right Ctrl.'
}
