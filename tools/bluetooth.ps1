<#
    winarchy: Bluetooth details and the on/off switch, for the bar's Bluetooth panel.
    Keep this file ASCII-only (Windows PowerShell 5.1 reads scripts as ANSI).

    bluetooth.ps1 info          Radio state and paired devices (connected, battery) as JSON, also
                                saved for the panel to show at once next time
    bluetooth.ps1 radio on|off  Bluetooth radio, like the Quick Settings tile (no admin needed);
                                answers with the new state (as "info")
#>
param(
    [Parameter(Position = 0)][string]$Command = 'info',
    [Parameter(Position = 1)][string]$Arg1
)
$ErrorActionPreference = 'Stop'
$cache = Join-Path $env:USERPROFILE '.glzr\winarchy\bluetooth.json'

function Write-Json($obj) {
    [Console]::Out.Write(($obj | ConvertTo-Json -Depth 6 -Compress))
}

# Windows.Devices.Radios (WinRT) from Windows PowerShell: wait on its async calls.
function Get-BluetoothRadio {
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
    return $radios | Where-Object { $_.Kind -eq 'Bluetooth' } | Select-Object -First 1
}

# What kind of device, from its Bluetooth class (classic devices) or its name.
function Get-Kind([string]$name, $cod) {
    if ($cod) {
        $major = ([int64]$cod -shr 8) -band 0x1F
        $minor = ([int64]$cod -shr 2) -band 0x3F
        switch ($major) {
            1 { return 'computer' }
            2 { return 'phone' }
            4 { if ($minor -in 1, 2, 6) { return 'headset' } else { return 'speaker' } }
            5 { if (($minor -band 0x10) -and -not ($minor -band 0x20)) { return 'keyboard' } elseif ($minor -band 0x20) { return 'mouse' } else { return 'gamepad' } }
        }
    }
    switch -Regex ($name) {
        'mouse|mx master|mx anywhere|trackball|trackpad' { return 'mouse' }
        'keyboard|keys|mx mechanical' { return 'keyboard' }
        'buds|airpods|headphone|headset|wh-|wf-|bose|jabra|beats' { return 'headset' }
        'speaker|soundbar|sonos|jbl|boom' { return 'speaker' }
        'controller|gamepad|xbox|dualsense|dualshock|joy-con|8bitdo' { return 'gamepad' }
        'phone|iphone|pixel|galaxy' { return 'phone' }
        'watch|band' { return 'watch' }
    }
    return 'other'
}

function Get-Info {
    $radio = 'none'
    try { $r = Get-BluetoothRadio; if ($r) { $radio = ([string]$r.State).ToLower() } } catch { $radio = 'unknown' }

    # Paired devices: one node per device (BTHLE\DEV_... for Bluetooth LE, BTHENUM\DEV_... for classic).
    $nodes = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match '^(BTHLE|BTHENUM)\\DEV_' })
    $devices = @()
    if ($nodes.Count) {
        $keys = '{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 2', '{83DA6326-97A6-4088-9453-A1923F573B29} 15', '{2BD67D8B-8BEB-48D5-87E0-6CDA3428040A} 10'
        $props = @(Get-PnpDeviceProperty -InstanceId ($nodes | ForEach-Object InstanceId) -KeyName $keys -ErrorAction SilentlyContinue)
        foreach ($n in $nodes) {
            $mine = $props | Where-Object InstanceId -eq $n.InstanceId
            $battery = ($mine | Where-Object KeyName -eq $keys[0]).Data
            $connected = ($mine | Where-Object KeyName -eq $keys[1]).Data
            $cod = ($mine | Where-Object KeyName -eq $keys[2]).Data
            $devices += [ordered]@{
                name      = $n.FriendlyName
                connected = [bool]$connected
                battery   = $(if ($battery -is [byte] -or $battery -is [int]) { [int]$battery } else { $null })
                kind      = Get-Kind $n.FriendlyName $cod
                le        = $n.InstanceId.StartsWith('BTHLE')
            }
        }
    }
    $info = [ordered]@{
        radio   = $radio                                   # on, off, disabled, unknown, none
        devices = @($devices | Sort-Object { -not $_.connected }, { $_.name })
        updated = (Get-Date).ToUniversalTime().ToString('o')
    }
    try { New-Item -ItemType Directory -Force (Split-Path $cache) | Out-Null; ($info | ConvertTo-Json -Depth 6 -Compress) | Set-Content -Path $cache -Encoding UTF8 } catch { }
    return $info
}

switch ($Command) {
    'info' { Write-Json (Get-Info) }
    'radio' {
        if ($Arg1 -notin 'on', 'off') { throw 'usage: bluetooth.ps1 radio on|off' }
        $r = Get-BluetoothRadio
        if (-not $r) { Write-Json @{ ok = $false; status = 'no Bluetooth radio' }; break }
        $state = [Windows.Devices.Radios.RadioState]$(if ($Arg1 -eq 'on') { 'On' } else { 'Off' })
        $status = & $script:Await ($r.SetStateAsync($state)) ([Windows.Devices.Radios.RadioAccessStatus])
        Start-Sleep -Milliseconds 600
        Write-Json @{ ok = ([string]$status -eq 'Allowed'); status = [string]$status; info = (Get-Info) }
    }
    default { throw "Unknown command: $Command" }
}
