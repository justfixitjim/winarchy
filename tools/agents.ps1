# winarchy agents: AI subscription usage and accounts for Claude Code and Codex, like Omarchy's.
#
#   agents.ps1 usage [-Refresh]            JSON for the bar (cached; refreshed every few minutes)
#   agents.ps1 status                      usage table in the terminal
#   agents.ps1 add <claude|codex>          sign in another account (opens a terminal)
#   agents.ps1 use <claude|codex> [id|next] new sessions use that account
#   agents.ps1 list [claude|codex]
#   agents.ps1 remove <claude|codex> <id>
#   agents.ps1 restore                     put the main accounts back (uninstall; works with switching off)
#   agents.ps1 mode <claude|codex> <manual|auto> [threshold]
#   agents.ps1 prefer <claude|codex> <id>  the account to be on; auto-switch returns to it
#                                          once its limits reset
#   agents.ps1 switching <on|off>          account switching (add / use / prefer / mode) is off
#                                          until turned on ("accountSwitching" in settings.json),
#                                          because it moves login files; usage works either way
#
# Claude: every session starts in ~\.claude, which holds the login of the "seated" account;
# the other logins wait in ~\.glzr\winarchy\agents\claude\<id>. Switching swaps the
# chosen login into ~\.claude, so new and running `claude` sessions follow (the Claude desktop
# app has its own sign-in and is not switched). Codex: each extra account has its own
# CODEX_HOME, sharing sessions, prompts and config with ~\.codex; switching sets CODEX_HOME
# for new terminals. Tokens never leave the account folders and are never printed.
param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [Parameter(Position = 1)][string]$Provider,
    [Parameter(Position = 2)][string]$Arg1,
    [Parameter(Position = 3)][string]$Arg2,
    [switch]$Refresh
)
$ErrorActionPreference = 'Stop'
if ($Command -eq 'usage' -and -not $Refresh) {
    $cache = Join-Path $(if ($env:WINARCHY_AGENTS_STATE) { $env:WINARCHY_AGENTS_STATE } else { Join-Path $env:USERPROFILE '.glzr\winarchy\agents' }) 'usage.json'
    if ((Test-Path $cache) -and ((Get-Date) - (Get-Item $cache).LastWriteTime).TotalMinutes -lt 4) { [IO.File]::ReadAllText($cache); return }
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# State lives in the user profile, not AppData: apps started from a packaged app (MSIX) see a
# private copy of new AppData folders, so a sign-in terminal could miss files the bar wrote.
$stateDir = if ($env:WINARCHY_AGENTS_STATE) { $env:WINARCHY_AGENTS_STATE } else { Join-Path $env:USERPROFILE '.glzr\winarchy\agents' }
$oldState = Join-Path $env:LOCALAPPDATA 'winarchy\agents'
if (-not $env:WINARCHY_AGENTS_STATE -and -not (Test-Path $stateDir) -and (Test-Path $oldState)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $stateDir) | Out-Null
    Move-Item $oldState $stateDir
}
$usagePath = Join-Path $stateDir 'usage.json'
$utf8 = New-Object Text.UTF8Encoding $false
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$script = $MyInvocation.MyCommand.Path

$claudePrimary = if ($env:WINARCHY_CLAUDE_HOME) { $env:WINARCHY_CLAUDE_HOME } else { Join-Path $env:USERPROFILE '.claude' }
$codexPrimary = if ($env:WINARCHY_CODEX_HOME) { $env:WINARCHY_CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$names = @{ claude = 'Claude'; codex = 'Codex' }
$codexShared = @('sessions', 'archived_sessions', 'prompts', 'skills', 'rules', 'plugins')
$codexSharedFiles = @('config.toml', 'AGENTS.md', 'history.jsonl', 'hooks.json')
$refreshMinutes = 4

function Read-Text($p) { [IO.File]::ReadAllText($p, $utf8) }
function Write-Text($p, $t) { [IO.File]::WriteAllText($p, $t, $utf8) }
# Replaces a file in one step: a reader, or a crash, never sees half of it.
function Write-Whole($p, $t) {
    $tmp = "$p.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Write-Text $tmp $t
        for ($i = 0; ; $i++) {
            try { if (Test-Path $p) { [IO.File]::Replace($tmp, $p, [NullString]::Value) } else { [IO.File]::Move($tmp, $p) }; return }
            catch { if ($i -ge 4) { throw }; Start-Sleep -Milliseconds 40 }   # a reader has it open
        }
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}
# One change to the accounts at a time (the bar's auto-switch, the menu, the panel and a sign-in
# window are separate processes). Throws, changing nothing, if another one keeps the lock. Nests.
$script:accountLock = New-Object Threading.Mutex($false, 'Local\winarchy-agents-accounts')
function Invoke-Locked([scriptblock]$Action) {
    $gotLock = $false
    try { $gotLock = $script:accountLock.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $gotLock = $true }
    if (-not $gotLock) { throw 'Another account change is still running. Try again in a moment.' }
    try { & $Action } finally { $script:accountLock.ReleaseMutex() }
}
# Claude's own files go through a case-sensitive parser and are changed one key at a time.
$script:ser = $null
function Get-Serializer {
    if (-not $script:ser) {
        Add-Type -AssemblyName System.Web.Extensions
        $script:ser = New-Object Web.Script.Serialization.JavaScriptSerializer
        $script:ser.MaxJsonLength = [int]::MaxValue
    }
    return $script:ser
}
function Read-Dict($p) { if (Test-Path $p) { try { return (Get-Serializer).DeserializeObject((Read-Text $p)) } catch {} }; return $null }
function Write-Dict($p, $d) { Write-Text $p ((Get-Serializer).Serialize($d)) }

function Show-Toast($title, $body) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $x = New-Object Windows.Data.Xml.Dom.XmlDocument
        $esc = { param($s) [Security.SecurityElement]::Escape([string]$s) }
        $x.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$(& $esc $title)</text><text>$(& $esc $body)</text></binding></visual></toast>")
        $app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show((New-Object Windows.UI.Notifications.ToastNotification $x))
    } catch {}
    Write-Host "$title - $body"
}

