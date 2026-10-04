# Translations

Glideball is in English (the development language) plus Spanish, French, German, Italian,
Brazilian Portuguese, Japanese, Korean and Simplified Chinese. Without Xcode there's no
String Catalog, so translations are classic tables:

```
Resources/<lang>.lproj/Localizable.strings      key = English text, value = translation
Resources/<lang>.lproj/Localizable.stringsdict  plural forms
Resources/en.lproj/Localizable.stringsdict      English plurals (English needs no .strings)
```

`build.sh` and `scripts/release.sh` copy every `Resources/*.lproj` into the app before signing.
`CFBundleLocalizations` in `Resources/Info.plist` lists the languages (it's also what makes Glideball
show up in System Settings › General › Language & Region › Applications). Overview › General ›
Language sets the same per-app preference from inside Glideball.

## Adding or changing a string

1. **Write it so it's localizable.**
   - SwiftUI text — `Text("…")`, `Button("…")`, `Label("…", systemImage:)`, `.help("…")`,
     `Toggle`, `Picker`, `Section`, `.accessibilityLabel`… — is localized already: just use a
     literal.
   - Glideball's components take a `LocalizedStringKey` too: `GlassCard(title:)`,
     `ToggleRow(title:subtitle:)`, `TuningSlider(title:lowLabel:highLabel:)`, `StatusPill(text:)`,
     `ModePill(text:)`, `StatTile(title:)` (full list: `COMPONENTS` in `check.py`). If you add a
     component like that, add it there.
   - Anything that's a `String` (model titles, toasts, errors, menu items, panel titles):
     `String(localized: "…", comment: "context for translators")`. Never `String(format:)` for
     text people read, and don't glue sentences together from pieces — give each whole sentence
     its own key (word order differs between languages).
   - Already-localized `String` into a view that wants a `LocalizedStringKey`: `.verbatim(s)`.
     Names, file names and shortcuts aren't translated: `Text(verbatim:)` or pass the `String`.
   - Numbers: `.formatted()`, `x.decimals(1)`, `x.wholePercent`, `Tally.length(…)` — they follow
     the reader's locale. Counts that change a noun ("1 combo" / "2 combos") need a plural
     entry: add it to `Resources/en.lproj/Localizable.stringsdict` and every language's
     `.stringsdict`.
   - Interpolations: Int becomes `%lld`, everything else `%@`. `check.py` recognizes Ints by shape
     (`Int(…)`, `….count`, `x + 1`, or a name in `INT_NAMES`) — stick to those or extend the list.
   - Never localize what's saved or sent: Codable values, UserDefaults keys, feedback tags/context,
     log lines (`Diagnostics`).
2. **Run the check:** `scripts/l10n/check.py` — it lists, per language, missing keys, unused
   keys, and translations whose `%@`/`%lld` don't match the key. It exits non-zero while anything
   is missing or mismatched. `--keys` lists every key with where it's used, `--json FILE` exports
   them with comments, and `--audit` lists string literals that look like UI text but aren't
   localized.
3. **Add the translations** to each `Resources/<lang>.lproj/Localizable.strings`
   (`"English key" = "Translation";`, UTF-8; escape `"` and `\`). Reorder arguments with
   `%1$@`, `%2$lld`. Use Apple's own macOS terms for the language (System Settings, Accessibility,
   Input Monitoring, Mission Control, iCloud Drive, Dock, menu bar…). Run the check again until
   it prints `✓ all languages complete`.

Try a language without changing your Mac: run the built app with
`Glideball.app/Contents/MacOS/Glideball -AppleLanguages '(de)'`, or pick it in Overview › General ›
Language and relaunch.
