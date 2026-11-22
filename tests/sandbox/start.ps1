<#
    winarchy fresh-PC test: installs winarchy in a clean Windows Sandbox, checks it works,
    uninstalls it and checks everything was put back. Keep this file ASCII-only.

    Needs Windows Sandbox (Windows 11 Pro / Enterprise / Education). To turn it on, in an
    administrator PowerShell, then restart:
        Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All

    .\tests\sandbox\start.ps1            test this checkout
    .\tests\sandbox\start.ps1 -Ref v0.1.0  test a published release the way users get it (irm | iex)
    .\tests\sandbox\start.ps1 -User        test the no-admin install (install.ps1 -User)

    The sandbox window opens and runs everything by itself (10-20 minutes, most of it winget).
    The report lands in tests\sandbox\results\report.txt; close the sandbox when it says done.
#>
param([string]$Ref, [switch]$User)
$ErrorActionPreference = 'Stop'
$sandbox = Join-Path $env:WINDIR 'System32\WindowsSandbox.exe'
if (-not (Test-Path $sandbox)) {
    throw "Windows Sandbox isn't turned on. In an administrator PowerShell run:`n  Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All`nthen restart and try again."
}
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$results = Join-Path $PSScriptRoot 'results'
New-Item -ItemType Directory -Force $results | Out-Null
Get-ChildItem $results -File | Remove-Item -Force

$refArg = if ($Ref) { " -Ref $Ref" } else { '' }
if ($User) { $refArg += ' -User' }
$wsb = Join-Path $results 'winarchy-test.wsb'
@"
<Configuration>
  <MemoryInMB>8192</MemoryInMB>
  <Networking>Enable</Networking>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$repo</HostFolder>
      <SandboxFolder>C:\winarchy-src</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$results</HostFolder>
      <SandboxFolder>C:\results</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File C:\winarchy-src\tests\sandbox\inside.ps1$refArg</Command>
  </LogonCommand>
</Configuration>
"@ | Set-Content -Path $wsb -Encoding UTF8
Start-Process $wsb
Write-Host "Sandbox starting. Watch its window; the report will be in $results\report.txt"
