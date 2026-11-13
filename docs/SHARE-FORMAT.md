# The shared-setup format

What Share… makes and what `glideball://import`, a `.glide-settings` share file and the website's
`/s/` page read. There is one format, written once here; the Mac app (`SharedSetup.swift`) and the
page (`website/s/share-decode.js`) both follow it, and both are tested against the same fixtures
(`website/tests/fixtures/share/`, see the end).

## The link

```
https://glideball.netlify.app/s/#<d>      what Copy Link and the QR code give
glideball://import?d=<d>                  what the page's Import to Glideball opens (and the app still accepts)
```

`<d>` is the payload: **base64url without padding** (RFC 4648 §5, `-` and `_`, no `=`) of the
**raw DEFLATE** stream (RFC 1951, no zlib or gzip header) of the share's **UTF-8 JSON**.

- The Mac app writes it with Compression's `COMPRESSION_ZLIB`, which is raw deflate. Beta 12 links
  used exactly the same payload, so they still import.
- The page reads it with the browser's own `DecompressionStream('deflate-raw')` (Safari 16.4,
  Chrome 103 and Firefox 113 and later; Glideball needs macOS 26, whose Safari has it). There's no
  JavaScript inflate to maintain; a browser without it gets a friendly "this browser can't read it,
  open it in Glideball" page and no Import button.
- On the website the payload sits after `#`: the fragment is never sent to the server (browsers
  don't put it in requests or in the `Referer`), so nothing about a share reaches Netlify, and
  nothing is stored anywhere. Whoever has the link has the settings; that's all.

Sizes: a sender offers the https link only when the whole link is at most **2,000 characters**
(otherwise it says why and offers the file). A receiver accepts `d` of at most **2,048** characters
and inflates into at most **65,535 bytes**; output that reaches 65,536 is refused (a zip bomb, or
cut off). JSON nested deeper than **32** levels (brackets outside strings) is refused before it's
parsed.

## The JSON

A share made by Glideball 2.10 beta 13 and later (a "checklist share"):

```json
{
  "format": "glideball-share",
  "version": 1,
  "kind": "parts",
  "parts": ["pointer", "scrolling", "buttons", "combos", "gestures", "app:com.apple.Safari", "look", "sounds"],
  "from": "Levi",
  "writtenBy": "2.10-beta.13",

  "trackingSpeed": 6.5,
  "precisionSpeed": 1,
  "displaySpeeds": { "enabled": true, "speeds": { "1552-41234-0": 8 }, "names": { "1552-41234-0": "LG UltraFine" } },
  "scroll": { "scrollMode": "flywheel", "nativeScrollSpeed": 0.5, "flyDistance": 4, "flyAcceleration": 0.5,
              "flyGlide": 0.35, "flyReach": 0.5, "smoothScrolling": true, "scrollDistance": 14,
              "scrollSmoothness": 0.4, "scrollAcceleration": 0.5, "throwEnabled": true, "throwAmount": 0.4,
              "reverseScroll": false, "shiftScrollsHorizontally": true },
  "ballScrollSpeed": 1,
  "buttons": { "1": { "rightClick": {} }, "2": { "shortcut": { "_0": { "keyCode": 8, "modifiers": 1048576, "keyName": "C" } } },
               "3": { "gesture": { "_0": { "up": { "action": { "media": { "_0": 0 } }, "repeats": true }, "tap": { "system": {} } } } } },
  "chords": [ { "buttons": [2, 3], "action": { "openApp": { "bundleID": "com.apple.Notes" } } } ],
  "gesturesEnabled": true,
  "gestureDistance": "normal",
  "gestureSteadyHands": false,
  "apps": [ { "bundleID": "com.apple.Safari", "name": "Safari", "trackingSpeed": 3, "buttons": { "2": { "back": {} } } } ],
  "look": { "theme": "custom", "custom": ["FFE070", "2EC99A", "2B3A9E"] },
  "sounds": { "on": true, "volume": 0.8, "kinds": { "pauseResume": true, "modes": true, "ticks": false, "milestones": true, "buttons": true } }
}
```

Every field but `format`, `version`, `kind` and `parts` is optional. Unknown fields are ignored.

| Field | Meaning |
| --- | --- |
| `format` | Always `"glideball-share"`. |
| `version` | 1, or 2 when what's inside uses something a Glideball before 2.10 would drop (gestures, media keys, Open an app, per-display speeds): the settings file's own rule. Anything else is refused. |
| `kind` | `"parts"` for a checklist share. Beta 12's kinds are still read (below). |
| `parts` | What's in it, as ids: `pointer`, `displays`, `scrolling`, `buttons`, `combos`, `gestures`, `app:<bundle ID>` (one per app setup), `look`, `sounds`. Unknown ids are ignored (a newer Glideball's part), repeats count once. A part whose fields are missing is dropped; a share with no parts left is refused. |
| `from` | The sender's name, only when they turned on "Put my name on shared links and files". Free text they typed, **never verified**: shown as plain text, labelled as what they typed. Cleaned (below) to at most 40 characters; empty means absent. |
| `writtenBy` | The Glideball version that made it (cleaned, at most 24 characters). Never a Mac's name. |

