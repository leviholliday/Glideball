// Drives the real gesture decision code (Gestures.swift: GestureRoute and
// GestureMachine) and the real settings model (Config.swift, AppProfile.swift)
// with scripted button and ball events, wired the way Engine.swift wires them,
// and checks the hard rules after every single event:
//
//   1. The pointer is frozen exactly while a gesture is held (never left frozen).
//   2. The primary button (0) never starts a gesture, alone or in a combo.
//   3. Every freeze is matched by exactly one unfreeze.
//   4. A gesture never fires anything that holds: no held keys, modes or buttons.
//   5. Pause, quit, unplug, sleep, the tap switched off by macOS, a lost release
//      and the timeout all end a hold at once; its late release does nothing.
//   6. A tap happens only for a release with the ball (nearly) still, no direction
//      fired and no other button pressed; one-shot directions fire once per hold.
//   7. Continuous gestures respect the rate limit; no hold outlives maxHold.
//
// Then the settings: old files load unchanged, gesture settings round-trip, and a
// newer Glideball's unknown actions and fields never break this one.
// Run: scripts/gesture-sim/run.sh (exits 1 on any failure).
import Foundation

var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: UInt = #line) {
    checks += 1
    if !ok {
        failures += 1
        if failures <= 40 { print("  ✗ \(what()) (line \(line))") }
    }
}
func section(_ name: String) { print("▸ \(name)") }

/// Only press-and-release actions may ever be fired by a gesture.
func isFireAndForget(_ a: ButtonAction) -> Bool {
    switch a {
    case .shortcut, .mediaKey, .leftClick, .rightClick, .middleClick, .back, .forward, .modifiedClick: true
    default: false
    }
}

// MARK: - The engine's wiring, in miniature

/// What Engine.swift does with a press, a release, ball movement and the ways a
/// hold can end, minus CoreGraphics. `frozen` is CGAssociateMouseAndMouseCursorPosition.
final class Rig {
    let machine = GestureMachine()
    var config = GlideConfig()
    var canReadBall = true
    var now = 0.0
    var frozen = false
    var freezeOns = 0, freezeOffs = 0
    var overrides: [Int: String] = [:]     // "gesture", "swallow", "other"
    var fired: [(ButtonAction, GestureDirection)] = []
    var taps: [(ButtonAction, [Int])] = []
    var instantTaps: [(ButtonAction, [Int])] = []   // gestures off / no ball: the tap at press time
    var primaryPasses = 0

    init(_ buttons: [Int: ButtonAction] = [3: .gesture(.standard)]) {
        config.buttons = buttons
    }

    func apply(_ effects: [GestureEffect]) {
        for e in effects {
            switch e {
            case .freeze(let on):
                frozen = on
                if on { freezeOns += 1 } else { freezeOffs += 1 }
            case .fire(let a, let d): fired.append((a, d))
            case .tap(let a, let b): taps.append((a, b))
            }
        }
        invariants()
    }

    private func route(_ action: ButtonAction, _ buttons: [Int]) {
        switch GestureRoute.decide(action: action, buttons: buttons, enabled: config.gesturesEnabled,
                                   canReadBall: canReadBall, gestureHeld: machine.isHeld) {
        case .begin:
            guard case .gesture(let g) = action else { fatalError("begin for a non-gesture") }
            let effects = machine.begin(buttons: buttons, gesture: g, now: now)
            for b in buttons { overrides[b] = effects.isEmpty ? "swallow" : "gesture" }
            apply(effects)
        case .tapInstead(let t):
            instantTaps.append((t, buttons))
            for b in buttons { overrides[b] = "other" }
        case .ignore:
            // As Engine.pressAction: a repeat press of the held button keeps the hold's override.
            for b in buttons where !(machine.hold?.buttons.contains(b) ?? false) { overrides[b] = "swallow" }
        case .notGesture:
            for b in buttons { overrides[b] = "other" }
        }
        invariants()
    }

    /// One button down (`Engine.handleButton` → `press`).
    func press(_ b: Int) {
        if machine.isHeld { machine.otherPress(b) }
        if b == 0 { primaryPasses += 1; overrides[0] = "other"; invariants(); return }   // never remapped
        route(config.buttons[b] ?? .system, [b])
    }

