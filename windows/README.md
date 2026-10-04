# Glideball for Windows

A Windows port of [Glideball](../README.md) for the Kensington Expert Mouse (USB `VID 0x047D`, `PID 0x1020`). It replaces KensingtonWorks with a small, fast tray app: a scroll ring that feels like the Mac version, programmable buttons and 2–3-button combos, a separate pointer speed for the trackball, and settings files that move between your Mac and your PC.

> **Status: beta, untested on real hardware.** The logic is unit-tested in CI, but the Windows input layer has not yet run against a physical Expert Mouse. See [Manual test checklist](#manual-test-checklist).

## Install

> [!IMPORTANT]
> **Uninstall KensingtonWorks first, then restart.** Kensington's driver remaps the trackball itself and conflicts with Glideball.

1. Download **`Glideball-Setup-x64.exe`** (or `-arm64` for Windows on ARM) from the latest **Windows** workflow run's artifacts, or the bare `Glideball.exe` if you'd rather not install anything. The `.exe` is self-contained: no .NET install is needed.
2. Run it. It installs for your user only (no administrator prompt) into `%LOCALAPPDATA%\Programs\Glideball`, adds a Start menu entry, optionally starts with Windows, and lets you double-click `.glide-settings` files to import them.
3. Glideball lives in the notification area. Click the icon to open the window; right-click it to pause or quit. Closing the window keeps Glideball running.

### SmartScreen

Glideball is **not code-signed**, so the first launch shows *"Windows protected your PC"*. Click **More info › Run anyway**. Your browser may also warn about downloading an unsigned `.exe`; keep the file. Antivirus tools sometimes flag any app that installs a low-level mouse hook; Glideball's source is all here, and it never sends anything over the network.

**To uninstall**, use *Settings › Apps*, or just quit and delete `Glideball.exe`. Settings live in `%APPDATA%\Glideball`; delete that folder to remove them too.

## What it does

| Area | Windows behaviour |
| --- | --- |
| **Devices** | The Expert Mouse always; Kensington's other trackballs (SlimBlade, Orbit, Expert Mouse Wireless, …) with the **Beta program** switch. Every other mouse, touchpad and trackball is passed through untouched. |
| **Buttons** | Left/right/middle click, back, forward, keyboard shortcut, hold shortcut, modified click (Ctrl-/Shift-/Alt-click), do nothing, Precision (hold/toggle), Scroll with ball (hold), Drag lock. The bottom-left button always stays a left click. |
| **Combos** | 2- or 3-button combos. A button in a combo waits **70 ms** for its partners, extended to at most **160 ms** from the first press while a 3-button combo is still possible. Buttons in no combo act instantly. |
| **Scrolling** | **Flywheel** (default), **Follow** and **Native**, using a line-by-line port of `SmoothScroller.swift` (Flywheel's constants are Kensington's measured behaviour: τ ≈ 82 ms, ~4 pt per slow tick). Output is high-resolution wheel input (`SendInput` with sub-120 `MOUSEEVENTF_WHEEL`/`HWHEEL` deltas) at your display's refresh rate. Reverse direction, Shift for sideways, Ctrl/Alt/Win + scroll keep their meaning. |
| **Pointer speed** | Optional **per-device speed** (experimental) for the trackball alone, past Windows' limit. Off by default: then Windows' own (global) pointer speed applies. |
| **Panic pause** | **Ctrl+Alt+Win+G** anywhere, the tray menu, or the switch in the window. Pause uses a system hotkey, not the hook, so it works even if a mapping goes wrong; a watchdog removes the hook outright if the input thread doesn't respond. |
| **Settings** | `%APPDATA%\Glideball\settings.glide-settings`, in exactly the Mac's `GlideSettingsFile` JSON. Import/export; unknown fields from newer versions are kept. |
| **Backups** | `%APPDATA%\Glideball\Backups`: a daily snapshot (only when something changed) and a checkpoint before every import or restore. Every backup from the last 14 days, then the newest per month for a year; the newest is always kept. Same file names as the Mac. |
| **Per-app setups** | Keyed by process name (`chrome.exe`) via the foreground window. Pointer speed, scrolling and buttons can each be overridden. |

## How it tells the trackball apart from other mice

Windows gives a low-level mouse hook (`WH_MOUSE_LL`) every mouse's events **without saying which device sent them**, and Raw Input tells you the device **but can't block or change anything**. Glideball uses both, on one dedicated high-priority thread:

1. **Raw Input** (`RegisterRawInputDevices`, usage page 1 / usage 2, `RIDEV_INPUTSINK | RIDEV_DEVNOTIFY`) delivers `WM_INPUT` for every mouse to a message-only window. Each report's `hDevice` is mapped to the device interface path (`GetRawInputDeviceInfo(RIDI_DEVICENAME)`), whose `VID_047D&PID_1020` (or Bluetooth `VID&0002047d_PID&…`) identifies the trackball. Kensington devices also get their HID product name, read with a zero-access handle (the device is never opened for reading or exclusively).
2. **The low-level hook** sees every button and wheel event. For each one that *matters* — a press of a button you've remapped or put in a combo, a wheel tick when Glideball is shaping the scrolling — it asks the **correlator** (`Glideball.Core/Devices/InputCorrelator.cs`) whether the trackball reported **that exact event** (same button and direction, or same wheel direction):
   - For one physical event Windows normally calls the hook first and queues `WM_INPUT` just after. So inside the hook callback Glideball **drains the pending `WM_INPUT` messages right away** (`PeekMessage(WM_INPUT, PM_REMOVE)`) and usually decides synchronously.
   - If the raw report hasn't arrived yet, the hook **holds** the event (swallows it) until its raw partner arrives, then either acts on it (trackball) or **replays it untouched** (anything else). Held events are released strictly in order, so a press can't overtake its own release.
   - If no raw report arrives within **40 ms**, the event **fails open**: it's treated as another device's and replayed untouched.
3. A press is attributed to the trackball **only if the trackball itself reported that press**. There is no "last active device" guess anywhere — this is the fix for the Mac bug where a touchpad's right-click right after using the trackball was taken for the trackball's.

Releases always follow the press: if Glideball took over a press, its release is Glideball's too, whatever device the release seems to come from, so no button or key can stay stuck down.

Everything Glideball injects carries `dwExtraInfo = 0x474C4944` ("GLID") so the hook never processes its own input again. Input injected by other software (`LLMHF_INJECTED`) is always passed through untouched.

### Failure modes (and what happens)

| Situation | Result |
| --- | --- |
| The raw report for a press arrives late (> 40 ms) | The press is replayed untouched: a remapped trackball button acts as its plain Windows button once. Never a lost click. |
| Another mouse's press, while the trackball is connected | If its raw report wasn't already queued, the press is held for a moment (usually well under a millisecond) and replayed. Replayed events are marked as injected, which a few games or anti-cheat systems ignore. Only presses of buttons you've remapped or put in combos are ever held; plain left clicks are only held if the left button is in a combo. |
| Two devices press the same button within a few ms | Attribution follows the order of raw reports; the worst case is that the remap applies to the wrong one of the two presses. |
| Another app's low-level hook swallows an event before Glideball sees it | Glideball never sees it; its raw report expires unmatched after 60 ms. |
| Windows removes the hook (a callback exceeded `LowLevelHooksTimeout`) | Raw Input keeps flowing while the hook goes quiet; after 2 s of that Glideball reinstalls the hook. Hook callbacks only do in-memory work and `SendInput`, never disk or UI. |
| The window under the pointer belongs to an elevated (administrator) app | Windows blocks injected input into it (UIPI), so presses and wheel ticks over it are left completely alone. Releases still go through Glideball so nothing sticks. Run Glideball as administrator if you need remapping there. |
| The secure desktop (UAC prompt, Ctrl+Alt+Del) | No hooks run there; the trackball is a plain mouse. |
| Glideball crashes or is killed | Unhandled-exception and process-exit handlers let go of every key and button Glideball pressed, unfreeze the cursor and restore Windows' pointer speed. Windows removes the hook when the process dies. (A hard kill can't run handlers; a held shortcut key could then stay down until you press it once.) |

