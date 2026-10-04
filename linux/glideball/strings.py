"""Every user-visible English string in one place (v1 is English only).

To translate later, swap this table (or wrap values in gettext)."""

from . import config as c
from . import keymap as k

APP_NAME = "Glideball"
APP_ID = "app.glideball.Glideball"

S = {
    # pages
    "overview": "Overview",
    "pointer": "Pointer",
    "scrolling": "Scrolling",
    "buttons": "Buttons",
    "backup": "Backup",

    # overview
    "status": "Status",
    "active": "Glideball is active",
    "paused": "Paused",
    "paused_sub": "The trackball is behaving as plain Linux would. Press Ctrl+Alt+Super+G to resume.",
    "failed": "Passing the trackball through",
    "failed_sub": "Something went wrong, so Glideball stepped aside. Change any setting or press Resume to try again. Details: {why}",
    "no_daemon": "The Glideball service isn't running",
    "no_daemon_sub": "Start it with: systemctl --user start glideball",
    "no_device": "No Kensington trackball found",
    "no_device_sub": "Plug in your Expert Mouse. If it is connected, check the permissions section in the README.",
    "enable": "Glideball on",
    "enable_sub": "Off hands the trackball back to the desktop (Ctrl+Alt+Super+G)",
    "resume": "Resume",
    "devices": "Trackballs",
    "activity": "Activity",
    "ball_speed": "Ball speed (in/s)",
    "ring_speed": "Scroll ring (notches/s)",
    "today_clicks": "Clicks since the service started",
    "beta": "Beta program",
    "beta_sub": "Also handle Kensington's other trackballs (SlimBlade, Orbit, Expert Wireless…). Other brands are never touched.",
    "modes": "Modes",
    "mode_precision": "Precision",
    "mode_ballScroll": "Scroll with ball",
    "mode_dragLock": "Drag lock",

    # pointer
    "tracking_speed": "Tracking speed",
    "tracking_speed_sub": "0.5 – 80. Applies to the trackball only; your other mice keep the desktop's speed.",
    "presets": "Presets",
    "precision_speed": "Precision speed",
    "precision_speed_sub": "Used while a Precision button is held or toggled on",
    "response_curve": "Response curve",
    "wayland_accel_note": "On Wayland the desktop's own acceleration still applies on top. For the Mac feel, set the mouse acceleration profile to Flat in your desktop's mouse settings.",

    # scrolling
    "scroll_mode": "Scroll mode",
    "mode_native": "Native",
    "mode_flywheel": "Flywheel",
    "mode_follow": "Follow",
    "mode_native_sub": "The desktop scrolls the ring itself, one notch at a time.",
    "mode_flywheel_sub": "Each tick pushes the page and friction slows it — Kensington's measured feel.",
    "mode_follow_sub": "The page tracks the ring exactly; a real flick throws it.",
    "fly_distance": "Slow-turn distance",
    "fly_acceleration": "Spin power",
    "fly_glide": "Glide",
    "kensington_feel": "Kensington feel",
    "scroll_distance": "Distance per tick",
    "scroll_smoothness": "Follow softness",
    "scroll_acceleration": "Spin acceleration",
    "throw_enabled": "Throw to coast",
    "throw_amount": "Throw length",
    "smooth_scrolling": "Smooth scrolling",
    "smooth_scrolling_sub": "Off gives plain steps",
    "reverse_scroll": "Reverse direction",
    "ball_scroll_speed": "Scroll-with-ball speed",

    # buttons
    "button_names": ["Bottom left (primary)", "Bottom right", "Top left", "Top right"],
    "primary_locked": "Always a left click, so a mapping can never lock you out",
    "combos": "Combos",
    "combos_sub": "Press 2 or 3 buttons together. Combo buttons wait 70 ms (160 ms for 3) for their partners.",
    "add_combo": "Add combo…",
    "learn": "Press the buttons on your trackball…",
    "learn_title": "New combo",
    "remove": "Remove",
    "record_title": "Press a keyboard shortcut",
    "record_sub": "Press the keys now. Esc cancels.",
    "custom_shortcut": "Keyboard shortcut…",
    "hold_shortcut": "Hold keyboard shortcut…",
    "cancel": "Cancel",
    "panic": "Pause shortcut",
    "panic_sub": "Ctrl+Alt+Super+G pauses or resumes Glideball (set up by install.sh on GNOME; see the README for other desktops).",

    # backup
    "export": "Export settings…",
    "import": "Import settings…",
    "import_done": "Settings imported. A backup of the old ones was saved first.",
    "import_failed": "Couldn't import: {why}",
    "auto_backups": "Automatic backups",
    "auto_backups_sub": "Daily when something changed. Kept for 14 days, then one a month for a year.",
    "back_up_now": "Back up now",
    "restore": "Restore",
    "restored": "Restored. The settings you had were backed up first.",
    "open_folder": "Open folder",
    "no_backups": "No backups yet",
    "file_filter": "Glideball settings",
}

# Button actions offered in the menus. Shortcuts use the Mac presets so files
# stay portable; keymap.translate maps them to their Linux meaning.
ACTION_PRESETS = [
    ("Default", c.action("system")),
    ("Left click", c.action("leftClick")),
    ("Right click", c.action("rightClick")),
    ("Middle click", c.action("middleClick")),
    ("Back", c.action("back")),
    ("Forward", c.action("forward")),
    ("Ctrl-click", c.modified_click(0, k.CONTROL)),
    ("Shift-click", c.modified_click(0, k.SHIFT)),
    ("Alt-click", c.modified_click(0, k.OPTION)),
    ("Previous workspace", c.shortcut_action(c.PREVIOUS_SPACE)),
    ("Next workspace", c.shortcut_action(c.NEXT_SPACE)),
    ("Activities overview", c.shortcut_action(k.shortcut(126, k.CONTROL, "↑"))),
    ("Browser Back", c.shortcut_action(k.shortcut(33, k.COMMAND, "["))),
    ("Browser Forward", c.shortcut_action(k.shortcut(30, k.COMMAND, "]"))),
    ("Copy", c.shortcut_action(k.shortcut(8, k.COMMAND, "C"))),
    ("Paste", c.shortcut_action(k.shortcut(9, k.COMMAND, "V"))),
    ("Undo", c.shortcut_action(k.shortcut(6, k.COMMAND, "Z"))),
    ("New Tab", c.shortcut_action(k.shortcut(17, k.COMMAND, "T"))),
    ("Close Tab", c.shortcut_action(k.shortcut(13, k.COMMAND, "W"))),
    ("Push to talk (Ctrl+Space, held)", c.shortcut_action(c.WISPR_FLOW, hold=True)),
    ("Precision (hold)", c.action("precisionHold")),
    ("Precision (toggle)", c.action("precisionToggle")),
    ("Scroll with ball (hold)", c.action("ballScrollHold")),
    ("Drag lock", c.action("dragLock")),
    ("Do nothing", c.action("disabled")),
]


def action_title(act) -> str:
    import json
    key = json.dumps(act, sort_keys=True)
    for title, a in ACTION_PRESETS:
        if json.dumps(a, sort_keys=True) == key:
            return title
    parsed = c.parse_action(act)
    if parsed and parsed[0] in ("shortcut", "holdShortcut"):
        label = k.display(parsed[1])
        return label + (" (held)" if parsed[0] == "holdShortcut" else "")
    if parsed and parsed[0] == "modifiedClick":
        return "Modified click"
    return "Custom (from a newer version)"
