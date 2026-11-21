<#
    winarchy: network details and switches for the bar's network panel.
    Keep this file ASCII-only (Windows PowerShell 5.1 reads scripts as ANSI).

    network.ps1 info              Wi-Fi and wired adapters as JSON (also saved for the panel to
                                  show at once next time)
    network.ps1 public            Public IP and country, from Cloudflare (1.1.1.1/cdn-cgi/trace)
    network.ps1 wifi on|off       Wi-Fi radio, like the Quick Settings tile (no admin needed)
    network.ps1 adapter <n> on|off
                                  Enable or disable the adapter with interface index <n>.
                                  Windows requires an administrator for this, so it asks (UAC).
#>
param(
    [Parameter(Position = 0)][string]$Command = 'info',
    [Parameter(Position = 1)][string]$Arg1,
    [Parameter(Position = 2)][string]$Arg2
)
$ErrorActionPreference = 'Stop'
$stateDir = if ($env:WINARCHY_NETWORK_STATE) { $env:WINARCHY_NETWORK_STATE } else { Join-Path $env:USERPROFILE '.glzr\winarchy' }
$cache = Join-Path $stateDir 'network.json'

function Write-Json($obj) {
    $json = $obj | ConvertTo-Json -Depth 5 -Compress
    [Console]::Out.Write($json)
    return $json
}

# Windows.Devices.Radios (WinRT) from Windows PowerShell: wait on its async calls.
function Get-WifiRadio {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $script:asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } |
        Select-Object -First 1
    $script:Await = {
        param($op, [Type]$type)
        $task = $script:asTask.MakeGenericMethod($type).Invoke($null, @($op))
        $task.Wait(-1) | Out-Null
        $task.Result
    }
    [Windows.Devices.Radios.Radio, Windows.System.Devices, ContentType = WindowsRuntime] | Out-Null
    [Windows.Devices.Radios.RadioAccessStatus, Windows.System.Devices, ContentType = WindowsRuntime] | Out-Null
    & $script:Await ([Windows.Devices.Radios.Radio]::RequestAccessAsync()) ([Windows.Devices.Radios.RadioAccessStatus]) | Out-Null
    $radios = & $script:Await ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]])
    return $radios | Where-Object { $_.Kind -eq 'WiFi' } | Select-Object -First 1
}

# Band, channel and link rate of the connected Wi-Fi network. netsh's labels are only
# matched in English; on other languages these extras are simply left out.
function Get-WifiLink {
    $link = @{}
    try {
        foreach ($line in (netsh.exe wlan show interfaces)) {
            if ($line -match '^\s*(Band|Channel|Receive rate \(Mbps\)|Radio type)\s*:\s*(.+)$') {
                switch ($Matches[1]) {
                    'Band' { $link.band = $Matches[2].Trim() }
                    'Channel' { $link.channel = $Matches[2].Trim() }
                    'Radio type' { $link.radio = $Matches[2].Trim() }
                    default { $link.rate = $Matches[2].Trim() + ' Mbps' }
                }
            }
        }
    } catch { }
    return $link
}

switch ($Command) {
    'info' {
        # Physical Wi-Fi and wired adapters only (no VPN, Bluetooth or virtual switches), including
        # disabled ones so they can be switched back on.
        $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
                $_.NdisPhysicalMedium -in 9, 14 -or $_.PhysicalMediaType -in 'Native 802.11', '802.3' } |
            Sort-Object { if ($_.Status -eq 'Up') { 0 } else { 1 } }, Name | ForEach-Object {
                $wifi = $_.NdisPhysicalMedium -eq 9 -or $_.PhysicalMediaType -eq 'Native 802.11'
                [ordered]@{
                    index       = $_.ifIndex
                    name        = $_.Name
                    kind        = $(if ($wifi) { 'wifi' } else { 'wired' })
                    description = $_.InterfaceDescription
                    status      = [string]$_.Status          # Up, Disconnected, Disabled
                    enabled     = $_.Status -ne 'Disabled'
                    speed       = $(if ($_.Status -eq 'Up') { $_.LinkSpeed } else { '' })
                    mac         = $_.MacAddress -replace '-', ':'
                }
            })
        $radio = 'none'
        if ($adapters | Where-Object kind -eq 'wifi') {
            try { $r = Get-WifiRadio; $radio = $(if ($r) { ([string]$r.State).ToLower() } else { 'unknown' }) } catch { $radio = 'unknown' }
        }
        $result = [ordered]@{
            updated   = (Get-Date).ToString('o')
            wifiRadio = $radio                               # on, off, disabled, unknown, none
            wifiLink  = $(if ($adapters | Where-Object { $_.kind -eq 'wifi' -and $_.status -eq 'Up' }) { Get-WifiLink } else { @{} })
            adapters  = $adapters
        }
        $json = Write-Json $result
        try { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null; [IO.File]::WriteAllText($cache, $json) } catch { }
    }
    'public' {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        try {
            $text = (Invoke-WebRequest 'https://1.1.1.1/cdn-cgi/trace' -UseBasicParsing -TimeoutSec 5).Content
            $f = @{}
            foreach ($line in $text -split "`n") { if ($line -match '^(\w+)=(.*)$') { $f[$Matches[1]] = $Matches[2].Trim() } }
            Write-Json ([ordered]@{ ip = $f.ip; country = $f.loc }) | Out-Null
        } catch {
            Write-Json ([ordered]@{ ip = $null; error = 'offline or blocked' }) | Out-Null
        }
    }
    'wifi' {
        if ($Arg1 -notin 'on', 'off') { throw 'usage: network.ps1 wifi on|off' }
        $r = Get-WifiRadio
        if (-not $r) { throw 'No Wi-Fi radio found.' }
        $state = [Windows.Devices.Radios.RadioState]$(if ($Arg1 -eq 'on') { 'On' } else { 'Off' })
        $status = & $script:Await ($r.SetStateAsync($state)) ([Windows.Devices.Radios.RadioAccessStatus])
        Write-Json @{ ok = ([string]$status -eq 'Allowed'); status = [string]$status } | Out-Null
    }
    'adapter' {
        if ($Arg1 -notmatch '^\d+$' -or $Arg2 -notin 'on', 'off') { throw 'usage: network.ps1 adapter <index> on|off' }
        $verb = $(if ($Arg2 -eq 'on') { 'Enable-NetAdapter' } else { 'Disable-NetAdapter' })
        $cmd = "Get-NetAdapter -InterfaceIndex $([int]$Arg1) | $verb -Confirm:`$false"
        try {
            $p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -Wait -PassThru `
                -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd
            Write-Json @{ ok = ($p.ExitCode -eq 0) } | Out-Null
        } catch {
            Write-Json @{ ok = $false; status = 'cancelled' } | Out-Null   # UAC prompt declined
        }
    }
    default { throw "Unknown command: $Command" }
}
