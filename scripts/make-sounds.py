#!/usr/bin/env python3
"""Glideball's interface sounds ("glass marble"), synthesized from scratch.

    python3 scripts/make-sounds.py     -> Resources/Sounds/*.caf

Pure standard library (wave, math, struct, array); deterministic: the same
bytes every run. Each sound is rendered to 44.1 kHz 16-bit stereo WAV in a
temp dir, checked numerically (the table printed at the end, with asserts),
then converted with macOS's `afconvert` to 16-bit PCM CAF.

Why CAF/PCM rather than AAC .m4a: AAC adds encoder priming (~2000 samples,
about 47 ms) that AVAudioPlayer has to trim via metadata, and any miss there
is a late or clicky start on a 0.12 s tick. PCM has no priming and no decode
step, so playback starts the instant the buffer does. The whole set is about
0.5 MB, so there is nothing to save by compressing.

The voice: a sine fundamental, a quieter partial at 4x (marimba-like) that
dies about 3x faster, and a very quiet partial at 9.2x that dies faster still;
a 2-4 ms raised-cosine attack; exponential decay; 1 cent of detune plus 0.3 ms
of offset between the channels for a little width; two faint early reflections
(about -18 dB, 20-45 ms, different per ear) so it is not dry; a short fade so
every file ends on exactly zero; a DC-free result; peak level per file.

Notes are D major pentatonic: D5 587.33, E5 659.25, F#5 739.99, A5 880.00,
B5 987.77, D6 1174.66 (and D4 / A4 an octave down for warmth).

    resume        A5 then D6                        up, "on"
    pause         D6 then A5 (softer)               down, "off"
    mode-on       one D6 tick                       high tick
    mode-off      one A5 tick, a little softer      low tick
    tick          F#5, very short and soft          assigned / saved
    milestone     D5 F#5 A5 rise
    milestone-big D5 F#5 A5 B5 D6 bloom, last rings (+ a D5 under it)
    hello         D4 + A4 + F#5, gently rolled
"""
import array
import hashlib
import math
import os
import shutil
import subprocess
import sys
import tempfile
import wave

SR = 44100
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources", "Sounds")

D4, A4 = 293.66, 440.00
D5, E5, FS5, A5, B5, D6 = 587.33, 659.25, 739.99, 880.00, 987.77, 1174.66

# The voice
P4_AMP, P4_DECAY = 0.28, 1 / 3      # 4x partial: relative level, decay-time ratio
P9_AMP, P9_DECAY = 0.06, 1 / 5      # 9.2x partial
DETUNE_CENTS = 0.5                  # +/- per channel = 1 cent between ears
EAR_OFFSET = 0.0003                 # right channel starts 0.3 ms late
TAPS_L = ((0.023, 10 ** (-18 / 20)), (0.041, 10 ** (-22 / 20)))   # early reflections
TAPS_R = ((0.029, 10 ** (-18 / 20)), (0.037, 10 ** (-22 / 20)))
END_FADE = 0.020                    # seconds


def note(t0, freq, amp=1.0, tau=0.07, attack=0.003):
    return dict(t0=t0, f=freq, amp=amp, tau=tau, attack=attack)


# name: (duration s, notes, target peak dBFS, max duration allowed)
SOUNDS = {
    "resume": (0.38, [note(0.00, A5, 0.90), note(0.09, D6, 1.00)], -14.0, 0.40),
    "pause": (0.38, [note(0.00, D6, 1.00), note(0.09, A5, 0.62, tau=0.065)], -14.0, 0.40),
    "mode-on": (0.18, [note(0.00, D6, 1.00, tau=0.040)], -14.0, 0.40),
    "mode-off": (0.19, [note(0.00, A5, 1.00, tau=0.045)], -15.5, 0.40),
    "tick": (0.12, [note(0.00, FS5, 1.00, tau=0.025, attack=0.0025)], -18.0, 0.15),
    "milestone": (0.70, [note(0.00, D5, 0.80, tau=0.11),
                         note(0.12, FS5, 0.90, tau=0.11),
                         note(0.24, A5, 1.00, tau=0.11)], -13.0, 0.70),
    "milestone-big": (1.20, [note(0.00, D5, 0.70, tau=0.12),
                             note(0.10, FS5, 0.78, tau=0.12),
                             note(0.20, A5, 0.86, tau=0.12),
                             note(0.30, B5, 0.94, tau=0.13),
                             note(0.40, D6, 1.00, tau=0.20),
                             note(0.40, D5, 0.42, tau=0.20)], -12.0, 1.20),
    "hello": (1.20, [note(0.00, D4, 1.00, tau=0.27, attack=0.004),
                     note(0.07, A4, 0.80, tau=0.27, attack=0.004),
                     note(0.14, FS5, 0.55, tau=0.27, attack=0.004)], -14.0, 1.20),
}


def render_note(buf, n, side):
    """Add one note into buf (one channel). side: -1 left, +1 right."""
    cents = side * -DETUNE_CENTS            # left sharp, right flat
    detune = 2 ** (cents / 1200)
    t0 = n["t0"] + (EAR_OFFSET if side > 0 else 0.0)
    start = int(round(t0 * SR))
    f, tau, atk = n["f"] * detune, n["tau"], n["attack"]
    partials = ((1.0, 1.0, tau), (4.0, P4_AMP, tau * P4_DECAY), (9.2, P9_AMP, tau * P9_DECAY))
    natk = max(1, int(round(atk * SR)))
    for i in range(start, len(buf)):
        t = (i - start) / SR
        env = 0.5 * (1 - math.cos(math.pi * (i - start) / natk)) if (i - start) < natk else 1.0
        s = 0.0
        for mult, a, tp in partials:
            s += a * math.exp(-t / tp) * math.sin(2 * math.pi * f * mult * t)
        buf[i] += n["amp"] * env * s


