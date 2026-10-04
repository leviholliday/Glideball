"""The event pipeline: buttons, combos, modes, pointer speed and scrolling.

A port of Engine.swift's button/combo/mode logic, driven by plain calls
(``button``, ``motion``, ``wheel``, ``poll``) with an injected clock and an
injected ``Output``. No evdev here, so tests run it against fake event
streams and a recording output; the daemon wires it to a grabbed device and
a uinput device.

Buttons use the Mac's numbering: 0 = primary (BTN_LEFT), 1 = BTN_RIGHT,
2 = BTN_MIDDLE, 3 = BTN_SIDE, 4 = BTN_EXTRA ... (evdev code = 0x110 + n).
"""

from __future__ import annotations

import math
import time
from typing import Callable, Dict, List, Optional, Set, Tuple

from . import keymap
from .config import Effective
from .pointer import PointerAccel
from .scroller import ScrollSettings, SmoothScroller

COMBO_WINDOW = 0.07      # how long a combo button waits for its partners
COMBO_MAX_WAIT = 0.16    # longest a press is ever held back (3-button combos)

BACK, FORWARD = 3, 4     # Mac button numbers for BTN_SIDE / BTN_EXTRA


class Output:
    """What the engine emits. The daemon implements it with uinput."""

    def rel(self, dx: int, dy: int) -> None: ...
    def button(self, n: int, down: bool) -> None: ...
    def key(self, code: int, down: bool) -> None: ...
    def wheel(self, v: int, v_hi: int, h: int, h_hi: int) -> None: ...
    def sync(self) -> None: ...


class RecordingOutput(Output):
    """Collects everything, for tests (and the daemon's dry-run mode)."""

    def __init__(self):
        self.events: List[tuple] = []

    def rel(self, dx, dy):
        self.events.append(("rel", dx, dy))

    def button(self, n, down):
        self.events.append(("button", n, down))

    def key(self, code, down):
        self.events.append(("key", code, down))

    def wheel(self, v, v_hi, h, h_hi):
        self.events.append(("wheel", v, v_hi, h, h_hi))

    def sync(self):
        pass

    def take(self, kinds=None):
        out = [e for e in self.events if kinds is None or e[0] in kinds]
        self.events.clear()
        return out


class _WheelUnits:
    """Mac points -> Linux hi-res wheel units (120 per notch), with remainders,
    plus the legacy REL_WHEEL notch whenever 120 units accumulate."""

    def __init__(self):
        self.frac = 0.0
        self.hi_acc = 0

    def convert(self, units: float) -> Tuple[int, int]:
        self.frac += units
        hi = int(self.frac)
        self.frac -= hi
        self.hi_acc += hi
        lo = int(self.hi_acc / 120)
        self.hi_acc -= lo * 120
        return lo, hi

    def reset(self):
        self.frac = 0.0
        self.hi_acc = 0


