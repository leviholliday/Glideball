"""Keyboard shortcuts across platforms.

Settings files store shortcuts the Mac way (``KeyShortcut``): a macOS virtual
key code (kVK_*), CGEventFlags modifier bits, and a display name. That keeps
``.glide-settings`` files identical on Mac and Linux. This module converts
those to Linux evdev key codes when a shortcut is sent, and back when one is
recorded in the Linux GUI.

Modifier mapping (literal): Control -> Ctrl, Option -> Alt, Shift -> Shift,
Command -> Super. The Mac app's built-in presets (Copy = Cmd+C, Previous
Space = Ctrl+Left, ...) are translated to their Linux equivalents instead,
so a file made on a Mac does the expected thing here.
"""

from __future__ import annotations

from typing import Dict, List, Optional, Tuple

# CGEventFlags
SHIFT = 0x20000
CONTROL = 0x40000
OPTION = 0x80000
COMMAND = 0x100000
MODIFIER_MASK = SHIFT | CONTROL | OPTION | COMMAND

# evdev key codes (linux/input-event-codes.h)
KEY_LEFTCTRL, KEY_LEFTSHIFT, KEY_LEFTALT, KEY_LEFTMETA = 29, 42, 56, 125

MODIFIER_KEYS: List[Tuple[int, int]] = [  # press order, like the Mac
    (CONTROL, KEY_LEFTCTRL),
    (OPTION, KEY_LEFTALT),
    (SHIFT, KEY_LEFTSHIFT),
    (COMMAND, KEY_LEFTMETA),
]

# macOS kVK code -> (evdev code, display name)
MAC_TO_LINUX: Dict[int, Tuple[int, str]] = {
    0: (30, "A"), 1: (31, "S"), 2: (32, "D"), 3: (33, "F"), 4: (35, "H"), 5: (34, "G"),
    6: (44, "Z"), 7: (45, "X"), 8: (46, "C"), 9: (47, "V"), 11: (48, "B"), 12: (16, "Q"),
    13: (17, "W"), 14: (18, "E"), 15: (19, "R"), 16: (21, "Y"), 17: (20, "T"),
    18: (2, "1"), 19: (3, "2"), 20: (4, "3"), 21: (5, "4"), 22: (7, "6"), 23: (6, "5"),
    24: (13, "="), 25: (10, "9"), 26: (8, "7"), 27: (12, "-"), 28: (9, "8"), 29: (11, "0"),
    30: (27, "]"), 31: (24, "O"), 32: (22, "U"), 33: (26, "["), 34: (23, "I"), 35: (25, "P"),
    36: (28, "↩"), 37: (38, "L"), 38: (36, "J"), 39: (40, "'"), 40: (37, "K"), 41: (39, ";"),
    42: (43, "\\"), 43: (51, ","), 44: (53, "/"), 45: (49, "N"), 46: (50, "M"), 47: (52, "."),
    48: (15, "⇥"), 49: (57, "Space"), 50: (41, "`"), 51: (14, "⌫"), 53: (1, "Esc"),
    57: (58, "Caps Lock"), 72: (115, "Volume Up"), 73: (114, "Volume Down"), 74: (113, "Mute"),
    122: (59, "F1"), 120: (60, "F2"), 99: (61, "F3"), 118: (62, "F4"), 96: (63, "F5"),
    97: (64, "F6"), 98: (65, "F7"), 100: (66, "F8"), 101: (67, "F9"), 109: (68, "F10"),
    103: (87, "F11"), 111: (88, "F12"), 105: (183, "F13"), 107: (184, "F14"), 113: (185, "F15"),
    106: (186, "F16"), 64: (187, "F17"),
    114: (138, "Help"), 115: (102, "Home"), 116: (104, "Page Up"), 117: (111, "⌦"),
    119: (107, "End"), 121: (109, "Page Down"),
    123: (105, "←"), 124: (106, "→"), 125: (108, "↓"), 126: (103, "↑"),
}
LINUX_TO_MAC: Dict[int, int] = {lin: mac for mac, (lin, _) in MAC_TO_LINUX.items()}

# evdev modifier keys -> CGEventFlags (for recording)
LINUX_MODIFIER_FLAGS = {29: CONTROL, 97: CONTROL, 42: SHIFT, 54: SHIFT, 56: OPTION, 100: OPTION,
                        125: COMMAND, 126: COMMAND}

