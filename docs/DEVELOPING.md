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

## All the checks: `scripts/check.sh`

One command runs everything that should pass before a release, prints a line per step and a summary, and exits non-zero if anything failed (each step's output is in `build/check/<step>.log`; `-v` shows it as it runs):

| Step | What |
| --- | --- |
| build | `swift build -c release` |
| scroll-sim, backup-sim, command-sim | the three simulators above |
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

Screens: the six tabs as the window opens (`overview`, `pointer`, `scrolling`, `buttons`, `apps`, `sync`) and each whole tab top to bottom (`*-page`, the content column without the sidebar); the sidebar's trackball in each of its looks, at its own size and large (`trackball-states`); states (`permissions-needed`, `permissions-half`, `paused`, `no-trackball`, `other-kensington`, `modes-on`, `app-setup-active`, `celebration-toast`, `celebration-confetti`, `toast-import`, `import-preview`, `quick-assign`, `small-favor`); the Welcome Tour (`tour-1-welcome` … `tour-5-done`, plus `tour-3-buttons-found`); What's New (`whats-new`, and `min-size-whats-new` with the tour's busiest steps at the smallest window); `about`, `feedback`, `feedback-idea`, `feedback-sending`, `feedback-sent`, `backup-history`; Settings (`settings-general`, `-updates`, `-privacy`, `-shortcuts`, through the real Settings window with its toolbar); frames of the launch animations (`launch-intro-rolling-in`, `-ring-spinning-up`, `-finished`; `launch-ring-spin` and `launch-roll-in`, each also `-start`; `launch-fade`); Software Update (`update-checking`, `-failed`, `-up-to-date`, `-available`, `-in-header`, `-downloading`, `-install-failed`, reached by answering the update check and download with canned replies).

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

Proves a build launches without launching it. `--self-test` runs `AppDelegate`'s real launch path (menus, model, hot keys, the launch animation choice, the main window, built but never shown), then draws every tab, the Settings window's four tabs, each Welcome Tour step, the sheets and panels, What's New and frames of every launch animation, checks when What's New is due (after an update, never on a fresh install) and that only one thing ever shows over the window (never over the launch animation or the tour; What's New before the small favor), checks that nothing went live (no engine, no visible window, not the active app), and runs the quit path. One line per step; exit 0 if all pass, 1 on a failure, a crash (the step is named) or a timeout (10 s). The script runs it twice: as a brand-new Mac (first-launch intro) and with `--returning` (a returning user's settings just after an update: short animation, then What's New). It takes about six seconds each.

## Controlling Glideball from other apps

Raycast, Shortcuts, Stream Deck, Alfred and shell scripts can control Glideball through a `glideball://` URL scheme, and read what it's doing from a status file. Both are off until **Allow Raycast and scripts** is on (per Mac, never synced, UserDefaults key `GlideAllowExternalControl`, `AppModel.allowExternalControl`; the switch in Settings › General isn't drawn yet).

Everything goes through one list of commands, `Commands.swift`: the menu-bar menu, the global hot keys and the URLs all call the same entries, so they behave the same. `ExternalControl.swift` turns URLs into commands, `StatusFile.swift` writes the status file, and `ExternalControlApp.swift` connects them to the app.

### The URLs

Open them with `open -g "glideball://…"` (the `-g` keeps Glideball in the background). Percent-encode values (`%20` for a space).

| URL | Does |
| --- | --- |
| `glideball://pause`, `resume`, `toggle` | Pause, resume, or switch between them. Pausing undoes every mode and held key, like the hot key. |
| `glideball://precision?state=on\|off\|toggle` | Precision. `state` defaults to `toggle`; `on` twice stays on. Does nothing while paused. |
| `glideball://scroll-mode?mode=native\|flywheel\|follow` | The main setup's scroll mode. |
| `glideball://pointer-speed?value=<number>` | The main setup's pointer speed. Plain decimals only (`4`, `4.5`); rounded to the slider's 0.5 steps and clamped to 0.5…80. |
| `glideball://app-setup?name=<name or bundle ID>` | Uses that app setup whatever app is in front (names ignore case). `name=automatic` goes back to following the app in front, and so does pausing or quitting. Not saved. |
| `glideball://open?tab=overview\|pointer\|scrolling\|buttons\|apps\|sync` | Shows the window, on that tab if given. Works with the switch off. |
| `glideball://settings?tab=general\|updates\|privacy\|shortcuts` | Opens Settings, on that tab if given. Works with the switch off. |
| `glideball://check-for-updates` | Opens Software Update and checks. |

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

Send Feedback (in the app) and the website's [/feedback](https://glideball.netlify.app/feedback/) page post to a small Netlify function (`website/netlify/functions/feedback.mjs`). Reports are stored in Netlify Blobs and read on a password-protected admin page (`admin.mjs`). Each new report triggers an ntfy push with its title, priority and app version, not the message itself (`website/netlify/lib/common.mjs`). `cleanup.mjs` prunes old data on a schedule.

## Linux & Windows

The previews share the Mac app's scroll physics, buttons, combos and `.glide-settings` format. See [linux/README.md](../linux/README.md) and [windows/README.md](../windows/README.md). CI builds and tests both (`.github/workflows/`).
