"""Settings: the Mac app's ``GlideSettingsFile`` JSON, read and written as-is.

The file on disk is the source of truth and is kept as a plain JSON dict, so
anything this version doesn't understand (a newer Mac's fields, per-app
profiles, unknown button actions) survives a save untouched. Reading is
lenient the same way ``GlideConfig.init(from:)`` is: a missing or mistyped
field means its default, an unreadable button action just skips that button.

Button actions keep their Swift ``Codable`` shape, e.g.
``{"shortcut": {"_0": {"keyCode": 8, "modifiers": 1048576, "keyName": "C"}}}``
or ``{"leftClick": {}}``.
"""

from __future__ import annotations

import copy
import datetime as _dt
import json
import os
import socket
import tempfile
import uuid
from typing import Any, Dict, List, Optional, Tuple

from . import keymap

CURRENT_VERSION = 1
FILE_EXTENSION = "glide-settings"


def config_dir() -> str:
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "glideball")


def settings_path() -> str:
    return os.path.join(config_dir(), "settings." + FILE_EXTENSION)


def local_path() -> str:
    """Per-machine settings that never travel (like the Mac's UserDefaults)."""
    return os.path.join(config_dir(), "local.json")


# ---- actions -----------------------------------------------------------------

SIMPLE_ACTIONS = ("system", "leftClick", "rightClick", "middleClick", "back", "forward", "disabled",
                  "precisionHold", "precisionToggle", "ballScrollHold", "dragLock")
KNOWN_ACTIONS = SIMPLE_ACTIONS + ("shortcut", "holdShortcut", "modifiedClick")
MODE_ACTIONS = ("precisionHold", "precisionToggle", "ballScrollHold", "dragLock")


def action(kind: str, payload: Optional[dict] = None) -> dict:
    return {kind: payload if payload is not None else {}}


def shortcut_action(sc: dict, hold: bool = False) -> dict:
    return {("holdShortcut" if hold else "shortcut"): {"_0": dict(sc)}}


def modified_click(button: int, modifiers: int) -> dict:
    return {"modifiedClick": {"button": int(button), "modifiers": int(modifiers)}}


def parse_action(obj: Any) -> Optional[Tuple[str, Any]]:
    """Swift-encoded ButtonAction -> (kind, payload), or None if unreadable."""
    if not isinstance(obj, dict) or len(obj) != 1:
        return None
    kind, payload = next(iter(obj.items()))
    if kind not in KNOWN_ACTIONS:
        return None
    if kind in ("shortcut", "holdShortcut"):
        sc = payload.get("_0") if isinstance(payload, dict) else None
        if not isinstance(sc, dict) or not isinstance(sc.get("keyCode"), int) \
                or not isinstance(sc.get("modifiers"), int):
            return None
        return kind, sc
    if kind == "modifiedClick":
        if not isinstance(payload, dict) or not isinstance(payload.get("button"), int) \
                or not isinstance(payload.get("modifiers"), int):
            return None
        return kind, (payload["button"], payload["modifiers"])
    return kind, None


# Mac presets (KeyShortcut statics in Config.swift)
PREVIOUS_SPACE = keymap.shortcut(123, keymap.CONTROL, "←")
NEXT_SPACE = keymap.shortcut(124, keymap.CONTROL, "→")
WISPR_FLOW = keymap.shortcut(49, keymap.CONTROL, "Space")
DEFAULT_PAUSE = keymap.shortcut(5, keymap.CONTROL | keymap.OPTION | keymap.COMMAND, "G")


def default_config() -> Dict[str, Any]:
    """Exactly ``GlideConfig()``."""
    return {
        "enabled": True,
        "trackingSpeed": 4.0,
        "precisionSpeed": 1.0,
        "scrollMode": "flywheel",
        "nativeScrollSpeed": 0.5,
        "flyDistance": 4.0,
        "flyAcceleration": 0.5,
        "flyGlide": 0.35,
        "smoothScrolling": True,
        "scrollDistance": 14.0,
        "scrollSmoothness": 0.4,
        "scrollAcceleration": 0.5,
        "throwEnabled": True,
        "throwAmount": 0.4,
        "reverseScroll": False,
        "shiftScrollsHorizontally": True,
        "ballScrollSpeed": 1.0,
        "buttons": {"2": shortcut_action(PREVIOUS_SPACE), "3": shortcut_action(NEXT_SPACE)},
        "chords": [{"buttons": [0, 2, 3], "action": shortcut_action(WISPR_FLOW, hold=True),
                    "id": str(uuid.uuid4()).upper()}],
        "appProfiles": [],
        "globalShortcuts": {"pause": dict(DEFAULT_PAUSE), "precision": None,
                            "ballScroll": None, "dragLock": None},
    }


_NUMBER_FIELDS = ("trackingSpeed", "precisionSpeed", "nativeScrollSpeed", "flyDistance", "flyAcceleration",
                  "flyGlide", "scrollDistance", "scrollSmoothness", "scrollAcceleration", "throwAmount",
                  "ballScrollSpeed")
_BOOL_FIELDS = ("enabled", "smoothScrolling", "throwEnabled", "reverseScroll", "shiftScrollsHorizontally")
SCROLL_MODES = ("native", "flywheel", "follow")


class Chord:
    __slots__ = ("buttons", "kind", "payload", "raw")

    def __init__(self, buttons: List[int], kind: str, payload: Any, raw: dict):
        self.buttons, self.kind, self.payload, self.raw = sorted(buttons), kind, payload, raw


