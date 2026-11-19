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
    [switch]$NoMediaTools
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
Get-Process winarchy, winarchy-daemon, winarchy-menu, winarchy-autotile -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300

# --- 3. Build the helpers ----------------------------------------------------------
Step "Building helpers into $dest"
New-Item -ItemType Directory -Force -Path $dest, $configDir | Out-Null
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw ".NET Framework C# compiler not found at $csc" }
$common = @('/nologo', '/codepage:65001', '/optimize+', '/target:winexe')
& $csc @common "/out:$dest\winarchy.exe" /r:System.Windows.Forms.dll /r:System.Drawing.dll `
    /r:System.Web.Extensions.dll /r:Microsoft.CSharp.dll /r:System.Core.dll /r:System.Data.dll "$here\src\winarchy.cs"
if ($LASTEXITCODE) { throw 'Building winarchy.exe failed.' }
& $csc @common "/out:$dest\winarchy-daemon.exe" /r:System.Windows.Forms.dll /r:System.Web.Extensions.dll "$here\src\daemon.cs"
if ($LASTEXITCODE) { throw 'Building winarchy-daemon.exe failed.' }
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
Copy-Item "$here\config\zebar\*" $pack -Force
$unit = 'F'; if ($Celsius) { $unit = 'C' }
# The bar's logo button runs winarchy.exe; Zebar only allows a program whose path in the
# HTML exactly matches the one whitelisted in zpack.json, so both get the same string.
$winarchyPath = (Join-Path $dest 'winarchy.exe').Replace('\', '/')
$barHtml = Join-Path $pack 'bar.html'
Write-Utf8 $barHtml ([IO.File]::ReadAllText($barHtml).Replace("const TEMP_UNIT = 'F';", "const TEMP_UNIT = '$unit';").Replace('{{WINARCHY_EXE}}', $winarchyPath.Replace("'", "\'")))
$zpack = Join-Path $pack 'zpack.json'
Write-Utf8 $zpack ([IO.File]::ReadAllText($zpack).Replace('{{WINARCHY_EXE}}', $winarchyPath.Replace('"', '\"')))
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