    /// A combo formed (`Engine.fireCombo`): its buttons went down together.
    func combo(_ buttons: [Int], _ action: ButtonAction) {
        if machine.isHeld { for b in buttons { machine.otherPress(b) } }
        route(action, buttons)
    }

    func release(_ b: Int) {
        let o = overrides[b]
        overrides[b] = nil
        guard o == "gesture" else { invariants(); return }
        let effects = machine.release(button: b, now: now)
        for (k, v) in overrides where v == "gesture" { overrides[k] = "swallow" }
        apply(effects)
    }

    func ball(_ dx: Double, _ dy: Double) {
        if machine.isHeld { apply(machine.ball(dx: dx, dy: dy, now: now)) }
    }

    /// Rolls `distance` counts in steps of `step`, `dt` seconds apart.
    func roll(dx: Double, dy: Double, steps: Int, dt: Double = 0.008) {
        for _ in 0..<steps { now += dt; ball(dx, dy) }
    }

    func cancel(_ reason: GestureCancel) {
        let effects = machine.cancel(reason)
        for (k, v) in overrides where v == "gesture" { overrides[k] = "swallow" }
        apply(effects)
    }

    /// The engine's 0.25 s hold check.
    func tick() {
        if let h = machine.hold, now - h.start >= machine.tuning.maxHold { cancel(.timeout) }
        invariants()
    }

    func invariants() {
        check(frozen == machine.isHeld, "pointer frozen (\(frozen)) exactly while a gesture is held (\(machine.isHeld))")
        check(frozen == machine.frozen, "the machine knows whether it froze the pointer")
        check(!(machine.hold?.buttons.contains(0) ?? false), "the primary button never holds a gesture")
        check(freezeOns - freezeOffs == (frozen ? 1 : 0), "every freeze has exactly one unfreeze (\(freezeOns) on, \(freezeOffs) off)")
        check(fired.allSatisfy { isFireAndForget($0.0) }, "a gesture only fires press-and-release actions")
        check(taps.allSatisfy { t in t.1.count != 1 || t.1[0] != 0 }, "never a tap of the primary button")
        if let h = machine.hold { check(now - h.start <= machine.tuning.maxHold + 0.3, "no hold outlives maxHold") }
    }
}

let tuning = GestureTuning()

// MARK: - The basics

section("tap, dead zone, threshold")
do {
    let r = Rig()
    r.press(3); r.now += 0.08; r.release(3)
    check(r.taps.count == 1 && r.taps[0].0 == .system && r.taps[0].1 == [3], "a still press and release is one tap of the button's own click")
    check(r.fired.isEmpty && !r.frozen, "nothing fired, pointer free")

    r.press(3); r.roll(dx: 1, dy: 1, steps: 8); r.release(3)   // ~11 counts: a wobble
    check(r.taps.count == 2 && r.fired.isEmpty, "a wobble under the tap slop is still a tap")

    r.press(3); r.roll(dx: 3, dy: 0, steps: 10); r.release(3)  // 30 counts: between slop and commit
    check(r.taps.count == 2 && r.fired.isEmpty, "between the slop and the threshold: neither tap nor gesture (hysteresis band)")

    r.press(3); r.roll(dx: 4, dy: 0.5, steps: 12)               // 48 counts right
    check(r.fired.count == 1 && r.fired[0].1 == .right, "rolling right past the threshold fires right, before the release")
    check(r.fired[0].0 == .shortcut(.nextSpace), "right is Next Space in the standard gesture")
    check(r.frozen, "still frozen until the release")
    r.roll(dx: 4, dy: 0, steps: 100)
    check(r.fired.count == 1, "one-shot: rolling on fires nothing more")
    r.roll(dx: -4, dy: 0, steps: 100)
    check(r.fired.count == 1, "one-shot: rolling back fires nothing either")
    r.release(3)
    check(r.taps.count == 2 && !r.frozen, "a fired gesture's release is no tap; pointer free")

    for (dx, dy, want) in [(0.0, -5.0, GestureDirection.up), (0, 5, .down), (-5, 0, .left), (5, 0, .right)] {
        let r = Rig()
        r.press(3); r.roll(dx: dx, dy: dy, steps: 12); r.release(3)
        check(r.fired.map(\.1) == [want], "rolling \(want.rawValue) fires \(want.rawValue)")
    }
}

