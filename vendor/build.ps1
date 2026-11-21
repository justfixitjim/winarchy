<#
    Rebuilds config\zebar\vendor: the bar's libraries and icon font, kept in the repo so the bar
    and its panels load nothing from the internet. Only needed when updating a version here or in
    package.json; install.ps1 just copies the built files. Needs Node.js (npm).
#>
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$out = Join-Path $here '..\config\zebar\vendor'
New-Item -ItemType Directory -Force -Path $out | Out-Null

Push-Location $here
try {
    npm install --no-audit --no-fund --silent
    if ($LASTEXITCODE) { throw 'npm install failed' }
    node bundle.mjs
    if ($LASTEXITCODE) { throw 'esbuild failed' }
} finally { Pop-Location }

# Nerd Fonts symbols (the bar's icons): the stylesheet nerdfonts.com serves, pointed at a local copy
# of its font. Pinned by SHA-256 so an upstream change is noticed rather than shipped.
$fontUrl = 'https://www.nerdfonts.com/assets/fonts/Symbols-2048-em%20Nerd%20Font%20Complete.woff2'
$fontSha = 'B5C1850F13F5FE418A7B992CE16DCFE645E1EB9536DA730F9C7CDD8BFBE16B69'
$cssUrl = 'https://www.nerdfonts.com/assets/css/webfont.css'
$font = Join-Path $out 'nerd-fonts.woff2'
& curl.exe -fsSL $fontUrl -o $font
$sha = (Get-FileHash $font -Algorithm SHA256).Hash
if ($fontSha -notlike '{{*' -and $sha -ne $fontSha) { throw "Nerd Fonts symbols font changed upstream (SHA-256 $sha). Check it, then update the pin." }
$css = (& curl.exe -fsSL $cssUrl) -join "`n"
$css = $css -replace 'url\("\.\./fonts/Symbols-2048-em Nerd Font Complete\.woff2"\)', 'url("./nerd-fonts.woff2")'
if ($css -notmatch 'nerd-fonts\.woff2') { throw 'Nerd Fonts stylesheet layout changed; update build.ps1.' }
[IO.File]::WriteAllText((Join-Path $out 'nerd-fonts.css'), $css)
Write-Host "Built $out (font SHA-256 $sha)"
