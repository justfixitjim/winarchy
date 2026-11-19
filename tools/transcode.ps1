<#
    winarchy: Transcode (Omarchy's "Trigger > Transcode").
    Pick a picture or video, then a format and size; the result is saved next to the
    original (e.g. holiday-1080p.mp4) and shown in Explorer.

    Pictures (ImageMagick): jpg, png, webp, avif  at original / 2560 / 1920 / 1280 px
    Videos   (ffmpeg):      mp4 at original / 4K / 1080p / 720p,  gif at 720 / 480 / 360,
                            mp3 (audio only)

    transcode.ps1 [file]
#>
param([string]$Path)
. "$PSScriptRoot\common.ps1"
$Host.UI.RawUI.WindowTitle = 'winarchy: Transcode'

$pictureExt = 'jpg', 'jpeg', 'png', 'webp', 'avif', 'heic', 'heif', 'gif', 'bmp', 'tif', 'tiff'
$videoExt = 'mp4', 'mov', 'mkv', 'webm', 'avi', 'wmv', 'm4v', 'flv', 'mpg', 'mpeg', '3gp'

if (-not $Path) {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Transcode: pick a picture or video'
    $dlg.Filter = 'Pictures and videos|' + (($pictureExt + $videoExt | ForEach-Object { "*.$_" }) -join ';') + '|All files|*.*'
    $dlg.InitialDirectory = [Environment]::GetFolderPath('MyPictures')
    if ($dlg.ShowDialog() -ne 'OK') { exit }
    $Path = $dlg.FileName
}
if (-not (Test-Path $Path)) { throw "File not found: $Path" }
$ext = [IO.Path]::GetExtension($Path).TrimStart('.').ToLowerInvariant()
Write-Host "  $Path" -ForegroundColor DarkGray

if ($pictureExt -contains $ext -and $ext -ne 'gif') {
    $format = Read-Choice 'Picture format' @('jpg', 'png', 'webp', 'avif')
    if (-not $format) { exit }
    $size = Read-Choice 'Size (long edge)' @(
        @{ Tag = 'full'; Px = 0; Text = 'Original size' },
        @{ Tag = 'large'; Px = 2560; Text = 'Large (2560 px)' },
        @{ Tag = 'medium'; Px = 1920; Text = 'Medium (1920 px)' },
        @{ Tag = 'small'; Px = 1280; Text = 'Small (1280 px)' }) { $_.Text }
    if (-not $size) { exit }

    $out = Get-OutputPath $Path $size.Tag $format
    $margs = @($Path, '-auto-orient')
    if ($size.Px) { $margs += @('-resize', "$($size.Px)x$($size.Px)>") }
    switch ($format) {
        'jpg' { $margs += @('-quality', '88', '-strip') }
        'webp' { $margs += @('-quality', '85', '-strip') }
        'avif' { $margs += @('-quality', '60', '-strip') }
    }
    Write-Host "`n  Converting..." -ForegroundColor Cyan
    & (Get-Magick) @margs $out
    if ($LASTEXITCODE) { throw "ImageMagick failed (exit $LASTEXITCODE)" }
}
elseif ($videoExt -contains $ext -or $ext -eq 'gif') {
    $format = Read-Choice 'Video format' @(
        @{ Ext = 'mp4'; Text = 'mp4 (H.264, plays everywhere)' },
        @{ Ext = 'gif'; Text = 'gif (looping, no sound)' },
        @{ Ext = 'mp3'; Text = 'mp3 (audio only)' }) { $_.Text }
    if (-not $format) { exit }
    $ff = Get-Ffmpeg
    $common = @('-hide_banner', '-loglevel', 'error', '-stats', '-i', $Path)

    switch ($format.Ext) {
        'mp4' {
            $size = Read-Choice 'Resolution' @(
                @{ Tag = 'full'; H = 0; Text = 'Original' },
                @{ Tag = '4k'; H = 2160; Text = '4K (2160p)' },
                @{ Tag = '1080p'; H = 1080; Text = '1080p' },
                @{ Tag = '720p'; H = 720; Text = '720p' }) { $_.Text }
            if (-not $size) { exit }
            $out = Get-OutputPath $Path $size.Tag 'mp4'
            $vf = @()
            if ($size.H) { $vf = @('-vf', "scale=-2:'min(ih,$($size.H))'") }
            & $ff @common @vf -c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p -c:a aac -b:a 160k -movflags +faststart $out
        }
        'gif' {
            $size = Read-Choice 'Width' @(
                @{ Tag = '720w'; W = 720; Text = '720 px wide' },
                @{ Tag = '480w'; W = 480; Text = '480 px wide' },
                @{ Tag = '360w'; W = 360; Text = '360 px wide' }) { $_.Text }
            if (-not $size) { exit }
            $out = Get-OutputPath $Path $size.Tag 'gif'
            # One pass, with a palette generated from the clip itself for clean colours.
            $filter = "fps=15,scale=$($size.W):-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4"
            & $ff @common -vf $filter -loop 0 $out
        }
        'mp3' {
            $out = Get-OutputPath $Path 'audio' 'mp3'
            & $ff @common -vn -c:a libmp3lame -q:a 2 $out
        }
    }
    if ($LASTEXITCODE) { throw "ffmpeg failed (exit $LASTEXITCODE)" }
}
else {
    throw "Not a picture or video winarchy knows: .$ext"
}

$kb = [math]::Round((Get-Item $out).Length / 1KB)
Write-Host "`n  Saved $out ($kb KB)" -ForegroundColor Green
Show-InExplorer $out
Start-Sleep -Seconds 2
exit
