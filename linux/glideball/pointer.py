"""Pointer speed: gain plus an acceleration curve on the trackball's counts.

On macOS Glideball writes a tracking speed (0.5...80) to the device's HID
service and macOS applies its curve. On Linux the device is grabbed, so the
curve is applied here, mirroring the Mac's response curve
(PointerView.cursorSpeed):

    cursor = ball * (1 + t * 0.55 * ball^0.8)          (ball in inches/second)

Sub-pixel remainders are kept so slow motion stays smooth.
"""

from __future__ import annotations

import math

COUNTS_PER_INCH = 400.0     # Expert Mouse sensor resolution
MIN_DT = 0.002
MAX_DT = 0.05               # a pause longer than this starts from rest
SPEED_MIN, SPEED_MAX = 0.5, 80.0

PRESETS = [("Precise", 1.5), ("macOS", 3.0), ("Fast", 5.0), ("Turbo", 7.5)]   # Components.swift


def cursor_speed(ball: float, tracking: float) -> float:
    """The Mac's response curve (both in inches/second)."""
    return ball * (1 + tracking * 0.55 * math.pow(max(ball, 0.0), 0.8))


def gain(ball: float, tracking: float) -> float:
    return 1 + max(tracking, 0.0) * 0.55 * math.pow(max(ball, 0.0), 0.8)


class PointerAccel:
    def __init__(self):
        self.rx = 0.0
        self.ry = 0.0
        self.last_t = None
        self.ball_speed = 0.0     # inches / second, smoothed (for the GUI graph)

    def reset(self):
        self.rx = self.ry = 0.0
        self.last_t = None

    def process(self, dx: float, dy: float, now: float, tracking: float):
        """Returns whole (ix, iy) to emit."""
        if dx == 0 and dy == 0:
            return 0, 0
        if self.last_t is None or now - self.last_t > MAX_DT:
            dt = 1 / 125.0              # USB polling interval
            self.rx = self.ry = 0.0
        else:
            dt = max(now - self.last_t, MIN_DT)
        self.last_t = now
        v = math.hypot(dx, dy) / COUNTS_PER_INCH / dt
        self.ball_speed += (v - self.ball_speed) * 0.3
        g = gain(v, tracking)
        self.rx += dx * g
        self.ry += dy * g
        ix, iy = int(self.rx), int(self.ry)   # toward zero
        self.rx -= ix
        self.ry -= iy
        return ix, iy