class Engine:
    def __init__(self, cfg: Optional[dict] = None, out: Optional[Output] = None,
                 clock: Callable[[], float] = time.monotonic, points_per_notch: float = 50.0):
        self.out = out or RecordingOutput()
        self.clock = clock
        self.points_per_notch = points_per_notch
        self.cfg = Effective(cfg)
        self.scroller = SmoothScroller(ScrollSettings.from_config(self.cfg.__dict__), clock=clock)
        self.scroller.output = self._scroll_out
        self.scroller.ball_output = self._ball_out
        self._v = _WheelUnits()
        self._h = _WheelUnits()
        self.pointer = PointerAccel()

        self.pending: List[int] = []
        self.pending_start = 0.0
        self.pending_deadline: Optional[float] = None
        self.overrides: Dict[int, tuple] = {}
        self.down_buttons: Set[int] = set()     # buttons we hold down on the output
        self.down_keys: List[int] = []          # keys we hold down on the output

        self.precision_held = False
        self.precision_toggled = False
        self.ball_scroll_held = False
        self.ball_scroll_latched = False
        self.ball_scrolling = False
        self.drag_locked = False

        self.learn_handler: Optional[Callable[[Set[int]], None]] = None
        self._learn_held: Set[int] = set()
        self._learn_max: Set[int] = set()

        # live activity, read by the daemon for the GUI
        self.stats = {"clicks": 0, "ballCounts": 0.0, "notches": 0, "scrolledPoints": 0.0}
        self.on_modes_changed: Optional[Callable[[], None]] = None

    # ---- config ----------------------------------------------------------

    def update(self, cfg: dict) -> None:
        self.cfg = Effective(cfg)
        self.scroller.config = ScrollSettings.from_config(self.cfg.__dict__)

    @property
    def modes(self) -> dict:
        return {"precision": self.precision_active, "ballScroll": self.ball_scrolling,
                "dragLock": self.drag_locked}

    @property
    def precision_active(self) -> bool:
        return self.precision_held or self.precision_toggled

    # ---- timers ------------------------------------------------------------

    def next_deadline(self, frame_interval: float) -> Optional[float]:
        times = []
        if self.pending_deadline is not None:
            times.append(self.pending_deadline)
        if self.scroller.running:
            times.append(self.scroller._last_frame + frame_interval if self.scroller._last_frame else self.clock())
        return min(times) if times else None

    def poll(self, now: Optional[float] = None, frame_interval: float = 1 / 120) -> None:
        now = self.clock() if now is None else now
        if self.pending_deadline is not None and now >= self.pending_deadline:
            self._combo_window_ended()
        if self.scroller.running and now >= self.scroller._last_frame + frame_interval - 0.0005:
            self.scroller.frame(now)
        self.out.sync()

    # ---- input ---------------------------------------------------------------

    def motion(self, dx: int, dy: int) -> None:
        if dx == 0 and dy == 0:
            return
        self.stats["ballCounts"] += math.hypot(dx, dy)
        if self.pending:
            self._flush_pending()     # moving means "not a combo" (like a drag on the Mac)
        if self.ball_scrolling:
            # Page follows the ball (Mac sign convention: + = up / left).
            self.scroller.add_ball_delta(dx, dy)
            return
        speed = self.cfg.precisionSpeed if self.precision_active else self.cfg.trackingSpeed
        ix, iy = self.pointer.process(dx, dy, self.clock(), speed)
        if ix or iy:
            self.out.rel(ix, iy)

    def wheel(self, ticks: int, horizontal: bool = False) -> None:
        """Raw REL_WHEEL (+ = up) or REL_HWHEEL (+ = right) from the trackball."""
        if ticks == 0:
            return
        self.stats["notches"] += abs(ticks)
        if self.cfg.scrollMode == "native":
            t = -ticks if self.cfg.reverseScroll else ticks
            if horizontal:
                self.out.wheel(0, 0, t, t * 120)
            else:
                self.out.wheel(t, t * 120, 0, 0)
            return
        # Mac scroll direction: + = up, and for horizontal + = left.
        self.scroller.add_ticks(-ticks if horizontal else ticks, horizontal=horizontal)

    def _scroll_out(self, delta: float, horizontal: bool) -> None:
        self.stats["scrolledPoints"] += abs(delta)
        units = delta * 120.0 / self.points_per_notch
        if horizontal:
            lo, hi = self._h.convert(-units)
            if hi:
                self.out.wheel(0, 0, lo, hi)
        else:
            lo, hi = self._v.convert(units)
            if hi:
                self.out.wheel(lo, hi, 0, 0)

    def _ball_out(self, dx: float, dy: float) -> None:
        self.stats["scrolledPoints"] += math.hypot(dx, dy)
        vlo, vhi = self._v.convert(dy * 120.0 / self.points_per_notch)
        hlo, hhi = self._h.convert(-dx * 120.0 / self.points_per_notch)
        if vhi or hhi:
            self.out.wheel(vlo, vhi, hlo, hhi)

    # ---- buttons ---------------------------------------------------------------

    def button(self, b: int, down: bool) -> None:
        if down:
            self.stats["clicks"] += 1
            self._down(b)
        else:
            self._up(b)

    def learn_next_press(self, handler: Optional[Callable[[Set[int]], None]]) -> None:
        self.learn_handler = handler
        self._learn_held = set()
        self._learn_max = set()

    def _down(self, b: int) -> None:
        # Drag lock: a click lets go, and that's all it does.
        if self.drag_locked and self._is_left_press(b) and not self._in_drag_lock_combo(b):
            self._end_drag_lock()
            self.overrides[b] = ("swallow",)
            return
        if self.learn_handler is not None:
            self._learn_held.add(b)
            self._learn_max |= self._learn_held
            return
        combo_buttons = {x for c in self.cfg.chords for x in c.buttons}
        if b not in combo_buttons:
            if self.pending:
                self._flush_pending()
            self._press(b)
            return
        # Hold this press briefly to see if it becomes a combo.
        now = self.clock()
        self.pending.append(b)
        held = set(self.pending)
        exact = next((c for c in self.cfg.chords if set(c.buttons) == held), None)
        bigger = any(set(c.buttons) > held for c in self.cfg.chords)
        if exact is not None and not bigger:
            self._fire_combo(exact)
        elif len(self.pending) == 1:
            self.pending_start = now
            self.pending_deadline = now + COMBO_WINDOW
        elif bigger:
            left = COMBO_MAX_WAIT - (now - self.pending_start)
            self.pending_deadline = now + max(0.01, min(COMBO_WINDOW, left))

    def _up(self, b: int) -> None:
        if self.learn_handler is not None and b in self._learn_held:
            self._learn_held.discard(b)
            if not self._learn_held:
                handler, result = self.learn_handler, set(self._learn_max)
                self.learn_handler = None
                handler(result)
            return
        if b in self.pending:
            self._flush_pending()
        o = self.overrides.pop(b, None)
        if o is None:
            if b in self.down_buttons:
                self._emit_button(b, False)
            return
        kind = o[0]
        if kind == "remap":
            _, target, mods = o
            self._emit_button(target, False)
            for k in reversed(mods):
                self._key(k, False)
        elif kind == "held":
            self._send_up(o[1])
            for other, ov in list(self.overrides.items()):
                if ov[0] == "held":
                    self.overrides[other] = ("swallow",)
        elif kind == "precision":
            self._end_precision_hold()
        elif kind == "ballScroll":
            self._end_ball_scroll(latched=False, glide=True)
        # "swallow" and "dragButton": nothing to do

    def _combo_window_ended(self) -> None:
        held = set(self.pending)
        chord = next((c for c in self.cfg.chords if set(c.buttons) == held), None) if len(held) > 1 else None
        if chord is not None:
            self._fire_combo(chord)
        else:
            self._flush_pending()

    def _fire_combo(self, chord) -> None:
        self.pending_deadline = None
        pressed, self.pending = self.pending, []
        if self._begin_mode(chord.kind, pressed):
            return
        if chord.kind == "holdShortcut":
            for p in pressed:
                self.overrides[p] = ("held", chord.payload)
            self._send_down(chord.payload)
        else:
            for p in pressed:
                self.overrides[p] = ("swallow",)
            self._perform(chord.kind, chord.payload)

    def _flush_pending(self) -> None:
        self.pending_deadline = None
        presses, self.pending = self.pending, []
        for p in presses:
            self._press(p)

    def _press(self, b: int) -> None:
        if self.drag_locked and self._is_left_press(b):
            self._end_drag_lock()
            self.overrides[b] = ("swallow",)
            return
        # The primary button always stays a left click.
        if b == 0:
            self._emit_button(0, True)
            return
        kind, payload = self.cfg.action_for(b)
        if self._begin_mode(kind, [b]):
            return
        target = None
        if kind == "system":
            target = b
        elif kind == "leftClick":
            target = 0
        elif kind == "rightClick":
            target = 1
        elif kind == "middleClick":
            target = 2
        elif kind == "back":
            target = BACK
        elif kind == "forward":
            target = FORWARD
        elif kind == "disabled":
            self.overrides[b] = ("swallow",)
            return
        elif kind == "shortcut":
            self.overrides[b] = ("swallow",)
            self._send(payload)
            return
        elif kind == "holdShortcut":
            self.overrides[b] = ("held", payload)
            self._send_down(payload)
            return
        elif kind == "modifiedClick":
            button, mods = payload
            keys = keymap.click_modifier_keys(mods)
            self.overrides[b] = ("remap", button, keys)
            for k in keys:
                self._key(k, True)
            self._emit_button(button, True)
            return
        else:
            target = b
        if target == b:
            self._emit_button(b, True)
            return
        self.overrides[b] = ("remap", target, [])
        self._emit_button(target, True)

    # ---- modes -----------------------------------------------------------------

    def _begin_mode(self, kind: str, buttons: List[int]) -> bool:
        if kind == "precisionHold":
            for b in buttons:
                self.overrides[b] = ("precision",)
            self.precision_held = True
        elif kind == "precisionToggle":
            for b in buttons:
                self.overrides[b] = ("swallow",)
            self.precision_toggled = not self.precision_toggled
        elif kind == "ballScrollHold":
            for b in buttons:
                self.overrides[b] = ("ballScroll",)
            self._begin_ball_scroll(latched=False)
        elif kind == "dragLock":
            if self.drag_locked:
                for b in buttons:
                    self.overrides[b] = ("swallow",)
                self._end_drag_lock()
            else:
                for b in buttons:
                    self.overrides[b] = ("dragButton",)
                self._begin_drag_lock()
        else:
            return False
        self._modes_changed()
        return True

    def toggle_mode(self, mode: str) -> None:
        """Keyboard / tray toggles (the Mac's global mode shortcuts)."""
        if mode == "precision":
            self.precision_toggled = not self.precision_toggled
        elif mode == "ballScroll":
            if self.ball_scroll_latched:
                self._end_ball_scroll(latched=True, glide=False)
            else:
                self._begin_ball_scroll(latched=True)
        elif mode == "dragLock":
            if self.drag_locked:
                self._end_drag_lock()
            else:
                self._begin_drag_lock()
        self._modes_changed()

    def _end_precision_hold(self) -> None:
        self.precision_held = False
        for b, o in list(self.overrides.items()):
            if o[0] == "precision":
                self.overrides[b] = ("swallow",)
        self._modes_changed()

    def _begin_ball_scroll(self, latched: bool) -> None:
        if latched:
            self.ball_scroll_latched = True
        else:
            self.ball_scroll_held = True
        if self.ball_scrolling:
            return
        self.ball_scrolling = True
        self.pointer.reset()
        self.scroller.begin_ball()

    def _end_ball_scroll(self, latched: bool, glide: bool) -> None:
        if latched:
            self.ball_scroll_latched = False
        else:
            self.ball_scroll_held = False
            for b, o in list(self.overrides.items()):
                if o[0] == "ballScroll":
                    self.overrides[b] = ("swallow",)
        if self.ball_scroll_held or self.ball_scroll_latched or not self.ball_scrolling:
            return
        self.ball_scrolling = False
        self.scroller.end_ball(glide=glide)
        self._modes_changed()

    def _begin_drag_lock(self) -> None:
        self.drag_locked = True
        self._emit_button(0, True)

    def _end_drag_lock(self) -> None:
        if not self.drag_locked:
            return
        self.drag_locked = False
        self._emit_button(0, False)
        for b, o in list(self.overrides.items()):
            if o[0] == "dragButton":
                self.overrides[b] = ("swallow",)
        self._modes_changed()

    def _is_left_press(self, b: int) -> bool:
        if b == 0:
            return True
        kind, payload = self.cfg.action_for(b)
        return kind == "leftClick" or (kind == "modifiedClick" and payload[0] == 0)

    def _in_drag_lock_combo(self, b: int) -> bool:
        return any(c.kind == "dragLock" and b in c.buttons for c in self.cfg.chords)

    def _modes_changed(self) -> None:
        if self.on_modes_changed:
            self.on_modes_changed()

    # ---- actions -----------------------------------------------------------------

    def _perform(self, kind: str, payload) -> None:
        """A one-shot action (combos): clicks are a quick press-and-release."""
        if kind in ("system", "disabled"):
            return
        if kind in ("shortcut", "holdShortcut"):
            self._send(payload)
            return
        keys: List[int] = []
        if kind == "modifiedClick":
            button, mods = payload
            keys = keymap.click_modifier_keys(mods)
        else:
            button = {"leftClick": 0, "rightClick": 1, "middleClick": 2, "back": BACK, "forward": FORWARD}.get(kind)
            if button is None:
                return
        for k in keys:
            self._key(k, True)
        self._emit_button(button, True)
        self._emit_button(button, False)
        for k in reversed(keys):
            self._key(k, False)

    def _send(self, sc: dict) -> None:
        self._send_down(sc)
        self._send_up(sc)

    def _send_down(self, sc: dict) -> None:
        t = keymap.translate(sc)
        if t is None:
            return
        mods, key = t
        for m in mods:
            self._key(m, True)
        self._key(key, True)

    def _send_up(self, sc: dict) -> None:
        t = keymap.translate(sc)
        if t is None:
            return
        mods, key = t
        self._key(key, False)
        for m in reversed(mods):
            self._key(m, False)

    # ---- output bookkeeping (so nothing can stay stuck) ----------------------------

    def _emit_button(self, n: int, down: bool) -> None:
        if down:
            if n in self.down_buttons:
                return
            self.down_buttons.add(n)
        else:
            if n not in self.down_buttons:
                return
            self.down_buttons.discard(n)
        self.out.button(n, down)
        self.out.sync()

    def _key(self, code: int, down: bool) -> None:
        # Counted, so two actions sharing a modifier don't release it early.
        if down:
            already = code in self.down_keys
            self.down_keys.append(code)
            if already:
                return
        else:
            if code not in self.down_keys:
                return
            self.down_keys.remove(code)
            if code in self.down_keys:
                return
        self.out.key(code, down)
        self.out.sync()

    def release_all(self) -> None:
        """Let go of everything we hold on the output and stop all modes.
        Called on pause, on errors, and on shutdown."""
        self.pending = []
        self.pending_deadline = None
        self.overrides.clear()
        self.learn_handler = None
        self.precision_held = self.precision_toggled = False
        self.ball_scroll_held = self.ball_scroll_latched = self.ball_scrolling = False
        self.drag_locked = False
        self.scroller.stop_all()
        self._v.reset()
        self._h.reset()
        self.pointer.reset()
        for n in sorted(self.down_buttons):
            self.out.button(n, False)
        self.down_buttons.clear()
        for k in reversed(list(dict.fromkeys(self.down_keys))):
            self.out.key(k, False)
        self.down_keys.clear()
        self.out.sync()
        self._modes_changed()
