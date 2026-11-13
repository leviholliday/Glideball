# Developing Glideball

This is the technical side of Glideball that used to be in the README: how it works inside, how to build it, and how releases go out. If you just want to use Glideball, the [README](../README.md) and the [help pages](https://glideball.netlify.app/help/) are all you need.

## Repo layout

| Path | What's there |
| --- | --- |
| `Sources/Glide/` | The Mac app (Swift 6.2, SwiftUI, a plain Swift package with no Xcode project). The target and executable are still called `Glide`; the app was renamed Glideball in 2.8. |
| `Resources/` | `Info.plist`, the icon, the launch sounds and the translations (`*.lproj`). |
| `build.sh` | Builds, installs and launches the app on your Mac. |
| `scripts/` | Release and website scripts, the scroll and backup simulators, and the translation checker. |
| `linux/`, `windows/` | The Linux and Windows previews. Each has its own README. |
| `website/` | glideball.netlify.app, including the feedback functions. |
| `docs/` | This file, the demo clip and the README screenshots. |
| `brand/` | The email signature and the icon-redesign reference image. |

## How it works

Glideball never takes the trackball away from macOS. The Expert Mouse stays an ordinary mouse, and Glideball adjusts it from the side.

- **Event tap on a dedicated thread.** The input engine runs on its own high-priority thread and run loop, so a busy UI can never stall the mouse. A session-level `CGEventTap` sees button and scroll events and changes only the ones that came from a supported Kensington device. Events that Glideball posts itself are tagged, so it never processes them twice. If macOS disables the tap, Glideball turns it back on, and a maintenance timer retries anything that a late permission grant made possible.
- **`IOHIDManager` listens without seizing.** Glideball opens every pointing device read-only (it never uses `kIOHIDOptionsTypeSeizeDevice`). That is how it knows which device produced the latest event (Kensington's vendor ID is `0x047D`, the wired Expert Mouse is product `0x1020`; see `DeviceSupport.swift`), how it reads raw scroll-ring detents straight from the HID reports, and where the live graphs get their data.
- **Per-device `HIDMouseAcceleration`.** Glideball doesn't move the cursor itself. It sets the acceleration value on the trackball's own `IOHIDServiceClient`, so macOS keeps doing pointer acceleration inside the HID system while other devices stay untouched. Glideball applies the value again after sleep, after you replug the trackball, or when the driver restarts. Since 2.10, pausing or quitting puts System Settings' own pointer and scroll speeds back (`PointerTuner.restoreSpeeds`).
- **Display-synced scroll engine.** In Flywheel and Follow modes, ring ticks feed a scroll engine driven by a `CADisplayLink`. It computes each frame for the moment that frame reaches the screen. It posts plain continuous pixel-scroll events with no gesture phases, so apps don't add momentum of their own.

## Scroll engine and research notes

Flywheel is modeled on measurements of Kensington's own driver:

- The driver emits scroll output at **60 Hz**. Between ticks, the speed decays by a factor of **0.816 per frame**. That is exponential friction with a time constant of **τ = −(1/60 s) / ln 0.816 ≈ 82 ms**.
- In Glideball, each tick adds a push of `d / τ` to the page speed, which works out to exactly `d` points of travel. The distance `d` grows with spin rate. In the measurements, a slow tick moved about 4 pt, and a 10-tick flick moved about 2,300 pt and coasted for roughly half a second. Glideball uses the same friction (the default glide is τ ≈ 82 ms) but renders at your display's refresh rate instead of 60 Hz.
- The Flywheel sliders are slow-turn distance, spin power, **Fast-spin reach** and glide (40–160 ms). The **Kensington feel** button restores the measured distance, power and glide; it leaves Fast-spin reach alone (set it to 0% for Kensington's exact top speed).

Follow mode's throw uses the shape of macOS's own momentum curve, **v(t) = v₀ (1 − t/T)³**, where T = c · v₀^⅓ (macOS uses c ≈ 0.063). A throw therefore travels v₀ T / 4 and stops at a definite moment, without a long creeping tail.

Other details the app's own setting descriptions also explain:

- In Flywheel and Follow, ⇧ scrolls sideways and ⌘/⌃/⌥ + scroll keep their usual meaning (zoom, for example).
- Native mode lets macOS scroll the ring itself; Glideball only sets the wheel speed for the trackball, up to 5 (System Settings stops at 1.7).
- A button that belongs to a combo waits 70 ms for its partners, extended to at most 0.16 s from the first press while a three-button combo is still possible (`Engine.swift`). Buttons in no combo act instantly.
- Automatic backups are ~2 KB `.glide-settings` files in `~/Library/Application Support/Glide/Backups/`: one a day plus checkpoints before imports and restores, all kept for 14 days, then one per month for a year (`BackupStore.swift`).

## Building from source

You need macOS 26 and a Swift 6.2 toolchain (Xcode 26 or its Command Line Tools).

```sh
git clone https://github.com/leviholliday/glideball.git
cd glideball
./build.sh           # build, install to /Applications/Glideball.app, and launch
./build.sh --icon    # also re-render the app icons first (Orb and classic)
```

> [!WARNING]
> `./build.sh` quits any running Glideball, **deletes `/Applications/Glideball.app`** (and an old `Glide.app`) and puts the fresh build in its place. Without the signing identity below, you'll have to grant Accessibility and Input Monitoring again after every build.

## Local signing identity

macOS ties Accessibility and Input Monitoring grants to an app's code signature. An ad-hoc signature changes on every build, so you would have to grant both permissions again after each `./build.sh`. To avoid that, `build.sh` and `release.sh` look for a code-signing identity named **`Glide Local Signing`**:

```sh
security find-identity -p codesigning | grep "Glide Local Signing"
```

If it's there, `build.sh` signs with it; if not, it warns and falls back to ad-hoc signing. `release.sh` refuses to run without it, because updates are only accepted when they're signed with the same certificate. A self-signed certificate is enough, and you only need to create it once.

**With Keychain Access:**

1. Open **Keychain Access** and choose **Keychain Access › Certificate Assistant › Create a Certificate…**
2. Set **Name** to `Glide Local Signing`, **Identity Type** to *Self-Signed Root*, and **Certificate Type** to *Code Signing*. Click **Create**.
3. The first time `codesign` uses the key, macOS asks for access. Choose **Always Allow**.

<details>
<summary><b>Or from Terminal</b></summary>

```sh
cat > glide-signing.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Glide Local Signing
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# /usr/bin/openssl is LibreSSL, whose .p12 format the macOS keychain accepts.
# (With OpenSSL 3, add -legacy to the pkcs12 command.)
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config glide-signing.cnf -keyout glide-signing.key -out glide-signing.crt
/usr/bin/openssl pkcs12 -export -name "Glide Local Signing" \
  -inkey glide-signing.key -in glide-signing.crt -passout pass:glide -out glide-signing.p12

security import glide-signing.p12 -k ~/Library/Keychains/login.keychain-db \
  -P glide -T /usr/bin/codesign
rm glide-signing.cnf glide-signing.key glide-signing.crt glide-signing.p12
```

</details>

`security find-identity` will list the certificate as `CSSMERR_TP_NOT_TRUSTED`. That is expected: `codesign` can sign with an untrusted self-signed certificate, and macOS keeps permissions valid across builds as long as the certificate stays the same. Keep the private key to yourself, because anything signed with it under Glideball's bundle identifier inherits Glideball's permissions.

## Testing without a trackball

- **`scripts/scroll-sim/run.sh`** compiles the real `SmoothScroller.swift` together with a test harness and feeds it synthetic tick patterns shaped like real Expert Mouse logs: single ticks, slow turns, flicks, catches and reversals, snapped to 8 ms USB polling. For every mode it reports distance, latency, settle time, stalled frames and how steady the speed is.
- **`scripts/backup-sim/run.sh`** runs a year and a half of simulated use through the real `BackupStore` and checks the retention rules.
- **`scripts/command-sim/run.sh`** compiles the real command registry, `glideball://` parser and status.json writer with a fake app, then throws URLs at them: every good one, the switch off, about sixty malformed and hostile ones (100 KB strings, path traversal, percent-encoding tricks, NUL and newline, format strings, shell syntax, unknown and app-only commands) and a burst of 1,000. It checks nothing changed that shouldn't have, the log never repeats URL text, and the rate limit holds.
- **`scripts/gesture-sim/run.sh`** compiles the real gesture decision code (`Gestures.swift`) and settings model with a harness wired the way `Engine.swift` wires them, then plays scripted, hostile and about 640,000 random button and ball events through the engine's combo wait (chains, flicks, wobbles, rapid reversals, gesture combos released in any order, unplug, pause, quit, sleep and the tap switched off mid-chain, lost releases, 1,000 rapid taps, a gesture on the primary button and on combos with it). After every event it checks the hard rules: the pointer is frozen exactly while a gesture is held, every freeze is undone once, the primary button never becomes a gesture and its click always goes through, nothing that holds is ever fired, no two fires within 50 ms or inside a chained fire's cool-down, once-per-hold fires once, a tap only when nothing fired, a late release does nothing, no hold outlives its timeout. It also loads old and beta settings, a newer version's settings with unknown actions and fields, and checks what sync puts back after an older Glideball.
- **`scripts/import-sim/run.sh`** compiles the import code (`ImportSafety.swift`, `SharedSetup.swift`, `ImportReview.swift`, `KensingtonWorks.swift`) and checks every share kind round-tripping as a file and a link, hostile links (bad base64, a 2 MB deflate bomb, deep nesting, wrong versions and kinds), hostile settings files, KensingtonWorks fixtures shaped like the real file plus malformed ones, 3,000 fuzzed inputs, that the primary button never changes, that every new Open or shortcut is listed in the preview, and that KensingtonWorks' file is only read.
- **`scripts/device-sim/run.sh`** checks per-display pointer speed (which display the pointer is on, how often it looks, displays appearing and disappearing, the speed precedence), the connection types and the low-battery notices.
- **`scripts/engine-fuzz/run.sh`** is the engine fuzzer. It compiles the real `Engine.swift` (with the scroll engine, gestures, display tracking and settings model) against a fake `EngineIO`, so there's no event tap, no IOHIDManager, no real cursor and no pointer-speed writes, and plays long random sequences from a seed: trackball presses (its HID report first or late), ball and ring, another mouse and the trackpad, keyboard modifiers, settings and app setups changing mid-press, sync applying another Mac's settings, pause, unplug and replug, sleep, macOS switching the tap off (events lost), Quick assign, the keyboard modes, quit and relaunch. After every event it checks the hard rules: the primary button always reaches apps as a left click; apps never see a button go down twice or come up without going down; every key, modifier and button the engine pressed is up again once its trigger is up, and at once after pause, quit, unplug and sleep; no mode stays on after pause, quit and unplug; the pointer is frozen exactly while Scroll with ball or a gesture has it; a gesture hold (alone or on a combo) never includes the primary button, so a combo with it never starts one; each direction a gesture fires needs the hold's whole distance of roll (its own distance, the global one and Steady hands), fires are numbered 1, 2, 3 in their hold and never come faster than 20 a second, a "once per hold" direction fires once, and a tap only follows a hold that stayed still and never fired; other mice and the trackpad pass through untouched; the flywheel never scrolls after pause, unplug or sleep and never runs away; pointer speeds stay inside the app's limits and are never applied while paused. "Connected" always matches the hardware (the fuzzer also delivers the unplugged trackball's last HID values after its removal, puts another mouse at its address, and loses a removal callback until a wake, unlock or the window opening makes the engine check IOHIDManager's devices; like the real IOHIDManager, its fake still lists a device while that device's own removal callback runs and can list a gone one forever, the trackball has two HID interfaces removed in either order or not at all, and a replug can come back with new registry IDs). Devices are keyed by their I/O Registry entry ID, and a device check only believes devices IOKit still has registered (`EngineIO.serviceIsAlive`); Help › Copy Connection Details shows both sides. A failure prints the seed and a minimized list of events (`FUZZ_TRACE=1` adds a play-by-play and the engine's own log). `--threads` runs the engine on its own threads as the app does, for the thread sanitizer. Every third seed leans on gestures (gesture buttons and combos everywhere, chained, continuous and once-per-hold directions, every distance and Steady hands, more flicks, fewer pauses), and the summary counts the holds, fires, chained fires and taps it saw. Each bug it found has a named regression case at the top of its run, and the gesture cases also check what fired.
- **`scripts/file-fuzz/run.sh`** throws hostile files at everything Glideball reads back (settings import and shared setups through `ImportFile`, `glideball://import` link payloads, KensingtonWorks' settings, backups, sync, daily totals, the milestone ledger, crash reports): broken, huge, deeply nested, wrong-typed, future-version and malicious ones (path traversal, links, pipes, NaN and enormous numbers, invalid UTF-8). Nothing may crash, hang, write outside its folder or change settings it wasn't asked to, and every accepted setting must be inside the app's limits. `--deep` adds a few minutes of random mutations.
- **`scripts/fuzz.sh`** is the long run of both (10 minutes of engine fuzzing by default, `--minutes N` for more, `--tsan` to add the sanitizer run). **`scripts/sanitize.sh [thread|address]`** builds Glideball and the engine fuzzer with a sanitizer and runs the self-test (both launches) and the fuzzer, including its threaded mode; it needs a few GB free for its own build folder. What these found is in [DIAGNOSIS-2026-11.md](DIAGNOSIS-2026-11.md).

All the engine's effects on the outside world go through one class, `EngineIO` (`EngineIO.swift`): the clock, the cursor, posting events, the taps, IOHIDManager, battery lookups in the registry, pointer speeds, timers, the key queue and main-thread callbacks. The app uses it as it is; the fuzzer subclasses it.

Every settings value from outside (a file, a backup, sync, UserDefaults) and every config handed to the engine goes through `GlideConfig.clamped()` (`ConfigLimits` in `Config.swift`): numbers inside the ranges the app's own sliders allow, NaN to the default, button numbers 0–31, combos of two or more buttons, no global shortcut without ⌘, ⌃ or ⌥.

### Gestures, per-display speed, battery

- **Gestures** (`Gestures.swift`, button or combo action `.gesture(ButtonGesture)`): hold a button, or two or three together, and roll the ball. The pointer is frozen while it's held, the same way Scroll with ball freezes it, and the ball's HID movement goes to `GestureMachine`. Frozen means in any app: `CGAssociateMouseAndMouseCursorPosition` only holds the pointer while Glideball is in front, and a session tap can't stop the cursor (WindowServer has moved it before the tap sees the event), so while frozen the engine also puts the pointer back on its anchor whenever the trackball's own HID movement (or its drag or move event) moved it, and swallows the trackball's plain moves (a move tap, on only while frozen or drag-locked). Movement is the trackball's when its HID report is the latest and under 0.25 s old; another mouse's HID movement moves the anchor with it. The trackpad never shows up in HID, so trackpad movement while the ball is rolling during a hold is put back too (the trade-off). It only happens while the tap is on, and ends with the freeze (release, pause, unplug, sleep, the tap switched off, the 30 s limit). The engine fuzzer checks the pointer's position after every ball movement with Glideball in front and behind. A direction fires the moment the roll crosses the threshold (Gesture distance: Short 32, Normal 48, Long 72 counts, about 2, 3 and 4.5 mm; a gesture can have its own) along an axis that clearly dominates (2× for the first fire, 1.6× after it, or the larger one past twice the threshold); a release under the tap slop (16 counts, 12 for Short) is the tap; in between, nothing (so a near-gesture never clicks). **Chained**: after every fire the origin re-centers where the ball is, so one hold can fire left, up, left again without letting go or rolling back; a chained fire is followed by a 120 ms cool-down in which the origin follows the ball (the rest of the same flick never fires a second command), and no two fires are ever closer than 50 ms (20 a second). Each direction fires one of three ways (`GestureStep.mode`): each time you roll (the default), continuously (`repeats`: every further 64 counts along its axis, rolling back fires the opposite one, rolling across breaks out into the other axis), or once per hold (`once`). Picking volume or zoom makes a direction continuous; everything else starts chained. **Steady hands** widens the dead zone (28 counts), asks for a clearer axis (2.5× / 2×) and a 200 ms cool-down. Everything a gesture fires is a quick press and release, so ending a hold has nothing to undo. Precedence (`GestureRoute.decide`): combos first: a button in a combo waits for its partners (70 ms, up to 0.16 s), and a combo that forms runs its own gesture from that moment (its buttons' own gestures never start); the first of its buttons to come up ends the hold and the others' releases do nothing, in any order. The primary button is never a gesture, alone or in a combo: a gesture freezes the pointer and takes the ball, which with the left button down would be a drag that can't move (or a left press apps never see), so a combo that includes it does the gesture's tap instead and the editor doesn't offer Gesture there. One gesture at a time; gestures off or no Input Monitoring: the tap, at once. Any other press during a hold cancels its tap. Pause, quit, unplug, sleep or the screen locking, macOS switching the tap off, a lost release and a 30 s limit all end a hold and free the pointer. While a hold is armed the sidebar ball and the Buttons page's map get a soft amber ring and the page's edge lights; the Buttons page ticks quietly on each fire (Settings › Sound's button switch). Settings: `once` and `distance` are written only when used, and only gestures make a file version 2 (Gesture distance and Steady hands on their own don't); a 2.10 beta before `GlideSettingsFile.gestureTuningSince` drops them on the way back, and sync puts them back (`keepingGestureTuning`).
- **Per-display speed** (`DisplayTracking.swift`, `GlideConfig.displaySpeeds`): displays are keyed by vendor-model-serial, or macOS's own display UUID when there's no serial. The engine checks which display the pointer is on only from the trackball's own movement reports, at most every 50 ms, and only while it's on with two or more displays: a location read and a rectangle test, and a new speed only on a crossing. Nothing runs while the ball is still. Precedence: Precision, an app setup's own speed, the display's speed, the main speed. Displays coming and going arrive through `NSApplication.didChangeScreenParametersNotification`.
- **Battery and connection** (`DeviceBattery.swift`): `Engine.Status.connection` (USB, Bluetooth or a 2.4 GHz receiver, from the HID `Transport` property) and `batteryPercent` (from a HID battery element, or `BatteryPercent` in the I/O Registry, read once a minute; nil when unknown, wired, or "Other Kensington trackballs" is off). Untested on wireless hardware. Low-battery notifications at 15% and 5%, once each per discharge, only with the per-Mac `GlideLowBatteryAlerts` switch on.

## All the checks: `scripts/check.sh`

One command runs everything that should pass before a release, prints a line per step and a summary, and exits non-zero if anything failed (each step's output is in `build/check/<step>.log`; `-v` shows it as it runs):

| Step | What |
| --- | --- |
| build | `swift build -c release` |
| scroll-sim, backup-sim, command-sim, gesture-sim, device-sim, import-sim | the simulators above |
| engine-fuzz | the engine fuzzer: its regression cases, seeds 1–60 (about 1.2 million events) and one random seed, printed in the log so a failure can be replayed |
| file-fuzz | the hostile-file fuzzer's fixed cases and a short random run |
| l10n | `scripts/l10n/check.py`: every language complete, format specifiers match, no key written twice in a `.strings` file |
| website | `npm run test:usage` and any other `website/tests/*.test.mjs` (runs `npm ci` first if `node_modules` is missing) |
| site | `build_pages.py` and `check_site.py` in a temporary copy of `website/`, so the check never changes committed files. If the fresh build differs from what's committed (usually a new release in the changelog) that's a note, not a failure. |
| self-test | `scripts/self-test.sh` (below) |
| render-ui | every screen drawn once (dark, 1x): all pictures made, none blank |

`ship.sh` and `release.sh` run it first and stop if it fails. `--skip-checks` releases anyway, with a loud warning.

## The sandbox: render-ui and self-test

Two command-line modes run Glideball's real code with nothing live, so they're safe while the installed Glideball is running and owns the trackball (`Sources/Glide/Sandbox/`):

- No `Engine.start()`: no event tap, no IOHIDManager, no input thread, no `PointerTuner` writes. `AppModel`'s init stops before its timers, observers, sync and update checks; an engine that was never started ignores every call.
- `UserDefaults.standard` is swapped for an in-memory store before anything reads it, so the real settings are never read or written. Backups, the iCloud Drive sync folder and the scroll log go to a temp folder that's deleted at exit.
- Every `URLSession.shared` request is answered inside the process (the update check and download); the mode proves that at start and stops if it isn't so. ShareData and Send Feedback never send.
- No global hot keys, no menu-bar icon, no sounds or haptics, no login-item changes, no AppRename. The activation policy is `.prohibited` (no Dock icon, never in front) and no window is ever ordered front.
- They refuse to run as the real app (bundle ID `com.leviholliday.glide`). The scripts run a copy, `build/sandbox/Glideball Sandbox.app` (`scripts/sandbox-app.sh`), with its own bundle ID, an executable called `GlideSandbox`, no document types, and the real translations, icon and sounds.

Every guard is a `Sandbox.isActive` check, so `grep -rn Sandbox.isActive Sources` lists them.

### Pictures of every screen: `scripts/render-ui.sh`

```sh
scripts/render-ui.sh                                  # build/screens/, light and dark, 2x
scripts/render-ui.sh build/screens-de --lang de       # any translation, to check long strings
scripts/render-ui.sh build/s --only 'settings-*,tour-*' --appearance dark --scale 1
```

It builds, then draws each screen offscreen with demo data (a connected Kensington Expert Mouse, a month of stats, milestones part-way, three app setups, two combos, sync on with three Macs, a backup history) to `<screen>.<light|dark>.png`, plus `index.html` (a contact sheet: open it in a browser) and `manifest.json`. `--only` takes names, a name's variants (`overview` also matches `overview-page`) or globs. Options: `--appearance light|dark|both`, `--scale 1|2`, `--lang <code>`, `--no-build`. About a minute for everything.

Wide windows (`Views/PageLayout.swift`): pages are one column (680 pt, left) until they have 900 pt of room, then two columns (three-wide rows from 1,240), at most 1,360 pt and centered. `--only 'wide-*'` draws every tab in full screen at 1440, 1920 and 2560 wide (`wide-<w>-<tab>`, and `-page` for the whole page), in 1220 and 1440 windows (`wide-window-*`) and Overview at 3440. The self-test lays every tab out at 980, 1440 and 2560.

The website's screenshots come from the same pictures: `scripts/site-screens.sh [--no-build]` renders `overview`, `pointer`, `scrolling` and `buttons` (dark, 2x), writes `website/assets/screens/<screen>-960.webp`, `-1600.webp` and `-1200.png`, and updates the homepage's `?v=` and image sizes so browsers fetch the new ones. `scripts/site-icons.py` does the same for the site's icons, favicon and `og.png`, from `brand/icon-candidates/orb-b.png` (bump `ASSET_V` in `build_pages.py` and the `?v=` in the hand-written pages after).

Screens: the six tabs as the window opens (`overview`, `pointer`, `scrolling`, `buttons`, `apps`, `sync`) and each whole tab top to bottom (`*-page`, the content column without the sidebar); the sidebar's trackball in each of its looks, at its own size and large (`trackball-states`), and the ball turning as it rolls right and away, large and small (`trackball-rolling`); the light and motion that a still can't otherwise show (`overview-record`: the moment today passes your best, with the dial's sweep, the number's pop and the sparks; `atmosphere-rolling`, `atmosphere-ring`, `atmosphere-click`: the room lit by each part of the hand; `slider-dragging`; `mode-card-hover`: a mode card's demo playing; `minimal-performance`: rolling with the stage held still); states (`permissions-needed`, `permissions-half`, `paused`, `no-trackball`, `other-kensington`, `modes-on`, `app-setup-active`, `celebration-toast`, `celebration-confetti`, `toast-import`, `import-preview`, `quick-assign`, `small-favor`, `icon-prompt`); the Welcome Tour (`tour-1-welcome` … `tour-6-done`, plus `tour-3-buttons-found`, `tour-4-option-try` (a speed ⌥-clicked beside the ⌥ tip, also at the smallest size), the name step `tour-5-name` and `tour-name-filled`); What's New (`whats-new`, and `min-size-whats-new` with the tour's busiest steps at the smallest window); `about`, `feedback`, `feedback-idea`, `feedback-sending`, `feedback-sent`, `backup-history`, `shortcuts-sheet`, `quit-card` (over the window; in the app it floats over the whole screen), `quit-card-close` (at its real size), `scrolling-try-active` (Try it here after a click, without its hint); the Buttons page's picker and presets (`buttons-picker`, `-picker-search`, `-picker-nothing`, `-picker-record`, `-preset-preview`, `-preset-applied`, `-new-combo`, and `apps-add-picker`; popovers can't be drawn, so the picker is drawn where it opens, on a glass card); ball colors (`ball-colors`, `overview-theme-ember`, `-ocean`, `-classic`); badges and sharing (`badges`, `badge-detail`, `share-panel`, `share-panel-posted` and `share-panel-badge` (the note a site button leaves), `share-card-overview`, `-badge`, `-badge-locked`, `-theme`, drawn with ImageRenderer as Share… makes them); `fullscreen` and `fullscreen-pointer` (simulated: the toolbar hidden as the app hides it in full screen, at 1440 × 900); `overview-hint-gone` (Overview once the Settings hint has gone); Settings (`settings-general`, `-trackball`, `-look`, `-sound`, `-sharing`, `-updates`, `-privacy`, `-shortcuts`, through the real Settings window with its toolbar; `settings-laptop-*` and `settings-1080p-*` on a screen 860 and 985 points tall, where the window stops at the screen's edge and a taller tab scrolls inside; plus `settings-general-spotlight`, `settings-look-classic`, `settings-look-custom`, `settings-privacy-deleted`, `settings-privacy-nothing`, `settings-privacy-stats` (Privacy's live "What this sends" in each choice), `settings-shortcuts-search`, `-no-match` and `-conflict`) and `external-control-notice`; frames of the launch animations (`launch-intro-rolling-in`, `-ring-spinning-up`, `-light-drawing-in`, `-held-beat`, `-the-hit`, `-the-word-landing`, `-ripple`, `-finished`; `launch-ring-spin` and `launch-roll-in`, each also `-start` and `-settling`; `launch-reveal-opening` and `-wide`, the hand-off over the window; `launch-fade`); Software Update (`update-checking`, `-failed`, `-up-to-date`, `-available`, `-in-header`, `-downloading`, `-install-failed`, reached by answering the update check and download with canned replies).

Round 4: the search palette (`search`, `-recent`, `-speed`, `-speed-number`, `-moved`, `-buttons`, `-badge`, `-nothing`, `-jump`, `-jump-settings`), the menu-bar icon in every state, Mono and Color, light and dark bars, 1x and 2x blown up beside Apple's glyphs (`menubar-icons`, drawn by `MenuBarIcon.swift`), the menu-bar panel (`menubar-panel`, `-modes`, `-paused`; drawn on glass, since a popover is its own window), the weekly recap (`weekly-recap`, `-quiet`, `share-card-recap`) and Try before you change (`try-hint`, `try-slider`, `try-preset`, `try-scroll-mode`).

Sharing (RenderSharing.swift): Share…'s checklist (`share-sheet-checklist`, `-some` with a name going with it, `-none`), the receive preview with parts unticked and a sender's name (`share-preview-parts`) and a beta 12 link (`share-preview-beta12`), the pictures with and without a name (`share-card-checklist`, `share-card-overview`, `share-card-badge`, each also `-named`), `settings-sharing-named` and `tour-name-filled`. The website's share page has its own pictures: `node scripts/share-page-shots.mjs [folder]` (headless Chrome, a few payloads at 1440 and 390 wide).

Search finds what each page declares: every row sits inside a `.findable(...)` whose `Findable` is written next to it, and the self-test fails if a drawn row isn't inside one or a `Findable` isn't drawn.

How it draws: each view is hosted in a window that's never ordered front, given a moment to settle (onAppear, async work), and its layer tree is drawn by Core Animation's own renderer (`CARenderer`) into a Metal texture: the renderer that draws windows on screen, so Liquid Glass, materials and vibrancy come out as they do in the app. AppKit's `cacheDisplay` (try `GLIDE_RENDER_ENGINE=appkit`) leaves glass empty and text in it black; `ImageRenderer` can't draw AppKit controls or scroll views. The window claims to be key, so controls, switches and traffic lights draw in their active colors. Animations are switched off, so everything is drawn where its animation would end.

What isn't faithful:

- The glass is drawn by the same renderer, but against what's inside the window only, and I couldn't compare it with a real screenshot (that needs screen capture). There's no window shadow or desktop behind the window.
- Anything that's a separate window isn't drawn: menus and pop-up menus opened, tooltips, the menu-bar icon's menu, the share sheet, open and save panels. Sheets (About, Feedback) are drawn on their own, not over the dimmed window.
- No hover or pressed states, no focus rings, no text cursor.
- Things that move all the time are one moment of their motion: the live graphs show a fixed eight seconds of demo input, launch animations one chosen frame each, repeating effects (the syncing pulse, Quick assign's pulse) their first frame.
- The Software Update panel's "Installing…" state isn't drawn: it only follows a verified download, which a render can't (and mustn't) produce.
- Sync's "This Mac" row shows the real Mac's name, and app setups show icons of apps installed on the Mac that renders (a generic icon if one isn't).
- `Context leak detected, CoreAnalytics returned false` in the output is macOS noise from the renderer, not an error.

### The self-test: `scripts/self-test.sh`

Proves a build launches without launching it. `--self-test` runs `AppDelegate`'s real launch path (menus, model, hot keys, the launch animation choice, the main window, built but never shown), then draws every tab, the Settings window's five tabs, each Welcome Tour step, the sheets and panels, What's New, "Glideball has a new look" and frames of every launch animation, checks when What's New is due (after an update, never on a fresh install), which icon a Mac starts with (the Orb on a fresh install; the classic one and the question after an update), and that only one thing ever shows over the window (never over the launch animation, the tour or a sheet; What's New, then the icon question, then a link or file preview that had to wait (one with nothing in the way shows straight away), then the weekly recap, then the small favor), checks sharing end to end (Overview and a badge, earned and not, panel to post links), switches pages faster than their transition and with ⇧1–⇧6, checks when the Settings hint goes away, checks the crash-report scrubbing against the server's cases, checks that nothing went live (no engine, no visible window, not the active app), and runs the quit path. One line per step; exit 0 if all pass, 1 on a failure, a crash (the step is named) or a timeout (10 s). The script runs it twice: as a brand-new Mac (first-launch intro) and with `--returning` (a returning user's settings just after an update: short animation, then What's New). It takes about six seconds each.

## Controlling Glideball from other apps

Raycast, Stream Deck, Alfred and shell scripts can control Glideball through a `glideball://` URL scheme, and read what it's doing from a status file. Both are off until **Allow Raycast and scripts** is on (per Mac, never synced, UserDefaults key `GlideAllowExternalControl`, `AppModel.allowExternalControl`, the switch in Settings › General).

Everything goes through one list of commands, `Commands.swift`: the menu-bar menu, the global hot keys and the URLs all call the same entries, so they behave the same. `ExternalControl.swift` turns URLs into commands, `StatusFile.swift` writes the status file, and `ExternalControlApp.swift` connects them to the app.

### The URLs

Open them with `open -g "glideball://…"` (the `-g` keeps Glideball in the background). Percent-encode values (`%20` for a space).

| URL | Does |
| --- | --- |
| `glideball://pause`, `resume`, `toggle` | Pause, resume, or switch between them. Pausing undoes every mode and held key, like the hot key. |
| `glideball://precision?state=on\|off\|toggle` | Precision. `state` defaults to `toggle`; `on` twice stays on. Does nothing while paused. |
| `glideball://scroll-mode?mode=native\|flywheel\|follow` | The main setup's scroll mode. |
| `glideball://pointer-speed?value=<number>` | The main setup's pointer speed. Plain decimals only (`4`, `4.5`); rounded to the slider's 0.5 steps and clamped to 0.5…80. |
| `glideball://per-display-speed?state=on\|off\|toggle` | Per-display pointer speeds (only picks between speeds you set). `state` defaults to `toggle`. |
| `glideball://app-setup?name=<name or bundle ID>` | Uses that app setup whatever app is in front (names ignore case). `name=automatic` goes back to following the app in front, and so does pausing or quitting. Not saved. |
| `glideball://open?tab=overview\|pointer\|scrolling\|buttons\|apps\|sync` | Shows the window, on that tab if given. Works with the switch off. |
| `glideball://settings?tab=general\|trackball\|look\|sound\|sharing\|updates\|privacy\|shortcuts` | Opens Settings, on that tab if given. Works with the switch off. |
| `glideball://check-for-updates` | Opens Software Update and checks. |
| `glideball://import?d=<payload>` | A shared setup: shows its preview. Never changes anything by itself. Works with the switch off. |

### Shared setups (`/s/#…` and `glideball://import`)

The format is written once in [SHARE-FORMAT.md](SHARE-FORMAT.md); the app (`SharedSetup.swift`) and
the website's share page (`website/s/share-decode.js`) both follow it and are checked against the same
fixtures (`website/tests/fixtures/share/`: `swift-made.json` from `scripts/import-sim/run.sh
--write-fixtures`, `js-made.json` and `hostile.json` from `node website/tests/make-share-fixtures.mjs`;
import-sim reads all three with the Swift decoder, `website/tests/share-page.test.mjs` with the page's).

Share… (each page's header menu, the Apps page per setup, Sync › Export) is a checklist: Pointer feel,
Per-display speeds (only when there are some), Scroll feel, Buttons, Combos, Gestures, each app setup,
Ball color and look, Sounds, with Everything and None and a summary line. A page's menu ticks that
page's part; Share Everything… ticks the last choice (`ShareChoiceMemory`, `GlideShareParts`), or
everything but per-display speeds the first time. The JSON (`.glide-settings`, `"format": "glideball-share"`,
`"kind": "parts"`, `parts`) carries exactly the ticked parts, plus `from` (the sender's name, below) when
they chose it. No Mac name goes in it. `version` follows the settings file's rule.

Copy Link and the QR code give `https://glideball.netlify.app/s/#<d>`: the website shows what's in it
and its Import to Glideball button opens `glideball://import?d=<d>` (the same payload; the app still
accepts it directly, and beta 12's one-`kind` links still import). `<d>` is base64url (no padding) of
raw-deflated JSON (Compression's `COMPRESSION_ZLIB`; the page reads it with `DecompressionStream('deflate-raw')`).
The payload after `#` never reaches a server, and nothing is stored. A link is offered only when it's at
most 2,000 characters; otherwise Share… says by how much and offers the file.

The sender's name (`SharingName.swift`): optional, asked in the Welcome Tour's name step and in Settings ›
Sharing, cleaned and at most 40 characters, in this Mac's UserDefaults only (`GlideSharingName`,
`GlideSharingNameOnPictures`, `GlideSharingNameInLinks`). It's not part of `GlideConfig`, so never synced,
backed up or exported; it's never in the opt-in stats, and `CrashReports.scrub` takes it out of crash
reports (the self-test's "the sharing name stays private" checks both). Both switches are off without a
name and on with the first one. It goes on share pictures, badge pictures and the weekly recap with the
first switch, and into a link or file's `from` with the second.

Receiving is the dangerous side, since any page can open the link:
- A link or file opens a preview sheet over Glideball's window listing every setting that would change,
  part by part, before and after (`ImportReview.swift`), each part with a checkbox to leave it out; a
  sender's name shows as "From …, the name they typed, not checked by Glideball". Actions that open an
  app or press keys are marked, and an Open shows its bundle ID. Only Apply changes anything, and only
  the ticked parts: a backup checkpoint, the change, Undo in the toast (which puts the ball color and
  sounds back too).
- One preview at a time; anything arriving while one is open, or in the 1.5 s after it closes, is dropped.
  Links also share the URL rate limit (20 a second).
- The URL is at most 2,100 characters, `d` once and at most 2,048, inflated into a fixed 64 KB buffer
  (anything that fills it is refused), JSON nested at most 32 deep, a known `format`, `kind` and version.
- Every share, settings file and KensingtonWorks import goes through `GlideConfig.sanitizedForImport()`
  (`ImportSafety.swift`): values clamped to the sliders' ranges, text cleaned, counts capped, bundle IDs
  and shortcuts checked, and the primary button never set. A share never changes global shortcuts or
  the pause switch, and per-display speeds only when that part is in it and ticked. Unknown fields are ignored. What any of them
  would give is then clamped like every config from a file, backup or sync (`GlideConfig.clamped()`).
- A chosen or double-clicked file is read by `ImportFile` (`SharedSetup.swift`): plain files only (a link
  someone chose is followed, a pipe or device never), at most 1 MB, then a share or a settings file.
- `scripts/command-sim`, `scripts/import-sim` and `scripts/file-fuzz` throw hostile and fuzzed links and
  files at all of it; the self-test runs the app's real receive path.

KensingtonWorks import: see [KENSINGTONWORKS-IMPORT.md](KENSINGTONWORKS-IMPORT.md).

Commands and values ignore case. Unknown parameters are ignored; an unknown command, a bad or repeated value, or a missing required one means the whole URL is ignored, silently (the scroll log, `~/Library/Logs/Glide/scroll.log`, says `url ignored: <why>`). With the switch off, a URL that would change something does nothing and brings up one short explanation, once per launch. A URL that launches Glideball starts it quietly, like Open at Login (no window unless it's the first launch or a permission is missing).

**Why the list is this short.** Any web page can open a custom URL scheme (browsers ask "Open Glideball?" first, but only once per site), and any app or script can open one with no prompt at all. So a URL may only do things that are safe whoever asks, are undone by asking again, and leave nothing behind. Never anything that deletes, imports, exports, changes what a button does, grants a permission, sends something off the Mac or runs anything; that's why Send Feedback isn't a URL. Scroll with ball and Drag lock aren't either: they freeze the pointer or hold the left button down until switched off, which is fine from your own keyboard but not from a web page. URL text is only compared with fixed lists, parsed as a plain decimal, or matched against your own app setup names; it never reaches a shell, AppleScript, a file path, a format string or the log. At most 20 URLs a second are looked at; the rest are dropped. And the hard rules still hold: the primary button stays a left click, and pause and quit undo everything.

### status.json

`~/Library/Application Support/Glide/status.json` (the data folder keeps the old name). It exists only while the switch is on: turning it off or quitting deletes it, and so does the next launch with the switch off if a crash left one behind. It's written atomically (a temp file, then a rename), when something changes, at most about once a second, on a background queue; today's numbers are checked every 5 seconds. Never in `--render-ui` or `--self-test`.

```json
{
  "activeAppSetup" : { "name" : "Safari", "pinned" : false },
  "appVersion" : "2.10-beta.8",
  "modes" : { "ballScroll" : false, "dragLock" : false, "precision" : true },
  "paused" : false,
  "pid" : 4242,
  "pointerSpeed" : 4.5,
  "schemaVersion" : 1,
  "scrollMode" : "flywheel",
  "today" : { "ballMeters" : 41.25, "clicks" : 1234, "scrollMeters" : 63.5 },
  "trackballConnected" : true,
  "trackballs" : [ "Kensington Expert Mouse" ],
  "updatedAt" : "2026-11-11T18:04:05Z"
}
```

- `schemaVersion`: 1. It goes up only if a field changes meaning or goes away; new fields can appear without it.
- `pid`: the running Glideball's process ID. If no process has it, the file is left over from a crash: treat Glideball as not running.
- `scrollMode`, `pointerSpeed`: the main setup's, which is what the URLs change. An app setup in effect may override them.
- `activeAppSetup`: the setup in effect right now (`pinned` means chosen with `app-setup`), or absent when the main setup is.
- `trackballs`: the trackball Glideball is working with (empty when none is connected).
- `today`: since midnight, distances in meters, rounded to the centimeter.
- `updatedAt`: ISO 8601, UTC.

Nothing else is in it: no app names besides the active setup's, no history, nothing typed.

### The Raycast extension

`raycast-extension/` is a Raycast extension (TypeScript) that uses the URLs and status.json above: Toggle, Pause and Resume Glideball, Toggle Precision Mode, Set Scroll Mode, Set Pointer Speed, Glideball Status, Open Glideball Settings and Check for Glideball Updates. It sends `open -g "glideball://…"` through `execFile` (no shell), reads status.json to confirm each change, and explains what's missing (not installed, not running, or the switch off) instead of failing silently. Its README is the user-facing description.

```sh
cd raycast-extension
npm install
npm run dev      # opens Raycast's develop mode; the commands show up in Raycast
npm run build    # also: npm run lint
```

If a URL or a status.json field changes, update `src/lib/glideball.ts` (the only file that knows them) and the README. `npm run lint` checks `author` against a real Raycast username, so it needs the author's own account. To submit to the store: `npm run publish`, after adding screenshots to `metadata/` (see `metadata/SCREENSHOTS.md`). Not submitted yet.

### App Intents (Shortcuts, Spotlight): not yet

I checked on 2026-11-11 whether a SwiftPM-built, hand-assembled app can offer App Intents without Xcode. The answer for now is no:

- The Command Line Tools have the `AppIntents` framework in the SDK, and `swiftc` compiles an intent fine. It can also write the constant values the metadata step reads (`-emit-const-values-path` with `-Xfrontend -const-gather-protocols-file`, whole-module), and that output looked right.
- But the step that turns those into the bundle's `Contents/Resources/Metadata.appintents` (`appintentsmetadataprocessor`) only ships inside Xcode.app. It isn't in the Command Line Tools (`xcrun --find appintentsmetadataprocessor` fails), and without that metadata macOS never finds the intents, so Shortcuts and Spotlight show nothing.
- The metadata format isn't documented, so writing it by hand would be guesswork that could break with any macOS update.

So nothing is shipped. With Xcode installed it should be possible: build with the const-values flags, run `appintentsmetadataprocessor` (copy its arguments from an Xcode build log) on the binary and those files, and copy `Metadata.appintents` into the app before signing, in `build.sh` and `scripts/release.sh`. The intents would just call `Commands`. Until then, Shortcuts can use the URLs (an Open URLs action with `glideball://…`).

## Translations

Glideball ships in nine languages. How to add or change a string, and how to check every language, is in [`scripts/l10n/README.md`](../scripts/l10n/README.md). Run `scripts/l10n/check.py` before committing anything that adds UI text.

## Releasing

```sh
scripts/ship.sh 2.11 "What's new in this version"
scripts/ship.sh 2.11-beta.1 "What's new in this beta" --beta
```

`ship.sh` does the whole release:

0. `scripts/check.sh` (above) must pass; `--skip-checks` overrides it, with a loud warning.
1. `scripts/release.sh` bumps the version, builds a universal (Apple silicon + Intel) app, signs it, zips it, commits, tags, pushes and publishes the GitHub release. Then it downloads `Glideball.zip` and `Glide.zip` back from GitHub into a temp folder and checks each app: `codesign --verify --deep --strict`, the pinned requirement installed copies check updates against (identifier and certificate leaf), the bundle ID, that the version matches the tag, and that `Glideball.zip` is the file it uploaded. If anything's wrong it says so loudly and exits 1, with the command to pull the release (`gh release edit <tag> --draft`). `scripts/release.sh --verify v2.11` re-runs just that check on any published release.
2. For a full release, `scripts/update-cask.sh` points the [Homebrew cask](https://github.com/leviholliday/homebrew-tap) at it, and `scripts/deploy-site.sh` redeploys the website if `website/` changed since the last full release (`--no-site` skips it).
3. `scripts/attach-previews.sh` waits for CI and attaches the Linux and Windows previews.

It doesn't install the new build locally; update your own copy from inside Glideball, which tests the update path too.

With `--beta`, the release is a GitHub prerelease: only people in the Beta program see it, and the website (which always offers the newest full release) isn't redeployed. A prerelease version like `2.11-beta.1` must use `--beta`, so a beta can't reach everyone by accident.

Everyone else sees a button with the new version number at the top of the window within a day. **Install & Relaunch** downloads the zip, checks that the new app satisfies the running app's own designated requirement (same certificate and bundle ID, `UpdateChecker.swift`), refuses it otherwise, swaps the app and relaunches. Permissions carry over because the signature matches.

`scripts/release.sh` on its own does just the GitHub half (checks included) and has `--dry-run` (stop after building the zip), `--prerelease`, `--skip-checks` and `--verify <tag>`.

## Feedback backend

Send Feedback (in the app) and the website's [/feedback](https://glideball.netlify.app/feedback/) page post to a small Netlify function (`website/netlify/functions/feedback.mjs`). Reports are stored in Netlify Blobs and read on the password-protected admin site (`admin-site/`, admin-glideball.netlify.app), whose edge function passes `/api/admin/*` on to `admin.mjs` on the main site with a shared secret ([ADMIN-SITE.md](ADMIN-SITE.md)). Each new report triggers an ntfy push with its title, priority and app version, not the message itself (`website/netlify/lib/common.mjs`). `cleanup.mjs` prunes old data on a schedule.

## Linux & Windows

The previews share the Mac app's scroll physics, buttons, combos and `.glide-settings` format. See [linux/README.md](../linux/README.md) and [windows/README.md](../windows/README.md). CI builds and tests both (`.github/workflows/`).
