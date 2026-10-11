# Build Windows MSIX Installer

This guide explains how to build the `.msix` installer for Banana Farm, which includes proper registry entries for Deep Linking (`app.bananafarm.desktop://`) and can be distributed through Microsoft Store or sideloaded.

## Prerequisites

1. **Flutter Installed**: Ensure `flutter doctor` is healthy.
2. **MSIX Package Installed**: The `msix` package is already configured in `pubspec.yaml` (version 3.16.7).
3. **Windows SDK**: Required for signing (optional for development builds).

## Build Steps

### 1. Clean and Prepare the Flutter App
First, clean any previous builds and get dependencies:

```powershell
cd flutter_app
flutter clean
flutter pub get
```

### 2. Build the Flutter App
Compile the Flutter application in release mode:

```powershell
flutter build windows --release
```

### 3. Create the MSIX Package
Run the MSIX package command to generate the installer:

```powershell
flutter pub run msix:create
```

This command will:
- Package the release build into an MSIX installer
- Configure deep link protocol activation (`app.bananafarm.desktop://`)
- Set up the app identity and publisher information
- Include the app icon and capabilities

### 4. Output
The MSIX installer will be generated at:
```
flutter_app/build/windows/x64/runner/Release/bananafarm.msix
```

## MSIX Configuration

The MSIX settings are configured in `pubspec.yaml`:

```yaml
msix_config:
  display_name: Banana Farm
  publisher_display_name: Day Dream
  identity_name: com.daydream.bananafarm
  msix_version: 1.0.1.0
  logo_path: assets/icon/icon.png
  capabilities: 'internetClient,privateNetworkClientServer'
  protocol_activation: app.bananafarm.desktop
```

## Installation Methods

### Method A: Sideloading (Development/Testing)
For testing or distributing outside the Microsoft Store:

1. **Enable Developer Mode** (First-time only):
   - Go to `Settings > Update & Security > For developers`
   - Enable "Developer mode"

2. **Install the MSIX**:
   - Double-click `bananafarm.msix`
   - Click "Install" in the App Installer dialog
   - The app will be installed and appear in the Start Menu

3. **Alternative: PowerShell Installation**:
   ```powershell
   Add-AppxPackage -Path ".\build\windows\x64\runner\Release\bananafarm.msix"
   ```

### Method B: Microsoft Store (Production)
For public distribution:
1. Create a Microsoft Partner Center account
2. Upload the `.msix` package
3. Complete the store listing
4. Submit for certification

## Deep Link Verification

After installing the app using the generated MSIX:
1. Open a web browser
2. Type `app.bananafarm.desktop://test`
3. The browser should prompt to open "Banana Farm"
4. The app should launch

## Uninstalling

To uninstall:
- **Via Settings**: `Settings > Apps > Banana Farm > Uninstall`
- **Via PowerShell**:
  ```powershell
  Get-AppxPackage *bananafarm* | Remove-AppxPackage
  ```

## Comparison: MSIX vs Inno Setup

| Feature | MSIX | Inno Setup (.exe) |
|---------|------|-------------------|
| Distribution | Store or sideload | Direct download |
| Installation | Modern, clean UI | Traditional wizard |
| Uninstallation | Clean removal | Registry cleanup needed |
| Auto-updates | Built-in (Store) | Custom implementation |
| Signing Required | Yes (for non-dev) | Optional |
| File Size | Larger | Smaller (compressed) |
| Deep Links | Native support | Registry manual |

## Troubleshooting

### Issue: "Install failed" error
**Solution**: Enable Developer Mode or use a certificate for signing.

### Issue: Deep links not working
**Solution**: Verify `protocol_activation` in `msix_config` matches your deep link scheme.

### Issue: App won't install
**Solution**: Uninstall previous versions first using the uninstall commands above.

## Advanced: Code Signing (Optional)

For production or enterprise distribution, sign your MSIX:

1. **Create a certificate** (development):
   ```powershell
   New-SelfSignedCertificate -Type Custom -Subject "CN=Day Dream" -KeyUsage DigitalSignature -FriendlyName "BananaFarm Certificate" -CertStoreLocation "Cert:\CurrentUser\My"
   ```

2. **Configure signing in pubspec.yaml**:
   ```yaml
   msix_config:
     certificate_path: path/to/certificate.pfx
     certificate_password: your_password
   ```

For production, obtain a trusted certificate from a Certificate Authority.