def synth(duration, notes, target_db):
    n = int(round(duration * SR))
    chans = []
    for side in (-1, +1):
        dry = [0.0] * n
        for nt in notes:
            render_note(dry, nt, side)
        wet = dry[:]
        for delay, gain in (TAPS_L if side < 0 else TAPS_R):
            d = int(round(delay * SR))
            for i in range(d, n):
                wet[i] += gain * dry[i - d]
        chans.append(wet)

    # exact zero at the end: a raised-cosine fade over the last END_FADE seconds
    nf = int(round(END_FADE * SR))
    for ch in chans:
        for k in range(nf):
            i = n - nf + k
            ch[i] *= 0.5 * (1 + math.cos(math.pi * (k + 1) / nf)) if k + 1 < nf else 0.0
        ch[-1] = 0.0
        ch[0] = 0.0

    # DC-free without disturbing the zero ends: subtract a Hann-shaped bump
    # (about 3-5 Hz, inaudible) scaled so the mean is exactly zero.
    for ch in chans:
        mean = sum(ch) / n
        hann = [0.5 * (1 - math.cos(2 * math.pi * i / (n - 1))) for i in range(n)]
        scale = mean / (sum(hann) / n)
        for i in range(n):
            ch[i] -= scale * hann[i]

    peak = max(max(abs(x) for x in ch) for ch in chans)
    gain = 10 ** (target_db / 20) / peak
    return [[x * gain for x in ch] for ch in chans]


def write_wav(path, chans):
    n = len(chans[0])
    data = array.array("h")
    for i in range(n):
        for ch in chans:
            data.append(max(-32768, min(32767, int(round(ch[i] * 32767)))))
    if sys.byteorder == "big":
        data.byteswap()
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())


def read_wav(path):
    with wave.open(path, "rb") as w:
        assert w.getnchannels() == 2 and w.getsampwidth() == 2 and w.getframerate() == SR
        raw = w.readframes(w.getnframes())
    data = array.array("h")
    data.frombytes(raw)
    if sys.byteorder == "big":
        data.byteswap()
    return [data[0::2], data[1::2]]


def db(x):
    return 20 * math.log10(x) if x > 0 else -999.0


def analyse(chans):
    n = len(chans[0])
    peak = max(max(abs(x) for x in ch) for ch in chans) / 32768
    rms = math.sqrt(sum(x * x for ch in chans for x in ch) / (2 * n)) / 32768
    dc = max(abs(sum(ch) / n) for ch in chans) / 32768
    # level just before the end fade starts, relative to the peak (is it decayed?)
    nf = int(round(END_FADE * SR))
    pre = max(abs(ch[n - nf - 1]) for ch in chans) / 32768
    # first/last audible-level jump (click check): biggest sample step in the fade
    return dict(dur=n / SR, peak=db(peak), rms=db(rms), dc=dc,
                first=tuple(ch[0] for ch in chans), last=tuple(ch[-1] for ch in chans),
                tail=db(pre) - db(peak))


def main():
    os.makedirs(OUT, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="glide-sounds-")
    rows = []
    try:
        for name, (dur, notes, target, max_dur) in SOUNDS.items():
            wav = os.path.join(tmp, name + ".wav")
            write_wav(wav, synth(dur, notes, target))
            caf = os.path.join(OUT, name + ".caf")
            if os.path.exists(caf):
                os.remove(caf)
            subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16", "-c", "2", wav, caf], check=True)
            rows.append((name, max_dur, target, analyse(read_wav(wav)), caf))

        print(f"{'file':<14}{'dur s':>7}{'peak':>8}{'rms':>8}{'DC':>10}{'first':>9}{'last':>9}{'tail':>8}  bytes")
        for name, max_dur, target, r, caf in rows:
            print(f"{name:<14}{r['dur']:>7.3f}{r['peak']:>8.2f}{r['rms']:>8.2f}{r['dc']:>10.2e}"
                  f"{str(r['first'][0]) + '/' + str(r['first'][1]):>9}"
                  f"{str(r['last'][0]) + '/' + str(r['last'][1]):>9}{r['tail']:>8.1f}  {os.path.getsize(caf)}")
        print("(peak/rms in dBFS; DC as fraction of full scale; tail = dB below peak when the end fade begins)")

        for name, max_dur, target, r, caf in rows:
            assert r["dur"] <= max_dur + 1e-9, f"{name}: {r['dur']:.3f} s > {max_dur} s"
            assert abs(r["peak"] - target) < 0.2, f"{name}: peak {r['peak']:.2f} vs {target}"
            assert -19 <= r["peak"] <= -11.5, f"{name}: peak {r['peak']:.2f} out of range"
            assert r["dc"] < 2e-5, f"{name}: DC {r['dc']}"
            assert r["first"] == (0, 0) and r["last"] == (0, 0), f"{name}: doesn't start/end at zero"
            assert r["tail"] < -28, f"{name}: still ringing at {r['tail']:.1f} dB when the fade starts"
        print("All limits hold.")

        digest = hashlib.sha256()
        for name, *_rest, caf in rows:
            with open(caf, "rb") as f:
                digest.update(f.read())
        print("set sha256:", digest.hexdigest()[:16])
        for name, *_rest, caf in rows:
            info = subprocess.run(["afinfo", caf], capture_output=True, text=True, check=True).stdout
            keep = [l.strip() for l in info.splitlines()
                    if l.startswith(("File:", "File type", "Data format", "estimated duration"))]
            print(f"\n{name}.caf\n  " + "\n  ".join(keep))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
