#!/usr/bin/env python3
"""Glide's launch sounds, synthesized from scratch (pure Python, no packages).

    python3 scripts/make-intro-music.py            -> Resources/IntroMusic.m4a
                                                      Resources/LaunchChime.m4a

IntroMusic (about 8 s) plays once, under the first-launch intro, and is timed
to its picture (LaunchViews.swift):

    0.0  a warm G major-ninth pad swells up out of nothing (the mesh blooms)
    0.6  a soft low "roll" as the trackball ball rolls in
    1.9  the pad lifts to A sus (tension); the scroll ring starts to spin,
         and its ridges tick faster and faster, panning around you
    1.0  a bell arpeggio climbs and quickens all the way up to ...
    3.9  THE MOMENT: "Glide" writes in. A rising whoosh lands on a soft sub
         bloom, a bright bell chord and the pad resolving to D major nine,
         shimmering an octave up and ringing out through a long reverb
    6.4  everything fades as the window's glass dissolves in

LaunchChime (about 1.6 s) goes with the short launch animation: a quick airy
flick and a glassy two-note bell (A5 -> D6) over a soft fifth.

Everything is original: sine/additive oscillators, filtered noise, and a
Freeverb-style reverb, written out below. Output: 44.1 kHz stereo WAV, then
AAC .m4a via macOS's built-in `afconvert` (the WAVs are kept with --wav).
"""
import math
import os
import random
import subprocess
import sys
import tempfile
import wave

SR = 44100
TAU = 2 * math.pi
HERE = os.path.dirname(os.path.abspath(__file__))
RESOURCES = os.path.join(HERE, "..", "Resources")


