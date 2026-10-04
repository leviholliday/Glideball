#!/bin/zsh
# Builds Glide.app, installs it to /Applications, and launches it. No Xcode needed.
#   ./build.sh           build + install + launch
#   ./build.sh --icon    also re-render the app icon first
set -e
cd "$(dirname "$0")"

if [[ "$1" == "--icon" || ! -f Resources/AppIcon.icns ]]; then
  swift scripts/make-icon.swift .
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

swift build -c release
BIN=".build/release/Glide"

APP="/Applications/Glide.app"
osascript -e 'tell application id "com.leviholliday.glide" to quit' >/dev/null 2>&1 || true
sleep 0.5
pkill -x Glide 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Glide"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/IntroMusic.m4a Resources/LaunchChime.m4a "$APP/Contents/Resources/"   # scripts/make-intro-music.py

# Sign with the local "Glide Local Signing" certificate so macOS remembers the
# Accessibility / Input Monitoring permissions across rebuilds. Falls back to
# ad-hoc signing (permissions must then be re-granted after each build).
IDENTITY=$(security find-identity -p codesigning | awk '/Glide Local Signing/ {print $2; exit}')
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --identifier com.leviholliday.glide "$APP"
else
  echo "warning: 'Glide Local Signing' certificate not found; using ad-hoc signature"
  codesign --force --sign - --identifier com.leviholliday.glide "$APP"
fi

touch "$APP"   # refresh the Dock/Finder icon cache
open "$APP"
echo "Glide installed to $APP and launched."
