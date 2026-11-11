#!/bin/bash
# Rebuilds SSDLinkBar, wraps it into an .app bundle, ad-hoc signs, installs to ~/Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SSDLinkBar"
BUILD_APP=".build/${APP_NAME}.app"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/${APP_NAME}.app"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/${APP_NAME}"

rm -rf "$BUILD_APP"
mkdir -p "$BUILD_APP/Contents/MacOS" "$BUILD_APP/Contents/Resources"
cp "$BIN" "$BUILD_APP/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "$BUILD_APP/Contents/Info.plist"
codesign --force --deep -s - "$BUILD_APP"
codesign --verify --verbose "$BUILD_APP"

pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5
mkdir -p "$DEST_DIR"
rm -rf "$DEST"
cp -R "$BUILD_APP" "$DEST"

# CLI: ~/.local/bin/ssdlink -> app binary (same engine as the GUI)
mkdir -p "$HOME/.local/bin"
ln -sfn "$DEST/Contents/MacOS/${APP_NAME}" "$HOME/.local/bin/ssdlink"
echo "CLI: $HOME/.local/bin/ssdlink"

if [[ "${1:-}" != "--no-launch" ]]; then
  open "$DEST"
fi
echo "Installed: $DEST"