SUPER_TAP = "super"   # a lone Super press (Activities / launcher)

# The Mac presets, by (kVK, modifiers): what they mean on a Linux desktop.
# Values: (modifier evdev codes, key evdev code | SUPER_TAP)
_PRESET_TRANSLATIONS: Dict[Tuple[int, int], Tuple[List[int], object]] = {
    (123, CONTROL): ([KEY_LEFTCTRL, KEY_LEFTALT], 105),   # Previous Space -> Ctrl+Alt+Left
    (124, CONTROL): ([KEY_LEFTCTRL, KEY_LEFTALT], 106),   # Next Space -> Ctrl+Alt+Right
    (126, CONTROL): ([], SUPER_TAP),                      # Mission Control -> overview
    (125, CONTROL): ([], SUPER_TAP),                      # App Exposé -> overview
    (33, COMMAND): ([KEY_LEFTALT], 105),                  # Browser Back -> Alt+Left
    (30, COMMAND): ([KEY_LEFTALT], 106),                  # Browser Forward -> Alt+Right
    (8, COMMAND): ([KEY_LEFTCTRL], 46),                   # Copy
    (9, COMMAND): ([KEY_LEFTCTRL], 47),                   # Paste
    (6, COMMAND): ([KEY_LEFTCTRL], 44),                   # Undo
    (17, COMMAND): ([KEY_LEFTCTRL], 20),                  # New Tab
    (13, COMMAND): ([KEY_LEFTCTRL], 17),                  # Close Tab
    (49, COMMAND): ([], SUPER_TAP),                       # Spotlight -> launcher
}


def shortcut(key_code: int, modifiers: int, name: str) -> dict:
    return {"keyCode": int(key_code), "modifiers": int(modifiers), "keyName": name}


def translate(sc: dict) -> Optional[Tuple[List[int], int]]:
    """A stored shortcut -> (modifier evdev codes to hold, evdev key code).

    Returns None if the key has no Linux equivalent.
    """
    try:
        code = int(sc.get("keyCode", -1))
        mods = int(sc.get("modifiers", 0)) & MODIFIER_MASK
    except (TypeError, ValueError, AttributeError):
        return None
    preset = _PRESET_TRANSLATIONS.get((code, mods))
    if preset is not None:
        held, key = preset
        if key == SUPER_TAP:
            return [], KEY_LEFTMETA
        return list(held), int(key)  # type: ignore[arg-type]
    if code not in MAC_TO_LINUX:
        return None
    held = [k for flag, k in MODIFIER_KEYS if mods & flag]
    return held, MAC_TO_LINUX[code][0]


def display(sc: dict) -> str:
    """Linux-style label: "Ctrl+Alt+Super+G"."""
    try:
        mods = int(sc.get("modifiers", 0))
    except (TypeError, ValueError):
        mods = 0
    parts = []
    if mods & CONTROL:
        parts.append("Ctrl")
    if mods & OPTION:
        parts.append("Alt")
    if mods & SHIFT:
        parts.append("Shift")
    if mods & COMMAND:
        parts.append("Super")
    name = sc.get("keyName")
    if not name:
        name = MAC_TO_LINUX.get(sc.get("keyCode", -1), (0, "?"))[1]
    parts.append(str(name))
    return "+".join(parts)


def from_linux(key_code: int, held_modifier_codes) -> Optional[dict]:
    """A key recorded in the GUI (evdev code + held modifier codes) -> stored shortcut."""
    mac = LINUX_TO_MAC.get(key_code)
    if mac is None:
        return None
    flags = 0
    for c in held_modifier_codes:
        flags |= LINUX_MODIFIER_FLAGS.get(c, 0)
    return shortcut(mac, flags, MAC_TO_LINUX[mac][1])


def click_modifier_keys(modifiers: int) -> List[int]:
    """Modifiers for a "modified click". Mac Command-click (open in new tab)
    and Control-click both become Ctrl-click; Option -> Alt; Shift -> Shift."""
    keys = []
    if modifiers & (CONTROL | COMMAND):
        keys.append(KEY_LEFTCTRL)
    if modifiers & OPTION:
        keys.append(KEY_LEFTALT)
    if modifiers & SHIFT:
        keys.append(KEY_LEFTSHIFT)
    return keys


ALL_KEY_CODES = sorted({lin for lin, _ in MAC_TO_LINUX.values()} | {k for _, k in MODIFIER_KEYS})