function Assert-Provider { if ($Provider -notin 'claude', 'codex') { throw "Say which agent: claude or codex." } }

# --- Opt-in: account switching moves Claude Code / Codex login files, so it's off until asked for.
$settingsFile = if ($env:WINARCHY_SETTINGS) { $env:WINARCHY_SETTINGS } else { Join-Path (Split-Path $stateDir) 'settings.json' }
function Test-Switching {
    $s = Read-Dict $settingsFile
    if ($s -and $s.ContainsKey('accountSwitching')) { return [bool]$s['accountSwitching'] }
    # Set up before this was opt-in: already has a second account, so it's in use.
    foreach ($prov in 'claude', 'codex') {
        $p = Registry-Path $prov
        if ((Test-Path $p) -and @((Read-Text $p | ConvertFrom-Json).accounts).Count -gt 1) { return $true }
    }
    return $false
}
function Set-Switching([bool]$on) {
    # Same lock and one-step replace as winarchy.exe and winarchy-daemon (settings.json is shared).
    $lock = New-Object Threading.Mutex($false, 'Local\winarchy-file-settings.json')
    $have = $false
    try { $have = $lock.WaitOne(3000) } catch [Threading.AbandonedMutexException] { $have = $true }
    if (-not $have) { throw 'settings.json is being changed by another winarchy program. Try again.' }
    try {
        $s = Read-Dict $settingsFile
        if (-not $s) { $s = New-Object 'Collections.Generic.Dictionary[string,object]' }
        $s['accountSwitching'] = $on
        $lines = foreach ($k in @($s.Keys)) { '  ' + (Get-Serializer).Serialize($k) + ': ' + (Get-Serializer).Serialize($s[$k]) }
        Write-Whole $settingsFile ("{`n" + ($lines -join ",`n") + "`n}`n")
    } finally { $lock.ReleaseMutex() }
    Remove-Item $usagePath -ErrorAction SilentlyContinue
}
function Assert-Switching {
    if (Test-Switching) { return $true }
    Show-Toast 'AI account switching is off' 'It swaps Claude Code / Codex logins between accounts. Turn it on: menu > AI > Account switching, or the AI panel.'
    return $false
}

# --- Registry: which accounts exist, which one is active, how switching works -------------
function Registry-Path($prov) { Join-Path $stateDir "$prov.json" }
function Save-Registry($prov, $reg) { Write-Whole (Registry-Path $prov) (($reg | ConvertTo-Json -Depth 6) + "`n") }
function Load-Registry($prov) {
    $p = Registry-Path $prov
    if (Test-Path $p) {
        $reg = Read-Text $p | ConvertFrom-Json
        $reg.accounts = @($reg.accounts)
        # Added later: the preferred account, and whether auto-switch moved us off it.
        if (-not $reg.PSObject.Properties['preferred']) { $reg | Add-Member preferred 'main' }
        if (-not $reg.PSObject.Properties['autoAway']) { $reg | Add-Member autoAway $false }
        if (-not (Find-Account $reg $reg.preferred)) { $reg.preferred = 'main' }
        return $reg
    }
    $id = Get-Identity $prov $(if ($prov -eq 'claude') { $claudePrimary } else { $codexPrimary }) $true
    $reg = [pscustomobject]@{
        active = 'main'; seated = 'main'; preferred = 'main'; autoAway = $false; mode = 'manual'; threshold = 90; alert = ''
        accounts = @([pscustomobject]@{ id = 'main'; label = $(if ($id.email) { $id.email } else { 'main' }); primary = $true })
    }
    Save-Registry $prov $reg
    return $reg
}
function Find-Account($reg, $id) { $reg.accounts | Where-Object { $_.id -eq $id } | Select-Object -First 1 }

