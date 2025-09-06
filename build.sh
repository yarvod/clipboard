#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

APP_NAME="ClipboardCommander"
# Try to read version from VERSION file (optional)
APP_VERSION="$(cat VERSION 2>/dev/null || echo "0.0.0")"
ASSETS_DIR="assets"
ICON_ICNS="$ASSETS_DIR/app.icns"
if [ ! -f "$ICON_ICNS" ]; then
  echo "[build] Missing $ICON_ICNS. Generate icons first: python3 generate_icons.py" >&2
  exit 1
fi

echo "[build] Cleaning previous build artifacts"
for target in build dist ClipboardCommander.spec *.spec; do
  if [ -e "$target" ]; then
    echo "  -> removing $target"
    chmod -R u+w "$target" 2>/dev/null || true
    rm -rf "$target"
  fi
done

echo "[build] Running PyInstaller (optimized)"
pyinstaller main.py \
  --name "$APP_NAME" \
  --windowed \
  --onedir \
  --noconsole \
  --icon "$ICON_ICNS" \
  --osx-bundle-identifier "com.yarvod.clipboardcommander" \
  --strip \
  --clean \
  --optimize 2 \
  --exclude-module PySide6.QtWebEngineCore \
  --exclude-module PySide6.QtWebEngineWidgets \
  --exclude-module PySide6.QtWebEngineQuick \
  --exclude-module PySide6.QtWebEngine \
  --exclude-module PySide6.QtQml \
  --exclude-module PySide6.QtQuick \
  --exclude-module PySide6.QtMultimedia \
  --exclude-module PySide6.QtMultimediaWidgets \
  --exclude-module PySide6.QtCharts \
  --exclude-module PySide6.QtBluetooth \
  --exclude-module PySide6.QtSerialPort \
  --exclude-module PySide6.QtSvg \
  --exclude-module PySide6.QtSvgWidgets \
  --exclude-module PySide6.QtTest \
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
  # Set version fields
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$PLIST" || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" "$PLIST" || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$PLIST" || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $APP_VERSION" "$PLIST" || true
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

  # Prune unused Qt plugins to slim the bundle (hardcore mode)
  echo "[build] Pruning Qt plugins"
  prune_plugins_dir() {
    local base="$1"
    [ -d "$base" ] || return 0
    echo "  - checking $base"
    # Keep only platforms (Cocoa) and imageformats (png,jpeg,ico,icns)
    for d in "$base"/*; do
      [ -d "$d" ] || continue
      case "$(basename "$d")" in
        platforms)
          # remove everything except libqcocoa.dylib
          for f in "$d"/*; do
            [ -e "$f" ] || continue
            case "$(basename "$f")" in
              libqcocoa.dylib) : ;; # keep
              *) rm -f "$f" ;;
            esac
          done
          ;;
        imageformats)
          for f in "$d"/*; do
            [ -e "$f" ] || continue
            case "$(basename "$f")" in
              qpng.*|qjpeg.*|qico.*|qicns.*) : ;; # keep
              *) rm -f "$f" ;;
            esac
          done
          ;;
        *)
          rm -rf "$d" # drop other plugin categories (styles, printsupport, tls, etc.)
          ;;
      esac
    done
  }

  # Common locations for PyInstaller’s Qt plugins inside the .app
  prune_plugins_dir "$APP_BUNDLE/Contents/Plugins"
  prune_plugins_dir "$APP_BUNDLE/Contents/MacOS/PySide6/Qt/plugins"

  # Remove Qt translations if present
  echo "[build] Removing Qt translations (if any)"
  rm -rf "$APP_BUNDLE/Contents/Resources/translations" || true
  rm -rf "$APP_BUNDLE/Contents/MacOS/PySide6/Qt/translations" || true

  # Thin universal binaries to current arch to reduce size
  ARCH=$(uname -m)
  echo "[build] Thinning binaries to arch: $ARCH"
  thin_macho() {
    local f="$1"
    # Only process regular files
    [ -f "$f" ] || return 0
    # Check if it's a universal binary containing multiple arches
    if file -b "$f" 2>/dev/null | grep -q "universal"; then
      if lipo -info "$f" 2>/dev/null | grep -q "$ARCH"; then
        tmp="$f.thin"
        lipo -thin "$ARCH" "$f" -output "$tmp" 2>/dev/null && mv -f "$tmp" "$f"
      fi
    fi
  }
  export -f thin_macho
  # Common binary locations inside the bundle
  find "$APP_BUNDLE/Contents" -type f \( -name "*.dylib" -o -name "*.so" -o -perm +111 \) -print0 | xargs -0 -I {} bash -c 'thin_macho "$0"' {}

  # Remove Python __pycache__ if any slipped in
  find "$APP_BUNDLE/Contents" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true

  # Re-sign ad-hoc after binary changes
  echo "[build] Ad-hoc codesign"
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
else
  echo "[build] Warning: App bundle not found in dist/; check PyInstaller output" >&2
fi

echo "[build] Done"
