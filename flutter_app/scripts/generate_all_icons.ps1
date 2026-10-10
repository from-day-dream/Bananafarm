# Script to generate all app icons and installer images
# Usage: Run from the 'scripts' directory or 'flutter_app' root

$ScriptPath = $PSScriptRoot
$ProjectRoot = Resolve-Path (Join-Path $ScriptPath "..")

Write-Host "🍌 Banana Farm Icon Generator 🍌" -ForegroundColor Yellow
Write-Host "Project Root: $ProjectRoot"

# 1. Generate Flutter Launcher Icons (Android, iOS, Web, Windows .ico)
Write-Host "`n1. Running flutter_launcher_icons..." -ForegroundColor Cyan
Push-Location $ProjectRoot
try {
    flutter pub get
    flutter pub run flutter_launcher_icons
}
catch {
    Write-Error "Failed to run flutter_launcher_icons"
    exit 1
}
finally {
    Pop-Location
}

# 2. Generate Inno Setup Installer Images (BMPs)
Write-Host "`n2. Generating Installer Images (BMPs)..." -ForegroundColor Cyan
$InputIcon = Join-Path $ProjectRoot "assets\icon\icon.png"
$OutputDir = Join-Path $ProjectRoot "windows\runner\resources"

if (-not (Test-Path $InputIcon)) {
    Write-Error "Source icon not found at $InputIcon"
    exit 1
}

try {
    & "$ScriptPath\create_installer_images.ps1" -InputPng $InputIcon -OutputDir $OutputDir
}
catch {
    Write-Error "Failed to generate installer images"
    exit 1
}

Write-Host "`n✨ All icons generated successfully! ✨" -ForegroundColor Green
