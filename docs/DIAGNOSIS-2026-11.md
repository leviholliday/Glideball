# Diagnosis, November 2026

A fuzzer is a program that feeds another program huge numbers of random (and deliberately nasty) inputs, and after each one checks rules that must always hold, so it finds the odd combinations no person would think to try. A sanitizer is a special build of the app that watches it while it runs and stops it the moment it does something unsafe with memory or with two threads touching the same data at once, which is the kind of bug that otherwise shows up as a rare, unexplainable crash. Glideball sits between your trackball and every app on your Mac, on its own thread beside the window, so a stuck key, a click that never lets go or a race between those threads would be felt everywhere, and these are the tools that find them before a person does.

This is step 2 of the plan in `.claude/plans/2026-11-10-from-cedarlogic.md`: diagnose before fixing, then fix what was found, each fix with a test that keeps it fixed.

## What was built

- **The engine fuzzer** (`scripts/engine-fuzz/`). It drives the real input engine, `Engine.swift`, with the scroll engine, gestures and settings, through a fake of the outside world. To make that possible, every effect the engine has on the Mac now goes through one class, `EngineIO` (`EngineIO.swift`). The app uses it unchanged; the fuzzer swaps in a fake with a virtual clock that records everything and never touches the real cursor, devices or settings. It plays random sequences of presses, ball and ring movement, another mouse, the trackpad, the keyboard, settings and app setups changing mid-press, sync applying another Mac's settings, pause, unplug, sleep, macOS switching the event tap off, Quick assign, the keyboard modes, and quit and relaunch. After every event it checks the hard rules from `HANDOFF.md` and a few more (listed in `docs/DEVELOPING.md`). A failure prints its seed and shrinks itself to the few events that still break the rule.
- **The hostile-file fuzzer** (`scripts/file-fuzz/`). It throws broken, huge, deeply nested, wrong-typed, future-version and malicious files at the settings importer, backup restore, sync, saved totals, the milestone ledger and crash reports.
- **Sanitizers** (`scripts/sanitize.sh`). Glideball built with the thread sanitizer, then the address sanitizer, running the sandboxed self-test and the engine fuzzer, including a mode where the engine runs on its own threads exactly as in the app while "the UI" pauses, changes settings and reads the live numbers.
- **Gestures on combos and chained gestures** (merged later). Their code goes through `EngineIO` like the rest, and the engine fuzzer checks them: no gesture hold with the primary button, every fire paid for by the hold's distance of roll (its own, the global one, Steady hands), chain numbers, the 20-a-second limit, "once per hold", taps only after a still hold, and nothing held after pause, unplug, quit or sleep. Shared setups, `glideball://import` links and KensingtonWorks imports are clamped like every settings file and are in the hostile-file fuzzer's corpus.
- **In the checks.** `scripts/check.sh` now runs both fuzzers on a short budget (about 1.2 million engine events from fixed seeds plus one random seed, printed in the log), and `scripts/fuzz.sh` runs them for as long as you like.

How much ran after the last fix: 60 million engine events (3,000 seeds), then the long run (`scripts/fuzz.sh --minutes 12`, 25 minutes): 96.7 million engine events over 4,834 seeds, the engine on its own threads for a minute (750,000 steps), and the deep file fuzz (about 13,000 hostile files, 10 minutes). Every rule held. Then both sanitizers over the self-test and the fuzzer.

## Found and fixed

Severity: **high** means a crash, or a key or button left held down that a person would have to fix by hand; **medium** means a hard rule broken in a situation that really happens (an unplug, a pause, macOS switching the tap off); **low** means a rare corner.

### By the engine fuzzer

Each has a regression case at the top of `scripts/engine-fuzz/main.swift`.

