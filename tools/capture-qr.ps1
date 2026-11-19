<#
    winarchy: Read a QR code off the screen (Omarchy's "Trigger > Capture > QR Code").
    Snip the code; its contents are copied to the clipboard. Decoded locally with ZXing.Net.
#>
. "$PSScriptRoot\common.ps1"
Get-ZXing

$bmp = Get-ScreenSnip
if (-not $bmp) { exit }

$reader = New-Object ZXing.BarcodeReader
$reader.Options.TryHarder = $true
$reader.AutoRotate = $true
$result = $reader.Decode($bmp)

if ($result) {
    [System.Windows.Forms.Clipboard]::SetText($result.Text)
    $preview = if ($result.Text.Length -gt 100) { $result.Text.Substring(0, 100) + '...' } else { $result.Text }
    Show-Note 'QR code copied' $preview
} else {
    Show-Note 'No QR code found' 'Snip just the code, with a little margin around it.'
}