# Where an account's login lives right now.
function Park-Dir($prov, $id) { Join-Path $stateDir "$prov\$id" }
function Login-Dir($prov, $reg, $acct) {
    if ($prov -eq 'claude') { if ($acct.id -eq $reg.seated) { return $claudePrimary } else { return (Park-Dir 'claude' $acct.id) } }
    if ($acct.primary) { return $codexPrimary } else { return (Park-Dir 'codex' $acct.id) }
}
function Claude-Profile($dir) {
    if ($dir -eq $claudePrimary -and -not $env:WINARCHY_CLAUDE_HOME) { Join-Path $env:USERPROFILE '.claude.json' } else { Join-Path $dir '.claude.json' }
}

function Decode-Jwt($token) {
    try {
        $part = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
        while ($part.Length % 4) { $part += '=' }
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
    } catch { return $null }
}

# Display-safe identity: is there a login, whose, and on which plan.
function Get-Identity($prov, $dir, [bool]$isPrimary = $false) {
    if ($prov -eq 'claude') {
        $creds = Read-Dict (Join-Path $dir '.credentials.json')
        $o = if ($creds) { $creds['claudeAiOauth'] } else { $null }
        $prof = Read-Dict (Claude-Profile $dir)
        $acct = if ($prof -and $prof.ContainsKey('oauthAccount')) { $prof['oauthAccount'] } else { $null }
        return @{
            login = [bool]($o -and $o['refreshToken'])
            email = if ($acct) { $acct['emailAddress'] } else { '' }
            plan = if ($o) { [string]$o['subscriptionType'] } else { '' }
        }
    }
    $auth = Join-Path $dir 'auth.json'
    if (-not (Test-Path $auth)) { return @{ login = $false; email = ''; plan = '' } }
    $a = Read-Text $auth | ConvertFrom-Json
    $claims = if ($a.tokens -and $a.tokens.id_token) { Decode-Jwt $a.tokens.id_token } else { $null }
    $openai = if ($claims) { $claims.'https://api.openai.com/auth' } else { $null }
    return @{
        login = [bool](($a.tokens -and $a.tokens.refresh_token) -or $a.OPENAI_API_KEY)
        email = if ($claims) { [string]$claims.email } else { '' }
        plan = if ($openai) { [string]$openai.chatgpt_plan_type } else { '' }
    }
}

# --- Usage ---------------------------------------------------------------------------------
# Reads an account's Claude sign-in, refreshing it if it expired. Call under the lock: refreshing a
# sign-in while a switch copies it would leave the copy with a dead refresh token.
function Get-ClaudeSignIn($acct) {
    $dir = Login-Dir 'claude' (Load-Registry 'claude') $acct
    $credPath = Join-Path $dir '.credentials.json'
    $creds = Read-Dict $credPath
    $o = if ($creds) { $creds['claudeAiOauth'] } else { $null }
    if (-not ($o -and $o['refreshToken'])) { return @{ status = 'Signed out' } }
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if (-not $o['accessToken'] -or [int64]$o['expiresAt'] -lt $nowMs + 60000) {
        # Let Claude Code refresh its own sign-in (no prompt, no usage).
        $claude = (Get-Command claude -ErrorAction SilentlyContinue).Source
        if ($claude) {
            $old = $env:CLAUDE_CONFIG_DIR
            if ($dir -ne $claudePrimary -or $env:WINARCHY_CLAUDE_HOME) { $env:CLAUDE_CONFIG_DIR = $dir } else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
            try { & $claude auth status 2>$null | Out-Null } catch {} finally { if ($old) { $env:CLAUDE_CONFIG_DIR = $old } else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue } }
            $creds = Read-Dict $credPath
            $o = if ($creds) { $creds['claudeAiOauth'] } else { $null }
        }
        if (-not ($o -and $o['accessToken'] -and [int64]$o['expiresAt'] -gt $nowMs)) {
            return @{ status = 'Sign-in expired: run claude auth login' }
        }
    }
    return @{ status = 'ok'; oauth = $o }
}

function Get-ClaudeUsage($acct) {
    $signIn = Invoke-Locked { Get-ClaudeSignIn $acct }
    if ($signIn.status -ne 'ok') { return $signIn }
    $o = $signIn.oauth
    try {
        $r = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -TimeoutSec 15 -Headers @{
            Authorization = 'Bearer ' + $o['accessToken']; 'anthropic-beta' = 'oauth-2025-04-20'; Accept = 'application/json'
        }
    } catch {
        $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        if ($code -eq 401 -or $code -eq 403) { return @{ status = 'Sign-in refused: run claude auth login' } }
        if ($code -eq 429) { return @{ status = 'Usage check rate-limited' } }
        return @{ status = "Usage check failed ($code)" }
    }
    $win = { param($b) if ($b -and $null -ne $b.utilization) { @{ pct = [double]$b.utilization; resetsAt = [string]$b.resets_at } } else { $null } }
    return @{ status = 'ok'; session = (& $win $r.five_hour); weekly = (& $win $r.seven_day); plan = [string]$o['subscriptionType'] }
}

