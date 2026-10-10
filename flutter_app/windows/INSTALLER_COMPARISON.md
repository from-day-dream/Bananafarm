# Windows Installer Methods Comparison

Banana Farm supports two methods for creating Windows installers. Choose the one that best fits your distribution needs.

## Quick Comparison

| Aspect | MSIX | Inno Setup (.exe) |
|--------|------|-------------------|
| **Best For** | Microsoft Store, Enterprise | Direct download, Web distribution |
| **Setup File** | `bananafarm.msix` | `bananafarm_setup.exe` |
| **File Size** | ~50-80 MB | ~40-60 MB (compressed) |
| **Installation** | Modern Windows installer | Traditional wizard |
| **Uninstall** | Clean, automatic | Standard Add/Remove Programs |
| **Auto-updates** | Built-in (if via Store) | Custom implementation needed |
| **Signing** | Required for production | Optional |
| **Deep Links** | Native protocol support | Registry-based |
| **Build Time** | 5-10 minutes | 3-5 minutes |
| **Documentation** | [BUILD_INSTALLER_MSIX.md](BUILD_INSTALLER_MSIX.md) | [BUILD_INSTALLER.md](BUILD_INSTALLER.md) |

---

## Method 1: MSIX (Modern)

### When to Use
✅ Distributing through Microsoft Store  
✅ Enterprise deployment (SCCM, Intune)  
✅ Need sandboxed installation  
✅ Want clean uninstall guarantee  

### Quick Build Commands
```powershell
cd flutter_app
flutter clean
flutter pub get
flutter build windows --release
flutter pub run msix:create
```

**Output**: `build/windows/x64/runner/Release/bananafarm.msix`

📖 **Full Guide**: [BUILD_INSTALLER_MSIX.md](BUILD_INSTALLER_MSIX.md)

---

## Method 2: Inno Setup (Traditional)

### When to Use
✅ Direct web download distribution  
✅ Need custom installer UI/branding  
✅ Maximum compatibility  
✅ Smaller file size  

### Quick Build Commands
```powershell
cd flutter_app
flutter clean
flutter pub get
flutter build windows --release
iscc windows/installer.iss
```

**Output**: `build/windows/installer/bananafarm_setup.exe`

📖 **Full Guide**: [BUILD_INSTALLER.md](BUILD_INSTALLER.md)

---

## Recommendation

- **For most users**: Use **Inno Setup** for easier distribution
- **For Store/Enterprise**: Use **MSIX**

Both methods support deep linking (`app.bananafarm.desktop://`) and include all required assets.
