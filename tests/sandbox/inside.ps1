<#
    Runs inside Windows Sandbox (started by start.ps1): get winget, install winarchy, check it,
    uninstall it, check again. Writes C:\results\report.txt (tests\sandbox\results on the host).
    Keep this file ASCII-only.
#>
param([string]$Ref, [switch]$User)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$report = 'C:\results\report.txt'
$script:failed = 0
function Log($text) { $line = "$(Get-Date -Format HH:mm:ss)  $text"; Write-Host $line; Add-Content -Path $report -Value $line }
function Check($name, [scriptblock]$test) {
    $ok = $false
    try { $ok = [bool](& $test) } catch { }
    if (-not $ok) { $script:failed++ }
    Log ("{0}  {1}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name)
}
function Wait-For([scriptblock]$test, [int]$seconds = 60) {
    for ($i = 0; $i -lt $seconds; $i++) { try { if (& $test) { return $true } } catch { }; Start-Sleep 1 }
    return $false
}
Add-Type -Namespace T -Name W -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string t);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
'@
function Taskbar-Visible { [T.W]::IsWindowVisible([T.W]::FindWindow('Shell_TrayWnd', $null)) }
function Running($name) { [bool](Get-Process $name -ErrorAction SilentlyContinue) }

Log "winarchy sandbox test ($(if ($Ref) { "release $Ref via irm | iex" } else { 'local checkout' })$(if ($User) { ', -User' }))"
Log ("Windows " + (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion + ", build " + [Environment]::OSVersion.Version.Build)

# --- 1. winget (Windows Sandbox doesn't have it) ---------------------------------------------
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Log 'Installing winget...'
    $rel = Invoke-RestMethod 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -Headers @{ 'User-Agent' = 'winarchy-test' }
    $dl = 'C:\winget'; New-Item -ItemType Directory -Force $dl | Out-Null
    foreach ($pattern in '*.msixbundle', '*License1.xml', 'DesktopAppInstaller_Dependencies.zip') {
        $a = $rel.assets | Where-Object { $_.name -like $pattern } | Select-Object -First 1
        Invoke-WebRequest $a.browser_download_url -OutFile (Join-Path $dl $a.name) -UseBasicParsing
    }
    Expand-Archive (Join-Path $dl 'DesktopAppInstaller_Dependencies.zip') -DestinationPath "$dl\deps" -Force
    Get-ChildItem "$dl\deps" -Recurse -Filter *.appx | Where-Object { $_.FullName -match 'x64' } | ForEach-Object { Add-AppxPackage $_.FullName }
    $bundle = (Get-ChildItem $dl -Filter *.msixbundle).FullName
    $license = (Get-ChildItem $dl -Filter *License1.xml).FullName
    Add-AppxProvisionedPackage -Online -PackagePath $bundle -LicensePath $license | Out-Null
    $env:PATH += ";$env:LOCALAPPDATA\Microsoft\WindowsApps"
    Wait-For { Get-Command winget -ErrorAction SilentlyContinue } 60 | Out-Null
}
Check 'winget available' { Get-Command winget -ErrorAction SilentlyContinue }

# --- 2. Install ----------------------------------------------------------------------------------
$taskbarBefore = Taskbar-Visible
Log 'Running the installer (this takes a while)...'
$userArg = @(); if ($User) { $userArg = @('-User') }
$installLog = 'C:\results\install.log'
if ($Ref) {
    $src = Invoke-RestMethod "https://raw.githubusercontent.com/justfixitjim/winarchy/$Ref/install.ps1"
    $tmp = Join-Path $env:TEMP 'winarchy-install.ps1'; Set-Content $tmp $src -Encoding UTF8
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp -Ref $Ref @userArg *>&1 | Tee-Object -FilePath $installLog | Out-Host
} else {
    Copy-Item C:\winarchy-src C:\winarchy -Recurse -Force
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\winarchy\install.ps1 @userArg *>&1 | Tee-Object -FilePath $installLog | Out-Host
}
Check 'installer finished without an error' { $LASTEXITCODE -eq 0 -and -not (Select-String $installLog -Pattern 'Exception|failed' -Quiet) }

