# Register the app.bananafarm.desktop scheme
$scheme = "app.bananafarm.desktop"
$description = "URL:BananaFarm Protocol"
$exePath = "$PSScriptRoot\..\build\windows\runner\Release\BananaFarm.exe"

# Check if the executable exists (adjust path if running from source/debug)
if (-not (Test-Path $exePath)) {
    # Try x64 Release
    $exePath = "$PSScriptRoot\..\build\windows\x64\runner\Release\BananaFarm.exe"
    if (-not (Test-Path $exePath)) {
        # Try standard Debug
        $exePath = "$PSScriptRoot\..\build\windows\runner\Debug\BananaFarm.exe"
        if (-not (Test-Path $exePath)) {
            # Try x64 Debug
            $exePath = "$PSScriptRoot\..\build\windows\x64\runner\Debug\BananaFarm.exe"
            if (-not (Test-Path $exePath)) {
                Write-Error "Executable not found. Please build the app first."
                exit 1
            }
        }
    }
}

$exePath = (Resolve-Path $exePath).Path
Write-Host "Registering $scheme for $exePath"

# Create the registry keys
New-Item -Path "HKCU:\Software\Classes\$scheme" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\Classes\$scheme" -Name "(default)" -Value $description
Set-ItemProperty -Path "HKCU:\Software\Classes\$scheme" -Name "URL Protocol" -Value ""

New-Item -Path "HKCU:\Software\Classes\$scheme\DefaultIcon" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\Classes\$scheme\DefaultIcon" -Name "(default)" -Value "$exePath,0"

New-Item -Path "HKCU:\Software\Classes\$scheme\shell" -Force | Out-Null
New-Item -Path "HKCU:\Software\Classes\$scheme\shell\open" -Force | Out-Null
New-Item -Path "HKCU:\Software\Classes\$scheme\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\Classes\$scheme\shell\open\command" -Name "(default)" -Value "`"$exePath`" `"%1`""

Write-Host "Registration complete."
