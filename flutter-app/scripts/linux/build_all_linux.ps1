# PowerShell script to build ALL Linux packages (DEB + AppImage) using Docker
# Run this from the flutter_app directory on Windows

$ErrorActionPreference = "Stop"

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Banana Farm - All Linux Packages Builder" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# Get the flutter_app directory (parent of scripts/linux)
$FLUTTER_APP_DIR = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$DOCKER_IMAGE = "bananafarm-linux-builder"

Write-Host "[1/5] Checking Docker..." -ForegroundColor Yellow
try {
    docker --version | Out-Null
    Write-Host "  [OK] Docker is available" -ForegroundColor Green
}
catch {
    Write-Host "  [ERROR] Docker is not installed or not running!" -ForegroundColor Red
    Write-Host "  Please install Docker Desktop for Windows" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "[2/5] Building Docker image (this may take a few minutes on first run)..." -ForegroundColor Yellow
docker build -f "$FLUTTER_APP_DIR\docker\Dockerfile.linux-builder" -t $DOCKER_IMAGE "$FLUTTER_APP_DIR"

if ($LASTEXITCODE -ne 0) {
    Write-Host "  [ERROR] Docker build failed!" -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] Docker image built successfully" -ForegroundColor Green

Write-Host ""
Write-Host "[3/5] Getting Flutter dependencies..." -ForegroundColor Yellow
docker run --rm `
    -v "${FLUTTER_APP_DIR}:/workspace" `
    -w /workspace `
    $DOCKER_IMAGE `
    flutter pub get

if ($LASTEXITCODE -ne 0) {
    Write-Host "  [ERROR] Failed to get Flutter dependencies!" -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] Dependencies downloaded" -ForegroundColor Green

Write-Host ""
Write-Host "[4/5] Building all Linux packages..." -ForegroundColor Yellow
Write-Host "  This will create DEB and AppImage packages" -ForegroundColor Gray

# Run flutter_distributor to build all Linux targets
docker run --rm `
    -v "${FLUTTER_APP_DIR}:/workspace" `
    -w /workspace `
    $DOCKER_IMAGE `
    flutter_distributor package --platform linux --targets deb, appimage --skip-clean

if ($LASTEXITCODE -ne 0) {
    Write-Host "  [ERROR] Package build failed!" -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] All packages built successfully" -ForegroundColor Green

Write-Host ""
Write-Host "[5/5] Build Summary:" -ForegroundColor Yellow
Write-Host ""

# Find and display DEB packages
Write-Host "  DEB Packages:" -ForegroundColor Cyan
$debFiles = Get-ChildItem -Path "$FLUTTER_APP_DIR\build\linux\packages\deb" -Filter "*.deb" -ErrorAction SilentlyContinue
if ($debFiles) {
    foreach ($file in $debFiles) {
        $fileSize = [math]::Round($file.Length / 1MB, 2)
        Write-Host "    [+] $($file.Name) ($fileSize MB)" -ForegroundColor Green
        Write-Host "        $($file.FullName)" -ForegroundColor Gray
    }
}
else {
    Write-Host "    [!] No DEB files found" -ForegroundColor Yellow
}

Write-Host ""

# Find and display AppImage packages
Write-Host "  AppImage Packages:" -ForegroundColor Cyan
$appImageFiles = Get-ChildItem -Path "$FLUTTER_APP_DIR\build\linux\packages\appimage" -Filter "*.AppImage" -ErrorAction SilentlyContinue
if ($appImageFiles) {
    foreach ($file in $appImageFiles) {
        $fileSize = [math]::Round($file.Length / 1MB, 2)
        Write-Host "    [+] $($file.Name) ($fileSize MB)" -ForegroundColor Green
        Write-Host "        $($file.FullName)" -ForegroundColor Gray
    }
}
else {
    Write-Host "    [!] No AppImage files found" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  All Builds Complete!" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  - Test the packages on a Linux system" -ForegroundColor Gray
Write-Host "  - DEB: sudo dpkg -i <package.deb>" -ForegroundColor Gray
Write-Host "  - AppImage: chmod +x <package.AppImage> && ./<package.AppImage>" -ForegroundColor Gray
