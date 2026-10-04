#!/usr/bin/env bash
# Builds dist/glideball_<version>_all.deb (Debian/Ubuntu). Needs dpkg-deb.
# The package installs the app to /usr/lib/glideball, the udev rule, the menu
# entry and a *user* service; after installing, each user runs:
#   systemctl --user enable --now glideball
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(python3 -c 'import glideball; print(glideball.__version__)')"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
BIN=/usr/lib/glideball/bin/glideball

install -d "$ROOT/DEBIAN" "$ROOT/usr/lib/glideball" "$ROOT/usr/bin" "$ROOT/lib/udev/rules.d" \
  "$ROOT/usr/lib/modules-load.d" "$ROOT/usr/lib/systemd/user" "$ROOT/usr/share/applications" \
  "$ROOT/usr/share/icons/hicolor/256x256/apps"
cp -R glideball bin "$ROOT/usr/lib/glideball/"
find "$ROOT/usr/lib/glideball" -name '__pycache__' -prune -exec rm -rf {} +
ln -s "$BIN" "$ROOT/usr/bin/glideball"
install -m 0644 packaging/70-glideball.rules "$ROOT/lib/udev/rules.d/70-glideball.rules"
echo uinput > "$ROOT/usr/lib/modules-load.d/glideball.conf"
sed "s|@BIN@|$BIN|g" packaging/glideball.service > "$ROOT/usr/lib/systemd/user/glideball.service"
sed "s|@BIN@|$BIN|g" packaging/glideball.desktop > "$ROOT/usr/share/applications/glideball.desktop"
install -m 0644 packaging/glideball.png "$ROOT/usr/share/icons/hicolor/256x256/apps/glideball.png"

cat > "$ROOT/DEBIAN/control" <<EOF
Package: glideball
Version: $VERSION
Section: utils
Priority: optional
Architecture: all
Depends: python3 (>= 3.10), python3-evdev, python3-gi, gir1.2-gtk-4.0, gir1.2-adw-1
Maintainer: Levi Holliday <leviholliday7@gmail.com>
Description: Kensington Expert Mouse customizer
 Pointer speed beyond the desktop's limit, Flywheel/Follow smooth scrolling,
 programmable buttons and combos for the Kensington Expert Mouse trackball.
EOF
cat > "$ROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
modprobe uinput 2>/dev/null || true
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --action=change --subsystem-match=misc --sysname-match=uinput 2>/dev/null || true
udevadm trigger --action=change --subsystem-match=input 2>/dev/null || true
echo "Glideball: run 'systemctl --user enable --now glideball' as your user."
EOF
chmod 0755 "$ROOT/DEBIAN/postinst"
mkdir -p dist
dpkg-deb --root-owner-group --build "$ROOT" "dist/glideball_${VERSION}_all.deb"
