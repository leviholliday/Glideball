#!/bin/zsh
# Builds Glideball.app, installs it to /Applications, and launches it. No Xcode needed.
#   ./build.sh           build + install + launch
#   ./build.sh --icon    also re-render the app icons first (the Orb icon and the classic one)
set -e
cd "$(dirname "$0")"

if [[ "$1" == "--icon" || ! -f Resources/AppIcon.icns || ! -f Resources/AppIconClassic.icns ]]; then
  swift scripts/make-icon.swift --style orb-b --icns Resources/AppIcon.icns
  swift scripts/make-icon.swift --style classic --icns Resources/AppIconClassic.icns
fi

swift build -c release
BIN=".build/release/Glide"

APP="/Applications/Glideball.app"
osascript -e 'tell application id "com.leviholliday.glide" to quit' >/dev/null 2>&1 || true
sleep 0.5
pkill -x Glide 2>/dev/null || true

rm -rf "$APP" /Applications/Glide.app   # the pre-2.8 name
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Glide"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/AppIconClassic.icns "$APP/Contents/Resources/"   # the Orb icon, and the classic one to offer
cp Resources/IntroMusic.m4a "$APP/Contents/Resources/"   # scripts/make-intro-music.py
cp Resources/Sounds/*.caf "$APP/Contents/Resources/"   # scripts/make-sounds.py
cp -R Resources/*.lproj(N) "$APP/Contents/Resources/"   # translations (scripts/l10n); before signing

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
echo "Glideball installed to $APP and launched."