What each part carries and what applying it does:

| Part | Fields | Applying it |
| --- | --- | --- |
| `pointer` | `trackingSpeed`, `precisionSpeed` | Sets those two speeds. |
| `displays` | `displaySpeeds` (`enabled`, `speeds`: display key → speed, `names`: display key → name) | Sets the per-display switch and speeds. Display keys are `vendor-model-serial` (or `uuid-…`), so they only match the same displays: this is mostly for moving your own setup to another Mac. |
| `scrolling` | `scroll` (the 14 scroll settings above), `ballScrollSpeed` | Sets the main setup's scroll feel and Scroll with ball speed. |
| `buttons` | `buttons`: an entry for **every** button 1–7 whose action isn't a gesture (`{"system":{}}` for Default) | Each of those buttons gets that action. A button the sender had as a gesture isn't in it, so it stays as it is. |
| `gestures` | `buttons`: an entry for each button that is a gesture; `gesturesEnabled`, `gestureDistance` (`short`, `normal`, `long`), `gestureSteadyHands` | Those buttons become those gestures; the three gesture settings are set. |
| `combos` | `chords` (may be empty: "no combos") | Replaces the combos. |
| `app:<id>` | an entry with that `bundleID` in `apps` | Adds that app setup, or replaces the one for the same app. Other app setups stay. |
| `look` | `look` | Uses that ball color. |
| `sounds` | `sounds` (`on`, `volume` 0–1, `kinds`: `pauseResume`, `modes`, `ticks`, `milestones`, `buttons`) | Sets the Sounds switch, volume and the per-kind switches. |

`buttons` is shared by `buttons` and `gestures`: an entry whose action is a gesture belongs to
`gestures`, any other entry to `buttons`. The receiver applies an entry only if its part is applied.

Never in a share, whatever is ticked: the primary button (button 0 is always a left click and is
never read), Glideball's global keyboard shortcuts, the pause switch, the Mac's name, the name of
anything on disk, stats, or anything that identifies the Mac.

### Actions

Button, combo, gesture-direction and tap actions are Swift's default `Codable` form of
`ButtonAction`:

