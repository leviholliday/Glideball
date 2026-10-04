"""Buttons, combos and modes, driven by fake event streams and a fake clock."""

import pytest

from glideball import config as c
from glideball import keymap as k
from glideball.engine import COMBO_MAX_WAIT, COMBO_WINDOW, Engine, RecordingOutput

CTRL, ALT, SPACE, LEFT = k.KEY_LEFTCTRL, k.KEY_LEFTALT, 57, 105


class Clock:
    def __init__(self):
        self.t = 100.0

    def __call__(self):
        return self.t


def make(cfg=None):
    clock = Clock()
    out = RecordingOutput()
    e = Engine(cfg if cfg is not None else c.default_config(), out, clock=clock)
    return e, out, clock


def advance(e, clock, dt):
    """Run the loop like the daemon would, in 1 ms steps."""
    end = clock.t + dt
    while clock.t < end - 1e-9:
        clock.t = min(end, clock.t + 0.001)
        e.poll(clock.t)


def test_button_outside_any_combo_is_immediate():
    e, out, clock = make()
    e.button(1, True)
    assert out.take() == [("button", 1, True)]
    e.button(1, False)
    assert out.take() == [("button", 1, False)]


def test_combo_member_waits_70ms_then_acts_alone():
    e, out, clock = make()
    e.button(2, True)                      # top-left: Previous Space, member of 0+2+3
    advance(e, clock, COMBO_WINDOW - 0.005)
    assert out.take() == []
    advance(e, clock, 0.01)
    # Mac "Previous Space" (Ctrl+Left) means Ctrl+Alt+Left on Linux
    assert out.take() == [("key", CTRL, True), ("key", ALT, True), ("key", LEFT, True),
                          ("key", LEFT, False), ("key", ALT, False), ("key", CTRL, False)]
    e.button(2, False)
    assert out.take() == []


def test_release_before_window_flushes_in_order():
    e, out, clock = make()
    e.button(0, True)                      # primary is in the default combo, so it waits...
    advance(e, clock, 0.02)
    assert out.take() == []
    e.button(0, False)                     # ...and a quick click still arrives intact
    assert out.take() == [("button", 0, True), ("button", 0, False)]


def test_three_button_combo_holds_shortcut_until_release():
    e, out, clock = make()
    e.button(0, True)
    advance(e, clock, 0.05)
    e.button(2, True)
    advance(e, clock, 0.05)                # 100 ms after the first: window was extended
    e.button(3, True)
    assert out.take() == [("key", CTRL, True), ("key", SPACE, True)]
    advance(e, clock, 1.0)
    assert out.take() == []                # held while the buttons are
    e.button(3, False)
    assert out.take() == [("key", SPACE, False), ("key", CTRL, False)]
    e.button(0, False)
    e.button(2, False)
    assert out.take() == []                # the others finish silently


def test_combo_window_never_exceeds_160ms():
    e, out, clock = make()
    e.button(0, True)
    advance(e, clock, 0.06)
    e.button(2, True)
    advance(e, clock, COMBO_MAX_WAIT - 0.06 + 0.005)
    out_events = out.take()
    assert ("button", 0, True) in out_events          # gave up: acted alone
    e.button(3, True)
    assert ("key", SPACE, True) not in out.take()


def test_two_button_combo_fires_immediately_when_nothing_bigger():
    cfg = c.default_config()
    cfg["chords"] = [c.new_chord([1, 3], c.action("middleClick"))]
    e, out, clock = make(cfg)
    e.button(1, True)
    advance(e, clock, 0.02)
    e.button(3, True)
    assert out.take() == [("button", 2, True), ("button", 2, False)]
    e.button(1, False)
    e.button(3, False)
    assert out.take() == []


def test_primary_always_left_click():
    cfg = c.default_config()
    cfg["buttons"]["0"] = c.action("disabled")
    cfg["chords"] = []
    e, out, clock = make(cfg)
    e.button(0, True)
    e.button(0, False)
    assert out.take() == [("button", 0, True), ("button", 0, False)]


def test_remaps_and_modified_click():
    cfg = c.default_config()
    cfg["chords"] = []
    cfg["buttons"] = {"1": c.action("back"), "2": c.modified_click(0, k.CONTROL), "3": c.action("disabled")}
    e, out, clock = make(cfg)
    e.button(1, True); e.button(1, False)
    assert out.take() == [("button", 3, True), ("button", 3, False)]
    e.button(2, True); e.button(2, False)
    assert out.take() == [("key", CTRL, True), ("button", 0, True), ("button", 0, False), ("key", CTRL, False)]
    e.button(3, True); e.button(3, False)
    assert out.take() == []


