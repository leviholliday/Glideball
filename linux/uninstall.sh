#!/usr/bin/env bash
# Removes Glideball. Settings (~/.config/glideball) and backups are kept
# unless you pass --purge.
set -uo pipefail

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
APP="$DATA/glideball"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

# Stopping the service ungrabs the trackball; the desktop gets it back at once.
systemctl --user disable --now glideball.service 2>/dev/null
rm -f "$UNIT_DIR/glideball.service"
systemctl --user daemon-reload 2>/dev/null

rm -rf "$APP/glideball" "$APP/bin" "$APP/packaging"
rm -f "$HOME/.local/bin/glideball" "$DATA/applications/glideball.desktop" \
      "$DATA/icons/hicolor/256x256/apps/glideball.png"

if command -v gsettings >/dev/null && gsettings list-schemas 2>/dev/null | grep -q '^org.gnome.settings-daemon.plugins.media-keys$'; then
  KEY_PATH=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/glideball/
  CURRENT="$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings)"
  NEW="$(python3 - "$CURRENT" "$KEY_PATH" <<'EOF'
import ast, sys
cur = sys.argv[1].replace("@as ", "")
items = [i for i in (ast.literal_eval(cur) if cur.strip() else []) if i != sys.argv[2]]
print("[" + ", ".join(repr(i) for i in items) + "]")
EOF
)"
  gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$NEW"
  gsettings reset-recursively "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KEY_PATH" 2>/dev/null
fi

if [ -f /etc/udev/rules.d/70-glideball.rules ] || [ -f /etc/modules-load.d/glideball.conf ]; then
  echo "Removing the udev rule (needs sudo)…"
  sudo rm -f /etc/udev/rules.d/70-glideball.rules /etc/modules-load.d/glideball.conf
  sudo udevadm control --reload-rules
fi

if [ "$PURGE" = 1 ]; then
  rm -rf "$APP" "${XDG_CONFIG_HOME:-$HOME/.config}/glideball"
  echo "Removed Glideball, its settings and backups."
else
  rmdir "$APP" 2>/dev/null
  echo "Removed Glideball. Settings are kept in ~/.config/glideball and backups in $APP/backups (use --purge to delete them)."
fi
