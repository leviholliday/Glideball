# Developing Glideball

Everything that used to sit in the bottom half of the README: how Glideball works inside, how to build it, and how releases go out. If you just want to use Glideball, the [README](../README.md) is all you need.

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
./build.sh --icon    # also re-render the app icon first
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

## Translations

Glideball ships in nine languages. How to add or change a string, and how to check every language, is in [`scripts/l10n/README.md`](../scripts/l10n/README.md). Run `scripts/l10n/check.py` before committing anything that adds UI text.

## Releasing

```sh
scripts/ship.sh 2.11 "What's new in this version"
scripts/ship.sh 2.11-beta.1 "What's new in this beta" --beta
```

`ship.sh` does the whole release:

1. `scripts/release.sh` bumps the version, builds a universal (Apple silicon + Intel) app, signs it, zips it, commits, tags, pushes and publishes the GitHub release.
2. For a full release, `scripts/update-cask.sh` points the [Homebrew cask](https://github.com/leviholliday/homebrew-tap) at it, and `scripts/deploy-site.sh` redeploys the website if `website/` changed since the last full release (`--no-site` skips it).
3. `scripts/attach-previews.sh` waits for CI and attaches the Linux and Windows previews.

It doesn't install the new build locally; update your own copy from inside Glideball, which tests the update path too.

With `--beta`, the release is a GitHub prerelease: only people in the Beta program see it, and the website (which always offers the newest full release) isn't redeployed. A prerelease version like `2.11-beta.1` must use `--beta`, so a beta can't reach everyone by accident.

Everyone else sees a button with the new version number at the top of the window within a day. **Install & Relaunch** downloads the zip, checks that the new app satisfies the running app's own designated requirement (same certificate and bundle ID, `UpdateChecker.swift`), refuses it otherwise, swaps the app and relaunches. Permissions carry over because the signature matches.

`scripts/release.sh` on its own does just the GitHub half and has `--dry-run` (stop after building the zip) and `--prerelease`.

## Feedback backend

Send Feedback (in the app) and the website's [/feedback](https://glideball.netlify.app/feedback/) page post to a small Netlify function (`website/netlify/functions/feedback.mjs`). Reports are stored in Netlify Blobs and read on a password-protected admin page (`admin.mjs`). Each new report triggers an ntfy push with its title, priority and app version, not the message itself (`website/netlify/lib/common.mjs`). `cleanup.mjs` prunes old data on a schedule.

## Linux & Windows

The previews share the Mac app's scroll physics, buttons, combos and `.glide-settings` format. See [linux/README.md](../linux/README.md) and [windows/README.md](../windows/README.md). CI builds and tests both (`.github/workflows/`).