class Effective:
    """A read-only, fully-defaulted view of a config dict, for the engine."""

    def __init__(self, cfg: Optional[dict] = None):
        cfg = cfg if isinstance(cfg, dict) else {}
        d = default_config()
        for k in _NUMBER_FIELDS:
            v = cfg.get(k, d[k])
            setattr(self, k, float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else d[k])
        for k in _BOOL_FIELDS:
            v = cfg.get(k, d[k])
            setattr(self, k, v if isinstance(v, bool) else d[k])
        mode = cfg.get("scrollMode", d["scrollMode"])
        self.scrollMode = mode if mode in SCROLL_MODES else d["scrollMode"]

        raw_buttons = cfg.get("buttons", d["buttons"])
        self.buttons: Dict[int, Tuple[str, Any]] = {}
        for key, val in _button_items(raw_buttons if raw_buttons is not None else d["buttons"]):
            parsed = parse_action(val)
            if parsed is not None:
                self.buttons[key] = parsed

        raw_chords = cfg.get("chords", d["chords"])
        self.chords: List[Chord] = []
        if isinstance(raw_chords, list):
            for c in raw_chords:
                if not isinstance(c, dict) or not isinstance(c.get("buttons"), list):
                    continue
                parsed = parse_action(c.get("action"))
                btns = [b for b in c["buttons"] if isinstance(b, int)]
                if parsed is None or len(btns) < 2:
                    continue
                self.chords.append(Chord(btns, parsed[0], parsed[1], c))

        gs = cfg.get("globalShortcuts")
        self.globalShortcuts = dict(d["globalShortcuts"])
        if isinstance(gs, dict):
            for k in self.globalShortcuts:
                if k in gs and (gs[k] is None or isinstance(gs[k], dict)):
                    self.globalShortcuts[k] = gs[k]

    def action_for(self, button: int) -> Tuple[str, Any]:
        return self.buttons.get(button, ("system", None))


def _button_items(raw: Any):
    """Swift encodes [Int: X] as {"2": X}; older encoders used [2, X, ...]. Accept both."""
    if isinstance(raw, dict):
        for k, v in raw.items():
            try:
                yield int(k), v
            except (TypeError, ValueError):
                continue
    elif isinstance(raw, list):
        for i in range(0, len(raw) - 1, 2):
            if isinstance(raw[i], int):
                yield raw[i], raw[i + 1]


# ---- the file ------------------------------------------------------------------

class SettingsError(Exception):
    pass


def now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def new_file(cfg: Optional[dict] = None) -> dict:
    return {"version": CURRENT_VERSION, "config": cfg if cfg is not None else default_config(),
            "exportedAt": now_iso(), "exportedFrom": socket.gethostname()}


def parse_file(text: str) -> dict:
    """Parse and validate a settings file. Raises SettingsError."""
    try:
        data = json.loads(text)
    except (ValueError, TypeError) as e:
        raise SettingsError(f"Not a Glideball settings file: {e}") from e
    if not isinstance(data, dict) or not isinstance(data.get("config"), dict):
        raise SettingsError("Not a Glideball settings file.")
    version = data.get("version")
    if version != CURRENT_VERSION:
        raise SettingsError(f"This settings file uses unsupported version {version}.")
    return data


def dumps(data: dict, compact: bool = False) -> str:
    if compact:
        return json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return json.dumps(data, sort_keys=True, indent=2, ensure_ascii=False)


def atomic_write(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def load(path: Optional[str] = None) -> dict:
    """The settings file, or defaults if there is none. A corrupt file is moved
    aside (never silently overwritten) and defaults are used."""
    path = path or settings_path()
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        return new_file()
    try:
        return parse_file(text)
    except SettingsError:
        try:
            os.replace(path, path + ".unreadable")
        except OSError:
            pass
        return new_file()


def save(data: dict, path: Optional[str] = None) -> None:
    data = dict(data)
    data["version"] = CURRENT_VERSION
    data["exportedAt"] = now_iso()
    data["exportedFrom"] = socket.gethostname()
    atomic_write(path or settings_path(), dumps(data) + "\n")


def config_of(data: dict) -> dict:
    cfg = data.get("config")
    return cfg if isinstance(cfg, dict) else {}


def with_changes(data: dict, **changes) -> dict:
    """A copy of the file with config fields replaced (unknown fields kept)."""
    out = copy.deepcopy(data)
    out.setdefault("config", {}).update(changes)
    return out


def new_chord(buttons: List[int], act: dict) -> dict:
    return {"buttons": sorted(set(buttons)), "action": act, "id": str(uuid.uuid4()).upper()}


def configs_equal(a: dict, b: dict) -> bool:
    """Same settings, ignoring the pause switch (backups never restore it)."""
    a, b = dict(a), dict(b)
    a.pop("enabled", None)
    b.pop("enabled", None)
    return json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)


# ---- per-machine settings ---------------------------------------------------------

LOCAL_DEFAULTS = {
    "betaProgram": False,       # also handle Kensington's other trackballs
    "autoBackups": True,
    "pointsPerNotch": 50.0,     # how many Mac "points" one 120-unit hi-res notch is
    "frameRate": 120.0,         # scroll animation rate (Hz); ~ display refresh
}


def load_local(path: Optional[str] = None) -> dict:
    out = dict(LOCAL_DEFAULTS)
    try:
        with open(path or local_path(), encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            for k, v in data.items():
                if k in LOCAL_DEFAULTS and type(v) is type(LOCAL_DEFAULTS[k]) or (
                        k in LOCAL_DEFAULTS and isinstance(LOCAL_DEFAULTS[k], float) and isinstance(v, int)):
                    out[k] = v
    except (OSError, ValueError):
        pass
    return out


def save_local(values: dict, path: Optional[str] = None) -> None:
    current = load_local(path)
    current.update(values)
    atomic_write(path or local_path(), json.dumps(current, indent=2, sort_keys=True) + "\n")
