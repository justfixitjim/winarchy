<#
    winarchy: Grab text from the screen (Omarchy's "Trigger > Capture > Text").
    Snip a region; the text in it is recognised with Windows' built-in OCR and copied
    to the clipboard. Nothing leaves your PC.
#>
. "$PSScriptRoot\common.ps1"

$bmp = Get-ScreenSnip
if (-not $bmp) { exit }

# Windows.Media.Ocr is a WinRT API; these lines make it callable from Windows PowerShell.
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } |
    Select-Object -First 1
function Await($op, [Type]$type) {
    $task = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
    $task.Wait() | Out-Null
    $task.Result
}

$tmp = Join-Path $env:TEMP ('winarchy-ocr-' + [guid]::NewGuid().ToString('N') + '.png')
try {
    # Small snips OCR badly; scale them up first.
    if ($bmp.Height -lt 200) {
        $f = [math]::Ceiling(200 / $bmp.Height)
        $big = New-Object System.Drawing.Bitmap ($bmp.Width * $f), ($bmp.Height * $f)
        $g = [System.Drawing.Graphics]::FromImage($big)
        $g.InterpolationMode = 'HighQualityBicubic'
        $g.DrawImage($bmp, 0, 0, $big.Width, $big.Height)
        $g.Dispose(); $bmp = $big
    }
    $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)

    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tmp)) ([Windows.Storage.StorageFile])
    $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $soft = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    $result = Await ($engine.RecognizeAsync($soft)) ([Windows.Media.Ocr.OcrResult])
    $stream.Dispose()

    $text = ($result.Lines | ForEach-Object { $_.Text }) -join "`r`n"
    if ($text.Trim()) {
        [System.Windows.Forms.Clipboard]::SetText($text)
        $preview = if ($text.Length -gt 80) { $text.Substring(0, 80) + '...' } else { $text }
        Show-Note "Copied $($text.Length) characters" $preview
    } else {
        Show-Note 'No text found' 'Try snipping a larger or sharper area.'
    }
} finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
}
