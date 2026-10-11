param(
    [string]$InputPng,
    [string]$OutputDir
)

Add-Type -AssemblyName System.Drawing

if (-not (Test-Path $InputPng)) {
    Write-Error "Input file not found: $InputPng"
    exit 1
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

function Resize-And-Save-Image {
    param(
        [string]$SourcePath,
        [string]$DestPath,
        [int]$Width,
        [int]$Height,
        [System.Drawing.Color]$BgColor
    )

    $srcImage = [System.Drawing.Image]::FromFile($SourcePath)
    $destBitmap = New-Object System.Drawing.Bitmap($Width, $Height)
    $graphics = [System.Drawing.Graphics]::FromImage($destBitmap)
    
    $graphics.Clear($BgColor)
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

    # Calculate scaling to fit within dimensions while maintaining aspect ratio
    $ratioX = $Width / $srcImage.Width
    $ratioY = $Height / $srcImage.Height
    $ratio = [Math]::Min($ratioX, $ratioY) * 0.8 # 80% padding

    $newWidth = [int]($srcImage.Width * $ratio)
    $newHeight = [int]($srcImage.Height * $ratio)

    $posX = [int](($Width - $newWidth) / 2)
    $posY = [int](($Height - $newHeight) / 2)

    $graphics.DrawImage($srcImage, $posX, $posY, $newWidth, $newHeight)
    
    $destBitmap.Save($DestPath, [System.Drawing.Imaging.ImageFormat]::Bmp)
    
    $graphics.Dispose()
    $destBitmap.Dispose()
    $srcImage.Dispose()
    
    Write-Host "Created $DestPath"
}

# Inno Setup Standard Sizes
# WizardImageFile: 164x314 (Side image)
# WizardSmallImageFile: 55x58 (Top right logo)

$largePath = Join-Path $OutputDir "wizard_image.bmp"
$smallPath = Join-Path $OutputDir "wizard_small.bmp"

Write-Host "Generating large wizard image..."
Resize-And-Save-Image -SourcePath $InputPng -DestPath $largePath -Width 164 -Height 314 -BgColor ([System.Drawing.Color]::White)

Write-Host "Generating small wizard image..."
Resize-And-Save-Image -SourcePath $InputPng -DestPath $smallPath -Width 55 -Height 58 -BgColor ([System.Drawing.Color]::White)

Write-Host "Done."