# Codex's limits come from its app-server (JSON-RPC over stdin/stdout), as in Omarchy.
# Compiled only when usage is actually checked (the bar's cached reads skip it).
$codexRpcSource = @'
using System;
using System.Diagnostics;
using System.Threading;
public static class WinarchyCodexRpc {
    // Sends initialize, then account/rateLimits/read; returns that reply's JSON line, or "".
    public static string Query(string exe, string home, int timeoutMs) {
        var psi = new ProcessStartInfo(exe, "app-server") { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        psi.EnvironmentVariables["CODEX_HOME"] = home;
        var p = Process.Start(psi);
        string init = null, limits = null;
        var got = new AutoResetEvent(false);
        p.OutputDataReceived += (s, e) => {
            if (e.Data == null) { got.Set(); return; }
            if (e.Data.StartsWith("{\"id\":1,") || e.Data.Contains("\"id\":1}")) { init = e.Data; got.Set(); }
            else if (e.Data.StartsWith("{\"id\":2,") || e.Data.Contains("\"id\":2}")) { limits = e.Data; got.Set(); }
        };
        p.ErrorDataReceived += (s, e) => { };
        p.BeginOutputReadLine(); p.BeginErrorReadLine();
        try {
            // .NET Framework starts stdin with a UTF-8 BOM; a blank first line soaks it up.
            p.StandardInput.WriteLine("");
            p.StandardInput.WriteLine("{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"winarchy\",\"version\":\"1\"}}}");
            p.StandardInput.Flush();
            var end = DateTime.UtcNow.AddMilliseconds(timeoutMs);
            while (init == null && DateTime.UtcNow < end && !p.HasExited) got.WaitOne(200);
            if (init == null) return "";
            p.StandardInput.WriteLine("{\"method\":\"initialized\",\"params\":{}}");
            p.StandardInput.WriteLine("{\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":{}}");
            p.StandardInput.Flush();
            while (limits == null && DateTime.UtcNow < end && !p.HasExited) got.WaitOne(200);
            return limits ?? "";
        } finally {
            try { Process.Start(new ProcessStartInfo("taskkill.exe", "/T /F /PID " + p.Id) { UseShellExecute = false, CreateNoWindow = true }).WaitForExit(5000); } catch { }
        }
    }
}
'@

function Find-Codex {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
    $native = Join-Path $env:APPDATA "npm\node_modules\@openai\codex\vendor\$arch-pc-windows-msvc\codex\codex.exe"
    if (Test-Path $native) { return $native }
    $cmd = Get-Command codex.exe, codex.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-CodexUsage($dir) {
    $id = Get-Identity 'codex' $dir
    if (-not $id.login) { return @{ status = 'Signed out' } }
    $codex = Find-Codex
    if (-not $codex) { return @{ status = 'Codex CLI not found' } }
    if (-not ('WinarchyCodexRpc' -as [type])) { Add-Type -TypeDefinition $codexRpcSource }
    $line = [WinarchyCodexRpc]::Query($codex, $dir, 25000)
    if (-not $line) { return @{ status = 'Codex did not answer' } }
    $m = $line | ConvertFrom-Json
    if ($m.error) { return @{ status = $(if ("$($m.error.message)" -match 'auth') { 'Signed out' } else { "Codex: $($m.error.message)" }) } }
    $b = $null
    if ($m.result.rateLimitsByLimitId -and $m.result.rateLimitsByLimitId.codex) { $b = $m.result.rateLimitsByLimitId.codex }
    elseif ($m.result.rateLimits) { $b = $m.result.rateLimits }
    if (-not $b) { return @{ status = 'Codex sent no limits' } }
    $out = @{ status = 'ok'; plan = $(if ($b.planType) { [string]$b.planType } else { $id.plan }) }
    foreach ($w in @($b.primary, $b.secondary)) {
        if (-not $w -or $null -eq $w.usedPercent) { continue }
        $reset = if ($w.resetsAt) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$w.resetsAt).ToString('o') } else { '' }
        $entry = @{ pct = [double]$w.usedPercent; resetsAt = $reset }
        if ([int]$w.windowDurationMins -ge 10080) { $out.weekly = $entry } else { $out.session = $entry }
    }
    return $out
}

# Highest share used across an account's windows; windows past their reset count as 0.
function Get-Peak($u) {
    if (-not $u) { return $null }
    $now = [DateTimeOffset]::UtcNow
    $vals = foreach ($w in @($u.session, $u.weekly)) {
        if (-not $w) { continue }
        $reset = [DateTimeOffset]::MinValue
        if ($w.resetsAt -and [DateTimeOffset]::TryParse([string]$w.resetsAt, [ref]$reset) -and $reset -lt $now) { 0 } else { [double]$w.pct }
    }
    if (-not $vals) { return $null }
    return ($vals | Measure-Object -Maximum).Maximum
}

