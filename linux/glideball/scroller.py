"""Scroll physics: a faithful port of the Mac app's SmoothScroller.swift.

Turns scroll-ring ticks into smooth scrolling. Three modes:

* **native** is handled by the engine (ticks pass straight through).
* **flywheel** (default): each tick pushes the page and exponential friction
  slows it. Constants were measured from Kensington's own driver.
* **follow**: a critically damped spring chases a predicted ring position;
  a real flick launches a macOS-shaped throw, v(t) = v0 * (1 - t/T)^3.

Everything is in *points* (the Mac's scroll unit). Output goes through the
``output(delta, horizontal)`` and ``ball_output(dx, dy)`` callbacks, signed
in macOS scroll direction (positive = wheel up / content down, and for
horizontal, positive = left). The engine converts to Linux hi-res units.

Pure Python, no I/O: the clock is injected so tests and the daemon drive the
exact same code. Keep this file in lockstep with SmoothScroller.swift.
"""

from __future__ import annotations

import math
import time
from typing import Callable, List, Optional, Tuple

THROW_MIN_SPEED = 800.0
THROW_MIN_TICKS = 6
THROW_MAX_SPEED = 12_000.0
UNBOOSTED_TICKS = 3

BALL_POINTS_PER_COUNT = 1.0
BALL_SMOOTHING = 0.016
BALL_GLIDE_WINDOW = 0.06


def _clamp(x: float, lo: float, hi: float) -> float:
    return min(max(x, lo), hi)


def smoothstep(u: float) -> float:
    x = _clamp(u, 0.0, 1.0)
    return x * x * (3 - 2 * x)


def acceleration_multiplier(rate: float, amount: float) -> float:
    g_max = 1 + amount * 8
    return 1 + (g_max - 1) * smoothstep((rate - 8) / 32)


def follow_omega(smoothness: float) -> float:
    return 80 - 55 * _clamp(smoothness, 0.0, 1.0)


def time_constant(smoothness: float) -> float:
    return 1 / follow_omega(smoothness)


def throw_coefficient(throw_amount: float) -> float:
    return 0.035 + _clamp(throw_amount, 0.0, 1.0) * 0.075


def throw_duration(v0: float, throw_amount: float) -> float:
    return throw_coefficient(throw_amount) * math.pow(abs(v0), 1.0 / 3)


def throw_distance(v0: float, throw_amount: float) -> float:
    return abs(v0) * throw_duration(v0, throw_amount) / 4


def fly_tau(glide: float) -> float:
    return 0.04 + _clamp(glide, 0.0, 1.0) * 0.12


def fly_tick_distance(rate: float, distance: float, acceleration: float) -> float:
    return distance + 5.4 * acceleration * math.pow(max(rate - 6, 0.0), 1.3)


def _round_half_away(x: float) -> float:
    """Swift's `.rounded()` (schoolbook: halves away from zero)."""
    return math.copysign(math.floor(abs(x) + 0.5), x)


def _trunc(x: float) -> float:
    return float(math.trunc(x))


IDLE, TRACKING, COASTING, FLYING = range(4)
BALL_IDLE, BALL_ROLLING, BALL_GLIDING = range(3)


class ScrollSettings:
    """The scroll-related fields of the config, as plain attributes."""

    __slots__ = ("scrollMode", "flyDistance", "flyAcceleration", "flyGlide", "smoothScrolling",
                 "scrollDistance", "scrollSmoothness", "scrollAcceleration", "throwEnabled",
                 "throwAmount", "reverseScroll", "shiftScrollsHorizontally", "ballScrollSpeed")

    def __init__(self, **kw):
        defaults = dict(scrollMode="flywheel", flyDistance=4.0, flyAcceleration=0.5, flyGlide=0.35,
                        smoothScrolling=True, scrollDistance=14.0, scrollSmoothness=0.4,
                        scrollAcceleration=0.5, throwEnabled=True, throwAmount=0.4,
                        reverseScroll=False, shiftScrollsHorizontally=True, ballScrollSpeed=1.0)
        defaults.update(kw)
        for k, v in defaults.items():
            setattr(self, k, v)

    @classmethod
    def from_config(cls, cfg: dict) -> "ScrollSettings":
        s = cls()
        for k in cls.__slots__:
            if k in cfg:
                setattr(s, k, cfg[k])
        return s


