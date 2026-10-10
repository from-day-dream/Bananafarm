#!/bin/bash

# Setup .desktop file for app.bananafarm.desktop scheme
SCHEME="app.bananafarm.desktop"
APP_NAME="BananaFarm"
EXEC_PATH="$(pwd)/../build/linux/x64/debug/bundle/flutter_app"
ICON_PATH="$(pwd)/../assets/icon/icon.png" # Adjust if you have an icon
DESKTOP_FILE="$HOME/.local/share/applications/bananafarm.desktop"

# Check if build exists
if [ ! -f "$EXEC_PATH" ]; then
    echo "Warning: Debug executable not found at $EXEC_PATH"
    echo "Please build the app first (flutter build linux --debug)"
    # We continue anyway to allow setup before build
fi

echo "Creating $DESKTOP_FILE..."

mkdir -p "$HOME/.local/share/applications"

cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Name=$APP_NAME
Exec=$EXEC_PATH %u
Icon=$ICON_PATH
Type=Application
Terminal=false
MimeType=x-scheme-handler/$SCHEME;
EOF

echo "Registering MIME type..."
update-desktop-database "$HOME/.local/share/applications"

echo "Setup complete. You can now handle $SCHEME:// links."