function Update-Usage {
    $old = if (Test-Path $usagePath) { Read-Text $usagePath | ConvertFrom-Json } else { $null }
    $result = [ordered]@{ updated = [DateTimeOffset]::UtcNow.ToString('o'); switching = (Test-Switching); providers = @() }
    foreach ($prov in 'claude', 'codex') {
        if ($prov -eq 'codex' -and -not (Test-Path $codexPrimary) -and -not (Test-Path (Registry-Path 'codex'))) { continue }
        if ($prov -eq 'claude' -and -not (Test-Path $claudePrimary)) { continue }
        $reg = Load-Registry $prov
        $prevProv = if ($old) { $old.providers | Where-Object { $_.id -eq $prov } } else { $null }
        $accounts = foreach ($acct in $reg.accounts) {
            $u = try { if ($prov -eq 'claude') { Get-ClaudeUsage $acct } else { Get-CodexUsage (Login-Dir $prov $reg $acct) } } catch { @{ status = "Error: $($_.Exception.Message)" } }
            $prev = if ($prevProv) { $prevProv.accounts | Where-Object { $_.id -eq $acct.id } } else { $null }
            $rec = [ordered]@{ id = $acct.id; label = $acct.label; active = ($acct.id -eq $reg.active); preferred = ($acct.id -eq $reg.preferred); status = $u.status; stale = $false
                plan = $(if ($u.plan) { $u.plan } elseif ($prev) { $prev.plan } else { '' }); session = $u.session; weekly = $u.weekly }
            if ($u.status -ne 'ok' -and $prev -and ($prev.session -or $prev.weekly)) {
                # Keep the last known numbers, marked stale.
                $rec.session = $prev.session; $rec.weekly = $prev.weekly; $rec.stale = $true
            }
            $rec.peak = Get-Peak ([pscustomobject]$rec)
            [pscustomobject]$rec
        }
        $result.providers += [pscustomobject][ordered]@{ id = $prov; name = $names[$prov]; mode = $reg.mode; threshold = $reg.threshold; active = $reg.active; accounts = @($accounts) }
        # Checking usage takes a while, and the accounts may have been switched meanwhile: decide on
        # (and save) the registry as it is now, never the copy read above.
        if ($result.switching) {
            try { Invoke-Locked { if (Test-Switching) { Invoke-AutoSwitch $prov (Load-Registry $prov) @($accounts) } } }
            catch { Show-Toast "$($names[$prov]) could not switch accounts" $_.Exception.Message }
        }
    }
    Write-Text $usagePath (($result | ConvertTo-Json -Depth 8 -Compress) + "`n")
    return $result
}

# At the threshold: in auto mode switch new sessions to the account with the most headroom;
# in manual mode say so once.
function Invoke-AutoSwitch($prov, $reg, $accounts) {
    if ($reg.accounts.Count -lt 2) { return }
    # Auto-switch moved us off the preferred account: go back once its limits have reset.
    if ($reg.autoAway -and $reg.active -ne $reg.preferred -and $reg.mode -eq 'auto') {
        $pref = $accounts | Where-Object { $_.id -eq $reg.preferred }
        if ($pref -and $null -ne $pref.peak -and $pref.peak -lt $reg.threshold) {
            Use-Account $prov $pref.id -Quiet
            Show-Toast "$($names[$prov]) is back on $($pref.label)" "Its limits reset ($([int]$pref.peak)% used). New sessions use it again."
            return
        }
    }
    $cur = $accounts | Where-Object { $_.id -eq $reg.active }
    if (-not $cur -or $null -eq $cur.peak -or $cur.peak -lt $reg.threshold) {
        if ($reg.alert) { $reg.alert = ''; Save-Registry $prov $reg }
        return
    }
    $target = $accounts | Where-Object { $_.id -ne $reg.active -and (Find-Account $reg $_.id) -and $null -ne $_.peak -and $_.peak -lt $reg.threshold } |
        Sort-Object peak | Select-Object -First 1
    $key = if ($target) { "$($reg.mode):$($cur.id):$($target.id)" } else { "exhausted:$($cur.id)" }
    if ($reg.alert -eq $key) { return }
    $reg.alert = $key
    Save-Registry $prov $reg
    $name = $names[$prov]
    if (-not $target) { Show-Toast "All $name accounts are over $($reg.threshold)%" "Staying on $($cur.label)."; return }
    if ($reg.mode -eq 'auto') {
        Use-Account $prov $target.id -Quiet -Auto
        Show-Toast "$name switched to $($target.label)" "$($cur.label) is at $([int]$cur.peak)%. New sessions use $($target.label)."
    } else {
        Show-Toast "$name ($($cur.label)) at $([int]$cur.peak)%" "Switch to $($target.label) ($([int]$target.peak)%): menu > AI > $name > Switch account."
    }
}

