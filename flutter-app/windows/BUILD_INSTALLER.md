# Build Windows Installer (Inno Setup Method)

This guide explains how to build the `setup.exe` installer for Banana Farm using **Inno Setup**, which includes proper registry entries for Deep Linking (`app.bananafarm.desktop://`).

> **Alternative Method**: For MSIX packaging (Microsoft Store or sideloading), see [BUILD_INSTALLER_MSIX.md](BUILD_INSTALLER_MSIX.md).

## Prerequisites

1.  **Flutter Installed**: Ensure `flutter doctor` is healthy.
2.  **Inno Setup 6 Installed**: [Download Inno Setup](https://jrsoftware.org/isdl.php).

## Build Steps

### 1. Build the Flutter App
First, compile the Flutter application in release mode. This generates the executable and assets.

```powershell
cd flutter_app
flutter build windows --release
```

### 2. Compile the Installer
Use Inno Setup to compile the `windows/installer.iss` script.

**Option A: Using GUI**
1.  Open `windows/installer.iss` in Inno Setup Compiler.
2.  Click **Build > Compile** (Ctrl+F9).

**Option B: Command Line**
If `ISCC.exe` is in your PATH:

```powershell
iscc windows/installer.iss
```

### 3. Output
The installer will be generated at:
`flutter_app/build/windows/installer/bananafarm_setup.exe`

## Deep Link Verification
After installing the app using the generated setup:
1.  Open a web browser.
2.  Type `app.bananafarm.desktop://test`.
3.  The browser should prompt to open "Banana Farm".
4.  The app should launch.