section("dominant axis")
do {
    // A diagonal: 40 right, 30 up, neither dominant, under 2× threshold: nothing yet.
    let r = Rig()
    r.press(3); r.roll(dx: 4, dy: -3, steps: 13)
    check(r.fired.isEmpty, "a true diagonal doesn't fire a guess")
    r.roll(dx: 4, dy: -3, steps: 12)   // ~100 right, 75 up: past 2× the threshold, the larger axis wins
    check(r.fired.map(\.1) == [.right], "past twice the threshold, the larger axis wins")
    r.release(3)

    // Mostly up with some drift: up, and the axis stays locked.
    let s = Rig([3: .gesture(.media)])
    s.press(3); s.roll(dx: 1, dy: -5, steps: 10)
    check(s.fired.map(\.1) == [.up], "mostly up is up")
    s.roll(dx: 8, dy: 0, steps: 40)
    check(s.fired.allSatisfy { $0.1 == .up || $0.1 == .down }, "once locked, sideways rolling fires nothing sideways")
    s.release(3)
}

section("continuous gestures")
do {
    let r = Rig([2: .gesture(.media)])
    r.press(2)
    r.roll(dx: 0, dy: -2, steps: 24)        // 48: the first step
    check(r.fired.count == 1 && r.fired[0].0 == .mediaKey(.volumeUp), "volume up at the threshold")
    r.roll(dx: 0, dy: -2, steps: 64)        // 128 more: two steps of 64, slow enough for the rate limit
    check(r.fired.count == 3, "then once per 64 counts (\(r.fired.count))")
    r.roll(dx: 0, dy: 2, steps: 64)         // back down 128
    check(r.fired.suffix(2).allSatisfy { $0.0 == .mediaKey(.volumeDown) }, "rolling back turns it down")
    r.release(2)
    check(r.taps.isEmpty && !r.frozen, "no tap after a continuous gesture")

    // A fast spin: 4,000 counts in 0.2 s. Never more often than the rate limit.
    let f = Rig([2: .gesture(.media)])
    f.press(2)
    var times: [Double] = []
    for _ in 0..<200 {
        f.now += 0.001
        let before = f.fired.count
        f.ball(0, -20)
        if f.fired.count > before { times.append(f.now) }
    }
    f.release(2)
    let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
    check(gaps.allSatisfy { $0 >= tuning.minRepeatInterval - 1e-9 }, "a fast spin stays under the rate limit")
    check(times.count <= Int(0.2 / tuning.minRepeatInterval) + 1, "a fast spin doesn't queue repeats (\(times.count))")

    // A one-shot direction never repeats, even with repeats on elsewhere.
    let o = Rig([2: .gesture(.media)])
    o.press(2); o.roll(dx: 5, dy: 0, steps: 200); o.release(2)
    check(o.fired.map(\.0) == [.mediaKey(.nextTrack)], "next track fires once")
}

// MARK: - Hostile sequences

section("ways out of a hold")
do {
    for reason in [GestureCancel.pause, .quit, .unplug, .tapDisabled, .sleep, .lostRelease, .configChanged] {
        let r = Rig()
        r.press(3); r.roll(dx: 1, dy: 0, steps: 5)
        r.cancel(reason)
        check(!r.frozen && !r.machine.isHeld, "\(reason.rawValue) mid-gesture frees the pointer")
        let taps = r.taps.count, fired = r.fired.count
        r.ball(50, 0)
        r.release(3)
        check(r.taps.count == taps && r.fired.count == fired, "\(reason.rawValue): the late release and rolling do nothing")
        r.press(3); r.release(3)
        check(r.taps.count == taps + 1, "\(reason.rawValue): the next press works normally")
    }

    // Pause after a direction fired, mid continuous gesture.
    let r = Rig([1: .gesture(.media)])
    r.press(1); r.roll(dx: 0, dy: -3, steps: 60)
    r.cancel(.pause)
    let n = r.fired.count
    r.roll(dx: 0, dy: -3, steps: 60)
    check(r.fired.count == n && !r.frozen, "after a pause, rolling fires nothing and moves the pointer")

    // Cancelling with nothing held is harmless (and doesn't unfreeze twice).
    let idle = Rig()
    idle.cancel(.pause); idle.cancel(.quit)
    check(idle.freezeOffs == 0, "no unfreeze without a freeze")
}