class SmoothScroller:
    def __init__(self, settings: Optional[ScrollSettings] = None,
                 clock: Callable[[], float] = time.monotonic):
        self.config = settings or ScrollSettings()
        self.clock = clock
        self.output: Optional[Callable[[float, bool], None]] = None
        self.ball_output: Optional[Callable[[float, float], None]] = None
        self.running = False
        self._last_frame = 0.0

        self._mode = IDLE
        self._position = 0.0
        self._speed = 0.0
        self._target = 0.0
        self._emitted = 0.0
        self._direction = 0.0
        self._horizontal = False

        self._window: List[float] = []
        self._intervals: List[float] = []
        self._last_tick = -1_000_000.0
        self._tick_distance = 0.0
        self._rate = 0.0
        self._ticks_in_movement = 0

        self._throw_start = 0.0
        self._throw_from = 0.0
        self._throw_speed = 0.0
        self._throw_duration = 0.0

        self._fly_ticks: List[float] = []

        self._ball_mode = BALL_IDLE
        self._ball_target = [0.0, 0.0]
        self._ball_pos = [0.0, 0.0]
        self._ball_emitted = [0.0, 0.0]
        self._ball_vel = [0.0, 0.0]
        self._ball_recent: List[Tuple[float, float, float]] = []

    # ---- input ---------------------------------------------------------

    def add_ticks(self, ticks: float, horizontal: bool = False, shift: bool = False) -> None:
        """`ticks` is signed in macOS scroll direction (+ = wheel up)."""
        if ticks == 0:
            return
        cfg = self.config
        is_horizontal = horizontal or (cfg.shiftScrollsHorizontally and shift)
        t = -ticks if cfg.reverseScroll else ticks
        direction = 1.0 if t > 0 else -1.0
        count = max(int(_round_half_away(abs(t))), 1)
        now = self.clock()
        turned = direction != self._direction or is_horizontal != self._horizontal

        if cfg.scrollMode == "flywheel":
            self._flywheel_tick(direction, count, is_horizontal, turned, now)
            return

        if self._mode == COASTING:
            if turned:
                self._halt()
                self._last_tick = now
                return
            self._mode = TRACKING
            self._target = self._position
            self._window.clear()
            self._intervals.clear()
            self._ticks_in_movement = UNBOOSTED_TICKS
        if turned:
            self._halt()
        self._direction = direction
        self._horizontal = is_horizontal

        if now - self._last_tick > 0.12:
            self._window.clear()
            self._intervals.clear()
            if self._mode != TRACKING:
                self._ticks_in_movement = 0
        else:
            self._intervals.append(now - self._last_tick)
            if len(self._intervals) > 4:
                self._intervals.pop(0)
        self._last_tick = now
        self._window.extend([now] * count)
        self._window = [w for w in self._window if not (now - w > 0.12)]
        if len(self._window) > 8:
            del self._window[: len(self._window) - 8]
        n = len(self._window)
        measured = (n - 1) / max(now - self._window[0], 0.002 * (n - 1)) if n >= 2 else 0.0
        self._rate = measured if (self._rate == 0 or measured == 0) else self._rate + (measured - self._rate) * 0.4
        self._ticks_in_movement += count

        ramp = min(1.0, max(self._ticks_in_movement - UNBOOSTED_TICKS, 0) / 4)
        gain = 1 + (acceleration_multiplier(self._rate, cfg.scrollAcceleration) - 1) * ramp
        self._tick_distance = cfg.scrollDistance * gain
        distance = count * self._tick_distance

        if not cfg.smoothScrolling:
            self._position += direction * distance
            self._target = self._position
            self._flush()
            return

        self._target += direction * distance
        w = self._prediction_weight()
        self._speed += direction * (1 - w) * follow_omega(cfg.scrollSmoothness) * distance
        self._mode = TRACKING
        self._start()

    # ---- flywheel ------------------------------------------------------

    def _flywheel_tick(self, direction: float, count: int, is_horizontal: bool, turned: bool, now: float) -> None:
        cfg = self.config
        if turned or self._mode != FLYING:
            if turned:
                self._speed = 0.0
            self._fly_ticks.clear()
        self._direction = direction
        self._horizontal = is_horizontal
        self._fly_ticks.extend([now] * count)
        self._fly_ticks = [f for f in self._fly_ticks if not (now - f > 0.15)]
        n = len(self._fly_ticks)
        measured = (n - 1) / max(now - self._fly_ticks[0], 0.004) if n >= 2 else 0.0
        distance = count * fly_tick_distance(measured, cfg.flyDistance, cfg.flyAcceleration)
        if not cfg.smoothScrolling:
            self._position += direction * distance
            self._flush()
            return
        self._speed += direction * distance / fly_tau(cfg.flyGlide)
        self._speed = _clamp(self._speed, -THROW_MAX_SPEED, THROW_MAX_SPEED)
        self._mode = FLYING
        self._start()

    def _fly(self, dt: float) -> None:
        tau = fly_tau(self.config.flyGlide)
        fade = math.exp(-dt / tau)
        self._position += self._speed * tau * (1 - fade)
        self._speed *= fade
        if abs(self._speed) < 15:
            self._position += self._speed * tau
            self._speed = 0.0
            self._mode = IDLE

    def _prediction_weight(self) -> float:
        return smoothstep((self._rate - 5) / 10) * min(1.0, max(self._ticks_in_movement - 1, 0) / 3)

    def _halt(self) -> None:
        self._speed = 0.0
        self._target = self._position
        self._window.clear()
        self._intervals.clear()
        self._ticks_in_movement = 0
        self._mode = IDLE

    def stop_all(self) -> None:
        """Drop all motion without posting more (pause, mode change)."""
        self._halt()
        self._emitted = self._position
        self.cancel_ball()
        self.running = False

    # ---- frame loop ----------------------------------------------------

    def _start(self) -> None:
        if self.running:
            return
        self.running = True
        self._last_frame = 0.0
        self.frame()

    def _stop(self) -> None:
        self.running = False

    def frame(self, at: Optional[float] = None) -> None:
        now = self.clock() if at is None else at
        dt = 1.0 / 120 if self._last_frame == 0 else _clamp(now - self._last_frame, 1.0 / 240, 1.0 / 30)
        self._last_frame = now
        if self._mode == TRACKING:
            self._track(now, dt)
        elif self._mode == COASTING:
            self._coast(now)
        elif self._mode == FLYING:
            self._fly(dt)
        self._ball_frame(dt)
        self._flush()

    def _track(self, now: float, dt: float) -> None:
        cfg = self.config
        since = max(now - self._last_tick, 0.0)
        release_after = _clamp(1.5 / self._rate, 0.025, 0.08) if self._rate > 0 else 0.08
        flick = cfg.throwEnabled and self._qualifies_for_throw()

        w = self._prediction_weight()
        cap = 2.0 if flick else 1.0
        progress = min(self._rate * since, cap)
        predicted = self._target + self._direction * w * self._tick_distance * (progress - 0.5)
        predicted_speed = self._direction * w * self._tick_distance * self._rate if self._rate * since < cap else 0.0

        omega = follow_omega(cfg.scrollSmoothness)
        steps = 4
        h = dt / steps
        for _ in range(steps):
            accel = omega * omega * (predicted - self._position) + 2 * omega * (predicted_speed - self._speed)
            self._speed += accel * h
            if self._speed * self._direction < 0:
                self._speed = 0.0
            self._position += self._speed * h

        if since > release_after and flick:
            ring_speed = self._tick_distance * self._rate
            v0 = min(max(abs(self._speed), ring_speed), THROW_MAX_SPEED)
            self._throw_from = self._position
            self._throw_speed = self._direction * v0
            self._throw_duration = throw_duration(v0, cfg.throwAmount)
            self._throw_start = now
            self._mode = COASTING
            return

        if since > release_after and abs(predicted - self._position) < 0.5 and abs(self._speed) < 5:
            self._target = self._position
            self._speed = 0.0
            self._mode = IDLE

    def _qualifies_for_throw(self) -> bool:
        if (self._ticks_in_movement < THROW_MIN_TICKS or len(self._window) < 4
                or self._tick_distance * self._rate < THROW_MIN_SPEED):
            return False
        if len(self._intervals) >= 4:
            last = self._intervals[-1]
            previous = self._intervals[-4:-1]
            mean = sum(previous) / len(previous)
            if last > mean * 1.3:
                return False
        return True

    def _coast(self, now: float) -> None:
        t = now - self._throw_start
        if t >= self._throw_duration:
            self._position = self._throw_from + self._throw_speed * self._throw_duration / 4
            self._halt()
            return
        left = 1 - t / self._throw_duration
        self._position = self._throw_from + self._throw_speed * self._throw_duration / 4 * (1 - math.pow(left, 4))
        self._speed = self._throw_speed * math.pow(left, 3)

    # ---- output --------------------------------------------------------

    def _flush(self) -> None:
        pending = self._position - self._emitted
        whole = _round_half_away(pending) if self._mode == IDLE else _trunc(pending)
        if whole != 0:
            self._emitted += whole
            self._post(whole)
        if self._mode == IDLE and (self._ball_mode == BALL_IDLE or self._ball_resting()):
            self._stop()

    def _post(self, delta: float) -> None:
        d = int(delta)
        if d != 0 and self.output:
            self.output(float(d), self._horizontal)

    # ---- scrolling with the ball ----------------------------------------

    @property
    def ball_active(self) -> bool:
        return self._ball_mode != BALL_IDLE

    def _ball_resting(self) -> bool:
        return (self._ball_mode == BALL_ROLLING
                and abs(self._ball_target[0] - self._ball_pos[0]) < 0.01
                and abs(self._ball_target[1] - self._ball_pos[1]) < 0.01)

    def begin_ball(self) -> None:
        self._ball_mode = BALL_ROLLING
        self._ball_target = [0.0, 0.0]
        self._ball_pos = [0.0, 0.0]
        self._ball_emitted = [0.0, 0.0]
        self._ball_vel = [0.0, 0.0]
        self._ball_recent.clear()

    def add_ball_delta(self, dx: float, dy: float) -> None:
        if self._ball_mode != BALL_ROLLING or (dx == 0 and dy == 0):
            return
        cfg = self.config
        gain = BALL_POINTS_PER_COUNT * max(cfg.ballScrollSpeed, 0) * (-1 if cfg.reverseScroll else 1)
        x, y = dx * gain, dy * gain
        now = self.clock()
        self._ball_target[0] += x
        self._ball_target[1] += y
        self._ball_recent.append((now, x, y))
        self._ball_recent = [r for r in self._ball_recent if not (now - r[0] > BALL_GLIDE_WINDOW)]
        self._start()

    def end_ball(self, glide: bool = True) -> None:
        if self._ball_mode != BALL_ROLLING:
            return
        now = self.clock()
        self._ball_recent = [r for r in self._ball_recent if not (now - r[0] > BALL_GLIDE_WINDOW)]
        if glide and self.config.smoothScrolling and self._ball_recent:
            w = BALL_GLIDE_WINDOW
            vx = sum(r[1] for r in self._ball_recent) / w
            vy = sum(r[2] for r in self._ball_recent) / w
            v = math.hypot(vx, vy)
            if v > THROW_MAX_SPEED:
                vx *= THROW_MAX_SPEED / v
                vy *= THROW_MAX_SPEED / v
            self._ball_vel = [vx, vy]
        self._ball_recent.clear()
        self._ball_mode = BALL_GLIDING
        self._start()

    def cancel_ball(self) -> None:
        self._ball_mode = BALL_IDLE
        self._ball_vel = [0.0, 0.0]
        self._ball_recent.clear()
        if self._mode == IDLE:
            self._stop()

    def _ball_frame(self, dt: float) -> None:
        if self._ball_mode == BALL_IDLE:
            return
        cfg = self.config
        vel, tgt, pos = self._ball_vel, self._ball_target, self._ball_pos
        if self._ball_mode == BALL_GLIDING and (vel[0] != 0 or vel[1] != 0):
            tau = fly_tau(cfg.flyGlide)
            fade = math.exp(-dt / tau)
            tgt[0] += vel[0] * tau * (1 - fade)
            tgt[1] += vel[1] * tau * (1 - fade)
            vel[0] *= fade
            vel[1] *= fade
            if math.hypot(vel[0], vel[1]) < 15:
                tgt[0] += vel[0] * tau
                tgt[1] += vel[1] * tau
                vel[0] = vel[1] = 0.0
        a = 1 - math.exp(-dt / BALL_SMOOTHING) if cfg.smoothScrolling else 1.0
        pos[0] += (tgt[0] - pos[0]) * a
        pos[1] += (tgt[1] - pos[1]) * a
        if self._ball_resting():
            pos[0], pos[1] = tgt[0], tgt[1]
        if (self._ball_mode == BALL_GLIDING and vel[0] == 0 and vel[1] == 0
                and abs(tgt[0] - pos[0]) < 0.5 and abs(tgt[1] - pos[1]) < 0.5):
            pos[0], pos[1] = tgt[0], tgt[1]
            self._ball_mode = BALL_IDLE
        px, py = pos[0] - self._ball_emitted[0], pos[1] - self._ball_emitted[1]
        idle = self._ball_mode == BALL_IDLE
        wx = _round_half_away(px) if idle else _trunc(px)
        wy = _round_half_away(py) if idle else _trunc(py)
        if wx != 0 or wy != 0:
            self._ball_emitted[0] += wx
            self._ball_emitted[1] += wy
            if self.ball_output:
                self.ball_output(wx, wy)
