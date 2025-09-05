#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

APP_NAME="ClipboardCommander"
ASSETS_DIR="assets"
ICON_ICNS="$ASSETS_DIR/app.icns"
if [ ! -f "$ICON_ICNS" ]; then
  echo "[build] Missing $ICON_ICNS. Generate icons first: python3 generate_icons.py" >&2
  exit 1
fi

echo "[build] Cleaning previous build artifacts"
rm -rf build dist *.spec

echo "[build] Running PyInstaller"
pyinstaller main.py \
  --name "$APP_NAME" \
  --windowed \
  --onedir \
  --noconsole \
  --icon "$ICON_ICNS" \
  --osx-bundle-identifier "com.yarvod.clipboardcommander" \
  -y

# Post-process Info.plist to hide Dock icon at launch
APP_BUNDLE="dist/${APP_NAME}.app"
if [ ! -d "$APP_BUNDLE" ]; then
  # some PyInstaller versions nest app inside a folder named like the app
  if [ -d "dist/${APP_NAME}/${APP_NAME}.app" ]; then
    APP_BUNDLE="dist/${APP_NAME}/${APP_NAME}.app"
  fi
fi

if [ -d "$APP_BUNDLE" ]; then
  PLIST="$APP_BUNDLE/Contents/Info.plist"
  echo "[build] Patching Info.plist at $PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$PLIST" || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$PLIST" || true
  # Hide from Dock (LSUIElement)
  if /usr/libexec/PlistBuddy -c "Print :LSUIElement" "$PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :LSUIElement 1" "$PLIST" || true
  else
    /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$PLIST" || true
  fi
  # Ensure icon is embedded
  if [ -f "$ICON_ICNS" ]; then
    cp -f "$ICON_ICNS" "$APP_BUNDLE/Contents/Resources/app.icns" || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile app.icns" "$PLIST" || true
  fi
  echo "[build] Built app: $APP_BUNDLE"
else
  echo "[build] Warning: App bundle not found in dist/; check PyInstaller output" >&2
fi

echo "[build] Done"
