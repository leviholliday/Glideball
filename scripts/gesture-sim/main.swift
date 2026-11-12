// Drives the real gesture decision code (Gestures.swift: GestureRoute and
// GestureMachine) and the real settings model (Config.swift, AppProfile.swift)
// with scripted button and ball events, wired the way Engine.swift wires them
// (combo wait included), and checks the hard rules after every single event:
//
//   1. The pointer is frozen exactly while a gesture is held (never left frozen).
//   2. The primary button (0) never starts a gesture, alone or in a combo.
//   3. Every freeze is matched by exactly one unfreeze.
//   4. A gesture never fires anything that holds: no held keys, modes or buttons.
//   5. Pause, quit, unplug, sleep, the tap switched off by macOS, a lost release
//      and the timeout all end a hold at once; its late release does nothing.
//   6. A tap happens only for a release with the ball (nearly) still and nothing
//      fired or crossed in the hold, and no other button pressed.
//   7. Chained fires: never two fires within 50 ms (20 a second at most), never a
//      fire within the cool-down after a chained one, "Once per hold" directions
//      at most once per hold; no hold outlives maxHold.
//
// Then the settings: old files load unchanged, gesture settings round-trip, a
// newer Glideball's unknown actions and fields never break this one, and what an
// older Glideball drops is put back.
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
    case .shortcut, .media, .openApp, .leftClick, .rightClick, .middleClick, .back, .forward, .modifiedClick: true
    default: false
    }
}

