# Saves a downscaled screenshot of the primary screen. Used while testing the controller UI.
param([string]$Out, [int]$Width = 1150)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# The game window sits at the top-left corner (see focus_game.ps1), 1920x1080 plus its frame.
$b = New-Object System.Drawing.Rectangle 0, 0, 1940, 1130
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
$h = [int]($b.Height * $Width / $b.Width)
$small = New-Object System.Drawing.Bitmap $Width, $h
$g2 = [System.Drawing.Graphics]::FromImage($small)
$g2.InterpolationMode = 'HighQualityBicubic'
$g2.DrawImage($bmp, 0, 0, $Width, $h)
$enc = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
$p = New-Object System.Drawing.Imaging.EncoderParameters 1
$p.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), 80L
$small.Save($Out, $enc, $p)
"$($b.Width)x$($b.Height) -> $Out"
