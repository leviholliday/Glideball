#!/bin/zsh
# Makes build/sandbox/Glideball Sandbox.app from a built Glide binary and prints
# the path of its executable. It's a copy of the app for --render-ui and
# --self-test only (see Sources/Glide/Sandbox/Sandbox.swift):
#   - its own bundle ID (com.leviholliday.glide.sandbox), which those modes
#     require: they refuse to run as the real com.leviholliday.glide;
#   - an executable named GlideSandbox, so it's never mistaken for the real
#     Glide process (build.sh's `pkill -x Glide`, Activity Monitor);
#   - no document or file types, so Launch Services never offers it for
#     .glide-settings files, and no URL scheme, so a glideball:// link never
#     reaches it (or launches it) instead of the real app;
#   - LSUIElement: no Dock icon, even for the moment before it says so itself.
# The translations, icon and sounds are copied so screens look and read as in
# the real app (and --lang works).
#
#   scripts/sandbox-app.sh [binary]     (default .build/release/Glide; doesn't build)
set -euo pipefail
ROOT=${0:A:h:h}
BIN=${1:-$ROOT/.build/release/Glide}
APP="$ROOT/build/sandbox/Glideball Sandbox.app"
PB=/usr/libexec/PlistBuddy

[[ -x $BIN ]] || { print -u2 "error: $BIN not found; run swift build -c release first"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GlideSandbox"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
$PB -c "Set :CFBundleIdentifier com.leviholliday.glide.sandbox" \
    -c "Set :CFBundleExecutable GlideSandbox" \
    -c "Delete :CFBundleDocumentTypes" \
    -c "Delete :UTExportedTypeDeclarations" \
    -c "Delete :CFBundleURLTypes" \
    -c "Add :LSUIElement bool true" \
    "$APP/Contents/Info.plist" >/dev/null
cp "$ROOT/Resources/AppIcon.icns" "$ROOT/Resources/AppIconClassic.icns" "$ROOT/Resources/IntroMusic.m4a" "$APP/Contents/Resources/"
cp -R "$ROOT"/Resources/*.lproj(N) "$APP/Contents/Resources/"
# Ad hoc, never the release identity: this copy must never satisfy the updater's requirement.
codesign --force --sign - --identifier com.leviholliday.glide.sandbox "$APP" 2>/dev/null
print -r -- "$APP/Contents/MacOS/GlideSandbox"
