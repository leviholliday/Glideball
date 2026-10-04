"""The background daemon: grab the Kensington, run the engine, emit via uinput.

Safety rules (the mouse must never be left dead):

* Only devices ``devices.is_supported`` accepts are ever grabbed.
* The kernel drops an EVIOCGRAB the moment this process dies, so a crash
  hands the trackball straight back to the desktop.
* If anything throws while handling an event, the daemon releases every
  held key/button, ungrabs, and passes events through (the desktop gets the
  raw device) until settings change or ``glideball ctl resume``.
* SIGTERM / SIGINT: release held keys and buttons, ungrab, exit.
* Paused (``enabled: false``, Ctrl+Alt+Super+G): ungrabbed entirely.
"""

from __future__ import annotations

import errno
import glob
import json
import logging
import os
import selectors
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import traceback
from typing import Dict, Optional

from . import backup as backupmod
from . import config as cfgmod
from . import devices, ipc, keymap
from .engine import Engine, Output

log = logging.getLogger("glideball")

# evdev constants (linux/input-event-codes.h) so this module reads without evdev
EV_SYN, EV_KEY, EV_REL = 0x00, 0x01, 0x02
SYN_REPORT = 0
REL_X, REL_Y, REL_HWHEEL, REL_WHEEL = 0x00, 0x01, 0x06, 0x08
REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES = 0x0B, 0x0C
BTN_LEFT, BTN_TASK = 0x110, 0x117

SETTINGS_POLL = 0.5
HOTPLUG_POLL = 1.0
BACKUP_POLL = 30 * 60


class UInputOutput(Output):
    """Two virtual devices: a pointer and a keyboard (libinput handles a
    split pair more predictably than one combined device)."""

    def __init__(self):
        import evdev
        from evdev import ecodes as e
        self._e = e
        self.pointer = evdev.UInput(
            {e.EV_KEY: list(range(BTN_LEFT, BTN_TASK + 1)),
             e.EV_REL: [REL_X, REL_Y, REL_HWHEEL, REL_WHEEL, REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES]},
            name=devices.VIRTUAL_DEVICE_NAME, vendor=0x1209, product=0x6762, version=1)
        self.keyboard = evdev.UInput({e.EV_KEY: keymap.ALL_KEY_CODES},
                                     name="Glideball Virtual Keyboard", vendor=0x1209, product=0x6763, version=1)
        self._dirty_p = self._dirty_k = False

    def rel(self, dx, dy):
        if dx:
            self.pointer.write(EV_REL, REL_X, dx)
        if dy:
            self.pointer.write(EV_REL, REL_Y, dy)
        self._dirty_p = True

    def button(self, n, down):
        self.pointer.write(EV_KEY, BTN_LEFT + n, 1 if down else 0)
        self._dirty_p = True

    def key(self, code, down):
        self.keyboard.write(EV_KEY, code, 1 if down else 0)
        self._dirty_k = True
        self.sync()   # keys must land in order relative to clicks

    def wheel(self, v, v_hi, h, h_hi):
        if v_hi:
            self.pointer.write(EV_REL, REL_WHEEL_HI_RES, v_hi)
        if v:
            self.pointer.write(EV_REL, REL_WHEEL, v)
        if h_hi:
            self.pointer.write(EV_REL, REL_HWHEEL_HI_RES, h_hi)
        if h:
            self.pointer.write(EV_REL, REL_HWHEEL, h)
        self._dirty_p = True

    def sync(self):
        if self._dirty_p:
            self.pointer.syn()
            self._dirty_p = False
        if self._dirty_k:
            self.keyboard.syn()
            self._dirty_k = False

    def close(self):
        for d in (self.pointer, self.keyboard):
            try:
                d.close()
            except Exception:
                pass


def sysfs_vendor(path: str) -> Optional[int]:
    """The USB/Bluetooth vendor of /dev/input/eventN, from sysfs, without opening it."""
    try:
        with open(f"/sys/class/input/{os.path.basename(path)}/device/id/vendor") as f:
            return int(f.read().strip(), 16)
    except (OSError, ValueError):
        return None