| Severity | What happened | Fix |
| --- | --- | --- |
| High | Two buttons each holding a shortcut: letting go of one silenced the other's release, so its keys (⌘ and ⌥ included) stayed down until that button was pressed again. | Only the buttons holding the same shortcut (a combo's) finish silently. |
| High | Unplugging the trackball while a button held a shortcut (Wispr Flow's ⌃Space, say) left the key down. | Unplug lets go of held keys and remapped buttons, like a pause. |
| High | A hand-made or broken settings file with NaN, infinity or huge numbers crashed the scroll engine (a number that can't become a scroll amount), and a click on button −7 crashed. | Every config is clamped to the app's own slider ranges when it's read and again when it reaches the engine (`GlideConfig.clamped()`); the scroll engine can no longer trap on a bad number. |
| Medium | macOS switches the event tap off when it's slow. A release that went by then left a held shortcut or a remapped button down until that button was pressed again. | The failsafe that already ended held modes now also lets go of keys and remapped buttons once the trackball itself says the button is up. |
| Medium | A combo button waiting for its partner when its release went by unseen was replayed later and stayed down. | It gets its release too: a whole click. |
| Medium | A combo button waiting for its partner at an unplug was replayed after the unplug and stayed down. | Waiting presses are dropped at an unplug. |
| Medium | A combo button waiting for its partner at a pause was replayed after the pause with its mapping, so a Drag lock could start while paused. | Waiting presses go through as plain presses at a pause; a paused engine never maps a press. |
| Medium | The flywheel kept scrolling for up to half a second after a pause or an unplug. | Pause, unplug and sleep stop all scrolling at once. |
| Medium | A remapped button held while quitting stayed down for apps; sleep or the screen locking left a Drag lock, held keys and remapped buttons held. | Quit and sleep let go of them (Precision switched on stays on through sleep). |
| Medium | After the trackball was unplugged, another mouse's release of the same button number could be swallowed, leaving that mouse's button down. | No leftovers once no trackball is connected. |
| Medium | A press of a button whose earlier release was lost replaced what that press held without letting go of it. | The old press lets go first, and the new one reaches apps after it. |
| Low | Apps could see one button pressed twice: a button remapped to left click while the primary was held (or the other way round), a click fired onto a button already down, a Drag lock started while the left button was held (and then held nothing). | A real press of a button wins: a remap holding the same button lets go first. A remap or a click onto a button apps already have down does nothing. A Drag lock doesn't start while the left button is down. |
| Low | Two buttons holding the same shortcut sent its key down twice. | The second joins the first. |
| Low | Restarting Quick assign while a button was held let that button's release reach apps without its press. | Quick assign keeps the release too. |
| Low | After the tap had been off, the engine could think the left button was still down and turn Precision's moves into drags. | It asks macOS which buttons are down when the tap comes back and at launch. |
| Low | Ring ticks handled back to back (after the input thread was held up) looked like 250+ ticks a second, so one tick could move the page about 17,000 points with smooth scrolling off. | The spin rate is never faster than the trackball can report (125 a second). |
| Low | A button held across a relaunch: its release could let go of another button's remap onto the same button. | That stray release is swallowed. |

Also: the diagnostics log trimmed itself by moving 6,000 lines on every entry; it now trims in batches.

### By the hostile-file fuzzer

| Severity | What happened | Fix |
| --- | --- | --- |
| High | A synced settings file with gestures nested about 150 deep (or 100,000 `[`) overflowed the sync queue's stack. Another Mac, or anything that can write to iCloud Drive, could crash Glideball this way. | Files are rejected past a nesting depth of 64 before they're decoded (`SafeRead.checkDepth`). |
| High | A pipe, `/dev/zero` or a 2 GB file in the import, backup or sync path hung Glideball or was read whole; iCloud's file coordinator waits forever on a pipe. | Only plain files, with a size cap, are ever read (`SafeRead.data`). |
| Medium | Links in the Backups folder were listed, restored and pruned, so a link to another settings file could be restored; a `devices` link let the sync heartbeat be written elsewhere; a device ID of `../../x` in UserDefaults became a file path. | Plain files only; no writing through a link; the device ID must be a UUID. |
| Medium | Merging an older Mac's sync file could hold more combos than the app allows. | The merge is clamped too. |
| Medium | (Found merging with chained gestures.) Clamping rebuilt each gesture direction without its "Once per hold" switch, so every settings file, backup, sync and engine update quietly turned "Once per hold" back into chained. | Clamping keeps it; the fuzzer's ordinary settings include it now. |
| Low | Saved totals near the largest number crashed when added to or shown; a saved low-battery state of the largest number crashed on the first reading; the crash-report scrubber took minutes on a few MB of text without spaces. | Totals add without overflowing and format safely; an impossible battery state is dropped; the scrubber's pattern is linear and its input is cut first. These need damaged UserDefaults or crash logs, so they're unlikely. |

### By the sanitizers

Nothing. The thread sanitizer ran the self-test (first launch and a returning user), 100,000 fuzzed engine events, and the engine on its own threads (about 200,000 steps of settings changes, pauses, mode switches, sleeps and telemetry reads from the main thread against button, ball and ring events on the input thread). The address sanitizer ran the same. Zero warnings from either.

What I checked by hand while reading for races, and why each is fine:

- `Telemetry`: written by the input thread, read by the window, always under its lock.
- `StatusFileWriter` and `Sounds`: their state is only touched on their own serial queues.
- `Engine.releaseAll` frees the pointer from the main thread as well as the input thread. That's on purpose (if the input thread were ever stuck, the cursor still comes back), and it's a call into macOS, which is safe from any thread.
- `Engine` is never freed (its timers hold it `unowned`). In the app it lives as long as the app; the fuzzer keeps its threaded engine alive the same way.

What the sanitizers can't see: the real event tap, IOHIDManager and display-link callbacks (the fuzzer fakes them), and sync and backups (off in the sandbox).

### Crash reports on this Mac

Four reports in `~/Library/Logs/DiagnosticReports/`, all from 2.10 beta 10 on 11 November, all the same crash: `EXC_BAD_ACCESS` in `__CFRunLoopDoObservers` while a badge's popover animated to a new size for Share…. That's the share crash already fixed in beta 11 (commit `5416a0d`). No others.

## Found and not fixed

- **Two mice pressing the same button number at once.** If another mouse or the trackpad presses, say, its left button while the trackball holds its own (or within 0.3 s of the trackball pressing it), the engine can't tell whose press and release is whose: macOS doesn't say which device a click came from, and the engine keys what each press holds by button number. A release can then be matched to the wrong press, and a button can stay down until the next click. The fuzzer stops judging button pairing in that situation (it still judges keys, and nothing stays stuck after the next click). A real fix would match each press to its device, perhaps through the HID report's timestamp.
- **The primary button isn't a plain left click in three places, by design:** the click that lets go of a Drag lock (it lets go, and that's all it does), Quick assign listening, and a combo you made that includes it. The fuzzer allows exactly those.
- **Buttons held through a relaunch.** A release whose press the new Glideball never saw passes through as macOS's own; at worst an app sees a release without a press.
- **Trackballs whose buttons don't come over HID** get no lost-release failsafe for held keys, because there's nothing to go on and a long push-to-talk hold must keep working.
- **Small file things:** a junk backup dated in the future stays the "newest" one; the action picker's recent list (UserDefaults only) isn't clamped; the updater wasn't fuzzed here (it's step 5 of the plan).