### Pointer speed for the trackball only

Windows' pointer speed is global. With **Per-device speed** on, Glideball takes over the trackball's motion: the hook swallows mouse moves while the trackball is the device moving, and Glideball moves the cursor itself (`SetCursorPos`) by the trackball's raw counts × a speed curve (`PointerRouter.Curve`: speed/4 px per count, easing up to 2.5× for fast spins). As soon as any other device moves, Windows owns the cursor again, and the trackball waits 100 ms of quiet before taking over.

This is **experimental** and off by default because:

- the hook decides per move from the latest raw report; at a hand-over between devices one report (≈ 8 ms) of motion can go to the wrong path — a pixel or two;
- the cursor is positioned rather than "moved", so games and apps that read raw mouse deltas don't see trackball motion while it's on;
- Windows' *Enhance pointer precision* no longer applies to the trackball (Glideball's curve replaces it).

With it off, the trackball simply uses Windows' speed, and **Precision** lowers Windows' (global) pointer speed while it's on — not saved to the registry, and restored on exit and on crash.

### Scrolling details

- **Ring ticks** come from the hook's `WM_MOUSEWHEEL` events attributed to the trackball (one notch = 120 = one tick), are swallowed, and drive the scroller. A frame thread paced by `DwmFlush` (one frame per display refresh) emits the motion as sub-120 wheel deltas.
- **Points → wheel units**: 1.2 units per point by default (Chromium-based browsers scroll 100 px per 120 units). Change it under *Scrolling › Wheel scale (this PC)*. Apps that only understand whole notches add the small deltas up and scroll once they reach 120, so distances still match.
- **Shift + ring** emits horizontal wheel input (`HWHEEL`); Shift stays physically held, which apps ignore for horizontal wheel input.
- **Scroll with ball**: the cursor is pinned with `ClipCursor` (re-applied on each move, since Windows resets clipping on focus changes) and the ball's raw counts drive the scroller.
- **Native** passes the ring's wheel events through unchanged (reversed if you ask). The Mac's "native scroll speed" setting has no Windows equivalent and is ignored.

