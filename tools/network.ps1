<#
    winarchy: network details and switches for the bar's network panel.
    Keep this file ASCII-only (Windows PowerShell 5.1 reads scripts as ANSI).

    network.ps1 info              Wi-Fi and wired adapters as JSON (also saved for the panel to
                                  show at once next time)
    network.ps1 public            Public IP and country, from Cloudflare (1.1.1.1/cdn-cgi/trace)
    network.ps1 password          The connected Wi-Fi network's saved password (no admin needed)
    network.ps1 wifi on|off       Wi-Fi radio, like the Quick Settings tile (no admin needed)
    network.ps1 adapter <n> on|off
                                  Enable or disable the adapter with interface index <n>.
                                  Windows requires an administrator for this, so it asks (UAC).
    The switches answer with the new adapter state (as "info"), saving the panel a second run.
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
    [Console]::Out.Write(($obj | ConvertTo-Json -Depth 6 -Compress))
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

function Format-Speed([UInt64]$bps) {
    if (-not $bps -or $bps -ge [UInt64]::MaxValue - 1) { return '' }
    if ($bps -ge 1e9) { return ('{0:0.#} Gbps' -f ($bps / 1e9)) }
    return ('{0:0} Mbps' -f ($bps / 1e6))
}

# Physical Wi-Fi (NDIS medium 9) and wired (14) adapters only: no VPN, Bluetooth, virtual switches
# or USB dongles. Disabled ones are included so they can be switched back on. Also saves the
# result for the panel to show at once next time.
function Get-Info {
    $adapters = @(Get-CimInstance -Namespace root/StandardCimv2 -ClassName MSFT_NetAdapter -Filter 'HardwareInterface = TRUE' |
        Where-Object { $_.NdisPhysicalMedium -in 9, 14 } | ForEach-Object {
            $disabled = $_.State -eq 3
            $up = -not $disabled -and $_.MediaConnectState -eq 1
            $mac = "$($_.PermanentAddress)"
            if ($mac.Length -eq 12) { $mac = ($mac -split '(..)' -ne '') -join ':' }
            [ordered]@{
                index       = [int]$_.InterfaceIndex
                name        = $_.Name
                kind        = $(if ($_.NdisPhysicalMedium -eq 9) { 'wifi' } else { 'wired' })
                description = $_.InterfaceDescription
                status      = $(if ($disabled) { 'Disabled' } elseif ($up) { 'Up' } else { 'Disconnected' })
                enabled     = -not $disabled
                speed       = $(if ($up) { Format-Speed $_.Speed } else { '' })
                mac         = $mac
            }
        } | Sort-Object { if ($_.status -eq 'Up') { 0 } else { 1 } }, { $_.name })
    $radio = 'none'
    if ($adapters | Where-Object { $_.kind -eq 'wifi' }) {
        try { $r = Get-WifiRadio; $radio = $(if ($r) { ([string]$r.State).ToLower() } else { 'unknown' }) } catch { $radio = 'unknown' }
    }
    $result = [ordered]@{
        updated   = (Get-Date).ToString('o')
        wifiRadio = $radio                               # on, off, disabled, unknown, none
        wifiLink  = $(if ($adapters | Where-Object { $_.kind -eq 'wifi' -and $_.status -eq 'Up' }) { Get-WifiLink } else { @{} })
        adapters  = $adapters
    }
    try {
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
        [IO.File]::WriteAllText($cache, ($result | ConvertTo-Json -Depth 5 -Compress))
    } catch { }
    return $result
}

switch ($Command) {
    'info' { Write-Json (Get-Info) | Out-Null }
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
        Write-Json ([ordered]@{ ok = ([string]$status -eq 'Allowed'); status = [string]$status; info = (Get-Info) }) | Out-Null
    }
    'adapter' {
        if ($Arg1 -notmatch '^\d+$' -or $Arg2 -notin 'on', 'off') { throw 'usage: network.ps1 adapter <index> on|off' }
        # The elevated copy calls the adapter's Enable / Disable method directly (no module to load).
        $method = $(if ($Arg2 -eq 'on') { 'Enable' } else { 'Disable' })
        $cmd = "`$r = Get-CimInstance -Namespace root/StandardCimv2 -ClassName MSFT_NetAdapter -Filter 'InterfaceIndex = $([int]$Arg1)' | " +
            "Invoke-CimMethod -MethodName $method; exit [int]`$r.ReturnValue"
        try {
            $p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -Wait -PassThru `
                -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd
            $out = [ordered]@{ ok = ($p.ExitCode -eq 0); status = $(if ($p.ExitCode) { "error $($p.ExitCode)" } else { 'done' }) }
        } catch {
            $out = [ordered]@{ ok = $false; status = 'cancelled' }   # UAC prompt declined
        }
        $out.info = Get-Info
        Write-Json $out | Out-Null
    }
    'password' {
        # The connected Wi-Fi network's saved password (Omarchy's `omarchy network password`).
        # netsh's labels are only matched in English.
        $ssid = (netsh.exe wlan show interfaces) | Where-Object { $_ -match '^\s+SSID\s+:\s+(.+)$' } |
            ForEach-Object { $Matches[1].Trim() } | Select-Object -First 1
        if (-not $ssid) { Write-Json ([ordered]@{ ssid = $null; error = 'not on Wi-Fi' }) | Out-Null; break }
        $lines = netsh.exe wlan show profile name="$ssid" key=clear
        $key = $lines | Where-Object { $_ -match '^\s+Key Content\s+:\s+(.+)$' } | ForEach-Object { $Matches[1] } | Select-Object -First 1
        $open = [bool]($lines | Where-Object { $_ -match '^\s+Authentication\s+:\s+Open\s*$' })
        Write-Json ([ordered]@{ ssid = $ssid; password = $key; open = $open; error = $(if (-not $key -and -not $open) { 'not saved, or Windows is not in English' } else { $null }) }) | Out-Null
    }
    default { throw "Unknown command: $Command" }
}