| JSON | What it does (the app's words) |
| --- | --- |
| `{"system":{}}` | Default (the button's own click) |
| `{"leftClick":{}}`, `rightClick`, `middleClick`, `back`, `forward` | Left click, Right click, Middle click, Back, Forward |
| `{"disabled":{}}` | Do nothing |
| `precisionHold`, `precisionToggle`, `ballScrollHold`, `dragLock` | Precision (hold), Precision (toggle), Scroll with ball (hold), Drag lock |
| `{"shortcut":{"_0":{"keyCode":8,"modifiers":1048576,"keyName":"C"}}}` | A keyboard shortcut (`holdShortcut`: held while the button is) |
| `{"modifiedClick":{"button":0,"modifiers":262144}}` | A click with modifiers (Control-click) |
| `{"media":{"_0":16}}` | A media key: 0 Volume Up, 1 Volume Down, 7 Mute, 16 Play or Pause, 17 Next Track, 18 Previous Track |
| `{"openApp":{"bundleID":"com.apple.Notes"}}` | Opens an app |
| `{"gesture":{"_0":{"up":{"action":…,"repeats":false,"once":true},"down":…,"left":…,"right":…,"tap":…,"distance":"short"}}}` | Hold and roll. Each direction is optional; `repeats` (continuous) and `once` (once per hold) are optional; `tap` defaults to Default. |

Modifier bits are macOS's `CGEventFlags`: ⇧ 131072, ⌃ 262144, ⌥ 524288, ⌘ 1048576, fn 8388608.
A shortcut reads as ⌃⌥⇧⌘ (in that order, the ones that are set) followed by `keyName`.

## Checks (both sides, the same)

The payload is hostile until proven otherwise: any web page can open a `glideball://` link, and
anyone can make a `/s/` link.

- `d`: 1–2,048 characters, only `A–Z a–z 0–9 - _`; it must base64-decode and inflate as above.
- JSON: an object, nesting ≤ 32, `format`, `version`, `kind` (and for `parts`, `parts`) as above.
- Numbers must be finite numbers; anything else means "not given". Each is clamped to what the
  app's own controls allow: pointer speed 0.5–80, Precision 0.25–3, Native scroll speed 0–5,
  slow-turn distance 1–20, spin power 0–1.5, glide, reach, smoothness, acceleration and throw 0–1,
  distance per tick 1–40, Scroll with ball 0.25–4, display speeds 0.5–80, sound volume 0–1.
- Buttons: keys `"1"`–`"7"` only. An action that isn't one of the above is skipped (that button
  isn't set). A shortcut needs `keyCode` 0–127; modifiers are masked to ⇧⌃⌥⌘fn; `keyName` is
  cleaned to 12 characters (`?` if empty). A modified click's button is 0–4. An Open's bundle ID
  is 1–155 ASCII letters, digits, `.`, `-` and `_`, not starting or ending with `.` and without
  `..`. A gesture can't contain a gesture.
- Combos: 2–4 distinct buttons from 0–7, a set at most once, at most 24 combos.
- App setups: at most 64, a valid bundle ID each (a bad one is dropped), names cleaned to 80
  characters (empty: the bundle ID).
- Per-display speeds: at most 16, keys at most 120 characters, names cleaned to 80.
- Ball color: one of `orb`, `ember`, `sunset`, `ocean`, `forest`, `graphite`, `classic`, or
  `custom` with exactly three six-digit hex colors. Anything else drops the part.
- Text (`from`, names, key names): control and invisible format characters (Unicode Cc and Cf,
  U+2028, U+2029) removed, trimmed, cut to its length.

The page additionally treats every string as text only: it's put on the page with `textContent`,
never as HTML; nothing from a share becomes a URL, an image or a style except the three validated
hex colors (set as CSS custom properties); and the `glideball://` link is built from `d` only after
`d` passed every check.

## Beta 12 shares (still read)

`kind` was one of these, with `version`, `format`, `writtenBy` and only that part's fields. Each is
read as the parts shown, so the rest of the app and the page only see checklist shares.

| `kind` | Fields | Read as |
| --- | --- | --- |
| `pointer` | `trackingSpeed`, `precisionSpeed` | `pointer` |
| `scrolling` | `scroll`, `ballScrollSpeed` | `scrolling` |
| `buttons` | `buttons` (missing buttons meant Default), `chords`, `gesturesEnabled` | `buttons`, `gestures` (and `combos` when `chords` is there), with buttons 1–7 filled in |
| `app-setup` | `appSetup` (one app setup), `name` | `app:<its bundle ID>` |
| `look` | `look` | `look` |
| `everything` | `config` (a whole settings object), `look` | `pointer`, `scrolling`, `buttons`, `gestures`, `combos`, each app setup, and `look` if present. Never the per-display speeds or global shortcuts it also carried. |

## Fixtures

`website/tests/fixtures/share/`:

- `swift-made.json`: payloads made by the Mac app's real code (`scripts/import-sim/run.sh --write-fixtures`).
- `js-made.json`: payloads made by Node's `zlib.deflateRawSync` (`node website/tests/make-share-fixtures.mjs`).
- `hostile.json`: payloads both sides must refuse, or accept only clamped and cleaned.

Each good case has `d` and `expect` (parts, `from`, and a few values). `scripts/import-sim` checks
all three files with the Swift decoder; `website/tests/share-page.test.mjs` with the page's.