class Tracked:
    def __init__(self, dev, kind: str):
        self.dev = dev
        self.kind = kind
        self.grabbed = False
        self.dx = 0
        self.dy = 0

    @property
    def info(self) -> dict:
        i = self.dev.info
        return {"path": self.dev.path, "name": devices.display_name(i.vendor, i.product, self.dev.name),
                "vendor": i.vendor, "product": i.product, "kind": self.kind, "grabbed": self.grabbed}


class Daemon:
    def __init__(self, settings_path: Optional[str] = None, output: Optional[Output] = None):
        self.settings_path = settings_path or cfgmod.settings_path()
        self.local = cfgmod.load_local()
        self.data = cfgmod.load(self.settings_path)
        self._settings_stamp = self._stamp()
        self.out = output or UInputOutput()
        self.engine = Engine(cfgmod.config_of(self.data), self.out,
                             points_per_notch=float(self.local["pointsPerNotch"]))
        self.frame_interval = 1.0 / max(30.0, min(float(self.local["frameRate"]), 360.0))
        self.devices: Dict[str, Tracked] = {}
        self.ignored: set = set()
        self.failed: Optional[str] = None
        self.sel = selectors.DefaultSelector()
        self.server = None
        self.stop = False
        self.learned = None
        self.backups = backupmod.BackupStore()
        self._last_hotplug = 0.0
        self._last_settings = 0.0
        self._last_backup = 0.0

    # ---- settings ----------------------------------------------------------

    def _stamp(self):
        try:
            st = os.stat(self.settings_path)
            return (st.st_mtime_ns, st.st_size)
        except OSError:
            return None

    @property
    def enabled(self) -> bool:
        return self.engine.cfg.enabled

    def reload_settings(self, force: bool = False) -> None:
        stamp = self._stamp()
        if not force and stamp == self._settings_stamp:
            return
        self._settings_stamp = stamp
        if stamp is None:
            return
        try:
            with open(self.settings_path, encoding="utf-8") as f:
                data = cfgmod.parse_file(f.read())
        except (OSError, cfgmod.SettingsError) as e:
            log.warning("settings not reloaded: %s", e)   # keep running on the last good ones
            return
        self.data = data
        self.engine.update(cfgmod.config_of(data))
        new_local = cfgmod.load_local()
        if new_local["betaProgram"] != self.local["betaProgram"]:
            self.local = new_local
            self.rescan(drop_unsupported=True)
        self.local = new_local
        self.engine.points_per_notch = float(self.local["pointsPerNotch"])
        if self.failed:
            log.info("settings changed: leaving pass-through mode")
            self.failed = None
        self.apply_grabs()

    def set_enabled(self, on: bool) -> None:
        latest = cfgmod.load(self.settings_path)
        latest = cfgmod.with_changes(latest, enabled=on)
        cfgmod.save(latest, self.settings_path)
        self.reload_settings(force=True)

    # ---- devices ------------------------------------------------------------

    def rescan(self, drop_unsupported: bool = False) -> None:
        import evdev
        beta = bool(self.local["betaProgram"])
        present = set(glob.glob("/dev/input/event*"))
        for path in list(self.devices):
            if path not in present:
                self._drop(path)
        if drop_unsupported:
            self.ignored.clear()
            for path, t in list(self.devices.items()):
                i = t.dev.info
                if not devices.is_supported(i.vendor, i.product, t.dev.name, beta):
                    self._drop(path)
        for path in sorted(present):
            if path in self.devices or path in self.ignored:
                continue
            if sysfs_vendor(path) not in (None, devices.KENSINGTON_VENDOR_ID):
                self.ignored.add(path)   # other brands are never even opened
                continue
            try:
                dev = evdev.InputDevice(path)
            except OSError:
                continue   # no permission (not a Kensington, by the udev rule) or gone
            i = dev.info
            ok = devices.is_supported(i.vendor, i.product, dev.name, beta) and \
                devices.is_pointer(dev.capabilities(absinfo=False))
            if not ok:
                dev.close()
                self.ignored.add(path)
                continue
            t = Tracked(dev, devices.kind(i.vendor, i.product, dev.name))
            self.devices[path] = t
            self.sel.register(dev.fd, selectors.EVENT_READ, ("dev", path))
            log.info("found %s at %s", t.info["name"], path)
            self._grab(t)
        self.ignored &= present

    def _drop(self, path: str) -> None:
        t = self.devices.pop(path, None)
        if t is None:
            return
        try:
            self.sel.unregister(t.dev.fd)
        except (KeyError, ValueError, OSError):
            pass
        try:
            t.dev.close()
        except OSError:
            pass
        log.info("removed %s", path)
        if not self.devices:
            self.engine.release_all()   # unplugged mid-press: let go of everything

    def _grab(self, t: Tracked) -> None:
        if t.grabbed or not self.enabled or self.failed:
            return
        try:
            t.dev.grab()
            t.grabbed = True
        except OSError as e:
            log.warning("could not grab %s (%s); leaving it to the desktop", t.dev.path, e)

    def _ungrab(self, t: Tracked) -> None:
        if not t.grabbed:
            return
        try:
            t.dev.ungrab()
        except OSError:
            pass
        t.grabbed = False
        t.dx = t.dy = 0

    def apply_grabs(self) -> None:
        active = self.enabled and not self.failed
        if not active:
            self.engine.release_all()
        for t in self.devices.values():
            self._grab(t) if active else self._ungrab(t)

    def ungrab_all(self) -> None:
        for t in self.devices.values():
            self._ungrab(t)

    # ---- events ---------------------------------------------------------------

    def _read(self, path: str) -> None:
        t = self.devices.get(path)
        if t is None:
            return
        try:
            events = list(t.dev.read())
        except BlockingIOError:
            return
        except OSError as e:
            if e.errno in (errno.ENODEV, errno.EIO, errno.EBADF):
                self._drop(path)
                return
            raise
        if not t.grabbed:
            return   # paused / pass-through: the desktop already got these
        try:
            for ev in events:
                self.handle(t, ev.type, ev.code, ev.value)
        except Exception:
            self.fail(traceback.format_exc())

    def handle(self, t: Tracked, type_: int, code: int, value: int) -> None:
        e = self.engine
        if type_ == EV_REL:
            if code == REL_X:
                t.dx += value
            elif code == REL_Y:
                t.dy += value
            elif code == REL_WHEEL:
                e.wheel(value)
            elif code == REL_HWHEEL:
                e.wheel(value, horizontal=True)
            # *_HI_RES from the device are ignored: the kernel mirrors REL_WHEEL
        elif type_ == EV_KEY:
            if BTN_LEFT <= code <= BTN_TASK and value in (0, 1):
                if t.dx or t.dy:
                    e.motion(t.dx, t.dy)
                    t.dx = t.dy = 0
                e.button(code - BTN_LEFT, value == 1)
        elif type_ == EV_SYN and code == SYN_REPORT:
            if t.dx or t.dy:
                e.motion(t.dx, t.dy)
                t.dx = t.dy = 0
            self.out.sync()

    def fail(self, why: str) -> None:
        """Something broke: never leave the user without a mouse."""
        log.error("engine error, passing the trackball through untouched:\n%s", why)
        self.failed = why.strip().splitlines()[-1] if why.strip() else "error"
        try:
            self.engine.release_all()
        except Exception:
            log.exception("release_all failed")
        self.ungrab_all()

    # ---- IPC ------------------------------------------------------------------------

    def status(self) -> dict:
        e = self.engine
        return {"ok": True, "enabled": self.enabled, "failed": self.failed,
                "devices": [t.info for t in self.devices.values()],
                "modes": e.modes, "stats": dict(e.stats), "ballSpeed": e.pointer.ball_speed,
                "betaProgram": bool(self.local["betaProgram"]),
                "learned": sorted(self.learned) if self.learned is not None else None}

    def command(self, msg: dict) -> dict:
        cmd = msg.get("cmd")
        if cmd == "status":
            return self.status()
        if cmd in ("pause", "resume", "toggle-pause"):
            on = {"pause": False, "resume": True}.get(cmd, not self.enabled)
            if cmd == "resume" and self.failed:
                self.failed = None
            self.set_enabled(on)
            return self.status()
        if cmd == "toggle-mode":
            self.engine.toggle_mode(str(msg.get("mode")))
            return self.status()
        if cmd == "learn":
            self.learned = None
            self.engine.learn_next_press(lambda s: setattr(self, "learned", s))
            return {"ok": True}
        if cmd == "learn-cancel":
            self.engine.learn_next_press(None)
            return {"ok": True}
        if cmd == "reload":
            self.local = cfgmod.load_local()
            self.rescan(drop_unsupported=True)
            self.reload_settings(force=True)
            return self.status()
        return {"ok": False, "error": f"unknown command {cmd!r}"}

    # ---- main loop ---------------------------------------------------------------------

    def run(self) -> int:
        rfd, wfd = os.pipe()
        os.set_blocking(wfd, False)
        os.set_blocking(rfd, False)
        signal.set_wakeup_fd(wfd)
        for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(s, self._on_signal)
        self.sel.register(rfd, selectors.EVENT_READ, ("signal", None))
        self.server = ipc.Server(self.sel, self.command)
        self._maybe_backup(force=True)
        self.rescan()
        self._flat_profile_x11()
        log.info("running; %d trackball(s)", len(self.devices))
        try:
            while not self.stop:
                self.loop_once()
        finally:
            self.shutdown()
        return 0

    def _on_signal(self, signum, frame):
        if signum == signal.SIGHUP:
            self._settings_stamp = None
            return
        self.stop = True

    def loop_once(self) -> None:
        now = time.monotonic()
        deadline = self.engine.next_deadline(self.frame_interval)
        timeout = SETTINGS_POLL if deadline is None else max(0.0, min(deadline - now, SETTINGS_POLL))
        for key, _ in self.sel.select(timeout):
            kind, arg = key.data
            if kind == "dev":
                self._read(arg)
            elif kind == "signal":
                try:
                    os.read(key.fd, 512)
                except OSError:
                    pass
            else:
                self.server.handle(key)
        try:
            if any(t.grabbed for t in self.devices.values()):
                self.engine.poll(time.monotonic(), self.frame_interval)
        except Exception:
            self.fail(traceback.format_exc())
        now = time.monotonic()
        if now - self._last_settings >= SETTINGS_POLL:
            self._last_settings = now
            self.reload_settings()
        if now - self._last_hotplug >= HOTPLUG_POLL:
            self._last_hotplug = now
            self.rescan()
        self._maybe_backup()

    def _maybe_backup(self, force: bool = False) -> None:
        now = time.monotonic()
        if not force and now - self._last_backup < BACKUP_POLL:
            return
        self._last_backup = now
        if self.local.get("autoBackups", True):
            try:
                self.backups.snapshot_if_due(cfgmod.config_of(self.data))
            except Exception:
                log.exception("backup failed")

    def _flat_profile_x11(self) -> None:
        """On X11, turn off the desktop's own acceleration for our virtual
        pointer only, so Glideball's curve isn't applied twice."""
        if not os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY") or not shutil.which("xinput"):
            return

        def run():
            time.sleep(1.0)
            name = "pointer:" + devices.VIRTUAL_DEVICE_NAME
            for args in (["libinput Accel Profile Enabled", "0", "1"], ["libinput Accel Speed", "0"]):
                subprocess.run(["xinput", "set-prop", name] + args, check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        threading.Thread(target=run, daemon=True).start()

    def shutdown(self) -> None:
        try:
            self.engine.release_all()
        except Exception:
            log.exception("release_all failed")
        self.ungrab_all()
        for path in list(self.devices):
            self._drop(path)
        if self.server:
            self.server.close()
        if hasattr(self.out, "close"):
            self.out.close()
        log.info("stopped")


def main(argv=None) -> int:
    logging.basicConfig(level=logging.INFO, format="glideball: %(message)s", stream=sys.stderr)
    try:
        import evdev  # noqa: F401
    except ImportError:
        log.error("python-evdev is missing. Install python3-evdev (or: pip install evdev).")
        return 1
    try:
        daemon = Daemon()
    except PermissionError:
        log.error("cannot open /dev/uinput. Install the udev rule (linux/install.sh) and log out and back in.")
        return 1
    except OSError as e:
        log.error("cannot create the virtual pointer: %s", e)
        return 1
    return daemon.run()