# --- Switching -------------------------------------------------------------------------------
function Move-ClaudeLogin($fromDir, $toDir) {
    New-Item -ItemType Directory -Force -Path $toDir | Out-Null
    $cred = Join-Path $fromDir '.credentials.json'
    $prof = Read-Dict (Claude-Profile $fromDir)
    $acct = if ($prof -and $prof.ContainsKey('oauthAccount')) { $prof['oauthAccount'] } else { $null }
    if (Test-Path $cred) { Write-Text (Join-Path $toDir '.credentials.json') (Read-Text $cred) } else { Remove-Item (Join-Path $toDir '.credentials.json') -ErrorAction SilentlyContinue }
    $toProfPath = Claude-Profile $toDir
    $toProf = Read-Dict $toProfPath
    if (-not $toProf) { $toProf = New-Object 'Collections.Generic.Dictionary[string,object]' }
    if ($acct) { $toProf['oauthAccount'] = $acct } else { [void]$toProf.Remove('oauthAccount') }
    Write-Dict $toProfPath $toProf
}

# A switch that was cut short (the process was ended midway) left its backup behind. Once the
# registry says the switch happened, only the tidying is missing; before that, undo it.
function Repair-ClaudeSwap($reg) {
    $bak = Join-Path $stateDir 'claude-swap'
    if (-not (Test-Path $bak)) { return }
    $swap = Read-Dict (Join-Path $bak 'swap.json')   # written once the backup is whole; without it nothing was moved
    if ($swap) {
        if ($reg.seated -eq $swap['to']) { Remove-Item (Join-Path (Park-Dir 'claude' $swap['to']) '.credentials.json') -ErrorAction SilentlyContinue }
        elseif ($reg.seated -eq $swap['from']) { Move-ClaudeLogin $bak $claudePrimary }
        else { throw "An interrupted account switch left $bak in an unexpected state. Nothing was changed." }
    }
    Remove-Item $bak -Recurse -Force
}

