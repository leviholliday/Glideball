"""The Python scroll physics must match the Swift SmoothScroller frame for frame.

fixtures/scroll_golden.json is produced by linux/tools/make-golden.sh, which
compiles the real Sources/Glide/SmoothScroller.swift with the scenarios from
scripts/scroll-sim/main.swift (jitter-free, so they're deterministic).
"""

import json
import os

import pytest

from glideball import scroller as sc
from glideball.scroller import ScrollSettings, SmoothScroller

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")
GOLDEN = json.load(open(os.path.join(FIXTURES, "scroll_golden.json")))


def simulate(mode, ticks, dirs, until, **cfg):
    now = [0.0]
    acc = [0.0]
    s = SmoothScroller(ScrollSettings(scrollMode=mode, **cfg), clock=lambda: now[0])
    s.output = lambda d, h: acc.__setitem__(0, acc[0] + d)
    frames = []
    i = 0
    t = 0.0
    while t <= until:
        while i < len(ticks) and ticks[i] <= t:
            now[0] = ticks[i]
            s.add_ticks(dirs[i])
            i += 1
        now[0] = t
        s.frame(t)
        frames.append(acc[0])
        acc[0] = 0.0
        t += 1 / 120.0
    return frames


@pytest.mark.parametrize("case", GOLDEN, ids=[f'{c["mode"]}-{c["name"]}' for c in GOLDEN])
def test_matches_swift(case):
    frames = simulate(case["mode"], case["ticks"], case["dirs"], case["until"])
    expected = case["frames"]
    assert len(frames) == len(expected)
    # Same libm on the same platform gives identical results; allow a 1-point
    # rounding flip per frame elsewhere (glibc vs Darwin pow/exp ulps).
    assert abs(sum(frames) - sum(expected)) <= 1
    assert all(abs(a - b) <= 1 for a, b in zip(frames, expected))
    mismatches = sum(1 for a, b in zip(frames, expected) if a != b)
    assert mismatches <= 2


def test_kensington_measurements():
    # Flywheel defaults: one tick ~ 4 pt; a 10-tick flick travels ~2300 pt.
    one = [c for c in GOLDEN if c["mode"] == "flywheel" and c["name"] == "one tick"][0]
    assert sum(one["frames"]) == 4
    flick = [c for c in GOLDEN if c["mode"] == "flywheel" and c["name"] == "typical flick"][0]
    assert 2000 <= sum(flick["frames"]) <= 2700


def test_helpers_match_swift_formulas():
    assert sc.fly_tau(0.35) == pytest.approx(0.082)
    assert sc.fly_tau(0) == pytest.approx(0.04) and sc.fly_tau(1) == pytest.approx(0.16)
    assert sc.acceleration_multiplier(5, 0.5) == 1
    assert sc.acceleration_multiplier(40, 0.5) == pytest.approx(5)
    assert sc.follow_omega(0) == 80 and sc.follow_omega(1) == 25
    assert sc.throw_coefficient(0.4) == pytest.approx(0.065)


def test_reverse_flips_direction():
    normal = simulate("flywheel", [0.05], [1], 0.6)
    reversed_ = simulate("flywheel", [0.05], [1], 0.6, reverseScroll=True)
    assert sum(normal) == -sum(reversed_) == 4


def test_unsmoothed_steps_land_immediately():
    frames = simulate("follow", [0.05], [1], 0.2, smoothScrolling=False)
    assert frames[7] == 14 and sum(frames) == 14   # tick at 0.05 lands on the 0.0583 frame


def test_ball_scroll_glides_and_stops():
    now = [0.0]
    out = []
    s = SmoothScroller(ScrollSettings(), clock=lambda: now[0])
    s.ball_output = lambda dx, dy: out.append((dx, dy))
    s.begin_ball()
    for i in range(10):
        now[0] = i * 0.008
        s.add_ball_delta(0, 10)
        s.frame(now[0])
    s.end_ball()
    t = now[0]
    while s.running and t < 2:
        t += 1 / 120
        now[0] = t
        s.frame(t)
    total = sum(dy for _, dy in out)
    assert total > 100           # the 100 counts plus a glide
    assert not s.running and not s.ball_active