section("timeout")
do {
    let r = Rig()
    r.press(3)
    for _ in 0..<200 { r.now += 0.25; r.tick() }   // 50 s of a release that never comes
    check(!r.machine.isHeld && !r.frozen, "a stuck hold ends by itself after \(tuning.maxHold) s")
    r.release(3)
    check(r.taps.isEmpty, "and its very late release isn't a tap")
}

section("rapid press and release")
do {
    let r = Rig()
    for _ in 0..<1_000 { r.press(3); r.now += 0.001; r.release(3); r.now += 0.001 }
    check(r.taps.count == 1_000 && r.fired.isEmpty, "1,000 quick taps are 1,000 taps")
    check(r.freezeOns == 1_000 && r.freezeOffs == 1_000 && !r.frozen, "and 1,000 freezes, each undone")
    // Press twice without a release in between (a lost release): the second is ignored, the first still ends.
    r.press(3); r.press(3)
    check(r.machine.isHeld, "a repeated press while held doesn't start a second hold")
    r.release(3)
    check(!r.frozen, "one release frees it")
}

section("primary button and combos")
do {
    // A hostile settings file with a gesture on the primary button.
    let r = Rig([0: .gesture(.standard), 3: .gesture(.standard)])
    r.press(0); r.roll(dx: 5, dy: 0, steps: 20); r.release(0)
    check(r.primaryPasses == 1 && r.fired.isEmpty && !r.frozen, "the primary button stays a left click")
    check(GestureRoute.decide(action: .gesture(.standard), buttons: [0], enabled: true, canReadBall: true, gestureHeld: false) == .notGesture,
          "the route never makes button 0 a gesture")
    check(r.machine.begin(buttons: [0], gesture: .standard, now: 0).isEmpty && !r.machine.isHeld,
          "the machine refuses button 0 even if asked")
    check(r.machine.begin(buttons: [0, 2], gesture: .standard, now: 0).isEmpty && !r.machine.isHeld,
          "and any combo that includes it")

    // A combo with the primary button and a gesture action: the tap, at once, never a hold.
    var g = ButtonGesture.standard; g.tap = .shortcut(.copy)
    r.combo([0, 2, 3], .gesture(g))
    check(!r.machine.isHeld && r.instantTaps.last?.0 == .shortcut(.copy), "a combo with the primary button does the tap action instead")
    r.release(0); r.release(2); r.release(3)

    // A two-button gesture combo: held while either is down, ends with the first release.
    let c = Rig([:])
    c.combo([1, 3], .gesture(.standard))
    check(c.machine.isHeld && c.frozen, "a combo can be a gesture")
    c.roll(dx: -5, dy: 0, steps: 12)
    c.release(1)
    check(!c.frozen && c.fired.map(\.1) == [.left], "the first release ends it")
    c.release(3)
    check(c.taps.isEmpty && !c.machine.isHeld, "the partner's release does nothing")

    // Chord overlap: a gesture is held when a combo of two other buttons forms.
    let o = Rig([3: .gesture(.standard)])
    o.press(3)
    o.combo([1, 2], .gesture(.standard))
    check(o.overrides[1] == "swallow" && o.overrides[2] == "swallow", "a second gesture while one is held is ignored")
    o.release(1); o.release(2)
    check(o.machine.isHeld && o.frozen, "the first gesture is still held")
    o.release(3)
    check(o.taps.isEmpty && !o.frozen, "other presses during the hold cancel its tap")

    // Another button (even the primary) during a hold: no tap on release.
    let p = Rig()
    p.press(3); p.press(0); p.release(0); p.release(3)
    check(p.taps.isEmpty && !p.frozen, "a click during a hold means no tap")
}

