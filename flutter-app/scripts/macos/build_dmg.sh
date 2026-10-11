#!/usr/bin/env bash
# Builds the macOS release app and packages it as a drag-to-Applications DMG.
# Run from anywhere: ./scripts/macos/build_dmg.sh [--clean]
#
# Signing is whatever Xcode applies during `flutter build macos` (Apple
# Development). The DMG is not notarized, so on other Macs the app must be
# opened with right-click → Open the first time.

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean]

  --clean     Run 'flutter clean' before building
  -h, --help  Show this help

Output: build/macos/dmg/BananaFarm-<version>-<arch>.dmg
EOF
}

CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

cyan()   { printf '\033[36m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
fail()   { printf '\033[31m  [ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

# flutter-app/ is two levels above scripts/macos/
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$APP_DIR"

cyan "====================================="
cyan "  Banana Farm DMG Builder"
cyan "====================================="
echo

yellow "[1/6] Checking prerequisites..."
[[ "$(uname)" == "Darwin" ]] || fail "This script must run on macOS"
command -v flutter >/dev/null || fail "flutter not found on PATH"
command -v create-dmg >/dev/null || fail "create-dmg not found. Install it with: brew install create-dmg"

VERSION="$(grep -E '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)"
APP_NAME="$(grep -E '^PRODUCT_NAME' macos/Runner/Configs/AppInfo.xcconfig | awk -F'= *' '{print $2}' | tr -d '[:space:]')"
ARCH="$(uname -m)"
[[ -n "$VERSION" ]] || fail "Could not read version from pubspec.yaml"
[[ -n "$APP_NAME" ]] || fail "Could not read PRODUCT_NAME from AppInfo.xcconfig"
green "  [OK] $APP_NAME $VERSION ($ARCH)"
echo

yellow "[2/6] Building Flutter app (release)..."
if [[ $CLEAN -eq 1 ]]; then
  flutter clean
fi
flutter pub get
flutter build macos --release
echo

yellow "[3/6] Checking app bundle..."
APP_PATH="build/macos/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP_PATH" ]] || fail "Build output not found at $APP_PATH"

SEVEN_ZIP="$APP_PATH/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/bin/mac/7zz"
[[ -f "$SEVEN_ZIP" ]] || fail "Bundled 7zz missing from the app ($SEVEN_ZIP)"

codesign --verify --deep --strict "$APP_PATH" || fail "Code signature verification failed"
AUTHORITY="$(codesign -dv --verbose=2 "$APP_PATH" 2>&1 | grep -m1 '^Authority=' | cut -d= -f2- || true)"
green "  [OK] Signed by: ${AUTHORITY:-ad-hoc}"
echo

yellow "[4/6] Staging app..."
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_PATH" "$STAGING/"
green "  [OK] Staged in $STAGING"
echo

yellow "[5/6] Creating DMG..."
OUT_DIR="build/macos/dmg"
DMG_PATH="$OUT_DIR/BananaFarm-$VERSION-$ARCH.dmg"
mkdir -p "$OUT_DIR"
rm -f "$DMG_PATH"

DMG_ARGS=(
  --volname "Banana Farm"
  --window-size 600 400
  --icon-size 128
  --icon "$APP_NAME.app" 150 190
  --app-drop-link 450 190
  --hide-extension "$APP_NAME.app"
  --no-internet-enable
)
VOLICON="$APP_PATH/Contents/Resources/AppIcon.icns"
[[ -f "$VOLICON" ]] && DMG_ARGS+=(--volicon "$VOLICON")
# Window styling uses AppleScript (Finder), which hangs without a GUI session
[[ -n "${CI:-}" ]] && DMG_ARGS+=(--skip-jenkins)

create-dmg "${DMG_ARGS[@]}" "$DMG_PATH" "$STAGING"
echo

yellow "[6/6] Verifying DMG..."
hdiutil verify "$DMG_PATH" >/dev/null || fail "hdiutil verify failed for $DMG_PATH"
green "  [OK] $(du -h "$DMG_PATH" | cut -f1)  $APP_DIR/$DMG_PATH"
echo

cyan "Done."
echo "Note: the app is signed for development only and not notarized. On other"
echo "Macs, right-click the app and choose Open the first time, or run:"
echo "  xattr -dr com.apple.quarantine /Applications/$APP_NAME.app"
