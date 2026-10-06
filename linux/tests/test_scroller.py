"""The Python scroll physics must match the Swift SmoothScroller frame for frame.

fixtures/scroll_golden.json is produced by linux/tools/make-golden.sh, which
compiles the real Sources/Glide/SmoothScroller.swift with the scenarios from
scripts/scroll-sim/main.swift (jitter-free, so they're deterministic).
"""

import json
import math
import os

import pytest

from glideball import scroller as sc
from glideball.scroller import ScrollSettings, SmoothScroller

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")
GOLDEN = json.load(open(os.path.join(FIXTURES, "scroll_golden.json")))
# The goldens from before Fast-spin reach existed (the old hard 12,000 pt/s limit).
PRE_REACH = json.load(open(os.path.join(FIXTURES, "scroll_golden_pre_reach.json")))


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


def spin(rate, count, start=0.05):
    """Ring ticks at `rate` per second, snapped to 8 ms like the Swift sim."""
    return [round((start + i / rate) / 0.008) * 0.008 for i in range(count)]


def distance(rate, count, reach):
    ticks = spin(rate, count)
    return sum(simulate("flywheel", ticks, [1] * count, 3.0, flyReach=reach))


def check_frames(frames, expected):
    assert len(frames) == len(expected)
    # Same libm on the same platform gives identical results; allow a 1-point
    # rounding flip per frame elsewhere (glibc vs Darwin pow/exp ulps).
    assert abs(sum(frames) - sum(expected)) <= 1
    assert all(abs(a - b) <= 1 for a, b in zip(frames, expected))
    mismatches = sum(1 for a, b in zip(frames, expected) if a != b)
    assert mismatches <= 2


@pytest.mark.parametrize("case", GOLDEN, ids=[f'{c["mode"]}-{c["name"]}' for c in GOLDEN])
def test_matches_swift(case):
    frames = simulate(case["mode"], case["ticks"], case["dirs"], case["until"],
                      flyReach=case.get("flyReach", 0.5))
    check_frames(frames, case["frames"])


@pytest.mark.parametrize("case", PRE_REACH, ids=[f'{c["mode"]}-{c["name"]}' for c in PRE_REACH])
def test_reach_zero_is_the_old_hard_cap(case):
    # Reach 0 must behave exactly like the Swift scroller did before the feature.
    frames = simulate(case["mode"], case["ticks"], case["dirs"], case["until"], flyReach=0.0)
    check_frames(frames, case["frames"])


def test_golden_has_the_reach_scenarios():
    names = {c["name"] for c in GOLDEN}
    for reach in ("0.0", "0.5"):
        for what in ("20 ticks @ 45 t/s", "20 ticks @ 100 t/s", "30 ticks @ 130 t/s"):
            assert f"reach {reach}: {what}" in names
    old = {(c["mode"], c["name"]) for c in PRE_REACH}
    assert old <= {(c["mode"], c["name"]) for c in GOLDEN}


def test_gentle_spins_ignore_reach():
    # A slow spin never reaches 12,000 pt/s, so reach can't matter.
    a = simulate("flywheel", spin(7, 10), [1] * 10, 2.2, flyReach=0.0)
    b = simulate("flywheel", spin(7, 10), [1] * 10, 2.2, flyReach=1.0)
    assert a == b


def test_fast_spin_goes_farther_with_reach():
    slow, fast = distance(45, 20, 0.5), distance(100, 20, 0.5)
    assert fast > slow * 1.15
    # With the old hard cap a harder spin gains (almost) nothing.
    assert distance(100, 20, 0.0) < distance(45, 20, 0.0) * 1.15
    assert distance(100, 20, 0.5) > distance(100, 20, 0.0)
    assert distance(100, 20, 1.0) > distance(100, 20, 0.5)


def test_fly_speed_is_continuous_at_the_knee_and_bounded():
    knee = sc.FLY_KNEE
    for reach in (0.0, 0.25, 0.5, 1.0):
        assert sc.fly_speed(knee, reach) == knee
        assert sc.fly_speed(knee + 1e-6, reach) == pytest.approx(knee, abs=1e-3)
        assert sc.fly_speed(-knee - 1e-6, reach) == pytest.approx(-knee, abs=1e-3)
        assert sc.fly_speed(-5000, reach) == -5000
        assert sc.fly_speed(1e9, reach) <= knee + reach * sc.FLY_HEADROOM + 1e-6
        assert sc.fly_speed(-1e9, reach) == pytest.approx(-sc.fly_speed(1e9, reach))
        assert sc.fly_speed(knee * 2, reach) <= sc.fly_speed(knee * 3, reach)
        if reach > 0:    # slope 1 at the knee: no kink
            assert sc.fly_speed(knee + 1, reach) - knee == pytest.approx(1, abs=1e-3)
    assert sc.fly_speed(1e9, 0.0) == knee and sc.fly_speed(-1e9, 0.0) == -knee
    assert sc.fly_speed(30_000, 0.5) == pytest.approx(12_000 + 30_000 * (1 - math.exp(-18_000 / 30_000)))


def test_coast_stretch():
    assert sc.fly_coast_stretch(50_000, 0.0) == 1
    assert sc.fly_coast_stretch(12_000, 1.0) == 1
    assert sc.fly_coast_stretch(72_000, 1.0) == pytest.approx(1.8)
    assert sc.fly_coast_stretch(-72_000, 0.5) == pytest.approx(1.4)


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
