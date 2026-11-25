<#
.SYNOPSIS
    Removes winarchy and puts Windows back the way it was.

.DESCRIPTION
    Stops GlazeWM, restores the taskbar, removes the sign-in shortcut and the
    ~\.glzr\winarchy folder, and restores the GlazeWM config that winarchy replaced
    (if there was one). Apps stay installed unless you pass -RemoveApps.

.EXAMPLE
    .\uninstall.ps1
    .\uninstall.ps1 -RemoveApps
#>
[CmdletBinding()]
param(
    # Also uninstall GlazeWM and Zebar (PowerToys is left alone).
    [switch]$RemoveApps
)

$ErrorActionPreference = 'Stop'
function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

$dest      = Join-Path $env:USERPROFILE '.glzr\winarchy'
$config    = Join-Path $env:USERPROFILE '.glzr\glazewm\config.yaml'
$userApps  = Join-Path $env:LOCALAPPDATA 'Programs\glzr.io'   # install.ps1 -User puts GlazeWM and Zebar here
$glazeCli  = Join-Path $userApps 'GlazeWM\cli\glazewm.exe'
if (-not (Test-Path $glazeCli)) { $glazeCli = Join-Path $env:ProgramFiles 'glzr.io\GlazeWM\cli\glazewm.exe' }
$daemon    = Join-Path $dest 'winarchy-daemon.exe'

Step 'Stopping GlazeWM and winarchy'
if ((Get-Process glazewm -ErrorAction SilentlyContinue) -and (Test-Path $glazeCli)) {
    & $glazeCli command wm-exit 2>$null | Out-Null
    Start-Sleep -Seconds 2
}
if (Test-Path $daemon) {
    & $daemon --stop
    Start-Sleep -Milliseconds 800
    Get-Process winarchy, winarchy-daemon, winarchy-top, winarchy-audio -ErrorAction SilentlyContinue | Stop-Process -Force
    & $daemon --restore-taskbar   # in case the daemon was not running
    Start-Sleep -Milliseconds 500
}

Step 'Removing the Explorer right-click entry'
Get-ChildItem 'HKCU:\Software\Classes\SystemFileAssociations' -ErrorAction SilentlyContinue | ForEach-Object {
    $verb = Join-Path $_.PSPath 'shell\winarchy.convert'
    if (Test-Path $verb) { Remove-Item $verb -Recurse -Force }
}

Step 'Removing sign-in shortcut'
$startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'GlazeWM.lnk'
$startupBackup = Join-Path $dest 'GlazeWM.lnk.before'
if (Test-Path $startupBackup) { Copy-Item $startupBackup $startup -Force; Write-Host '    put back the startup shortcut you had before' }
elseif (Test-Path $startup) { Remove-Item $startup -Force }

Step 'Restoring GlazeWM config'
if (Test-Path $config) {
    # The oldest backup that isn't itself a winarchy config is the one it replaced.
    $backup = Get-ChildItem "$config.bak-*" -ErrorAction SilentlyContinue | Sort-Object Name |
        Where-Object { (Get-Content $_.FullName -Raw) -notmatch 'winarchy' } | Select-Object -First 1
    if ((Get-Content $config -Raw) -match 'winarchy') {
        Move-Item $config "$config.winarchy-removed" -Force
        if ($backup) { Copy-Item $backup.FullName $config; Write-Host "    restored $($backup.Name)" }
        else { Write-Host '    moved winarchy config aside (GlazeWM writes its default on next start)' }
    }
}

Step 'Restoring the Zebar bar'
$zebarDir = Join-Path $env:USERPROFILE '.glzr\zebar'
$zebarSettings = Join-Path $zebarDir 'settings.json'
if (Test-Path $zebarSettings) {
    $zbackup = Get-ChildItem "$zebarSettings.bak-*" -ErrorAction SilentlyContinue | Sort-Object Name |
        Where-Object { (Get-Content $_.FullName -Raw) -notmatch '"winarchy"' } | Select-Object -First 1
    if ($zbackup) { Copy-Item $zbackup.FullName $zebarSettings -Force; Write-Host "    restored $($zbackup.Name)" }
    else {
        $zs = Get-Content $zebarSettings -Raw | ConvertFrom-Json
        $zs | Add-Member -NotePropertyName startupConfigs -Force `
            -NotePropertyValue @([pscustomobject]@{ pack = 'glzr-io.starter'; widget = 'with-glazewm'; preset = 'default' })
        [IO.File]::WriteAllText($zebarSettings, ($zs | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
        Write-Host '    switched Zebar back to its starter bar'
    }
}
$pack = Join-Path $zebarDir 'winarchy'
if (Test-Path $pack) { Remove-Item $pack -Recurse -Force }

# The agents.ps1 next to this script if there is one: an older installed copy may not know `restore`.
$agentsScript = Join-Path $dest 'tools\agents.ps1'
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'tools\agents.ps1'))) { $agentsScript = Join-Path $PSScriptRoot 'tools\agents.ps1' }
$agentsState = Join-Path $dest 'agents'
$keepAgents = $false
if (Test-Path $agentsState) {
    # Put the main Claude and Codex accounts back in ~\.claude and ~\.codex; extra accounts' sign-ins are removed.
    Step 'Switching Claude Code and Codex back to their main accounts'
    # (`restore` works whether account switching is on or off.)
    if (Test-Path $agentsScript) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $agentsScript restore }
    if (-not (Test-Path $agentsScript) -or $LASTEXITCODE) {
        # Without extra accounts nothing was ever moved, so there's nothing to lose.
        $keepAgents = Test-Path (Join-Path $agentsState 'claude')
    }
}
if ([Environment]::GetEnvironmentVariable('CODEX_HOME', 'User') -like "$agentsState*") { [Environment]::SetEnvironmentVariable('CODEX_HOME', $null, 'User') }

$themeScript = Join-Path $dest 'tools\theme.ps1'
if (Test-Path $themeScript) {
    Step 'Restoring Windows colours, Terminal and VS Code settings from before winarchy themes'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $themeScript -Restore
}

Step "Removing $dest"
if ($keepAgents) {
    Get-ChildItem $dest -Force | Where-Object { $_.Name -ne 'agents' } | Remove-Item -Recurse -Force
    Write-Warning "The main account's sign-in could not be put back, so saved sign-ins were kept in $agentsState. Check you can sign in (claude auth login), then delete that folder."
} elseif (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
$cache = Join-Path $env:LOCALAPPDATA 'winarchy'
if (Test-Path $cache) { Remove-Item $cache -Recurse -Force }

if ($RemoveApps) {
    Step 'Uninstalling GlazeWM and Zebar'
    if (Test-Path $userApps) {
        Get-Process glazewm, zebar -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 1
        Remove-Item $userApps -Recurse -Force
        Write-Host "    removed $userApps"
    }
    if (Test-Path (Join-Path $env:ProgramFiles 'glzr.io\GlazeWM\glazewm.exe')) { winget uninstall --id glzr-io.glazewm -e --disable-interactivity }
    if (Test-Path (Join-Path $env:ProgramFiles 'glzr.io\Zebar\zebar.exe')) { winget uninstall --id glzr-io.zebar -e --disable-interactivity }
}

Write-Host 'winarchy removed.' -ForegroundColor Green
