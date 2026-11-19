<#
    winarchy: Share Wi-Fi as a QR code (Omarchy's "Setup > Network > QR Code").
    Shows the current Wi-Fi network (name and password) as a QR code that phones can
    scan to join. Esc or a click closes it.   wifi-qr.ps1 [-Ssid <saved network>]
#>
param([string]$Ssid)   # optional: share a saved network other than the current one
. "$PSScriptRoot\common.ps1"
Get-ZXing

$ssid = if ($Ssid) { $Ssid } else { (netsh wlan show interfaces) | Where-Object { $_ -match '^\s+SSID\s+:\s+(.+)$' } |
    ForEach-Object { $Matches[1].Trim() } | Select-Object -First 1 }
if (-not $ssid) {
    Show-Note 'Not on Wi-Fi' 'Connect to a Wi-Fi network first; wired connections have nothing to share.'
    exit
}
$profileText = netsh wlan show profile name="$ssid" key=clear
$key = $profileText | Where-Object { $_ -match '^\s+Key Content\s+:\s+(.+)$' } | ForEach-Object { $Matches[1] } | Select-Object -First 1
$auth = if ($key) { 'WPA' } else { 'nopass' }

# The standard Wi-Fi QR payload; \ ; , : " must be escaped.
function Esc([string]$s) { ($s -replace '([\\;,:"])', '\$1') }
$payload = "WIFI:T:$auth;S:$(Esc $ssid);" + $(if ($key) { "P:$(Esc $key);" } else { '' }) + ';'

$writer = New-Object ZXing.BarcodeWriter
$writer.Format = [ZXing.BarcodeFormat]::QR_CODE
$writer.Options = New-Object ZXing.QrCode.QrCodeEncodingOptions
$writer.Options.Width = 480
$writer.Options.Height = 480
$writer.Options.Margin = 2
$qr = $writer.Write($payload)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'winarchy: Wi-Fi'
$form.FormBorderStyle = 'None'
$form.StartPosition = 'CenterScreen'
$form.TopMost = $true
$form.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#1a1b26')
$form.ClientSize = New-Object System.Drawing.Size 520, 600
$form.KeyPreview = $true
$pic = New-Object System.Windows.Forms.PictureBox
$pic.Image = $qr
$pic.SizeMode = 'Zoom'
$pic.SetBounds(20, 20, 480, 480)
$label = New-Object System.Windows.Forms.Label
$label.Text = "$ssid`nScan with your phone to join. Esc closes."
$label.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#c0caf5')
$label.Font = New-Object System.Drawing.Font 'Segoe UI', 13
$label.TextAlign = 'MiddleCenter'
$label.SetBounds(20, 510, 480, 70)
$form.Controls.AddRange(@($pic, $label))
$form.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $form.Close() } })
$pic.Add_Click({ $form.Close() })
$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