function Use-Account($prov, $target, [switch]$Quiet, [switch]$Auto) {
    $reg = Load-Registry $prov
    if ($prov -eq 'claude') { Repair-ClaudeSwap $reg }
    if (-not $target -or $target -eq 'next') {
        $i = [array]::IndexOf(@($reg.accounts.id), $reg.active)
        $target = $reg.accounts[($i + 1) % $reg.accounts.Count].id
    }
    $acct = Find-Account $reg $target
    if (-not $acct) { throw "No $($names[$prov]) account '$target'. Accounts: $($reg.accounts.id -join ', ')" }
    if ($prov -eq 'claude' -and $reg.seated -ne $acct.id) {
        $src = Park-Dir 'claude' $acct.id
        if (-not (Get-Identity 'claude' $src).login) { throw "$($acct.label) isn't signed in. Add it again: agents.ps1 add claude" }
        $park = Park-Dir 'claude' $reg.seated
        $bak = Join-Path $stateDir 'claude-swap'
        # Park the seated login, seat the target, then drop the target's old copy: a refresh
        # token works once, so a login is only ever kept in one place.
        Move-ClaudeLogin $claudePrimary $bak
        Write-Text (Join-Path $bak 'swap.json') "{`"from`":`"$($reg.seated)`",`"to`":`"$($acct.id)`"}"
        $was = $reg.seated
        try {
            Move-ClaudeLogin $claudePrimary $park
            Move-ClaudeLogin $src $claudePrimary
            $reg.seated = $acct.id
            Save-Registry 'claude' $reg   # the switch counts from here
        } catch {
            $reg.seated = $was
            Move-ClaudeLogin $bak $claudePrimary
            Remove-Item $bak -Recurse -Force -ErrorAction SilentlyContinue
            throw
        }
        Remove-Item (Join-Path $src '.credentials.json') -ErrorAction SilentlyContinue
        Remove-Item $bak -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($prov -eq 'codex') {
        $value = if ($acct.primary) { $null } else { Park-Dir 'codex' $acct.id }
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $value, 'User')
        Add-Type -Namespace Winarchy -Name Env -MemberDefinition '[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, UIntPtr w, string l, uint f, uint t, out UIntPtr r);' -ErrorAction SilentlyContinue
        $r = [UIntPtr]::Zero
        [void][Winarchy.Env]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 2000, [ref]$r)
    }
    $reg.active = $acct.id
    $reg.alert = ''
    # Only an automatic move away from the preferred account is undone automatically.
    $reg.autoAway = [bool]($Auto -and $acct.id -ne $reg.preferred)
    Save-Registry $prov $reg
    if (-not $Quiet) {
        $how = if ($prov -eq 'claude') { 'New and running claude sessions' } else { 'New Codex terminals' }
        Show-Toast "$($names[$prov]): $($acct.label)" "$how use $($acct.label)."
    }
}

# --- Adding and removing accounts --------------------------------------------------------------
function Start-SignIn($prov, $dir, $id) {
    $tool = if ($prov -eq 'claude') { 'claude auth login' } else { 'codex login' }
    $envName = if ($prov -eq 'claude') { 'CLAUDE_CONFIG_DIR' } else { 'CODEX_HOME' }
    $setEnv = if ($dir) { "`$env:$envName = '$dir'" } else { "Remove-Item Env:$envName -ErrorAction SilentlyContinue" }
    $tmp = Join-Path $stateDir "signin-$prov.ps1"
    Write-Text $tmp @"
`$Host.UI.RawUI.WindowTitle = 'Sign in to $($names[$prov])'
Write-Host 'Sign in to the $($names[$prov]) account to add. This window closes when you are done.' -ForegroundColor Cyan
$setEnv
$tool
& '$script' finish $prov $id
Read-Host 'Press Enter to close'
"@
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    $args2 = "-NoProfile -ExecutionPolicy Bypass -File `"$tmp`""
    if ($wt) { Start-Process $wt.Source -ArgumentList "new-tab --title `"Sign in`" powershell.exe $args2" }
    else { Start-Process powershell.exe -ArgumentList $args2 }
}

function Add-Account($prov) {
    $reg = Load-Registry $prov
    $primaryDir = if ($prov -eq 'claude') { $claudePrimary } else { $codexPrimary }
    $main = Find-Account $reg 'main'
    $mainDir = Login-Dir $prov $reg $main
    if (-not (Get-Identity $prov $mainDir).login -and ($prov -eq 'codex' -or $reg.seated -eq 'main')) {
        # The main account isn't signed in: sign it in first, where it normally lives.
        Start-SignIn $prov $null 'main'
        return
    }
    $n = 2; while (Find-Account $reg "account$n") { $n++ }
    $id = "account$n"
    $dir = Park-Dir $prov $id
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if ($prov -eq 'codex') {
        # Share sessions, prompts and settings with ~\.codex; only the login is the account's own.
        foreach ($d in $codexShared) {
            $target = Join-Path $codexPrimary $d
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            $link = Join-Path $dir $d
            if (-not (Test-Path $link)) { New-Item -ItemType Junction -Path $link -Target $target | Out-Null }
        }
        foreach ($f in $codexSharedFiles) {
            $target = Join-Path $codexPrimary $f
            $link = Join-Path $dir $f
            if ((Test-Path $target) -and -not (Test-Path $link)) { New-Item -ItemType HardLink -Path $link -Target $target | Out-Null }
        }
    }
    Start-SignIn $prov $dir $id
    Write-Host "A sign-in window opened. Sign in there with the other $($names[$prov]) account."
}

function Complete-SignIn($prov, $id) {
    $reg = Load-Registry $prov
    $acct = Find-Account $reg $id
    $dir = if ($acct) { Login-Dir $prov $reg $acct } elseif ($id -eq 'main') { if ($prov -eq 'claude') { $claudePrimary } else { $codexPrimary } } else { Park-Dir $prov $id }
    $ident = Get-Identity $prov $dir
    if (-not $ident.login) { Write-Host 'No sign-in found, so nothing was added.' -ForegroundColor Yellow; return }
    $dupe = $reg.accounts | Where-Object { $_.id -ne $id -and $_.label -eq $ident.email -and $ident.email }
    if ($dupe) { Write-Host "That's the same account as '$($dupe.id)'. Sign in with a different one." -ForegroundColor Yellow; return }
    $label = if ($ident.email) { $ident.email } else { $id }
    if ($acct) { $acct.label = $label }
    else { $reg.accounts = @($reg.accounts) + [pscustomobject]@{ id = $id; label = $label; primary = $false } }
    Save-Registry $prov $reg
    Write-Host "Added $label ($($ident.plan)). Switch with menu > AI > $($names[$prov])." -ForegroundColor Green
    Remove-Item $usagePath -ErrorAction SilentlyContinue
}

function Remove-Account($prov, $id) {
    $reg = Load-Registry $prov
    $acct = Find-Account $reg $id
    if (-not $acct) { throw "No account '$id'." }
    if ($acct.primary) { throw "The main account can't be removed." }
    if ($reg.active -eq $id -or ($prov -eq 'claude' -and $reg.seated -eq $id)) { throw "Switch to another account first." }
    $dir = Park-Dir $prov $id
    if (Test-Path $dir) {
        # Unlink shared folders first so removing the account can't touch their contents.
        Get-ChildItem $dir -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | ForEach-Object { [IO.Directory]::Delete($_.FullName) }
        Remove-Item $dir -Recurse -Force
    }
    $reg.accounts = @($reg.accounts | Where-Object { $_.id -ne $id })
    Save-Registry $prov $reg
    Write-Host "Removed $($acct.label)."
}

# --- Commands ----------------------------------------------------------------------------------
switch ($Command) {
    'usage' {
        $fresh = (Test-Path $usagePath) -and ((Get-Date) - (Get-Item $usagePath).LastWriteTime).TotalMinutes -lt $refreshMinutes
        if (-not $Refresh -and $fresh) { Read-Text $usagePath; return }
        $mutex = New-Object Threading.Mutex($false, 'winarchy-agents-usage')
        if (-not $mutex.WaitOne(0)) { if (Test-Path $usagePath) { Read-Text $usagePath } else { '{"providers":[]}' }; return }
        try { Update-Usage | ConvertTo-Json -Depth 8 -Compress } finally { $mutex.ReleaseMutex() }
    }
    'status' {
        $u = Update-Usage
        foreach ($p in $u.providers) {
            Write-Host "`n$($p.name)  (switching: $($p.mode) at $($p.threshold)%)" -ForegroundColor Cyan
            foreach ($a in $p.accounts) {
                $fmt = { param($w, $t) if ($w) { '{0} {1,3}%' -f $t, [int]$w.pct } else { "$t   -" } }
                $line = '{0} {1,-34} {2,-6} {3}  {4}  {5}' -f $(if ($a.active) { '*' } else { ' ' }), $a.label, $a.plan, (& $fmt $a.session '5h'), (& $fmt $a.weekly 'week'), $(if ($a.status -ne 'ok') { $a.status } else { '' })
                Write-Host $line
            }
        }
    }
    'list' {
        foreach ($prov in $(if ($Provider) { @($Provider) } else { @('claude', 'codex') })) {
            $reg = Load-Registry $prov
            Write-Host "$($names[$prov]) ($($reg.mode) at $($reg.threshold)%)" -ForegroundColor Cyan
            foreach ($a in $reg.accounts) { '{0} {1,-10} {2}' -f $(if ($a.id -eq $reg.active) { '*' } else { ' ' }), $a.id, $a.label }
        }
    }
    'switching' {
        if ($Provider -notin 'on', 'off') { throw 'usage: agents.ps1 switching on|off' }
        Set-Switching ($Provider -eq 'on')
        Show-Toast "AI account switching $Provider" $(if ($Provider -eq 'on') { 'Add accounts in the AI panel or menu > AI.' } else { 'Logins stay where they are now.' })
    }
    'add' { Assert-Provider; if (Assert-Switching) { Add-Account $Provider } }
    'finish' { Assert-Provider; Invoke-Locked { Complete-SignIn $Provider $Arg1 } }
    'use' { Assert-Provider; if (Assert-Switching) { Invoke-Locked { Use-Account $Provider $Arg1 }; Remove-Item $usagePath -ErrorAction SilentlyContinue } }
    'remove' { Assert-Provider; Invoke-Locked { Remove-Account $Provider $Arg1 } }
    'restore' {
        foreach ($prov in 'codex', 'claude') {
            if (-not (Test-Path (Registry-Path $prov))) { continue }
            Invoke-Locked {
                $reg = Load-Registry $prov
                if ($prov -eq 'claude') { Repair-ClaudeSwap $reg }
                if ($reg.active -ne 'main' -or $reg.seated -ne 'main') { Use-Account $prov 'main' -Quiet }
            }
        }
    }
    'prefer' {
        Assert-Provider
        if (-not (Assert-Switching)) { return }
        Invoke-Locked {
            $reg = Load-Registry $Provider
            $acct = Find-Account $reg $Arg1
            if (-not $acct) { throw "No $($names[$Provider]) account '$Arg1'." }
            $reg.preferred = $acct.id
            Save-Registry $Provider $reg
            # Move to it now if it has room; otherwise come back to it when its limits reset.
            $peak = $null
            if (Test-Path $usagePath) {
                $u = Read-Text $usagePath | ConvertFrom-Json
                $rec = (($u.providers | Where-Object { $_.id -eq $Provider }).accounts | Where-Object { $_.id -eq $acct.id })
                if ($rec) { $peak = Get-Peak $rec }
            }
            if ($reg.active -eq $acct.id) { Show-Toast "$($names[$Provider]) preferred account" "$($acct.label)." }
            elseif ($null -eq $peak -or $peak -lt $reg.threshold) { Use-Account $Provider $acct.id }
            else {
                $reg = Load-Registry $Provider; $reg.autoAway = $true; Save-Registry $Provider $reg
                Show-Toast "$($names[$Provider]) preferred account: $($acct.label)" "It's at $([int]$peak)%, so you stay on the current account until it resets."
            }
            Remove-Item $usagePath -ErrorAction SilentlyContinue
        }
    }
    'mode' {
        Assert-Provider
        if (-not (Assert-Switching)) { return }
        Invoke-Locked {
            $reg = Load-Registry $Provider
            if ($Arg1) { if ($Arg1 -notin 'manual', 'auto') { throw 'Mode is manual or auto.' }; $reg.mode = $Arg1 }
            if ($Arg2) { $reg.threshold = [int]$Arg2 }
            $reg.alert = ''
            Save-Registry $Provider $reg
            $msg = if ($reg.mode -eq 'auto') { "switches new sessions to the account with the most headroom at $($reg.threshold)%." } else { "notifies at $($reg.threshold)% and switches when you say so." }
            Show-Toast "$($names[$Provider]) accounts" "$($names[$Provider]) $msg"
        }
    }
    default { throw "Unknown command '$Command'. Commands: usage, status, add, use, prefer, list, remove, restore, mode, switching." }
}