section("gestures off, no ball, held actions")
do {
    let r = Rig()
    r.config.gesturesEnabled = false
    r.press(3)
    check(!r.frozen && r.instantTaps.count == 1 && r.instantTaps[0].0 == .system, "gestures off: the button just does its tap, at once")
    r.release(3)

    let b = Rig()
    b.canReadBall = false
    b.press(3)
    check(!b.frozen && b.instantTaps.count == 1, "no Input Monitoring (can't read the ball): the tap, never a frozen pointer")

    // Held actions never stay held.
    var g = ButtonGesture(up: GestureStep(.holdShortcut(.wisprFlow)), down: GestureStep(.precisionHold),
                          left: GestureStep(.dragLock), right: GestureStep(.ballScrollHold), tap: .holdShortcut(.wisprFlow))
    check(g.up?.firable == .shortcut(.wisprFlow), "a held shortcut fires as a quick press")
    check([g.down, g.left, g.right].allSatisfy { $0?.firable == nil }, "held modes and drag lock never fire from a gesture")
    check(g.tapAction == .shortcut(.wisprFlow), "a held-shortcut tap is a quick press")
    g.tap = .ballScrollHold
    check(g.tapAction == .disabled, "a held-mode tap does nothing")
    g.tap = .gesture(.standard)
    check(g.tapAction == .disabled, "a gesture as a tap does nothing")
    let h = Rig([3: .gesture(g)])
    h.press(3)
    for (dx, dy) in [(0.0, -6.0), (0, 6), (-6, 0), (6, 0)] { h.roll(dx: dx, dy: dy, steps: 12) }
    h.release(3)
    check(h.fired.allSatisfy { $0.0 == .shortcut(.wisprFlow) }, "only the quick press fired")
}

section("random event storm")
do {
    // 300,000 random events: presses, releases, combos, rolling, every way out,
    // and long waits, across several setups. The invariants run after each one.
    var rng = SystemRandomNumberGenerator()
    let setups: [[Int: ButtonAction]] = [
        [3: .gesture(.standard)],
        [1: .gesture(.media), 2: .gesture(.standard), 3: .back],
        [0: .gesture(.standard), 1: .gesture(.media), 2: .gesture(.media), 3: .gesture(.standard)],
    ]
    let reasons: [GestureCancel] = [.pause, .quit, .unplug, .tapDisabled, .sleep, .lostRelease]
    for setup in setups {
        let r = Rig(setup)
        var down = Set<Int>()
        for _ in 0..<100_000 {
            r.now += Double.random(in: 0...0.02, using: &rng)
            switch Int.random(in: 0..<100, using: &rng) {
            case 0..<15:
                let b = Int.random(in: 0...3, using: &rng)
                if !down.contains(b) { down.insert(b); r.press(b) }
            case 15..<30:
                if let b = down.randomElement(using: &rng) { down.remove(b); r.release(b) }
            case 30..<33:
                let bs = Array(Set((0..<2).map { _ in Int.random(in: 0...3, using: &rng) })).sorted()
                if bs.count == 2, down.isDisjoint(with: bs) {
                    down.formUnion(bs)
                    r.combo(bs, Bool.random(using: &rng) ? .gesture(.media) : .shortcut(.copy))
                }
            case 33..<36:
                r.cancel(reasons.randomElement(using: &rng)!)
                if Bool.random(using: &rng) { down.removeAll() }   // unplugged: the releases never come
            case 36..<38:
                r.now += Double.random(in: 1...40, using: &rng)
                r.tick()
            case 38..<40:
                r.config.gesturesEnabled.toggle()
            default:
                r.ball(Double.random(in: -30...30, using: &rng), Double.random(in: -30...30, using: &rng))
                r.tick()
            }
        }
        for b in down { r.release(b) }
        r.cancel(.quit)
        check(!r.frozen && !r.machine.isHeld, "after the storm and a quit, nothing is held")
    }
}

// MARK: - Settings

