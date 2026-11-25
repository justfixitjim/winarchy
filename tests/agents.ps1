<#
    Account-switching tests for tools\agents.ps1. Uses made-up sign-ins in a temporary folder; your
    own Claude Code and Codex sign-ins are never read or changed. Keep this file ASCII-only.
#>
$ErrorActionPreference = 'Stop'
$agents = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\agents.ps1')).Path
$root = Join-Path $env:TEMP ('winarchy-agents-test-' + [guid]::NewGuid().ToString('N'))
$failed = 0
function Check($name, [bool]$ok) { if (-not $ok) { $script:failed++ }; Write-Host ('{0}  {1}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name) }

function Put($path, $text) { New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null; [IO.File]::WriteAllText($path, $text) }
function Put-Login($dir, $who) {
    Put "$dir\.credentials.json" "{`"claudeAiOauth`":{`"refreshToken`":`"$who`",`"accessToken`":`"$who`",`"expiresAt`":4102444800000}}"
    Put "$dir\.claude.json" "{`"oauthAccount`":{`"emailAddress`":`"$who`"}}"
}
function Who($dir) { $f = "$dir\.credentials.json"; if (Test-Path $f) { (Get-Content $f -Raw | ConvertFrom-Json).claudeAiOauth.refreshToken } else { '' } }
function Put-Registry($seated) {
    Put "$state\claude.json" (@{ active = $seated; seated = $seated; preferred = 'main'; autoAway = $false; mode = 'auto'; threshold = 90; alert = ''
        accounts = @(@{ id = 'main'; label = 'main'; primary = $true }, @{ id = 'account2'; label = 'two'; primary = $false }, @{ id = 'account3'; label = 'three'; primary = $false }) } | ConvertTo-Json -Depth 5)
}
function Seated { (Get-Content "$state\claude.json" -Raw | ConvertFrom-Json).seated }
# Fresh made-up PC: account `seated` is in use, the other two are parked.
function Reset($seated) {
    $script:base = Join-Path $root ([guid]::NewGuid().ToString('N')); $script:state = "$base\w\agents"; $script:claudeHome = "$base\claude"; $script:park = "$state\claude"
    $env:WINARCHY_AGENTS_STATE = $state; $env:WINARCHY_CLAUDE_HOME = $claudeHome; $env:WINARCHY_CODEX_HOME = "$base\codex"; $env:WINARCHY_SETTINGS = "$base\w\settings.json"
    Put-Registry $seated
    foreach ($id in 'main', 'account2', 'account3') { Put-Login $(if ($id -eq $seated) { $claudeHome } else { "$park\$id" }) $id }
}
function Run($code) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "`$ErrorActionPreference = 'Stop'; . '$agents' list claude | Out-Null; $code" | Out-Null; return $LASTEXITCODE }
# Every login exists exactly once, and the seated one is the one the registry names.
function Whole {
    $all = @(Who $claudeHome) + @('main', 'account2', 'account3' | ForEach-Object { Who "$park\$_" }) | Where-Object { $_ } | Sort-Object
    (($all -join ',') -eq 'account2,account3,main') -and ((Who $claudeHome) -eq (Seated)) -and -not (Test-Path "$state\claude-swap")
}

$saved = @{}; foreach ($n in 'AGENTS_STATE', 'CLAUDE_HOME', 'CODEX_HOME', 'SETTINGS') { $saved[$n] = [Environment]::GetEnvironmentVariable("WINARCHY_$n") }
try {
    Reset 'account2'; Put "$base\w\settings.json" '{"accountSwitching": false}'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $agents restore
    Check 'restore puts main back with switching off' ($LASTEXITCODE -eq 0 -and (Who $claudeHome) -eq 'main' -and (Whole))

    Reset 'account2'; Remove-Item "$park\main" -Recurse
    $ErrorActionPreference = 'Continue'; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $agents restore 2>$null; $code = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
    Check 'restore reports failure when main has no saved sign-in' ($code -ne 0 -and (Who $claudeHome) -eq 'account2')

    Reset 'main'
    $procs = 1..8 | ForEach-Object { Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `". '$agents' list claude | Out-Null; Invoke-Locked { Use-Account claude next -Quiet }`"" }
    $procs | ForEach-Object { $_.WaitForExit() }
    Check '8 switches at once lose no login, and all of them count' ((Whole) -and (Seated) -eq 'account3')

    # The usage check reads the accounts, then a switch happens before it decides.
    Reset 'main'; Put "$base\w\settings.json" '{"accountSwitching": true}'
    $code = Run @'
function Show-Toast {}
function Get-ClaudeUsage($acct) { if ($acct.id -eq 'account3') { Use-Account claude account2 -Quiet }; @{ status = 'ok'; session = @{ pct = 95.0; resetsAt = '' } } }
Update-Usage | Out-Null
'@
    Check 'a switch during a usage check is not undone by it' ($code -eq 0 -and (Whole) -and (Seated) -eq 'account2')

    # Cut short after the target was seated but before the registry was saved.
    Reset 'main'; Put-Login "$state\claude-swap" 'main'; Put "$state\claude-swap\swap.json" '{"from":"main","to":"account2"}'
    Put-Login "$park\main" 'main'; Put-Login $claudeHome 'account2'
    $code = Run "Invoke-Locked { Use-Account claude account3 -Quiet }"
    Check 'an interrupted switch is undone' ($code -eq 0 -and (Whole) -and (Seated) -eq 'account3')

    # Cut short after the registry was saved but before the old copy was dropped.
    Reset 'account2'; Put-Login "$state\claude-swap" 'main'; Put "$state\claude-swap\swap.json" '{"from":"main","to":"account2"}'; Put-Login "$park\account2" 'account2'
    $code = Run "Invoke-Locked { Use-Account claude account3 -Quiet }"
    Check 'an interrupted switch is finished' ($code -eq 0 -and (Whole) -and (Seated) -eq 'account3')

    # Cut short while the backup was being written: nothing had moved.
    Reset 'main'; Put "$state\claude-swap\.credentials.json" '{"cla'
    $code = Run "Invoke-Locked { Use-Account claude account2 -Quiet }"
    Check 'a half-written backup is dropped' ($code -eq 0 -and (Whole) -and (Seated) -eq 'account2')
} finally {
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable("WINARCHY_$n", $saved[$n]) }
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host $(if ($failed) { "$failed FAILED" } else { 'All passed.' })
exit $(if ($failed) { 1 } else { 0 })