## What it says about the core

The engine's decisions were sound on the path people use every day: millions of random presses, combos, gestures and mode switches with nothing going wrong around them broke no rule. Every real bug was the world changing in the middle of a press: a release lost because macOS switched the tap off, an unplug, a pause or a settings change while a combo button was still waiting, two buttons holding the same thing, a relaunch. Those are exactly the cases a person can't test by hand, and each one left something held down, which is the worst thing Glideball can do.

Two design choices sit under most of them. First, what each press holds is remembered by button number, not by device; that's why the two-mice case can't be solved cleanly yet. Second, the engine used to trust that every release would arrive. It now checks the trackball's own HID state for lost releases, asks macOS which buttons are down after the tap was off, and lets go of everything at pause, quit, unplug and sleep.

Settings from outside were trusted too: any number in a file went straight to the scroll engine and IOKit. They're now clamped where they come in and again where they reach the engine, and files are read with limits on size, kind and depth.

The refactor (`EngineIO`) moved the engine's effects behind one class without changing what the app does; it's what makes the engine testable without a trackball, a tap or permissions.

## Next

1. Run `scripts/fuzz.sh` before each beta (and `--tsan` now and then); keep a seed from any failure as a regression case.
2. Match each press to its device, so the two-mice case can be fixed and fuzzed strictly.
3. Fuzz the updater with forged, altered, truncated and downgraded zips (plan step 5).
4. A Mac CI job that runs `scripts/check.sh` (plan step 3).
5. Real-hardware checks of the new behaviour on the Expert Mouse: unplug while holding a shortcut, sleep with a Drag lock on, a combo button held across a pause.