section("settings: old, new and newer")
do {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    // A file from before gestures and per-display speeds.
    let old = #"{"enabled":true,"trackingSpeed":6,"buttons":{"3":{"back":{}}},"chords":[]}"#
    let o = try? decoder.decode(GlideConfig.self, from: Data(old.utf8))
    check(o?.trackingSpeed == 6 && o?.buttons[3] == .back, "an old file loads unchanged")
    check(o?.gesturesEnabled == true && o?.displaySpeeds == DisplaySpeeds(), "with the new settings at their defaults")

    // Round trip.
    var c = GlideConfig()
    c.buttons[3] = .gesture(.keeping(.back))
    c.buttons[2] = .gesture(.media)
    c.chords = [Chord(buttons: [1, 2], action: .gesture(.standard))]
    c.gesturesEnabled = false
    c.displaySpeeds.enabled = true
    c.displaySpeeds.speeds = ["1552-41001-0": 6.5]
    c.displaySpeeds.names = ["1552-41001-0": "Studio Display"]
    let data = try! encoder.encode(c)
    let back = try? decoder.decode(GlideConfig.self, from: data)
    check(back == c, "gesture and display settings round-trip")
    if case .gesture(let g)? = back?.buttons[3] { check(g.tap == .back, "turning a button into a gesture keeps its old action as the tap") }
    else { check(false, "button 3 is a gesture") }
    let file = try? decoder.decode(GlideSettingsFile.self, from: try! encoder.encode(GlideSettingsFile(config: c, exportedFrom: "sim")))
    check(file?.config == c, "and survive an exported settings file")

    // A newer Glideball's gesture: an action this version doesn't know in one
    // direction, a field it doesn't know, an unknown tap.
    let newer = #"""
    {"buttons":{
        "2":{"gesture":{"_0":{"up":{"action":{"teleport":{}},"repeats":true},
                              "down":{"action":{"mediaKey":{"_0":"volumeDown"}},"repeats":true,"curve":"fast"},
                              "left":{"action":{"shortcut":{"_0":{"keyCode":123,"modifiers":262144,"keyName":"←"}}}},
                              "tap":{"hologram":{}},
                              "wiggle":{"action":{"back":{}}}}}},
        "3":{"warpDrive":{}}},
     "displaySpeeds":{"enabled":true,"speeds":{"a":5,"b":"fast","c":-1},"future":1},
     "gesturesEnabled":"maybe",
     "somethingNew":{"x":1}}
    """#
    let n = try? decoder.decode(GlideConfig.self, from: Data(newer.utf8))
    check(n != nil, "a newer settings file still loads")
    if case .gesture(let g)? = n?.buttons[2] {
        check(g.up == nil, "a direction with an unknown action is skipped")
        check(g.down == GestureStep(.mediaKey(.volumeDown), repeats: true), "a direction with an unknown field still loads")
        check(g.left?.action == .shortcut(.previousSpace), "known directions load")
        check(g.tap == .system, "an unknown tap falls back to the button's own click")
    } else {
        check(false, "the gesture button loads even with unknown parts")
    }
    check(n?.buttons[3] == nil, "an unknown action on a button is skipped, not the file")
    check(n?.gesturesEnabled == true, "an unreadable switch is its default")
    check(n?.displaySpeeds.enabled == false || n?.displaySpeeds.speeds.isEmpty == true || n?.displaySpeeds.speeds == ["a": 5],
          "unreadable display speeds are dropped, never wrong")

    // An unknown media key name (a newer version's key) skips just that button.
    let key = #"{"buttons":{"1":{"mediaKey":{"_0":"brightnessUp"}},"2":{"mediaKey":{"_0":"mute"}}}}"#
    let k = try? decoder.decode(GlideConfig.self, from: Data(key.utf8))
    check(k?.buttons[1] == nil && k?.buttons[2] == .mediaKey(.mute), "unknown media keys are skipped, known ones load")

    // App setups: the primary button stays the main setup's, gestures can be per app.
    var main = GlideConfig()
    main.buttons[0] = .system
    var p = AppProfile(bundleID: "com.example.app", name: "App")
    p.buttons = [0: .gesture(.standard), 3: .gesture(.media)]
    main.appProfiles = [p]
    let resolved = main.resolved(for: "com.example.app")
    check(resolved.buttons[0] == .system, "an app setup can't put a gesture on the primary button")
    check(resolved.buttons[3] == .gesture(.media), "an app setup can have its own gesture")
}

print(failures == 0 ? "✓ gesture-sim: all \(checks) checks passed" : "✗ gesture-sim: \(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