$dest = Join-Path $env:USERPROFILE '.glzr\winarchy'
Check 'helpers built' { (Test-Path "$dest\winarchy.exe") -and (Test-Path "$dest\winarchy-daemon.exe") -and (Test-Path "$dest\winarchy-top.exe") -and (Test-Path "$dest\winarchy-audio.exe") }
Check 'GlazeWM config written' { Select-String "$env:USERPROFILE\.glzr\glazewm\config.yaml" -Pattern "name: '1'" -Quiet }
Check 'GlazeWM running' { Wait-For { Running 'glazewm' } 60 }
Check 'winarchy-daemon running' { Wait-For { Running 'winarchy-daemon' } 60 }
Check 'resident menu running' { Wait-For { Running 'winarchy' } 60 }
Check 'Zebar running' { Wait-For { Running 'zebar' } 60 }
Check 'bar loaded (web server up and winarchy-top started by the bar)' {
    Wait-For { (Get-NetTCPConnection -LocalPort 6124 -State Listen -ErrorAction SilentlyContinue) -and (Running 'winarchy-top') } 90
}
Check 'taskbar hidden' { Wait-For { -not (Taskbar-Visible) } 30 }
Check 'starts at sign-in' { Test-Path (Join-Path ([Environment]::GetFolderPath('Startup')) 'GlazeWM.lnk') }
$userApps = Join-Path $env:LOCALAPPDATA 'Programs\glzr.io'
if ($User) { Check 'GlazeWM and Zebar installed in the user profile' { (Test-Path "$userApps\GlazeWM\glazewm.exe") -and (Test-Path "$userApps\Zebar\zebar.exe") } }
$glazeCli = if (Test-Path "$userApps\GlazeWM\cli\glazewm.exe") { "$userApps\GlazeWM\cli\glazewm.exe" } else { "$env:ProgramFiles\glzr.io\GlazeWM\cli\glazewm.exe" }
Check 'GlazeWM sees a workspace' {
    $q = & $glazeCli query workspaces | ConvertFrom-Json
    @($q.data.workspaces).Count -ge 1
}
Check 'reminder pops up' {
    & "$dest\winarchy.exe" remind add 0.05 sandbox test | Out-Null
    Wait-For { (Get-Content "$dest\reminders.json" -Raw).Trim() -eq '[]' } 20
}
Check 'menu opens' {
    Start-Process "$dest\winarchy.exe"
    $ok = Wait-For { [T.W]::IsWindowVisible([T.W]::FindWindow($null, 'winarchy')) } 10
    Start-Process "$dest\winarchy.exe"   # pressing it again closes it
    $ok
}

# --- 3. Uninstall ----------------------------------------------------------------------------------
Log 'Running the uninstaller...'
$un = 'C:\winarchy\uninstall.ps1'
if ($Ref) {
    $tmpU = Join-Path $env:TEMP 'winarchy-uninstall.ps1'
    Invoke-WebRequest "https://raw.githubusercontent.com/justfixitjim/winarchy/$Ref/uninstall.ps1" -OutFile $tmpU -UseBasicParsing
    $un = $tmpU
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $un *>&1 | Tee-Object -FilePath 'C:\results\uninstall.log' | Out-Host
Start-Sleep 5
Check 'winarchy processes stopped' { -not ((Running 'winarchy-daemon') -or (Running 'winarchy') -or (Running 'glazewm') -or (Running 'zebar')) }
Check 'taskbar back as it was' { (Taskbar-Visible) -eq $taskbarBefore }
Check 'winarchy folder removed' { -not (Test-Path $dest) }
Check 'sign-in shortcut removed' { -not (Test-Path (Join-Path ([Environment]::GetFolderPath('Startup')) 'GlazeWM.lnk')) }
Check 'Explorer right-click entry removed' { -not (Test-Path 'HKCU:\Software\Classes\SystemFileAssociations\.png\shell\winarchy.convert') }

Log $(if ($script:failed) { "DONE: $($script:failed) check(s) FAILED. Logs: install.log, uninstall.log" } else { 'DONE: all checks passed.' })
Log 'You can close the sandbox now (nothing in it is kept).'
