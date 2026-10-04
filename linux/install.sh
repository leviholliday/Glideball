#!/usr/bin/env bash
# Installs Glideball for the current user.
#   ./install.sh            install (asks for sudo for packages and the udev rule)
#   ./install.sh --no-deps  skip installing distro packages
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
APP="${XDG_DATA_HOME:-$HOME/.local/share}/glideball"
BIN="$APP/bin/glideball"
INSTALL_DEPS=1
for arg in "$@"; do
  case "$arg" in
    --no-deps) INSTALL_DEPS=0 ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

if [ "$(id -u)" = 0 ]; then
  echo "Run this as your normal user (it uses sudo only where needed)." >&2
  exit 1
fi

python3 - <<'EOF' || { echo "Glideball needs Python 3.10 or newer." >&2; exit 1; }
import sys
sys.exit(0 if sys.version_info >= (3, 10) else 1)
EOF

# 1. Dependencies -------------------------------------------------------------
if [ "$INSTALL_DEPS" = 1 ]; then
  say "Installing dependencies (python-evdev, PyGObject, GTK 4, libadwaita)…"
  if command -v apt-get >/dev/null; then
    sudo apt-get install -y python3-evdev python3-gi gir1.2-gtk-4.0 gir1.2-adw-1
  elif command -v dnf >/dev/null; then
    sudo dnf install -y python3-evdev python3-gobject gtk4 libadwaita
  elif command -v pacman >/dev/null; then
    sudo pacman -S --needed --noconfirm python-evdev python-gobject gtk4 libadwaita
  elif command -v zypper >/dev/null; then
    sudo zypper install -y python3-evdev python3-gobject typelib-1_0-Gtk-4_0 typelib-1_0-Adw-1
  else
    echo "Unknown package manager: install python-evdev, PyGObject, GTK 4 and libadwaita yourself."
  fi
fi

# 2. The app ----------------------------------------------------------------------
say "Copying Glideball to $APP…"
mkdir -p "$APP"
rm -rf "$APP/glideball" "$APP/bin" "$APP/packaging"    # never touches $APP/backups
cp -R "$SRC/glideball" "$SRC/bin" "$SRC/packaging" "$APP/"
find "$APP/glideball" -name '__pycache__' -prune -exec rm -rf {} +
chmod +x "$BIN"
mkdir -p "$HOME/.local/bin"
ln -sf "$BIN" "$HOME/.local/bin/glideball"

# 3. Menu entry and icon ---------------------------------------------------------
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
mkdir -p "$DATA/applications" "$DATA/icons/hicolor/256x256/apps"
sed "s|@BIN@|$BIN|g" "$SRC/packaging/glideball.desktop" > "$DATA/applications/glideball.desktop"
cp "$SRC/packaging/glideball.png" "$DATA/icons/hicolor/256x256/apps/glideball.png"
command -v update-desktop-database >/dev/null && update-desktop-database "$DATA/applications" || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$DATA/icons/hicolor" || true

# 4. Permissions (udev rule) -------------------------------------------------------
say "Permissions"
cat <<'EOF'
Glideball needs two things only root can grant, so sudo will ask for your password:
  * /dev/uinput, to create its virtual pointer (how it sends the cursor,
    scrolling, clicks and shortcuts to your desktop), and
  * your Kensington trackball's input device (vendor 047d), to take it over.
The rule (/etc/udev/rules.d/70-glideball.rules) grants these to whoever is
logged in at the screen, and to nothing else: your other mice, trackballs and
keyboards are not made readable. It also loads the uinput module at boot.
EOF
sudo install -m 0644 "$SRC/packaging/70-glideball.rules" /etc/udev/rules.d/70-glideball.rules
echo uinput | sudo tee /etc/modules-load.d/glideball.conf >/dev/null
sudo modprobe uinput || true
sudo udevadm control --reload-rules
sudo udevadm trigger --action=change --subsystem-match=misc --sysname-match=uinput || true
sudo udevadm trigger --action=change --subsystem-match=input || true

# 5. Background service ---------------------------------------------------------------
say "Starting the background service…"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$UNIT_DIR"
sed "s|@BIN@|$BIN|g" "$SRC/packaging/glideball.service" > "$UNIT_DIR/glideball.service"
systemctl --user daemon-reload
systemctl --user enable glideball.service
systemctl --user restart glideball.service || true

# 6. Ctrl+Alt+Super+G pause shortcut (GNOME) ------------------------------------------
if command -v gsettings >/dev/null && gsettings list-schemas 2>/dev/null | grep -q '^org.gnome.settings-daemon.plugins.media-keys$'; then
  say "Adding the Ctrl+Alt+Super+G pause shortcut (GNOME)…"
  KEY_PATH=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/glideball/
  SCHEMA=org.gnome.settings-daemon.plugins.media-keys.custom-keybinding
  CURRENT="$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings)"
  NEW="$(python3 - "$CURRENT" "$KEY_PATH" <<'EOF'
import ast, sys
cur = sys.argv[1].replace("@as ", "")
items = ast.literal_eval(cur) if cur.strip() else []
if sys.argv[2] not in items:
    items.append(sys.argv[2])
print("[" + ", ".join(repr(i) for i in items) + "]")
EOF
)"
  gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$NEW"
  gsettings set "$SCHEMA:$KEY_PATH" name 'Pause / resume Glideball'
  gsettings set "$SCHEMA:$KEY_PATH" command "$BIN ctl toggle-pause"
  gsettings set "$SCHEMA:$KEY_PATH" binding '<Control><Alt><Super>g'
else
  echo
  echo "Tip: bind Ctrl+Alt+Super+G to \"$BIN ctl toggle-pause\" in your desktop's keyboard"
  echo "settings so you can always pause Glideball. (Done automatically on GNOME.)"
fi

say "Done."
cat <<EOF
Open Glideball from your app menu, or run: glideball
If the trackball isn't detected yet, unplug it and plug it back in (or log out and in)
so the new permissions apply. Status: glideball ctl status
EOF
