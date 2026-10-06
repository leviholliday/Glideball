# Glideball for Linux

Glideball for the Kensington Expert Mouse, on Linux: pointer speed beyond the
desktop's limit, the Mac app's Flywheel and Follow scrolling with
high-resolution wheel events, and programmable buttons with 2- and 3-button
combos. Settings files are the same `.glide-settings` format as the Mac app's,
so you can export on one machine and import on the other.

Requirements: Python 3.10+, python-evdev, and for the settings window GTK 4
with libadwaita 1.4 or newer. That means Ubuntu 24.04+, Debian 13+, Fedora 39+,
Arch, or openSUSE Tumbleweed. Works on X11 and Wayland (GNOME, KDE, and others).

## Install

```sh
cd linux        # or the extracted glideball-linux-<version> folder
./install.sh
```

The installer:

1. installs `python-evdev`, PyGObject, GTK 4 and libadwaita with apt, dnf,
   pacman or zypper (skip this with `--no-deps`);
2. copies the app to `~/.local/share/glideball` and links `~/.local/bin/glideball`;
3. adds Glideball to your app menu, with its icon;
4. installs a udev rule with `sudo` (see [Permissions](#permissions));
5. enables and starts the `glideball` **systemd user service**;
6. on GNOME, binds **Ctrl+Alt+Super+G** to pause and resume Glideball.

If the trackball was plugged in before you installed, unplug and replug it (or
log out and back in) so the new permissions apply. Check with
`glideball ctl status`.

To remove: `./uninstall.sh` (keeps settings and backups) or
`./uninstall.sh --purge`. A Debian package can be built with `./build-deb.sh`.

## How it works

```
Expert Mouse ──► /dev/input/eventN ──(EVIOCGRAB)──► glideball daemon ──► uinput
                                                     (engine: speed curve,   "Glideball Virtual Pointer"
                                                      scroll physics,        "Glideball Virtual Keyboard"
                                                      buttons, combos)            │
settings window ── writes ~/.config/glideball/settings.glide-settings ──► daemon  ▼
                └─ Unix socket (status, pause, learn a press) ─────────►    your desktop
```

* The daemon opens **only** Kensington devices (USB vendor 047d) that are
  pointers. Before it opens anything, it reads the device's vendor from sysfs,
  so other brands are never even opened. The Expert Mouse (product 1020) is
  always supported. Kensington's other trackballs are supported only when you
  turn on **Beta program** on the Overview page. Every other mouse, touchpad
  and trackball (the ELECOM HUGE included) is left completely untouched.
* It takes exclusive control of the trackball (EVIOCGRAB) and re-emits
  everything through a virtual device, the same approach input-remapper and
  logiops use. **The kernel releases the grab the instant the daemon exits,
  for any reason**, so the trackball can't get stuck.
* If anything goes wrong while handling an event, Glideball lets go of every
  key and button it holds, ungrabs, and passes the trackball through untouched.
  It stays that way until you change a setting or press **Resume**.
* Settings changes apply live: the daemon re-reads the settings file within
  half a second.

## Features

**Pointer.** Tracking speed runs from 0.5 to 80 and applies only to the
trackball. Presets are Precise (1.5), macOS (3), Fast (5) and Turbo (7.5). The
curve is the Mac's response curve, `cursor = ball × (1 + speed × 0.55 × ball^0.8)`
with ball speed in inches per second, applied with sub-pixel remainders so slow
motion stays smooth. Precision speed is used while a Precision button is held
or toggled on.

**Scrolling.** There are three modes, the same as on the Mac:

* **Native**: each ring notch is passed through as one wheel notch.
* **Flywheel** (default): each tick pushes the page and friction slows it.
  This uses Kensington's measured constants. The **Fast-spin reach** slider
  (default 50%) sets how much farther the very fastest spins go: up to
  12,000 pt/s (about 45 ring ticks/s) the feel is unchanged, and beyond that a
  harder spin keeps going faster and coasts a little longer, up to a ceiling
  set by the slider. At 0% you get the old hard limit.
* **Follow**: the page tracks the ring, and a real flick throws it.

The physics are a line-for-line port of `SmoothScroller.swift`, tested frame for
frame against the Swift code. Output is `REL_WHEEL_HI_RES` (120 units per notch)
at about 120 Hz, plus the legacy `REL_WHEEL` once a full notch has accumulated.
You can also turn on reverse direction, turn smoothing off for plain steps, and
use Scroll with ball.

**Buttons.** Each button can be one of these:

* left, right or middle click
* back or forward
* Ctrl-, Shift- or Alt-click
* a workspace switch, the activities overview, browser back/forward,
  copy/paste/undo or new/close tab
* any keyboard shortcut, sent once or held while you hold the button
* Precision (hold or toggle), Scroll with ball (hold), or Drag lock
* nothing

Combos of 2 or 3 buttons work too. A combo button waits 70 ms for its partners,
and that wait extends up to 160 ms for 3-button combos. Buttons that aren't in a
combo respond instantly. **The primary (bottom-left) button always stays a left
click.**

**Pause.** Ctrl+Alt+Super+G, the header switch, the app icon's right-click
menu, or `glideball ctl toggle-pause`. While paused, the trackball is ungrabbed
and behaves exactly as plain Linux would.

**Backups.** Glideball takes a daily snapshot when your settings changed, plus
one before every import or restore. It keeps everything from the last 14 days,
then one per month for a year, and always keeps the newest. Backups are stored
in `~/.local/share/glideball/backups/` and are ordinary `.glide-settings` files.

### Shortcuts across Mac and Linux

Settings files store shortcuts the Mac way (macOS key code + modifier flags).
On Linux, the Mac presets are translated to their usual Linux meaning:

| Mac preset | On Linux |
| --- | --- |
| Previous / Next Space (⌃← / ⌃→) | Ctrl+Alt+← / Ctrl+Alt+→ |
| Mission Control, App Exposé, Spotlight | Super (activities overview / launcher) |
| Browser Back / Forward (⌘[ / ⌘]) | Alt+← / Alt+→ |
| Copy, Paste, Undo, New Tab, Close Tab (⌘…) | Ctrl+… |
| ⌘-click / ⌃-click | Ctrl-click |

Other shortcuts are sent literally: ⌃ is Ctrl, ⌥ is Alt, ⇧ is Shift and ⌘ is
Super. A shortcut you record on Linux uses the same mapping, so it means the
same keys if you open the file on a Mac.

## Permissions

`packaging/70-glideball.rules` contains two lines:

```
KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess"
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{id/vendor}=="047d", TAG+="uaccess"
```

`uaccess` gives the user who is logged in at the screen (and only that user) an
ACL on:

* `/dev/uinput`, so Glideball can create its virtual pointer and keyboard;
* Kensington input devices, so it can grab the trackball.

The ACL moves with logins and is removed when that user logs out. Glideball does
**not** need you to be in the `input` group, and it doesn't make your keyboard
or other mice readable. The installer also adds `uinput` to
`/etc/modules-load.d/` so the module loads at boot.

## Command line

```
glideball                 open the settings window
glideball daemon          run the service in the foreground (for debugging)
glideball ctl status      what the service sees (devices, grabbed, modes)
glideball ctl pause | resume | toggle-pause
glideball ctl toggle-mode precision | ballScroll | dragLock
```

Logs: `journalctl --user -u glideball -f`.

## Troubleshooting

* **"No Kensington trackball found"**
  * Run `ls -l /dev/input/by-id/ | grep -i kensington`, then
    `getfacl /dev/input/eventN`: your user should be listed.
  * If it isn't, replug the trackball or log out and back in.
  * Check that `/etc/udev/rules.d/70-glideball.rules` exists.
* **"cannot open /dev/uinput"**
  * Run `sudo modprobe uinput` and check `getfacl /dev/uinput`.
  * Over SSH or in a container there is no seat, so `uaccess` doesn't apply.
* **The pointer is too fast or feels doubled**
  * Your desktop's acceleration is applied on top of Glideball's curve.
  * On X11, Glideball sets the virtual pointer to the flat profile itself
    (this needs `xinput`).
  * On Wayland, set the mouse acceleration profile to **Flat** in your desktop's
    settings, or lower Glideball's speed.
* **Scrolling feels too short or too long**
  * One notch (120 hi-res units) is treated as 50 Mac points.
  * To change that, set `"pointsPerNotch"` in `~/.config/glideball/local.json`.
    Higher values scroll less.
  * `"frameRate"` sets the scroll animation rate (default 120).
* **Something's wrong and I need my mouse now.**
  * Press Ctrl+Alt+Super+G, or run `systemctl --user stop glideball`.
  * Either one ungrabs the trackball immediately.
  * Your other mice are never affected.
* **A shortcut does nothing**
  * Desktops differ: for example, KDE's default workspace switch is
    Ctrl+Meta+←.
  * Choose "Keyboard shortcut…" and record your desktop's actual shortcut.

## Limitations

* **No per-app profiles.**
  * Wayland has no reliable way for an app to know which window is focused, so
    per-app setups are skipped on Linux.
  * Per-app profiles in a Mac settings file are kept intact, so they still work
    when the file goes back to a Mac.
* **Shift + scroll ring.**
  * The daemon doesn't read your keyboard (on purpose: it has no access to it).
    So "Shift scrolls horizontally" is left to the toolkit; GTK, Qt and browsers
    already do this.
  * The Ctrl/Alt + scroll gestures (zoom and so on) keep working as usual.
* **The pause shortcut on non-GNOME desktops** must be bound by hand to
  `glideball ctl toggle-pause`.
* **No tray icon.** GTK 4 has no tray API. Pause and resume are available from:
  * the shortcut;
  * the window's header switch;
  * the app icon's right-click menu ("Pause / Resume Glideball").

  The service runs in the background whether or not the window is open.
* **Not supported (Mac-only):**
  * Native mode's wheel-speed setting;
  * the Mac's Precision / Scroll-with-ball / Drag-lock *keyboard* shortcuts
    (use `glideball ctl toggle-mode …` bound to a key instead);
  * iCloud sync;
  * translations (English only for now; every string is in `glideball/strings.py`).

## Development

```sh
cd linux
python3 -m pytest              # pure Python, no evdev or GTK needed
tools/make-golden.sh           # macOS only: regenerate the Swift-derived fixtures
./build-tarball.sh             # dist/glideball-linux-<version>.tar.gz
```

* `glideball/scroller.py`: scroll physics.
* `glideball/engine.py`: buttons, combos, modes, pointer and wheel output.
* `glideball/daemon.py`: evdev, uinput, hot-plug, IPC.
* `glideball/config.py`: the settings file.
* `glideball/backup.py`: backups.
* `glideball/gui/`: the settings window.

The engine takes a clock and an output object, so the tests drive it with fake
event streams. The daemon tests use a fake input device and a fake uinput.