def test_motion_cancels_pending_combo():
    e, out, clock = make()
    e.button(0, True)
    e.motion(3, 0)
    ev = out.take()
    assert ev[0] == ("button", 0, True) and ev[1][0] == "rel"


def test_precision_hold_slows_pointer():
    cfg = c.default_config()
    cfg["chords"] = []
    cfg["buttons"] = {"1": c.action("precisionHold")}
    cfg["trackingSpeed"] = 20.0
    cfg["precisionSpeed"] = 0.5

    def travel(e, clock):
        total = 0
        for _ in range(50):
            clock.t += 0.008
            e.motion(20, 0)
        for ev in e.out.take():
            if ev[0] == "rel":
                total += ev[1]
        return total

    e, out, clock = make(cfg)
    fast = travel(e, clock)
    e.button(1, True)
    assert e.precision_active
    slow = travel(e, clock)
    e.button(1, False)
    assert not e.precision_active
    assert slow < fast / 3


def test_drag_lock_and_click_to_drop():
    cfg = c.default_config()
    cfg["chords"] = []
    cfg["buttons"] = {"3": c.action("dragLock")}
    e, out, clock = make(cfg)
    e.button(3, True); e.button(3, False)
    assert out.take() == [("button", 0, True)] and e.drag_locked
    e.motion(5, 5)
    out.take()
    e.button(0, True); e.button(0, False)   # a click lets go, and that's all
    assert out.take() == [("button", 0, False)] and not e.drag_locked


def test_ball_scroll_hold_scrolls_instead_of_moving():
    cfg = c.default_config()
    cfg["chords"] = []
    cfg["buttons"] = {"1": c.action("ballScrollHold")}
    e, out, clock = make(cfg)
    e.button(1, True)
    for _ in range(20):
        clock.t += 0.008
        e.motion(0, 10)
        e.poll(clock.t)
    ev = out.take()
    assert not any(x[0] == "rel" for x in ev)
    assert sum(x[2] for x in ev if x[0] == "wheel") > 0   # ball down: page follows
    e.button(1, False)
    advance(e, clock, 1.0)
    assert not e.ball_scrolling


def test_release_all_lets_go_of_everything():
    e, out, clock = make()
    e.button(0, True); advance(e, clock, 0.05)
    e.button(2, True); e.button(3, True)    # Ctrl+Space held
    e.toggle_mode("dragLock")
    out.take()
    e.release_all()
    ev = out.take()
    assert ("key", SPACE, False) in ev and ("key", CTRL, False) in ev and ("button", 0, False) in ev
    assert not e.down_keys and not e.down_buttons


def test_native_wheel_passes_hi_res():
    cfg = c.default_config()
    cfg["scrollMode"] = "native"
    e, out, clock = make(cfg)
    e.wheel(1)
    e.wheel(-2)
    assert out.take() == [("wheel", 1, 120, 0, 0), ("wheel", -2, -240, 0, 0)]


def test_flywheel_emits_hi_res_at_frame_rate():
    e, out, clock = make()
    e.wheel(1)
    advance(e, clock, 0.6)
    ev = out.take()
    hi = sum(x[2] for x in ev if x[0] == "wheel")
    assert hi == int(4 * 120 / 50)          # 4 points at 50 points per notch
    assert all(x[1] == 0 for x in ev)        # less than a notch: no legacy REL_WHEEL


def test_learning_captures_buttons_without_acting():
    e, out, clock = make()
    got = []
    e.learn_next_press(got.append)
    e.button(2, True); e.button(3, True); e.button(3, False); e.button(2, False)
    assert got == [{2, 3}] and out.take() == []


def test_unknown_actions_are_skipped_not_fatal():
    cfg = c.default_config()
    cfg["buttons"] = {"1": {"teleport": {}}, "3": c.action("rightClick")}
    cfg["chords"] = [{"buttons": [1, 2], "action": {"future": {}}, "id": "X"}]
    e, out, clock = make(cfg)
    e.button(1, True); e.button(1, False)
    assert out.take() == [("button", 1, True), ("button", 1, False)]
    e.button(3, True)
    assert out.take() == [("button", 1, True)]