/// Once-per-hold copies of a gesture: how every one-shot direction worked before chaining.
func oncePerHold(_ g: ButtonGesture) -> ButtonGesture {
    var out = g
    for d in GestureDirection.allCases where out[d]?.repeats == false { out[d]?.once = true }
    return out
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
    var fireTimes: [Double] = []
    var taps: [(ButtonAction, [Int])] = []
    var instantTaps: [(ButtonAction, [Int])] = []   // gestures off / no ball: the tap at press time
    var primaryPasses = 0
    var primaryReleases = 0
    var comboActions: [(ButtonAction, [Int])] = []  // a combo that formed and isn't a gesture

    // This hold's fires, for the chaining rules.
    private var holdFires: [(t: Double, d: GestureDirection, chained: Bool)] = []
    private var holdTuning = GestureTuning()
    private var holdGesture: ButtonGesture?

    // Engine.swift's combo wait.
    static let comboWindow = 0.07, comboMaxWait = 0.16
    var pending: [Int] = []
    var pendingStart = 0.0
    var pendingDeadline: Double?

    init(_ buttons: [Int: ButtonAction] = [3: .gesture(.standard)], chords: [Chord] = []) {
        config.buttons = buttons
        config.chords = chords
    }

    func apply(_ effects: [GestureEffect]) {
        for e in effects {
            switch e {
            case .freeze(let on):
                frozen = on
                if on {
                    freezeOns += 1
                    holdFires = []
                    holdTuning = machine.hold?.tuning ?? GestureTuning()
                    holdGesture = machine.hold?.gesture
                } else {
                    freezeOffs += 1
                }
            case .fire(let a, let d):
                let step = holdGesture?[d]
                let chained = step?.repeats != true
                if let last = holdFires.last {
                    check(now - last.t >= holdTuning.minRepeatInterval - 1e-9, "never two fires within \(holdTuning.minRepeatInterval) s")
                    if last.chained { check(now - last.t >= holdTuning.chainCooldown - 1e-9, "nothing fires in the cool-down after a chained fire") }
                }
                if step?.once == true { check(!holdFires.contains { $0.d == d }, "a once-per-hold direction fires once per hold") }
                holdFires.append((now, d, chained))
                fired.append((a, d))
                fireTimes.append(now)
            case .tap(let a, let b):
                check(holdFires.isEmpty, "a tap only when nothing fired in the hold")
                taps.append((a, b))
            }
        }
        invariants()
    }

    private func route(_ action: ButtonAction, _ buttons: [Int]) {
        switch GestureRoute.decide(action: action, buttons: buttons, enabled: config.gesturesEnabled,
                                   canReadBall: canReadBall, gestureHeld: machine.isHeld) {
        case .begin:
            guard case .gesture(let g) = action else { fatalError("begin for a non-gesture") }
            let tuning = GestureTuning.for(distance: g.distance ?? config.gestureDistance, steadyHands: config.gestureSteadyHands)
            let effects = machine.begin(buttons: buttons, gesture: g, now: now, tuning: tuning)
            for b in buttons { overrides[b] = effects.isEmpty ? "swallow" : "gesture" }
            apply(effects)
        case .tapInstead(let t):
            instantTaps.append((t, buttons))
            for b in buttons { overrides[b] = b == 0 && buttons.count == 1 ? "other" : "swallow" }
        case .ignore:
            // As Engine.pressAction: a repeat press of the held button keeps the hold's override.
            for b in buttons where !(machine.hold?.buttons.contains(b) ?? false) { overrides[b] = "swallow" }
        case .notGesture:
            if buttons.count > 1 {
                comboActions.append((action, buttons))
                for b in buttons { overrides[b] = "swallow" }
            } else {
                for b in buttons { overrides[b] = "other" }
            }
        }
        invariants()
    }

    /// One button's own action (`Engine.press`): the primary always passes through.
    private func ownPress(_ b: Int) {
        if b == 0 { primaryPasses += 1; overrides[0] = "other"; invariants(); return }   // never remapped
        route(config.buttons[b] ?? .system, [b])
    }

    /// One button down (`Engine.handleButton`).
    func press(_ b: Int) {
        if machine.isHeld { machine.otherPress(b) }
        let comboButtons = Set(config.chords.flatMap(\.buttons))
        guard comboButtons.contains(b) else {
            flushPending()
            ownPress(b)
            return
        }
        pending.append(b)
        let held = Set(pending)
        let exact = config.chords.first { Set($0.buttons) == held }
        let bigger = config.chords.contains { Set($0.buttons).isStrictSuperset(of: held) }
        if let exact, !bigger {
            fireCombo(exact)
        } else if pending.count == 1 {
            pendingStart = now
            pendingDeadline = now + Self.comboWindow
        } else if bigger {
            pendingDeadline = now + max(0.01, min(Self.comboWindow, Self.comboMaxWait - (now - pendingStart)))
        }
        invariants()
    }

    /// Time passes: the combo wait may end.
    func advance(_ dt: Double) {
        now += dt
        if let d = pendingDeadline, now >= d {
            let held = Set(pending)
            if held.count > 1, let chord = config.chords.first(where: { Set($0.buttons) == held }) { fireCombo(chord) }
            else { flushPending() }
        }
    }

    private func fireCombo(_ chord: Chord) {
        pendingDeadline = nil
        let buttons = pending
        pending = []
        route(chord.action, buttons)
    }

    private func flushPending() {
        pendingDeadline = nil
        let presses = pending
        pending = []
        for b in presses { ownPress(b) }
    }

    /// A combo's buttons pressed together and held past the wait (or until it forms).
    func combo(_ buttons: [Int]) {
        for b in buttons { press(b) }
        advance(0.2)
    }

    func release(_ b: Int) {
        if pending.contains(b) { flushPending() }
        let o = overrides[b]
        overrides[b] = nil
        if b == 0 && o == "other" { primaryReleases += 1 }
        guard o == "gesture" else { invariants(); return }
        let effects = machine.release(button: b, now: now)
        for (k, v) in overrides where v == "gesture" { overrides[k] = "swallow" }
        apply(effects)
    }

    func ball(_ dx: Double, _ dy: Double) {
        if machine.isHeld { apply(machine.ball(dx: dx, dy: dy, now: now)) }
    }

    /// Rolls in `steps` reports, `dt` seconds apart.
    func roll(dx: Double, dy: Double, steps: Int, dt: Double = 0.008) {
        for _ in 0..<steps { advance(dt); ball(dx, dy) }
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
        check(overrides[0] != "gesture", "the primary button's press never belongs to a gesture")
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
    r.release(3)
    check(r.taps.count == 2 && !r.frozen, "a fired gesture's release is no tap; pointer free")

    for (dx, dy, want) in [(0.0, -5.0, GestureDirection.up), (0, 5, .down), (-5, 0, .left), (5, 0, .right)] {
        let r = Rig()
        r.press(3); r.roll(dx: dx, dy: dy, steps: 12); r.release(3)
        check(r.fired.map(\.1) == [want], "rolling \(want.rawValue) fires \(want.rawValue)")
    }

    // Once per hold: the old one-shot behavior, still there for those who want it.
    let o = Rig([3: .gesture(oncePerHold(.standard))])
    o.press(3); o.roll(dx: 4, dy: 0, steps: 12)
    check(o.fired.map(\.1) == [.right], "once per hold: fires right")
    o.roll(dx: 4, dy: 0, steps: 200)
    check(o.fired.count == 1, "once per hold: rolling on fires nothing more")
    o.roll(dx: -4, dy: 0, steps: 100)
    check(o.fired.map(\.1) == [.right, .left], "once per hold: another direction still fires (once)")
    o.roll(dx: -4, dy: 0, steps: 200); o.roll(dx: 4, dy: 0, steps: 200)
    check(o.fired.count == 2, "once per hold: each direction at most once")
    o.release(3)
    check(o.taps.isEmpty, "and no tap")
}

section("dominant axis")
do {
    // A diagonal: 52 right, 39 up, neither dominant, under 2× threshold: nothing yet.
    let r = Rig()
    r.press(3); r.roll(dx: 4, dy: -3, steps: 13)
    check(r.fired.isEmpty, "a true diagonal doesn't fire a guess")
    r.roll(dx: 4, dy: -3, steps: 12)   // ~100 right, 75 up: past 2× the threshold, the larger axis wins
    check(r.fired.map(\.1) == [.right], "past twice the threshold, the larger axis wins")
    r.release(3)

    // Mostly up with some drift: up.
    let s = Rig([3: .gesture(.media)])
    s.press(3); s.roll(dx: 1, dy: -5, steps: 10)
    check(s.fired.map(\.1) == [.up], "mostly up is up")
    // Drift while turning the volume up (a continuous run): still only volume.
    s.roll(dx: 1, dy: -4, steps: 60)
    check(s.fired.allSatisfy { $0.1 == .up }, "drift during a continuous run doesn't fire sideways (\(s.fired.map(\.1)))")
    s.release(3)
}

// MARK: - Chained gestures

section("chained gestures")
do {
    // Left, then up, then left again, in one hold: three commands.
    let r = Rig()
    r.press(3)
    r.roll(dx: -4, dy: 0, steps: 14)         // 56 left
    r.advance(0.15)
    r.roll(dx: 0, dy: -4, steps: 14)         // 56 up
    r.advance(0.15)
    r.roll(dx: -4, dy: 0, steps: 14)         // 56 left
    r.release(3)
    check(r.fired.map(\.1) == [.left, .up, .left], "left, up, left in one hold fires three (\(r.fired.map(\.1)))")
    check(r.fired.map(\.0) == [.shortcut(.previousSpace), .shortcut(.missionControl), .shortcut(.previousSpace)],
          "each its own action")
    check(r.taps.isEmpty && !r.frozen, "no tap after a chain; pointer free")

    // No going back first: a steady roll left keeps switching Spaces, one per threshold.
    let s = Rig()
    s.press(3)
    s.roll(dx: -2, dy: 0, steps: 300)        // 600 counts over 2.4 s
    s.release(3)
    let n = s.fired.count
    check(n >= 8 && n <= 12 && s.fired.allSatisfy { $0.1 == .left }, "a long slow roll left chains about one per threshold (\(n))")

    // The same direction again right away (a second flick).
    let t = Rig()
    t.press(3)
    t.roll(dx: -8, dy: 0, steps: 8)          // a fast flick: 64 left in 64 ms
    t.roll(dx: 0, dy: 0, steps: 20)          // a pause
    t.roll(dx: -8, dy: 0, steps: 8)          // again
    t.release(3)
    check(t.fired.map(\.1) == [.left, .left], "two flicks the same way fire twice (\(t.fired.map(\.1)))")

    // Overshoot: the tail of one fast flick never fires a second command.
    let o = Rig()
    o.press(3)
    o.roll(dx: -12, dy: 0, steps: 10)        // 120 counts in 80 ms: one flick
    o.roll(dx: -1, dy: 0, steps: 4)
    o.release(3)
    check(o.fired.count == 1, "one fast flick is one command, however far it went (\(o.fired.count))")

    // A chain mixing continuous and chained: volume up a few, then next track, then volume down.
    let m = Rig([2: .gesture(.media)])
    m.press(2)
    m.roll(dx: 0, dy: -2, steps: 90)          // 180 up: volume up ×3
    let ups = m.fired.filter { $0.0 == .media(.volumeUp) }.count
    m.roll(dx: 3, dy: 0, steps: 20)           // 60 right: next track
    m.advance(0.15)
    m.roll(dx: 0, dy: 2, steps: 60)           // 120 down: volume down
    m.release(2)
    check(ups == 3, "volume up keeps repeating (\(ups))")
    check(m.fired.contains { $0.0 == .media(.next) }, "rolling across breaks out of the continuous run (\(m.fired.map(\.1)))")
    check(m.fired.last?.0 == .media(.volumeDown), "then back to the other axis")
}

section("hysteresis and wobble")
do {
    // A shaky hand: small random wobble around the press point, for 3 s. Nothing fires, and it's still a tap.
    var rng = SystemRandomNumberGenerator()
    for steady in [false, true] {
        let r = Rig()
        r.config.gestureSteadyHands = steady
        let slop = GestureTuning.for(distance: .normal, steadyHands: steady).tapSlop
        r.press(3)
        var x = 0.0, y = 0.0
        for _ in 0..<375 {
            let nx = Double.random(in: -1...1, using: &rng) * (slop * 0.4), ny = Double.random(in: -1...1, using: &rng) * (slop * 0.4)
            r.advance(0.008); r.ball(nx - x, ny - y); x = nx; y = ny
        }
        r.release(3)
        check(r.fired.isEmpty && r.taps.count == 1, "a wobble (\(steady ? "Steady hands" : "normal")) never fires and is still a tap")
    }

    // After a fire, a wobble around the new origin never fires a second command.
    let w = Rig()
    w.press(3)
    w.roll(dx: 5, dy: 0, steps: 12)
    for i in 0..<300 { w.advance(0.008); w.ball(i % 2 == 0 ? 12 : -12, i % 4 < 2 ? 9 : -9) }
    w.release(3)
    check(w.fired.count == 1, "a wobble after a fire fires nothing more (\(w.fired.count))")

    // Rapid reversals: left-right-left as fast as a hand can, 3 s. Rate-limited, never stuck.
    let rr = Rig()
    rr.press(3)
    for i in 0..<300 { rr.roll(dx: i % 2 == 0 ? -10 : 10, dy: 0, steps: 6, dt: 0.002) }   // 60 counts each way, 12 ms each
    rr.release(3)
    let gaps = zip(rr.fireTimes.dropFirst(), rr.fireTimes).map { $0 - $1 }
    check(gaps.allSatisfy { $0 >= tuning.chainCooldown - 1e-9 }, "rapid reversals respect the cool-down")
    check(Double(rr.fired.count) <= 3.6 / tuning.chainCooldown + 1, "and never more than the cool-down allows (\(rr.fired.count))")
    check(!rr.frozen, "pointer free after")
}

section("continuous gestures")
do {
    let r = Rig([2: .gesture(.media)])
    r.press(2)
    r.roll(dx: 0, dy: -2, steps: 24)        // 48: the first step
    check(r.fired.count == 1 && r.fired[0].0 == .media(.volumeUp), "volume up at the threshold")
    r.roll(dx: 0, dy: -2, steps: 64)        // 128 more: two steps of 64, slow enough for the rate limit
    check(r.fired.count == 3, "then once per 64 counts (\(r.fired.count))")
    r.roll(dx: 0, dy: 2, steps: 64)         // back down 128
    check(r.fired.suffix(2).allSatisfy { $0.0 == .media(.volumeDown) }, "rolling back turns it down")
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

    // Presets: zoom and volume are continuous; everything else chains.
    for g in [ButtonGesture.media, .zoom] {
        check(g.up?.mode == .continuous && g.down?.mode == .continuous, "volume and zoom presets are continuous")
    }
    for s in ButtonGesture.suggestions {
        for d in GestureDirection.allCases {
            guard let step = s.gesture[d] else { continue }
            let continuous = [ButtonAction.media(.volumeUp), .media(.volumeDown), .shortcut(.zoomIn), .shortcut(.zoomOut)].contains(step.action)
            check(step.mode == (continuous ? .continuous : .chain), "the \(s.id) set's \(d.rawValue) is \(continuous ? "continuous" : "chained")")
        }
    }
    check(ButtonAction.media(.volumeUp).repeatsByDefault && ButtonAction.shortcut(.zoomIn).repeatsByDefault
          && !ButtonAction.shortcut(.nextSpace).repeatsByDefault, "a picked volume or zoom starts continuous, others chained")
}

section("gesture distance")
do {
    func firstFire(_ d: GestureDistance, steady: Bool = false, own: Bool = false) -> Double? {
        var g = ButtonGesture.standard
        if own { g.distance = d }
        let r = Rig([3: .gesture(g)])
        if !own { r.config.gestureDistance = d }
        r.config.gestureSteadyHands = steady
        r.press(3)
        for i in 1...200 { r.advance(0.008); r.ball(1, 0); if !r.fired.isEmpty { r.release(3); return Double(i) } }
        r.release(3)
        return nil
    }
    let short = firstFire(.short), normal = firstFire(.normal), long = firstFire(.long)
    check(short == 32 && normal == 48 && long == 72, "Short, Normal and Long fire at 32, 48 and 72 counts (\(String(describing: short)), \(String(describing: normal)), \(String(describing: long)))")
    check(firstFire(.short, own: true) == 32 && firstFire(.long, own: true) == 72, "a gesture's own distance wins over the setting")
    check(firstFire(.short, steady: true) == 48, "Steady hands never fires sooner than Normal")
    let st = GestureTuning.for(distance: .normal, steadyHands: true)
    check(st.tapSlop > tuning.tapSlop && st.tapSlop < st.commit, "Steady hands widens the dead zone, still under the threshold")
    for d in GestureDistance.allCases {
        for s in [false, true] {
            let t = GestureTuning.for(distance: d, steadyHands: s)
            check(t.tapSlop < t.commit && t.commit <= t.step && t.minRepeatInterval >= 0.05 && t.chainCooldown >= 0.12 && t.maxHold <= 30,
                  "\(d.rawValue)\(s ? " + steady" : ""): slop < threshold ≤ step, ≤ 20 fires a second, cool-down, 30 s")
        }
    }
}

// MARK: - Combos

section("gestures on combos")
do {
    // Top left + top right is a gesture; each alone is a gesture too.
    let chords = [Chord(buttons: [2, 3], action: .gesture(.tabs))]
    let r = Rig([2: .gesture(.media), 3: .gesture(.standard)], chords: chords)
    r.press(2); r.advance(0.02); r.press(3)
    check(r.machine.isHeld && r.machine.hold?.buttons == [2, 3], "the combo's gesture starts the moment it forms")
    check(r.overrides[2] == "gesture" && r.overrides[3] == "gesture", "both buttons belong to the combo's hold")
    r.roll(dx: 4, dy: 0, steps: 14)
    r.advance(0.15)
    r.roll(dx: 0, dy: -4, steps: 14)
    check(r.fired.map(\.0) == [.shortcut(.nextTab), .shortcut(.newTab)], "it chains the combo's own directions, never the buttons' (\(r.fired.map(\.0)))")
    r.release(3)
    check(!r.frozen && !r.machine.isHeld, "the first release ends it")
    r.roll(dx: 5, dy: 0, steps: 20)
    r.release(2)
    check(r.fired.count == 2 && r.taps.isEmpty, "the partner's late release and rolling do nothing")

    // Released in the other order.
    let o = Rig([2: .gesture(.media), 3: .gesture(.standard)], chords: chords)
    o.combo([3, 2]); o.release(2); o.release(3)
    check(o.taps.count == 1 && o.taps[0].1 == [2, 3] && !o.frozen, "a still combo is the combo's tap, released in any order")

    // A member alone, past the wait: its own gesture.
    let a = Rig([2: .gesture(.media), 3: .gesture(.standard)], chords: chords)
    a.press(3); a.advance(0.1)
    check(a.machine.hold?.buttons == [3], "a member alone starts its own gesture after the wait")
    a.press(2); a.advance(0.1)
    check(a.machine.hold?.buttons == [3] && a.overrides[2] == "swallow", "a partner that comes late doesn't form the combo (and is ignored)")
    a.release(2); a.release(3)
    check(!a.frozen && a.taps.isEmpty, "and the late press cancelled the tap")

    // A member's release inside the wait: not a combo, its own tap, nothing stuck.
    let q = Rig([2: .gesture(.media), 3: .gesture(.standard)], chords: chords)
    q.press(3); q.advance(0.03); q.release(3)
    check(q.taps.map(\.1) == [[3]] && !q.frozen, "a quick press of a member is its own tap")

    // Three-button combo with a gesture, two-button combo inside it.
    let three = Rig([:], chords: [Chord(buttons: [1, 2], action: .shortcut(.copy)), Chord(buttons: [1, 2, 3], action: .gesture(.standard))])
    three.press(1); three.advance(0.02); three.press(2); three.advance(0.03); three.press(3)
    check(three.machine.hold?.buttons == [1, 2, 3], "a three-button gesture combo forms")
    three.release(2); three.release(1); three.release(3)
    check(!three.frozen && three.comboActions.isEmpty, "no partial combo fired")

    // Unplug, pause and sleep mid-chain on a combo.
    for reason in [GestureCancel.unplug, .pause, .sleep, .tapDisabled] {
        let c = Rig([:], chords: chords)
        c.combo([2, 3])
        c.roll(dx: 4, dy: 0, steps: 14); c.advance(0.15); c.roll(dx: 0, dy: 4, steps: 14)
        let n = c.fired.count
        c.cancel(reason)
        c.roll(dx: 4, dy: 0, steps: 40)
        c.release(2); c.release(3)
        check(n == 2 && c.fired.count == n && !c.frozen && c.taps.isEmpty, "\(reason.rawValue) mid-chain on a combo ends it cleanly")
    }
}

section("primary button")
do {
    // A hostile settings file with a gesture on the primary button.
    let r = Rig([0: .gesture(.standard), 3: .gesture(.standard)])
    r.press(0); r.roll(dx: 5, dy: 0, steps: 20); r.release(0)
    check(r.primaryPasses == 1 && r.primaryReleases == 1 && r.fired.isEmpty && !r.frozen, "the primary button stays a left click")
    check(GestureRoute.decide(action: .gesture(.standard), buttons: [0], enabled: true, canReadBall: true, gestureHeld: false) == .notGesture,
          "the route never makes button 0 a gesture")
    check(r.machine.begin(buttons: [0], gesture: .standard, now: 0).isEmpty && !r.machine.isHeld,
          "the machine refuses button 0 even if asked")
    check(r.machine.begin(buttons: [0, 2], gesture: .standard, now: 0).isEmpty && !r.machine.isHeld,
          "and any combo that includes it")

    // A combo with the primary button and a gesture action: the tap, at once, never a hold.
    var g = ButtonGesture.standard; g.tap = .shortcut(.copy)
    let p = Rig([:], chords: [Chord(buttons: [0, 2, 3], action: .gesture(g))])
    p.combo([0, 2, 3])
    check(!p.machine.isHeld && !p.frozen && p.instantTaps.last?.0 == .shortcut(.copy), "a combo with the primary button does the tap action instead")
    p.roll(dx: 5, dy: 0, steps: 20)
    check(p.fired.isEmpty, "and rolling with it moves the pointer, fires nothing")
    p.release(0); p.release(2); p.release(3)

    // The primary alone, when it's in such a combo: still a left click, after the wait.
    let alone = Rig([:], chords: [Chord(buttons: [0, 2], action: .gesture(g))])
    alone.press(0); alone.advance(0.1)
    check(alone.primaryPasses == 1 && !alone.frozen, "the primary alone in a gesture combo is a left click")
    alone.release(0)
    check(alone.primaryReleases == 1, "and its release goes through")

    // A click during a gesture hold: it passes (a left click), and the hold's release is no tap.
    let c = Rig()
    c.press(3); c.press(0); c.release(0); c.release(3)
    check(c.taps.isEmpty && !c.frozen && c.primaryPasses == 1 && c.primaryReleases == 1, "a click during a hold goes through, no tap")

    // Chord overlap: a gesture is held when a combo of two other buttons forms.
    let o = Rig([3: .gesture(.standard)], chords: [Chord(buttons: [1, 2], action: .gesture(.standard))])
    o.press(3)
    o.combo([1, 2])
    check(o.overrides[1] == "swallow" && o.overrides[2] == "swallow", "a second gesture while one is held is ignored")
    o.release(1); o.release(2)
    check(o.machine.isHeld && o.frozen, "the first gesture is still held")
    o.release(3)
    check(o.taps.isEmpty && !o.frozen, "other presses during the hold cancel its tap")
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

        // Mid-chain: after two fires, in the cool-down.
        let c = Rig()
        c.press(3); c.roll(dx: -5, dy: 0, steps: 12); c.advance(0.15); c.roll(dx: 0, dy: -5, steps: 12)
        let n = c.fired.count
        c.cancel(reason)
        c.roll(dx: -5, dy: 0, steps: 40)
        c.release(3)
        check(n == 2 && c.fired.count == 2 && !c.frozen && c.taps.isEmpty, "\(reason.rawValue) mid-chain: nothing more fires")
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

    // A chain that keeps rolling for a minute still ends at 30 s.
    let c = Rig()
    c.press(3)
    for i in 0..<7_500 { c.advance(0.008); c.ball(i % 400 < 200 ? -2 : 2, 0); if i % 30 == 0 { c.tick() } }
    check(!c.machine.isHeld && !c.frozen, "a rolling chain ends at the time limit too")
    c.release(3)
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
    for (dx, dy) in [(0.0, -6.0), (0, 6), (-6, 0), (6, 0)] { h.roll(dx: dx, dy: dy, steps: 12); h.advance(0.15) }
    h.release(3)
    check(!h.fired.isEmpty && h.fired.allSatisfy { $0.0 == .shortcut(.wisprFlow) }, "only the quick press fired")
}

section("deep random run")
do {
    // Random events: presses, releases, combos (through the real wait), rolling
    // in flicks, wobbles and reversals, every way out, long waits and settings
    // changes, across several setups. The invariants run after each one.
    var rng = SystemRandomNumberGenerator()
    var odd = ButtonGesture.media
    odd.left?.once = true
    odd.distance = .short
    let setups: [([Int: ButtonAction], [Chord])] = [
        ([3: .gesture(.standard)], []),
        ([1: .gesture(.media), 2: .gesture(.standard), 3: .back], [Chord(buttons: [2, 3], action: .gesture(.tabs))]),
        ([0: .gesture(.standard), 1: .gesture(.media), 2: .gesture(odd), 3: .gesture(.zoom)],
         [Chord(buttons: [0, 3], action: .gesture(.standard)), Chord(buttons: [1, 2], action: .gesture(oncePerHold(.standard))),
          Chord(buttons: [1, 2, 3], action: .gesture(.media))]),
        ([2: .gesture(.zoom), 3: .gesture(.tabs)], [Chord(buttons: [0, 2, 3], action: .holdShortcut(.wisprFlow)),
                                                     Chord(buttons: [1, 3], action: .gesture(odd))]),
    ]
    let reasons: [GestureCancel] = [.pause, .quit, .unplug, .tapDisabled, .sleep, .lostRelease, .configChanged]
    var events = 0
    for (buttons, chords) in setups {
        let r = Rig(buttons, chords: chords)
        var down = Set<Int>()
        for _ in 0..<160_000 {
            events += 1
            r.advance(Double.random(in: 0...0.02, using: &rng))
            switch Int.random(in: 0..<100, using: &rng) {
            case 0..<12:
                let b = Int.random(in: 0...3, using: &rng)
                if !down.contains(b) { down.insert(b); r.press(b) }
            case 12..<26:
                if let b = down.randomElement(using: &rng) { down.remove(b); r.release(b) }
            case 26..<29:
                let bs = Array(Set((0..<Int.random(in: 2...3, using: &rng)).map { _ in Int.random(in: 0...3, using: &rng) }))
                if bs.count >= 2, down.isDisjoint(with: bs) {
                    down.formUnion(bs)
                    for b in bs.shuffled(using: &rng) { r.press(b); r.advance(Double.random(in: 0...0.05, using: &rng)) }
                }
            case 29..<31:
                r.cancel(reasons.randomElement(using: &rng)!)
                if Bool.random(using: &rng) { down.removeAll(); r.pending = []; r.pendingDeadline = nil }   // unplugged: the releases never come
            case 31..<33:
                r.now += Double.random(in: 1...40, using: &rng)
                r.tick()
            case 33..<35:
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: r.config.gesturesEnabled.toggle()
                case 1: r.config.gestureDistance = GestureDistance.allCases.randomElement(using: &rng)!
                default: r.config.gestureSteadyHands.toggle()
                }
            case 35..<45:
                // A flick: a burst in one direction.
                let dx = Double.random(in: -12...12, using: &rng), dy = Double.random(in: -12...12, using: &rng)
                r.roll(dx: dx, dy: dy, steps: Int.random(in: 3...15, using: &rng), dt: 0.004)
            case 45..<50:
                // A reversal.
                let dx = Double.random(in: -10...10, using: &rng)
                r.roll(dx: dx, dy: 0, steps: 6, dt: 0.003); r.roll(dx: -dx, dy: 0, steps: 6, dt: 0.003)
            default:
                r.ball(Double.random(in: -30...30, using: &rng), Double.random(in: -30...30, using: &rng))
                r.tick()
            }
        }
        r.advance(0.2)
        for b in down { r.release(b) }
        r.cancel(.quit)
        check(!r.frozen && !r.machine.isHeld, "after the run and a quit, nothing is held")
        check(r.overrides.values.allSatisfy { $0 != "gesture" }, "no button is left belonging to a hold")
    }
    print("  \(events.formatted()) random events, \(checks.formatted()) checks so far")
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
    check(o?.gestureDistance == .normal && o?.gestureSteadyHands == false, "gesture distance Normal, Steady hands off")

    // A 2.10 beta's gesture (before chaining): loads unchanged, its one-shot steps now chain.
    let beta = #"""
    {"buttons":{"3":{"gesture":{"_0":{"up":{"action":{"shortcut":{"_0":{"keyCode":126,"modifiers":262144,"keyName":"↑"}}},"repeats":false},
                                      "down":{"action":{"media":{"_0":1}},"repeats":true},"tap":{"back":{}}}}}},
     "chords":[{"id":"6B1D7C2E-0000-4000-8000-000000000001","buttons":[1,3],"action":{"gesture":{"_0":{"left":{"action":{"back":{}},"repeats":false}}}}}],
     "gesturesEnabled":true}
    """#
    let b = try? decoder.decode(GlideConfig.self, from: Data(beta.utf8))
    if case .gesture(let g)? = b?.buttons[3] {
        check(g.up?.mode == .chain && g.down?.mode == .continuous && g.tap == .back && g.distance == nil, "a beta gesture loads: one-shot is now chained, repeats continuous")
    } else { check(false, "the beta gesture loads") }
    check(b?.chords.first?.action.isGesture == true, "a beta gesture combo loads")
    if let b {
        let again = try? decoder.decode(GlideConfig.self, from: try! encoder.encode(b))
        check(again == b, "and round-trips")
        let json = String(data: try! encoder.encode(b), encoding: .utf8) ?? ""
        check(!json.contains("\"once\"") && !json.contains("\"distance\""), "nothing new is written for settings that don't use it")
    }

    // Round trip.
    var c = GlideConfig()
    c.buttons[3] = .gesture(.keeping(.back))
    var media = ButtonGesture.media
    media.left?.mode = .once
    media.distance = .long
    c.buttons[2] = .gesture(media)
    c.chords = [Chord(buttons: [1, 2], action: .gesture(.standard))]
    c.gesturesEnabled = false
    c.gestureDistance = .short
    c.gestureSteadyHands = true
    c.displaySpeeds.enabled = true
    c.displaySpeeds.speeds = ["1552-41001-0": 6.5]
    c.displaySpeeds.names = ["1552-41001-0": "Studio Display"]
    let data = try! encoder.encode(c)
    let back = try? decoder.decode(GlideConfig.self, from: data)
    check(back == c, "gesture and display settings round-trip (once, distances, Steady hands)")
    if case .gesture(let g)? = back?.buttons[3] { check(g.tap == .back, "turning a button into a gesture keeps its old action as the tap") }
    else { check(false, "button 3 is a gesture") }
    let file = try? decoder.decode(GlideSettingsFile.self, from: try! encoder.encode(GlideSettingsFile(config: c, exportedFrom: "sim")))
    check(file?.config == c, "and survive an exported settings file")
    check(GestureStep(.back, repeats: true, once: true).mode == .continuous, "continuous and once together: continuous")
    var m = GestureStep(.back); m.mode = .once; m.mode = .continuous
    check(m.repeats && !m.once, "switching modes leaves one on")

    // A newer Glideball's gesture: an action this version doesn't know in one
    // direction, a field it doesn't know, an unknown tap, an unknown distance.
    let newer = #"""
    {"buttons":{
        "2":{"gesture":{"_0":{"up":{"action":{"teleport":{}},"repeats":true},
                              "down":{"action":{"media":{"_0":1}},"repeats":true,"curve":"fast"},
                              "left":{"action":{"shortcut":{"_0":{"keyCode":123,"modifiers":262144,"keyName":"←"}}},"once":"sometimes"},
                              "tap":{"hologram":{}},
                              "distance":"lightyear",
                              "wiggle":{"action":{"back":{}}}}}},
        "3":{"warpDrive":{}}},
     "displaySpeeds":{"enabled":true,"speeds":{"a":5,"b":"fast","c":-1},"future":1},
     "gesturesEnabled":"maybe",
     "gestureDistance":"enormous",
     "gestureSteadyHands":3,
     "somethingNew":{"x":1}}
    """#
    let n = try? decoder.decode(GlideConfig.self, from: Data(newer.utf8))
    check(n != nil, "a newer settings file still loads")
    if case .gesture(let g)? = n?.buttons[2] {
        check(g.up == nil, "a direction with an unknown action is skipped")
        check(g.down == GestureStep(.media(.volumeDown), repeats: true), "a direction with an unknown field still loads")
        check(g.left?.action == .shortcut(.previousSpace) && g.left?.mode == .chain, "known directions load (an unreadable once is off)")
        check(g.tap == .system, "an unknown tap falls back to the button's own click")
        check(g.distance == nil, "an unknown distance follows the setting")
    } else {
        check(false, "the gesture button loads even with unknown parts")
    }
    check(n?.buttons[3] == nil, "an unknown action on a button is skipped, not the file")
    check(n?.gesturesEnabled == true, "an unreadable switch is its default")
    check(n?.gestureDistance == .normal && n?.gestureSteadyHands == false, "unreadable gesture settings are their defaults")
    check(n?.displaySpeeds.enabled == false || n?.displaySpeeds.speeds.isEmpty == true || n?.displaySpeeds.speeds == ["a": 5],
          "unreadable display speeds are dropped, never wrong")

    // An unknown media key name (a newer version's key) skips just that button.
    let key = #"{"buttons":{"1":{"media":{"_0":99}},"2":{"media":{"_0":7}}}}"#
    let k = try? decoder.decode(GlideConfig.self, from: Data(key.utf8))
    check(k?.buttons[1] == nil && k?.buttons[2] == .media(.mute), "unknown media keys are skipped, known ones load")

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

section("sync guard: older Glideballs")
do {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    // Plain settings stay version 1, so every older Glideball keeps syncing them.
    var plain = GlideConfig()
    plain.buttons[3] = .shortcut(.nextSpace)
    check(GlideSettingsFile(config: plain).version == 1, "settings without newer features are written as version 1")
    var tunedOnly = plain
    tunedOnly.gestureDistance = .long
    tunedOnly.gestureSteadyHands = true
    check(tunedOnly.requiredFileVersion == 1, "gesture distance or Steady hands without a gesture stay version 1")

    // A gesture anywhere (main, combo, app setup) or display speeds: version 2.
    var g = plain
    g.buttons[2] = .gesture(.standard)
    check(GlideSettingsFile(config: g).version == 2, "a gesture button makes it version 2")
    var c = plain
    c.chords = [Chord(buttons: [1, 3], action: .gesture(.media))]
    check(c.requiredFileVersion == 2, "a gesture combo makes it version 2")
    var a = plain
    var prof = AppProfile(bundleID: "x", name: "X")
    prof.buttons = [2: .gesture(.tabs)]
    a.appProfiles = [prof]
    check(a.requiredFileVersion == 2, "an app setup's gesture makes it version 2")
    var d = plain
    d.displaySpeeds.speeds = ["k": 7]
    check(d.requiredFileVersion == 2, "display speeds make it version 2")

    // What every shipped Glideball does with a file (validatedConfig: version == 1).
    func shippedAccepts(_ data: Data) -> Bool {
        struct Old: Decodable { let version: Int }
        guard let f = try? decoder.decode(Old.self, from: data) else { return false }
        return f.version == 1
    }
    if let v2 = try? encoder.encode(GlideSettingsFile(config: g)), let v1 = try? encoder.encode(GlideSettingsFile(config: plain)) {
        check(!shippedAccepts(v2), "an older Glideball refuses (won't adopt or overwrite) a version 2 file")
        check(shippedAccepts(v1), "an older Glideball still reads a version 1 file")
        check((try? decoder.decode(GlideSettingsFile.self, from: v2).validatedConfig()) != nil, "this Glideball reads version 2")
        check((try? decoder.decode(GlideSettingsFile.self, from: v1).validatedConfig()) != nil, "this Glideball reads version 1")
        let f2 = try? decoder.decode(GlideSettingsFile.self, from: v2)
        check(f2?.writtenBy != nil, "files say which Glideball wrote them")
    }
    let v3 = #"{"version":3,"config":{}}"#
    check((try? decoder.decode(GlideSettingsFile.self, from: Data(v3.utf8)).validatedConfig()) == nil, "a version 3 file is refused")

    // An older Glideball read our gesture settings (dropping the gestures) and wrote them back.
    var local = GlideConfig()
    var once = ButtonGesture.standard
    once.left?.mode = .once
    once.distance = .short
    local.buttons = [1: .rightClick, 2: .gesture(.media), 3: .gesture(.standard)]
    local.chords = [Chord(buttons: [1, 2], action: .gesture(once)), Chord(buttons: [2, 3], action: .shortcut(.copy))]
    local.displaySpeeds.enabled = true
    local.displaySpeeds.speeds = ["k": 9]
    local.gesturesEnabled = false
    local.gestureDistance = .long
    local.gestureSteadyHands = true
    var oldWrite = GlideConfig()
    oldWrite.buttons = [1: .rightClick, 3: .back]          // the user changed top right there; top left was dropped
    oldWrite.chords = [Chord(buttons: [2, 3], action: .shortcut(.copy))]   // the gesture combo was dropped
    oldWrite.trackingSpeed = 6
    let merged = oldWrite.keepingNewerFeatures(from: local)
    check(merged.kept, "keeping dropped gestures is noticed (the user is told once)")
    check(merged.config.buttons[2] == .gesture(.media), "a gesture the older one dropped comes back")
    check(merged.config.buttons[3] == .back, "what the older one set explicitly wins")
    check(merged.config.chords.contains { $0.buttons == [1, 2] && $0.action == .gesture(once) }, "a dropped gesture combo comes back whole (once, distance)")
    check(merged.config.chords.count == 2, "no combo is doubled")
    check(merged.config.trackingSpeed == 6, "everything else comes from the newer write")
    check(merged.config.displaySpeeds.speeds == ["k": 9] && merged.config.displaySpeeds.enabled, "display speeds stay this Mac's")
    check(merged.config.gesturesEnabled == false, "the gestures switch stays this Mac's")
    check(merged.config.gestureDistance == .long && merged.config.gestureSteadyHands, "gesture distance and Steady hands stay this Mac's")
    check(merged.config.requiredFileVersion == 2, "the merged settings go back up as version 2")
    let nothing = plain.keepingNewerFeatures(from: plain)
    check(!nothing.kept && nothing.config == plain, "settings with nothing newer merge to themselves, silently")

    // A 2.10 beta that knew gestures but not chaining's fields read ours and wrote them back.
    check(GlideSettingsFile.predatesGestureTuning("2.10-beta.11"), "2.10 beta 11 predates the new gesture fields")
    check(GlideSettingsFile.predatesGestureTuning("2.10-beta.2") && GlideSettingsFile.predatesGestureTuning("2.9"), "and so do older ones")
    check(!GlideSettingsFile.predatesGestureTuning(GlideSettingsFile.gestureTuningSince), "the first one that writes them doesn't")
    check(!GlideSettingsFile.predatesGestureTuning("2.10") && !GlideSettingsFile.predatesGestureTuning("2.11-beta.1")
          && !GlideSettingsFile.predatesGestureTuning("2.10.1"), "nor any later one")
    check(!GlideSettingsFile.predatesGestureTuning("weird"), "an unreadable version is never treated as older")
    check(GlideSettingsFile.predatesGestureTuning(nil), "no version at all is older")

    var betaWrite = local                                   // what a beta would write back: no once, no distance
    func strip(_ a: ButtonAction) -> ButtonAction {
        guard case .gesture(var g) = a else { return a }
        g.distance = nil
        for d in GestureDirection.allCases { g[d]?.once = false }
        return .gesture(g)
    }
    betaWrite.buttons = betaWrite.buttons.mapValues(strip)
    betaWrite.chords = betaWrite.chords.map { var c = $0; c.action = strip(c.action); return c }
    betaWrite.gestureDistance = .normal
    betaWrite.gestureSteadyHands = false
    betaWrite.trackingSpeed = 7
    let restored = betaWrite.keepingGestureTuning(from: local)
    check(restored.kept, "the beta's drop is noticed (and written back)")
    check(restored.config.chords.first { $0.buttons == [1, 2] }?.action == .gesture(once), "once per hold and a gesture's distance come back")
    check(restored.config.gestureDistance == .long && restored.config.gestureSteadyHands, "the gesture settings come back")
    check(restored.config.trackingSpeed == 7, "everything else comes from the beta's write")
    // The beta's user changed that direction: their change wins (it's chained now, as they'd see it).
    var changed = betaWrite
    if case .gesture(var cg) = changed.chords[0].action { cg.left = GestureStep(.back); changed.chords[0].action = .gesture(cg) }
    let mixed = changed.keepingGestureTuning(from: local)
    if case .gesture(let mg) = mixed.config.chords[0].action {
        check(mg.left == GestureStep(.back) && mg.distance == .short, "a direction changed on the beta keeps its change; the distance still comes back")
    } else { check(false, "the combo is still a gesture") }
    let same = local.keepingGestureTuning(from: local)
    check(!same.kept && same.config == local, "nothing dropped: nothing changes, silently")

    // A share or import sanitizes without losing the new fields.
    var sg = ButtonGesture.media
    sg.right?.mode = .once
    sg.distance = .short
    check(ButtonAction.gesture(sg).sanitized() == .gesture(sg), "import safety keeps once and distance")
}

print(failures == 0 ? "✓ gesture-sim: all \(checks.formatted()) checks passed" : "✗ gesture-sim: \(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
