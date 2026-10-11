# PowerShell script to build DEB package using Docker
# Run this from the flutter_app directory on Windows

$ErrorActionPreference = "Stop"

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "  Banana Farm DEB Package Builder" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

# Get the flutter_app directory (parent of scripts/linux)
$FLUTTER_APP_DIR = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$DOCKER_IMAGE = "bananafarm-linux-builder"
$OUTPUT_DIR = "build\linux\packages\deb"

Write-Host "[1/4] Checking Docker..." -ForegroundColor Yellow
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
Write-Host "[2/4] Building Docker image (this may take a few minutes on first run)..." -ForegroundColor Yellow
docker build -f "$FLUTTER_APP_DIR\docker\Dockerfile.linux-builder" -t $DOCKER_IMAGE "$FLUTTER_APP_DIR"

if ($LASTEXITCODE -ne 0) {
    Write-Host "  [ERROR] Docker build failed!" -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] Docker image built successfully" -ForegroundColor Green

Write-Host ""
Write-Host "[3/4] Building DEB package inside Docker container..." -ForegroundColor Yellow

# Run flutter_distributor inside Docker container
# Mount the flutter_app directory to /workspace
docker run --rm `
    -v "${FLUTTER_APP_DIR}:/workspace" `
    -w /workspace `
    $DOCKER_IMAGE `
    sh -c "flutter pub get && flutter_distributor package --platform linux --targets deb --skip-clean"

if ($LASTEXITCODE -ne 0) {
    Write-Host "  [ERROR] DEB package build failed!" -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] DEB package built successfully" -ForegroundColor Green

Write-Host ""
Write-Host "[4/4] Package Location:" -ForegroundColor Yellow
$debFiles = Get-ChildItem -Path "$FLUTTER_APP_DIR\$OUTPUT_DIR" -Filter "*.deb" -ErrorAction SilentlyContinue

if ($debFiles) {
    foreach ($file in $debFiles) {
        $fileSize = [math]::Round($file.Length / 1MB, 2)
        Write-Host "  [+] $($file.Name) ($fileSize MB)" -ForegroundColor Green
        Write-Host "      Location: $($file.FullName)" -ForegroundColor Gray
    }
}
else {
    Write-Host "  [!] No DEB files found in $OUTPUT_DIR" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "  Build Complete!" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