def hz(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


class Mix:
    """A stereo buffer with helpers to add voices into it."""

    def __init__(self, seconds, seed):
        self.n = int(SR * seconds)
        self.dur = seconds
        self.L = [0.0] * self.n
        self.R = [0.0] * self.n
        self.rng = random.Random(seed)

    # -- envelopes --------------------------------------------------------
    @staticmethod
    def adsr(tt, length, attack, release, curve=1.0):
        """Rises over `attack`, holds, falls over the last `release` of `length`."""
        if tt < 0 or tt > length:
            return 0.0
        a = min(1.0, tt / attack) if attack > 0 else 1.0
        r = min(1.0, (length - tt) / release) if release > 0 else 1.0
        e = min(a, r)
        # Smoothstep for soft corners.
        e = e * e * (3 - 2 * e)
        return e ** curve

    # -- voices -----------------------------------------------------------
    def pad_note(self, midi, start, length, amp, pan, attack, release, bright=0.5, voices=3):
        """A soft additive pad tone: a few detuned voices, each a saw-ish
        stack of harmonics rolled off by `bright` (via a wavetable)."""
        table = wavetable([(1.0 / k) * (bright ** (k - 1)) for k in range(1, 9)])
        size = len(table)
        i0 = max(0, int(start * SR))
        i1 = min(self.n, int((start + length) * SR))
        f = hz(midi)
        detunes = [-0.0045, 0.0, 0.005][:voices] if voices > 1 else [0.0]
        for vi, det in enumerate(detunes):
            inc = f * (1 + det) / SR * size
            phase = self.rng.random() * size
            vpan = min(1.0, max(0.0, pan + (vi - 1) * 0.22))
            gl = math.cos(vpan * math.pi / 2) * amp / len(detunes)
            gr = math.sin(vpan * math.pi / 2) * amp / len(detunes)
            vib_rate = 4.2 + vi * 0.7
            L, R = self.L, self.R
            for i in range(i0, i1):
                tt = i / SR - start
                e = self.adsr(tt, length, attack, release)
                if e <= 0.0:
                    continue
                # A whisper of vibrato keeps it alive.
                phase += inc * (1 + 0.0012 * math.sin(TAU * vib_rate * tt))
                s = table[int(phase) % size] * e
                L[i] += s * gl
                R[i] += s * gr

    def bell(self, midi, start, amp, pan, decay=1.2, bright=1.0):
        """A glassy FM bell: a sine carrier with a decaying 3.5:1 modulator,
        plus a quiet partial an octave and a fifth up."""
        f = hz(midi)
        i0 = max(0, int(start * SR))
        length = min(self.dur - start, decay * 5)
        i1 = min(self.n, i0 + int(length * SR))
        gl = math.cos(pan * math.pi / 2) * amp
        gr = math.sin(pan * math.pi / 2) * amp
        L, R = self.L, self.R
        w = TAU * f / SR
        for i in range(i0, i1):
            k = i - i0
            tt = k / SR
            env = min(1.0, tt / 0.003) * math.exp(-tt / decay)
            if env < 1e-4 and tt > 0.05:
                break
            index = 1.6 * bright * math.exp(-tt * 6)
            s = math.sin(w * k + index * math.sin(w * 3.5 * k))
            s += 0.22 * math.sin(w * 3.0 * k) * math.exp(-tt * 5)
            s *= env
            L[i] += s * gl
            R[i] += s * gr

    def sine(self, start, length, amp, freq_fn, env_fn, pan=0.5):
        """A plain sine whose frequency and envelope are functions of time."""
        i0 = max(0, int(start * SR))
        i1 = min(self.n, int((start + length) * SR))
        gl = math.cos(pan * math.pi / 2) * amp
        gr = math.sin(pan * math.pi / 2) * amp
        phase = 0.0
        for i in range(i0, i1):
            tt = i / SR - start
            phase += TAU * freq_fn(tt) / SR
            s = math.sin(phase) * env_fn(tt)
            self.L[i] += s * gl
            self.R[i] += s * gr

    def noise(self, start, length, amp, cutoff_fn, env_fn, pan_fn=lambda t: 0.5, highpass=0.0):
        """Noise through a two-pole low-pass whose cutoff moves (a whoosh)."""
        i0 = max(0, int(start * SR))
        i1 = min(self.n, int((start + length) * SR))
        rnd = self.rng.random
        y1 = y2 = 0.0
        hp = 0.0
        for i in range(i0, i1):
            tt = i / SR - start
            c = cutoff_fn(tt)
            a = math.exp(-TAU * c / SR)
            x = rnd() * 2 - 1
            y1 = (1 - a) * x + a * y1
            y2 = (1 - a) * y1 + a * y2
            s = y2
            if highpass > 0:
                hp += (s - hp) * (TAU * highpass / SR)
                s -= hp
            s *= env_fn(tt) * amp
            p = pan_fn(tt)
            self.L[i] += s * math.cos(p * math.pi / 2)
            self.R[i] += s * math.sin(p * math.pi / 2)

    def tick(self, start, freq, amp, pan):
        """One ridge of the scroll ring: a tiny damped click with a pitch."""
        i0 = int(start * SR)
        n = int(0.03 * SR)
        gl = math.cos(pan * math.pi / 2) * amp
        gr = math.sin(pan * math.pi / 2) * amp
        w = TAU * freq / SR
        for k in range(n):
            i = i0 + k
            if i >= self.n:
                break
            tt = k / SR
            e = math.exp(-tt * 260) * min(1.0, tt / 0.0006)
            s = (math.sin(w * k) + 0.4 * math.sin(w * 2.7 * k)) * e
            self.L[i] += s * gl
            self.R[i] += s * gr

    # -- effects ----------------------------------------------------------
    def reverb(self, wet, room=0.86, damp=0.32, predelay=0.012):
        """Freeverb-style: eight damped combs and four allpasses per side,
        with slightly different lengths left and right for width."""
        combs = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
        allpasses = [556, 441, 341, 225]
        pre = int(predelay * SR)
        out = []
        for side, src in ((0, self.L), (23, self.R)):
            x = [0.0] * pre + [s * 0.015 for s in src[: self.n - pre]]
            acc = [0.0] * self.n
            for length in combs:
                length += side
                buf = [0.0] * length
                idx = 0
                store = 0.0
                for i in range(self.n):
                    o = buf[idx]
                    store = o * (1 - damp) + store * damp
                    buf[idx] = x[i] + store * room
                    acc[i] += o
                    idx += 1
                    if idx == length:
                        idx = 0
            for length in allpasses:
                length += side
                buf = [0.0] * length
                idx = 0
                for i in range(self.n):
                    b = buf[idx]
                    o = -acc[i] + b
                    buf[idx] = acc[i] + b * 0.5
                    acc[i] = o
                    idx += 1
                    if idx == length:
                        idx = 0
            out.append(acc)
        for i in range(self.n):
            self.L[i] += out[0][i] * wet
            self.R[i] += out[1][i] * wet

    def master(self, fade_in=0.02, fade_out=1.0, peak=0.84, drive=1.3):
        """Fades, a gentle tanh limiter, and normalising to `peak`."""
        top = max(max(abs(s) for s in self.L), max(abs(s) for s in self.R)) or 1.0
        norm = math.tanh(drive)
        for i in range(self.n):
            tt = i / SR
            g = min(1.0, tt / fade_in) * min(1.0, max(0.0, (self.dur - tt) / fade_out)) ** 1.6
            self.L[i] = math.tanh(self.L[i] / top * drive) / norm * peak * g
            self.R[i] = math.tanh(self.R[i] / top * drive) / norm * peak * g

    def write(self, path):
        import struct
        frames = bytearray()
        pack = struct.Struct("<hh").pack
        for l, r in zip(self.L, self.R):
            frames += pack(int(max(-1, min(1, l)) * 32767), int(max(-1, min(1, r)) * 32767))
        with wave.open(path, "wb") as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(bytes(frames))


_tables = {}


def wavetable(weights, size=4096):
    key = tuple(round(w, 6) for w in weights)
    if key not in _tables:
        t = [sum(w * math.sin(TAU * (k + 1) * i / size) for k, w in enumerate(weights)) for i in range(size)]
        top = max(abs(v) for v in t)
        _tables[key] = [v / top for v in t]
    return _tables[key]


# ---------------------------------------------------------------------------
# The intro
# ---------------------------------------------------------------------------

def intro():
    HIT = 3.9
    m = Mix(8.2, seed=2026)

    # Pad, chord 1: G major nine (G2 D3 B3 F#4 A4) swelling out of silence.
    for k, (n, pan) in enumerate([(43, 0.5), (50, 0.3), (59, 0.7), (66, 0.35), (69, 0.65)]):
        m.pad_note(n, 0.0, 2.6, 0.16 if k else 0.2, pan, attack=1.5, release=0.9, bright=0.42)
    # Chord 2: A sus (A2 E3 A3 D4 E4 B4) — the lift, holding its breath.
    for k, (n, pan) in enumerate([(45, 0.5), (52, 0.3), (57, 0.7), (62, 0.4), (64, 0.6), (71, 0.55)]):
        m.pad_note(n, 1.85, HIT - 1.85 + 0.35, 0.14 if k else 0.18, pan, attack=0.8, release=0.4, bright=0.5)
    # Chord 3 (the resolution): D major nine (D2 A2 F#3 C#4 E4 A4 F#5).
    for k, (n, pan) in enumerate([(38, 0.5), (45, 0.45), (54, 0.3), (61, 0.7), (64, 0.38), (69, 0.62), (78, 0.5)]):
        m.pad_note(n, HIT - 0.04, 8.2 - HIT, 0.15 if k else 0.22, pan, attack=0.12, release=3.0, bright=0.55)

    # The ball rolling in: a low, soft rumble that slides from left to centre.
    m.noise(0.55, 1.7, 0.5, cutoff_fn=lambda t: 180 + 120 * t,
            env_fn=lambda t: math.sin(math.pi * min(1.0, t / 1.7)) ** 2,
            pan_fn=lambda t: 0.15 + 0.35 * min(1.0, t / 1.4))

    # The scroll ring spinning up: ridge ticks, faster and faster, circling.
    t = 1.95
    k = 0
    while t < HIT - 0.06:
        p = (t - 1.95) / (HIT - 1.95)
        gap = 0.13 * (1 - p) + 0.028 * p
        pan = 0.5 + 0.42 * math.sin(k * 0.55)
        m.tick(t, 2600 + 900 * p, 0.05 + 0.09 * p, pan)
        t += gap
        k += 1

    # The arpeggio: D major-ish tones climbing, quickening toward the hit.
    arp = [62, 66, 69, 71, 74, 76, 78, 81, 83, 86, 88, 90]
    t = 1.0
    k = 0
    while t < HIT - 0.1:
        p = (t - 1.0) / (HIT - 1.0)
        gap = 0.26 * (1 - p) + 0.085 * p
        note = arp[min(len(arp) - 1, int(p * len(arp)))] if p > 0.15 else arp[k % 3]
        m.bell(note, t, 0.05 + 0.06 * p, 0.25 if k % 2 else 0.75, decay=0.45, bright=0.6)
        t += gap
        k += 1

    # The whoosh: noise through a rising low-pass, sweeping left to right.
    m.noise(1.6, HIT - 1.6 + 1.4, 0.55,
            cutoff_fn=lambda t: (300 + 5200 * min(1.0, t / (HIT - 1.6)) ** 2.6) if t < HIT - 1.6
            else 5500 * math.exp(-(t - (HIT - 1.6)) * 3.2) + 200,
            env_fn=lambda t: (min(1.0, t / (HIT - 1.6)) ** 2.4) if t < HIT - 1.6
            else math.exp(-(t - (HIT - 1.6)) * 4.5),
            pan_fn=lambda t: 0.2 + 0.6 * min(1.0, t / (HIT - 1.6)), highpass=120)

    # THE MOMENT: a soft sub bloom (a sine falling in pitch) ...
    m.sine(HIT, 3.0, 0.55, freq_fn=lambda t: 73.4 * (1 + 0.9 * math.exp(-t * 16)),
           env_fn=lambda t: min(1.0, t / 0.008) * math.exp(-t * 1.6))
    # ... a bright bell chord (D5 A5 C#6 E6 F#6) ...
    for n, amp, pan in [(74, 0.15, 0.5), (81, 0.12, 0.3), (85, 0.09, 0.7), (88, 0.07, 0.42), (90, 0.05, 0.6)]:
        m.bell(n, HIT + 0.004, amp, pan, decay=1.6)
    # ... and a shimmer an octave up, arriving a breath later.
    for n, amp, pan, d in [(86, 0.05, 0.2, 0.09), (93, 0.04, 0.8, 0.14), (98, 0.025, 0.5, 0.2)]:
        m.bell(n, HIT + d, amp, pan, decay=1.3)
    # A last, quiet answer as the tagline lands.
    m.bell(81, 4.85, 0.05, 0.35, decay=1.1, bright=0.5)
    m.bell(86, 5.0, 0.04, 0.65, decay=1.1, bright=0.5)

    m.reverb(wet=0.42)
    m.master(fade_in=0.03, fade_out=1.6, peak=0.84)
    return m


def chime():
    m = Mix(1.7, seed=7)
    # An airy flick: bright noise sweeping across, very short.
    m.noise(0.0, 0.3, 0.35, cutoff_fn=lambda t: 1500 + 9000 * t / 0.3,
            env_fn=lambda t: math.sin(math.pi * min(1.0, t / 0.3)) ** 2,
            pan_fn=lambda t: 0.25 + 0.5 * t / 0.3, highpass=900)
    # A soft fifth underneath (D4 A4), then the bell: A5 -> D6.
    m.pad_note(62, 0.06, 1.5, 0.10, 0.4, attack=0.05, release=1.2, bright=0.4, voices=2)
    m.pad_note(69, 0.06, 1.5, 0.08, 0.6, attack=0.05, release=1.2, bright=0.4, voices=2)
    m.bell(81, 0.08, 0.20, 0.4, decay=0.55)
    m.bell(86, 0.19, 0.22, 0.6, decay=0.7)
    m.bell(93, 0.24, 0.05, 0.5, decay=0.5)
    m.reverb(wet=0.32, room=0.8)
    m.master(fade_in=0.004, fade_out=0.6, peak=0.7)
    return m


def render(m, name, keep_wav):
    os.makedirs(RESOURCES, exist_ok=True)
    wav = os.path.join(RESOURCES if keep_wav else tempfile.gettempdir(), name + ".wav")
    m.write(wav)
    peak = max(max(abs(s) for s in m.L), max(abs(s) for s in m.R))
    print(f"{name}: {m.dur:.2f} s, peak {20 * math.log10(peak):.1f} dBFS")
    out = os.path.join(RESOURCES, name + ".m4a")
    try:
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "160000", wav, out], check=True)
        print(f"  -> {os.path.relpath(out)}")
    except (OSError, subprocess.CalledProcessError) as e:
        print(f"  afconvert failed ({e}); WAV left at {wav}")
        return
    if not keep_wav:
        os.remove(wav)


if __name__ == "__main__":
    keep = "--wav" in sys.argv
    render(intro(), "IntroMusic", keep)
    render(chime(), "LaunchChime", keep)
