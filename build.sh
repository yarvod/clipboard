#!/bin/sh
# Сборка dist/ClipboardCommander.app из исходников на Swift (нужны только Command Line Tools).
#
#   ./build.sh                         — под текущую архитектуру, ad-hoc подпись
#   ARCHS="arm64 x86_64" ./build.sh    — универсальная сборка (Apple Silicon + Intel)
#   CODESIGN_IDENTITY="Apple Development: Имя (TEAMID)" ./build.sh
#                                      — подпись сертификатом: доступ «Универсальный доступ»
#                                        не слетает после каждой пересборки
#   ./build.sh --install               — ещё и установить в /Applications и запустить
set -eu

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

APP_NAME="ClipboardCommander"
BUNDLE_ID="com.yarvod.clipboardcommander"
VERSION="$(cat VERSION 2>/dev/null || echo 0.0.0)"
MIN_MACOS="14.0"
ARCHS="${ARCHS:-$(uname -m)}"
IDENTITY="${CODESIGN_IDENTITY:--}"
INSTALL=false

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "[build] неизвестный аргумент: $arg" >&2; exit 2 ;;
  esac
done

BUILD_DIR="build"
APP="dist/$APP_NAME.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SOURCES="$(find Sources -name '*.swift' | sort)"
mkdir -p "$BUILD_DIR" dist

# После неполного обновления Command Line Tools рядом с новым bridging.modulemap остаётся
# старый usr/include/swift/module.modulemap, и swiftc падает с
# «redefinition of module 'SwiftBridging'». Прячем старый файл через VFS-overlay.
# Настоящее лечение: sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install
EXTRA_FLAGS=""
SWIFT_INCLUDE="$(cd "$(dirname "$(xcrun --find swiftc)")/../include/swift" 2>/dev/null && pwd || true)"
if [ -n "$SWIFT_INCLUDE" ] && [ -f "$SWIFT_INCLUDE/module.modulemap" ] && [ -f "$SWIFT_INCLUDE/bridging.modulemap" ]; then
  echo "[build] обходим устаревший $SWIFT_INCLUDE/module.modulemap"
  : > "$BUILD_DIR/empty.modulemap"
  cat > "$BUILD_DIR/vfs-overlay.yaml" <<EOF
{ "version": 0, "case-sensitive": "false", "roots": [
  { "type": "file", "name": "$SWIFT_INCLUDE/module.modulemap",
    "external-contents": "$ROOT_DIR/$BUILD_DIR/empty.modulemap" } ] }
EOF
  EXTRA_FLAGS="-vfsoverlay $BUILD_DIR/vfs-overlay.yaml"
fi

BINARIES=""
for arch in $ARCHS; do
  echo "[build] компиляция ($arch)"
  mkdir -p "$BUILD_DIR/$arch"
  # shellcheck disable=SC2086
  xcrun swiftc -O -wmo -swift-version 5 $EXTRA_FLAGS \
    -target "$arch-apple-macosx$MIN_MACOS" -sdk "$SDK" \
    -module-name "$APP_NAME" \
    -framework AppKit -framework Carbon -framework ServiceManagement \
    $SOURCES -o "$BUILD_DIR/$arch/$APP_NAME"
  BINARIES="$BINARIES $BUILD_DIR/$arch/$APP_NAME"
done

echo "[build] сборка $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# shellcheck disable=SC2086
lipo -create $BINARIES -output "$APP/Contents/MacOS/$APP_NAME"
cp assets/app.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>CFBundleDisplayName</key><string>Clipboard Commander</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
      <key>CFBundleURLSchemes</key><array><string>clipboardcommander</string></array>
    </dict>
  </array>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Менеджер буфера обмена для macOS</string>
</dict>
</plist>
PLIST

echo "[build] подпись ($IDENTITY)"
codesign --force --options runtime --sign "$IDENTITY" "$APP"

if [ "$INSTALL" = true ]; then
  DEST="/Applications/$APP_NAME.app"
  echo "[build] установка в $DEST"
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  open "$DEST"
fi

echo "[build] готово: $APP"