## Settings files and the Mac

The file is the Mac's `GlideSettingsFile`, byte-for-byte the same shape: `{"version":1,"config":{…},"exportedAt":"2026-10-04T09:12:30Z","exportedFrom":"…"}`. Swift enum cases appear as `{"shortcut":{"_0":{…}}}`, buttons are keyed by the Mac's button numbers (0 primary/bottom-left, 1 bottom-right, 2 top-left, 3 top-right), and a cleared global shortcut is an explicit `null`. Missing keys fall back to the Mac's defaults; unknown actions and combos are skipped; unknown keys are written back unchanged.

**Keyboard shortcuts** are stored as macOS key codes and modifier flags, translated on the fly: **⌘ ↔ Ctrl, ⌃ ↔ Win, ⌥ ↔ Alt, ⇧ ↔ Shift** — so ⌘C is Ctrl+C. A few Mac presets have better Windows equivalents and are translated specially: Previous/Next Space → Ctrl+Win+←/→ (virtual desktops), Mission Control and App Exposé → Win+Tab, Spotlight → Win+S. Modified clicks follow meaning: ⌘-click is Ctrl-click, and the Mac's Control-click (its context-menu click) is a right click.

**Per-PC preferences** that never travel in a settings file (like the Mac's Beta switch) are in `%APPDATA%\Glideball\preferences.json`: Beta program, per-device speed, wheel scale, automatic backups.

A fresh Windows install starts with no button remaps or combos (the Mac's defaults send Mac shortcuts). A file from a Mac keeps its Mac mappings, translated as above.

## Limitations

- Untested on real hardware (see below). The button numbering assumes Windows' standard HID mouse driver maps the Expert Mouse's top-left button to middle and top-right to Back (XButton1); use **Quick assign** to check.
- The Mac's live trackball diagram and translations aren't ported; the UI is English only.
- Double-clicking a `.glide-settings` file while Glideball is already running brings the window forward but doesn't import; use *Backup › Import* or drop the file on the window.
- Windows 10 gets a solid dark window; Mica needs Windows 11 22H2 or later.
- Per-device speed: see above. Without it, the trackball shares Windows' pointer speed with every mouse.

## Project layout

```
windows/
  Glideball.sln
  src/Glideball.Core/      net8.0 class library, no Win32: scroll physics, buttons/combos, settings,
                           backups, device matching, correlator, key mapping, pointer curve
  src/Glideball/           net8.0-windows WPF app: hook + Raw Input engine, injection, tray, UI
  tests/Glideball.Core.Tests/  xUnit tests (golden data in Data/)
  tools/golden/            Swift harness that records golden data from the real Mac sources
  tools/icon/make_ico.py   PNG-in-ICO packer (stdlib only)
  installer/Glideball.iss  Inno Setup script
```

The input engine (`src/Glideball/Input/InputEngine.cs`) runs on its own `Highest`-priority thread with a message-only window; the scroll frame loop (`ScrollPump.cs`) runs on another; the UI never touches input.

## Building

CI (`.github/workflows/windows.yml`, `windows-latest`) restores, builds, runs the tests, publishes self-contained single-file `Glideball.exe` for **win-x64** and **win-arm64**, zips them and builds Inno Setup installers. Locally on Windows with the .NET 8 SDK:

```powershell
cd windows
dotnet test tests/Glideball.Core.Tests
dotnet publish src/Glideball/Glideball.csproj -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o out/win-x64
```

The core tests also run on macOS/Linux with the .NET 8 SDK. To regenerate the golden scroll data and the Mac sample file after changing `SmoothScroller.swift` or `Config.swift`, run `windows/tools/golden/run.sh` on a Mac.

## Manual test checklist

Run on a Windows 11 PC with the Expert Mouse **and** at least one other mouse or a touchpad. Uninstall KensingtonWorks first. Keep a second pointing device handy throughout.

**Setup**
1. Launch `Glideball.exe`; SmartScreen › More info › Run anyway. The tray icon appears and the window opens; the sidebar shows **Kensington Expert Mouse** with a green dot.
2. Unplug and replug the trackball: the status goes to "No trackball connected" and back within a second or two.

**Device separation (the important part)**
3. Buttons › set Bottom right to **Copy**. Bottom-right on the trackball copies (no context menu). **Right-click on the touchpad and on the other mouse still opens a context menu**, including immediately (< 1 s) after using the trackball.
4. Alternate quickly: trackball bottom-right, touchpad right-click, trackball, other mouse right-click. Every one does the right thing; no stuck buttons (try dragging afterwards).
5. With the trackball connected, scroll with the other mouse's wheel and the touchpad: they behave exactly as before Glideball (Windows' own steps, no Flywheel glide).
6. Play a game or app that uses raw mouse input with the other mouse (if available): no behaviour change.

**Buttons and combos**
7. Each preset on Top left / Top right: Back, Forward, Middle click, Ctrl-click (opens a link in a new tab), Previous/Next desktop (create two virtual desktops first), Task view, Search, Copy/Paste/Undo, New/Close tab, Do nothing.
8. Record a custom shortcut (e.g. Ctrl+Shift+T) and a **hold** shortcut (e.g. hold Shift while a button is held: Shift-select text with a left click). Release: the key is released.
9. Combo Top left + Top right → New tab: press both within 70 ms → one new tab and neither button's own action. Press one alone → its own action after ~70 ms. Hold one, press the other 100 ms later → two separate actions.
10. Three-button combo Bottom left + Top left + Top right: press all three with a natural (non-simultaneous) landing → the combo fires; the two-button combo doesn't.
11. Bottom left alone still left-clicks and drags normally; with it in a combo, clicks are ≈70 ms late but never lost (double-click a file to check).
12. Precision (hold) and (toggle): pointer slows; it recovers on release/toggle. With per-device speed off, check Windows' pointer speed slider afterwards: unchanged.
13. Scroll with ball (hold): cursor stays put, ball scrolls a page both axes, glides briefly on release; the cursor moves again afterwards.
14. Drag lock: press → item grabbed; roll to move it; any left click (trackball or other mouse) drops it.
15. Quick assign: press Top right, then press Ctrl+W → Top right closes tabs. Press two buttons together → creates a combo.

**Scrolling**
16. Flywheel: a single slow tick moves a few pixels in Chrome/Edge; a hard spin flies and coasts ~0.5 s; turning back stops it. Smooth in Edge, Chrome, Firefox, VS Code, Word, Explorer, Settings.
17. Follow: page tracks the ring and stops when you stop; a fast flick throws; one tick back catches the throw.
18. Native: Windows' own steps. Reverse direction works in all three modes.
19. Ctrl + ring zooms the browser; Shift + ring scrolls sideways (Excel, a wide web page).
20. A legacy app (Notepad, an old Win32 dialog) still scrolls, in coarser steps.

**Pointer speed**
21. Per-device speed off: trackball and other mouse both follow Windows' speed.
22. Turn it on, set Turbo: trackball is fast; the other mouse/touchpad unchanged; alternating between them never makes the cursor jump. Drag a window and select text with the trackball. Turn it off: Windows' speed immediately.

**Safety**
23. Ctrl+Alt+Win+G pauses (tray balloon; the trackball is a plain mouse: top buttons = middle/back, plain wheel), and again resumes. The tray menu's Pause does the same.
24. While holding a hold-shortcut button or in Drag lock, press Ctrl+Alt+Win+G: nothing stays held.
25. While holding a hold-shortcut button, end the process in Task Manager (End task): no key stays held (End process tree may skip handlers — note what happens).
26. Open Task Manager (elevated) and use the trackball over it: clicks and scrolling still work (Glideball leaves them alone).
27. Run for an hour of normal use and check `%APPDATA%\Glideball\glideball.log` for "hook went silent" or exceptions.

**Settings**
28. Export a file on the Mac and import it here (and the reverse): the preview lists the differences; mappings translate (⌘C → Ctrl+C); after importing, Backup lists a "before import" checkpoint, and Restore brings the old settings back.
29. Apps: add `chrome.exe` with its own speed and buttons; switching between Chrome and another app swaps setups within a quarter second.
30. Start with Windows: sign out and in; Glideball starts in the tray without a window.
