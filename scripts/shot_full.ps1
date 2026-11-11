# Screenshot of the whole primary screen, downscaled (controller UI testing).
param([string]$Out, [int]$Width = 1500)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
$h = [int]($b.Height * $Width / $b.Width)
$small = New-Object System.Drawing.Bitmap $Width, $h
$g2 = [System.Drawing.Graphics]::FromImage($small)
$g2.InterpolationMode = 'HighQualityBicubic'
$g2.DrawImage($bmp, 0, 0, $Width, $h)
$small.Save($Out, [System.Drawing.Imaging.ImageFormat]::Jpeg)
