# Importing from KensingtonWorks

What Glideball knows about KensingtonWorks' settings, how it reads them, and what's still a guess.
Code: `Sources/Glide/KensingtonWorks.swift`. Tests: `scripts/import-sim/` (fixtures in `fixtures/`).

## Where the settings are

KensingtonWorks 2.x on macOS (an Electron app with the DriverKit driver `com.kensington.tbwDKDriver`)
keeps everything in one JSON file that stays behind after it's uninstalled:

```
~/Library/Preferences/TbwSettings.json
```

Confirmed from a real file on Levi's Mac (written by KensingtonWorks 2.0, `versionMajor: 2`,
`versionMinor: 0`, after the app itself was uninstalled). The other leftovers have no settings in
them: `~/Library/Application Support/KensingtonWorks/` is Electron's Chromium profile (empty
`Local Storage`, a 3-byte `Settings`), and `~/Library/Preferences/com.kensington.kensingtonworks2.app.plist`
only holds window state. A web search (Kensington's pages and release notes, forums, GitHub) found no
documentation of the file and no other project that reads it.

## The format

```json
{
  "devices": [
    [4128, {
      "*": { "name": "*", "fileName": "", "config": { … } },
      "com.example.editor-Editor": { "name": "Editor", "fileName": "", "config": { … } }
    }]
  ],
  "platform": "darwin", "timestamp": 1790992180, "trayIcon": true,
  "versionMajor": 2, "versionMinor": 0
}
```

- `devices`: a list of `[USB product ID, profiles]` pairs. 4128 is `0x1020`, the wired Expert Mouse.
- Profiles: `"*"` is the main setup; every other key is an app profile, `"<bundle ID>-<app name>"`.
- `config`:
  - `commands`: a list of `[button mask, { "command": …, "params": … }]`.
  - `speed`, `acceleration`, `accelerationRate`, `customspeed`, `customacceleration`, `customaccelerationRate`: pointer.
  - `scrollLines`, `scrollInvert`, `inertialScroll`, `inertialScrollFactor`, `inertialScrollNullSteps`, `inertialScrollTimer`: scrolling.
  - `slowModifiers`, `snapModifiers`, `lockedAxisModifiers`, `customModifiers`: keys that change the pointer while held.
  - `snippets`: ten `{ "label", "content" }` text snippets.

Command names seen in the real file: `mouse_leftClick`, `mouse_rightClick`, `mouse_button5Click`,
`missionControl_missionControl`, `keyboard_shortcut` (`params`: `keyCode`, `modifiers`, `label`),
`disable`, `navigation_scrollLeft`, `navigation_scrollRight`.

## How Glideball maps it

| KensingtonWorks | Glideball | How sure |
| --- | --- | --- |
| mask 1, 2, 4, 8 | buttons 0 (bottom left), 1 (bottom right), 2 (top left), 3 (top right) | Inferred: it's the HID button order, which Glideball also uses, and the real file's app profile has left and right click on 1 and 2 |
| masks with two bits (3, 5, 10, 12) | combos of those buttons; `disable` there means no combo | Inferred the same way (KensingtonWorks offers exactly the top, bottom, left and right pairs) |
| mask 16 (`mouse_button5Click`) | left out: the Expert Mouse has four buttons | |
| masks 1<<30, 1<<31 (`navigation_scrollLeft/Right`) | left out (Glideball scrolls sideways with ⇧) | Inferred |
| `mouse_leftClick`, `mouse_rightClick`, `missionControl_missionControl`, `disable` | Left click, Right click, Mission Control (⌃↑), Do nothing | Confirmed names |
| `mouse_middleClick`, `mouse_button4Click`, `mouse_button5Click` | Middle click, Back, Forward | Names guessed from their siblings |
| `keyboard_shortcut` | that shortcut; `keyCode` is a Mac virtual key code, `modifiers` words like `cmd`, `ctrl`, `alt`, `shift` | Key codes fit the labels (8 is C for "Copy"). Whether `ctrl` really means ⌃ (and not ⌘ written the Windows way) isn't confirmed; it's imported as ⌃ and shown in the preview |
| `inertialScroll` true / false | Flywheel with Kensington feel / Native | |
| `scrollInvert` | Reverse direction | |
| speed, acceleration, `scrollLines`, snippets, slow/snap/locked-axis keys, any other command | not imported; the preview lists each one under "No equivalent in Glideball" and says why | |

The primary button never changes. App profiles become app setups (buttons and combos are the main
ones with the app's laid over them, like KensingtonWorks does). Only one device is imported: the
Expert Mouse if it's there, otherwise the first one, with a note.

## Safety

- Read-only: the file is opened for reading only; nothing of KensingtonWorks' is written, moved or deleted.
- Treated as hostile: at most 2 MB, JSON nesting at most 24 deep, every value type-checked (a `1` isn't
  `true`, a `true` isn't a number), strings cleaned of control and invisible characters and cut short,
  counts capped (16 devices, 100 profiles, 64 commands each), and the result goes through the same
  `sanitizedForImport()` as any settings file. `import-sim` throws malformed, hostile and 3,000 fuzzed files at it.
- Nothing changes until Import in the preview; a backup checkpoint comes first, and Undo follows.
- `--render-ui` and `--self-test` never read the real file (`KensingtonWorksSource.sample`).

## What would make it certain

From anyone who still has KensingtonWorks installed (Levi no longer does), with any Kensington trackball:

1. In KensingtonWorks, set each button to something different and easy to tell apart (bottom left:
   left click, bottom right: Copy, top left: Paste, top right: Mission Control), set the four chords to
   different shortcuts, and add one app profile.
2. Turn inertial scrolling on, invert scrolling, and set a custom speed.
3. Send `~/Library/Preferences/TbwSettings.json` (it holds no personal data unless snippets are used;
   clear those first), plus a note of which physical button got which action and which trackball model.

That would confirm the bit order on each model, the chord masks, what `ctrl` means, the names of other
commands (launch an app, media keys, back/forward), and what `speed` and `scrollLines` measure.
