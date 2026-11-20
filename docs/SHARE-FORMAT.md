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
A shortcut reads as ⌃⌥⇧⌘ (in that order, the ones that are set) followed by the key's name, **worked
out from `keyCode`**. `keyName` is still written (older versions and the other platforms want a
string there) but it's whatever the sender's file says, so it must never be what's shown: a share
could say `"keyName": "C"` beside `"keyCode": 12`, which is Q. Since 2.10 beta 35 the Mac app ignores
it (`KeyNames` in `Config.swift`: arrows, Space, ↩, ⇥, ⌫, ⌦, ⎋, Home, End, PgUp, PgDn, F1–F20 and the
keypad by fixed names; letters, digits and punctuation by the reader's keyboard layout, the US one
when it can't be read; `Key 110` for anything else).

The website's `/s/` page does the same since 19 Nov 2026 (`keyNameFor` in `website/s/share-decode.js`), with the US names for the keys a layout decides, since a page can't read the keyboard layout by key code. On a non-US layout the page's letter can differ from the app's preview; the app's preview is the one that counts. `hostile.json` has a spoofed-name case.

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
  not read by the app or the page (see above). A modified click's button is 0–4. An Open's bundle ID
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

## Pasting a link (the Mac app)

Since 19 Nov 2026 (after 2.10 beta 35) a link can be pasted into Glideball itself: Import › Paste a Link… on every page
(and Sync › Import, File › Paste a Link…, search), File › Import Setup from Clipboard, or ⌘V on the
main window while nothing in it takes text. `ImportPaste.swift` reads the text; what it finds goes
through `SharedSetup.decode(linkPayload:)` (or `ExternalControl.parseImport` itself, for a pasted
`glideball://` link) and on to the same preview, clamps, backup checkpoint and Undo as
`glideball://import`. The one difference: the 1.5 s pause after a preview closes doesn't apply,
since that's there to stop a page firing links and a paste is the person's own click.

The clipboard is read only on that click or keypress, never when the box opens, never to enable a
menu item, never in the background. In `--self-test` and `--render-ui` it isn't read at all.

The rule:

- At most 16,384 bytes of text; more is refused unread.
- Invisible format characters (Unicode Cf: zero-width spaces, soft hyphens, direction overrides)
  are removed, since chat apps put them inside long links. Nothing else is normalized: no case
  folding beyond ASCII, no NFKC, so a fullwidth or Cyrillic look-alike never matches.
- The text is cut into words at whitespace and at `" ' \` < > ( ) [ ] { } | *`, curly quotes and
  `« »`; then `. , ; : ! ?` are taken off a word's end. So a link in a sentence, quotes, Markdown or
  angle brackets is found.
- A word is accepted only when it is exactly `https://glideball.netlify.app/s/#<d>` (scheme and host
  in any ASCII case, then exactly `/s/#`) or a link that starts exactly `glideball://import?d=`
  (any ASCII case) and that `ExternalControl.parseImport` accepts; `glideball://import:?d=…` (an
  empty port, which the URL handler refuses too) and `glideball://import/?d=…` read as damaged.
  Everything else is refused even if what follows its `#`
  decodes: `http://`, no scheme, `www.`, a port, a user, a trailing dot, a query, another path,
  `glideball.netlify.app.evil.com`, `evil.com/glideball.netlify.app/s/#…`, punycode and other
  look-alikes. A `glideball://` link that isn't `import` (`glideball://pause`) is refused: a paste
  never runs a command.
- With no link in it, the whole text (trimmed) may be a bare `<d>`: 24 to 2,048 of `A–Z a–z 0–9 - _`.
- Two different setups in one paste are refused; the same one twice (or its web and app links side
  by side) is one. A refused `glideball://import` link refuses the whole paste.
- A link split over two lines reads as damaged (a line break ends a word).

`scripts/import-sim` ("Pasting") checks every case above, plus 2,000 mangled messages.

## Setup codes (Set up with AI)

Glideball has no AI in it and sends nothing anywhere. Set up with AI copies a prompt (built by
`AIReference.swift` at copy time) that the person pastes into any chatbot; the chatbot ends with a
**setup code**, plain JSON the person pastes back into the same paste box. A chatbot can't write the
link (it can't deflate), and it gets key codes, modifier masks and bundle IDs wrong, so a code is
this format with a thinner skin. `SetupCode.swift` and `SetupCodeReader.swift` turn it into an
ordinary `SharedSetup`, which is written out and read back through `SharedSetup.decode(json:)`; from
there it's the same clamps, `ImportSafety`, preview, backup checkpoint ("Before AI setup") and Undo
as any share. Only the app reads codes; the website doesn't.

```json
{"format": "glideball-ai-setup", "version": 1,
 "trackingSpeed": 6,
 "scroll": {"scrollMode": "follow", "scrollDistance": 18},
 "buttons": {"2": "keys:cmd+w",
             "3": {"gesture": {"left": "keys:ctrl+left", "right": "keys:ctrl+right",
                               "down": {"more": {"left": "media:previous", "right": "media:next"}},
                               "tap": "back", "show": "afterPause", "ring": "volume"}}},
 "combos": [{"buttons": [2, 3], "action": "open:Notes"}, {"buttons": [1, 3], "remove": true}],
 "apps": [{"app": "Safari", "buttons": {"2": "keys:cmd+t"}}],
 "look": {"theme": "ocean"},
 "sounds": {"volume": 0.5}}
```

What's different from a share:

- **Actions are short text**: `system leftClick rightClick middleClick back forward disabled
  precisionHold precisionToggle ballScrollHold dragLock switcher`, `keys:<mods+key>`,
  `holdKeys:<mods+key>`, `click:<mods+left|right|middle>`, `media:<playPause|next|previous|volumeUp|volumeDown|mute>`,
  `open:<app name or bundle ID>`, or `{"gesture": {…}}` / `{"switcher": {"tap": action}}`. Modifiers
  are `cmd ctrl opt shift fn` (and their long names); a key is one of `SetupKeys.fixed`, `key<0–127>`,
  or the character the key types on this Mac's layout (the US one when it can't be found), so
  `keys:cmd+a` presses the key that types A here. A shortcut needs a real key. The share format's own
  `{"shortcut":{"_0":…}}` is not read in a code at all (so a spoofed `keyName` never gets in).
- **Apps by name**, found on this Mac through Launch Services (`InstalledApps`), or by the exact bundle
  ID of an app already in the person's setup. Never guessed: an app that isn't found is left out.
- **Only what changes.** `parts` is worked out from the fields there. `scroll` and `sounds` are laid
  over the person's current values, and so are an app setup's areas, its buttons, and the combos (a
  combo for the same buttons, in any order, replaces that one's action, `"remove": true` takes one
  away). A code can't delete an app setup.
- **`null` works in exactly three places**: in an app setup, on `trackingSpeed`, `scroll`,
  `buttons`, `combos` or one of its buttons (back to what the main setup has: for one button, the
  main setup's action at the time); as a combo's `action` (the combo goes, like `"remove": true`);
  inside a gesture or a More (that place, tap or setting is empty or the usual one, as if it were
  left out). Anywhere else (a main setup's setting or button, a scroll or sound key, `look`) it's
  left out with a note (`SetupCodeReader.nullHint`).
  The prompt teaches only the first (one way to say each thing: a combo goes with
  `"remove": true`, an empty direction is left out); the reader takes the other two because
  chatbots write them anyway. import-sim checks both the prompt's wording and the reader.
- **A held shortcut inside a gesture** (`holdKeys:` as a direction, a More's place or the tap) is
  read and kept, and fires as one quick press (`GestureStep.firable`); the prompt's reference says
  so. The modes that hold (`precisionHold`, `ballScrollHold`, `dragLock`) can't be a direction.
- **Never read from a code**: button 0 (the primary button), `from`, `writtenBy`, `displaySpeeds`,
  global shortcuts, the pause switch, a whole settings object (`config`), and a Switcher's `hidden`
  (the apps it already hides stay hidden). Each is listed as left out if it's there.
- **Nothing is left out quietly.** Every value that can't be used (wrong type, unknown action, key,
  app or setting, a gesture inside a gesture, something held on a direction, a More's way back)
  becomes a `Note`: shown in the preview's "Left out" section, and in **Copy Note for the AI**, an
  English note built from fixed text plus the code's own words cleaned and cut to 80 characters.

Finding the code (`SetupCode.object(in:)`): at most 256 KB of text; the `{…}` around the last
`"glideball-ai-setup"` first, then the biggest blocks; read as it is, then tidied (curly quotes
straightened, `//` and `/* */` comments and trailing commas dropped, never inside a string); at most
64 KB of JSON, nested at most 32. A code that starts and never ends says it's cut off. Text that's a
share's own JSON goes to the share decoder as it is. A code that came back HTML-escaped (a chat page's
or an email's copy) is read with `&quot; &#34; &#x22; &#39; &#x27; &apos; &lt; &gt; &amp;` undone
(`&amp;` last), but only after it couldn't be read as it is, and only when it's clearly an escaped
code (`SetupCode.htmlUnescaped`: `&quot;` around its words, `{&quot;` or `&quot;format&quot;`, and no
real `{"` or `":` in it).

In the paste box (`ImportPaste.read(_:codes:codeFirst:)`): a Glideball link in the text is still
found by the link rules above, unless the text is marked as a code. A code wrapped in or beside a
link (`https://glideball.netlify.app/s/#{…}`, `glideball://pause {…}`, a look-alike host) is read
from its JSON, as a chatbot's, and never runs anything. ⌘V on the window with a marked code opens
Set up with AI with it in the box; Paste a Link… takes a code too and shows the usual preview,
labelled "Written by a chatbot".

There is no action that runs a command, a script or a file (`SetupCode.isSettingsOnly` is an
exhaustive switch over `ButtonAction`, so a new action can't be added without deciding).
`scripts/import-sim` ("Setup codes", "The prompt", "The paste box") checks: every action and preset
written and read back, every key on a US and a French layout, the reference against the model (every
action, range, default, enum case and setting), the person's setup round-tripping with nothing
private in it, nine golden codes as chatbots write them (`fixtures/setup-codes/`), hostile ones
(huge, deep, wrong types, control and bidi characters, spoofed key names, paths and commands as app
names, codes pretending to be links) and 7,500 fuzzed ones: nothing may change the primary button,
the pause switch, global shortcuts or per-display speeds, every Open or shortcut is marked in the
preview (inside a gesture or a More, on its own line), and nothing destructive gets through Apply
without its tick (see "Shortcuts that are hard to take back" in DEVELOPING.md).

### A setup code from an AI app (Allow AI apps)

An AI app on this Mac can send the same setup code through `propose_changes` while Allow AI apps is on
(DEVELOPING.md, "AI apps on this Mac (MCP)"). There is no second format and no second reader: the
`setup` argument is a setup code as a JSON object (a string holding one is read too), at most 64 KB,
handed to `SetupCode.read` exactly as pasted text is. What differs is only what's refused before it
gets there and what isn't taken at all:

- Only a setup code. A share's own JSON (`"format": "glideball-share"`, which can carry `from`), a link
  and a whole settings file are refused; pasted, the first two are read.
- No other arguments: no summary, no "apply", no ticks. The person's ticks exist only in Glideball's preview.
- What the reader left out goes back to the AI app as `left_out` (`at`: the note's path, `said`: what
  the code said there, cleaned and at most 80 characters, `fix`: the note's fixed hint), the same
  notes Copy Note for the AI copies.

`get_setup` writes the person's setup with the writer Copy Prompt uses, so what an AI app reads is
what it can send back.

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
