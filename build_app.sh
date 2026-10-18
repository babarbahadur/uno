#!/bin/bash
# Builds Uno.app. Run:  ./build_app.sh            (builds into ./build)
#                            ./build_app.sh --install  (also copies it to /Applications)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Uno"
APP="build/$APP_NAME.app"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift isn't installed. Run:  xcode-select --install   then try again."
  exit 1
fi

echo "▸ Compiling (first build takes a minute)…"
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "▸ Creating $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing locally"
codesign --force --deep --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  echo "✓ Installed to /Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
else
  echo "✓ Built $APP"
  open "$APP"
fi
