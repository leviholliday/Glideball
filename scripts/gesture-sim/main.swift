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
/// hold can end, minus CoreGraphics. `frozen` is the engine's freeze (CGAssociateMouseAndMouseCursorPosition
/// plus putting the pointer back in any app); scripts/engine-fuzz checks where the pointer ends up, in front and behind.
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
    var picks: [(ButtonAction, Int)] = []            // Wheel slots run (at the release)
    var ringSteps: [(ButtonAction, Bool)] = []       // ring job steps (while held)
    var ringRepeats: [(ButtonAction, Int)] = []      // a repeating place on the ring (while held)
    var picksWhileHeld = 0
    var switches: [(session: Int, index: Int)] = []  // Switcher: apps switched to (at the release)
    var switchesWhileHeld = 0
    /// The Switcher's list as the main thread would build it: this many apps, laid out so.
    /// Nil: the list never arrives in this hold (a busy main thread).
    var switcherGrid: SwitcherGrid? = SwitcherGrid.fitting(count: 6, maxColumns: 8, maxRows: 3)
    var switcherReadyAfter = 0.0                     // seconds after the press it arrives
    private var switcherDue: (session: Int, at: Double)?
    private var sessions = 0

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
            case .wheelPick(let a, let place):
                if machine.isHeld { picksWhileHeld += 1 }
                picks.append((a, place))
            case .ringStep(let a, let cw):
                check(machine.isHeld && !machine.switcherHeld && machine.ringTaken, "a ring step only while a Gestures button with a ring job is held")
                ringSteps.append((a, cw))
            case .ringRepeat(let a, let place):
                check(machine.wheelHeld, "a repeating place runs only while its ring is held")
                check(machine.hold?.wheel?.steps[place]?.repeats == true, "only a place that repeats runs while held")
                if let last = holdFires.last { check(now - last.t >= holdTuning.minRepeatInterval - 1e-9, "never two fires within \(holdTuning.minRepeatInterval) s") }
                holdFires.append((now, GestureDirection(place: place), false))
                ringRepeats.append((a, place))
            case .switchApp(let session, let index):
                if machine.isHeld { switchesWhileHeld += 1 }
                check(!switches.contains { $0.session == session }, "at most one switch per Switcher hold")
                if let g = switcherGrid { check(index >= 0 && index < g.count, "the switch is to an app in the list (\(index) of \(g.count))") }
                switches.append((session, index))
            }
        }
        invariants()
    }

    private func route(_ action: ButtonAction, _ buttons: [Int]) {
        switch GestureRoute.decide(action: action, buttons: buttons, enabled: config.gesturesEnabled,
                                   canReadBall: canReadBall, gestureHeld: machine.isHeld) {
        case .begin:
            let effects: [GestureEffect]
            switch action {
            case .gesture(let g):
                let tuning = GestureTuning.for(distance: g.distance ?? config.gestureDistance, steadyHands: config.gestureSteadyHands)
                effects = machine.begin(buttons: buttons, gesture: g, now: now, tuning: tuning)
            case .wheel(let w):
                let tuning = GestureTuning.for(distance: config.gestureDistance, steadyHands: config.gestureSteadyHands)
                effects = machine.beginWheel(buttons: buttons, menu: w, now: now, tuning: tuning)
            case .switcher(let a):
                let tuning = GestureTuning.for(distance: config.gestureDistance, steadyHands: config.gestureSteadyHands)
                sessions += 1
                effects = machine.beginSwitcher(buttons: buttons, switcher: a, session: sessions, now: now, tuning: tuning)
                if !effects.isEmpty { switcherDue = (sessions, now + switcherReadyAfter) }
            default: fatalError("begin for a non-gesture")
            }
            for b in buttons { overrides[b] = effects.isEmpty ? "swallow" : "gesture" }
            apply(effects)
            deliverSwitcherList()
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

    /// What other buttons did to the Switcher's apps (Engine.routeButton: hide or bring back).
    var hides: [SwitcherHold.HideResult] = []

    /// One button down (`Engine.handleButton`).
    func press(_ b: Int) {
        // Another trackball button while the Switcher's panel is up: the Switcher's (never the
        // primary button, never the hold's own), and nothing else happens.
        if b != 0, machine.switcherHeld, switcherPanel != nil, pending.isEmpty, let r = machine.switcherHide(button: b) {
            hides.append(r)
            overrides[b] = "swallow"
            check(machine.hold?.switcher?.dismissed == false, "hiding an app never dismisses the Switcher")
            invariants()
            return
        }
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
        deliverSwitcherList()
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

    /// The engine's 50 ms look while the ring waits on time (`Engine.syncWheel`, `wheelTick`).
    func tickRing() {
        if machine.wheelWaiting { apply(machine.wheelTick(now: now)) }
        invariants()
    }

    /// The scroll ring (Engine.hidWheel): a Wheel's ring job, or the Switcher's highlight, while one is held.
    func ring(_ ticks: Int) {
        if machine.ringTaken { apply(machine.ring(ticks: ticks, now: now)) }
        invariants()
    }

    /// The main thread hands the engine its list, when it's due (`switcherReadyAfter`).
    func deliverSwitcherList() {
        guard let due = switcherDue, now >= due.at else { return }
        switcherDue = nil
        if let g = switcherGrid { machine.switcherReady(session: due.session, grid: g) }
        invariants()
    }

    /// What the Switcher's panel shows now (nil: hidden), as the engine's `syncSwitcher` asks.
    var switcherPanel: SwitcherOverlayModel? { machine.switcherOverlay(now: now) }

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
        check(fired.allSatisfy { isFireAndForget($0.0) || $0.0 == .precisionToggle }, "a gesture only fires press-and-release actions")
        check(ringRepeats.allSatisfy { isFireAndForget($0.0) || $0.0 == .precisionToggle }, "a repeating place only runs a one-shot")
        check(picks.allSatisfy { isFireAndForget($0.0) || $0.0 == .precisionToggle }, "a Wheel slot only runs a one-shot")
        check(ringSteps.allSatisfy { isFireAndForget($0.0) || $0.0 == .precisionToggle }, "a ring step only runs a one-shot")
        check(picksWhileHeld == 0, "a Wheel slot never runs while the Wheel is held")
        check(switchesWhileHeld == 0, "the Switcher never switches while it's held")
        check(!(machine.wheelHeld && machine.switcherHeld), "a Wheel and a Switcher are never held at once")
        if let s = machine.hold?.switcher, let g = s.grid, g.count > 0 {
            check(s.index >= 0 && s.index < g.count, "the Switcher's highlight is on an app (\(s.index) of \(g.count))")
            let row = s.index / g.columns
            check(row >= s.firstRow && row < s.firstRow + g.visibleRows, "the lit app's row is on screen")
        }
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

// MARK: - The Wheel

section("the Wheel")
do {
    let menu = WheelMenu.standard   // up Mission Control, right Next Space, down App Exposé, left Previous Space
    // A still press: the tap (the button's own click), nothing else.
    let r = Rig([3: .wheel(menu)])
    r.press(3); r.now += 0.1; r.release(3)
    check(r.taps.count == 1 && r.taps[0].0 == .system && r.picks.isEmpty, "a still Wheel press is the tap")
    check(!r.frozen, "pointer free after")
    // Rolling right past the slot distance lights right; the release runs it, once.
    r.press(3); r.roll(dx: 4, dy: 0, steps: 12)
    check(r.picks.isEmpty, "nothing runs while held")
    check(r.machine.hold?.wheel?.selected == 2, "rolling right lights the right slot (\(String(describing: r.machine.hold?.wheel?.selected)))")
    r.release(3)
    check(r.picks.count == 1 && r.picks[0].0 == .shortcut(.nextSpace) && r.picks[0].1 == 2, "the release runs the lit slot once")
    check(r.taps.count == 1, "and no tap")
    // Each straight way.
    for (dx, dy, place) in [(0.0, -5.0, 0), (5, 0, 2), (0, 5, 4), (-5, 0, 6)] {
        let w = Rig([3: .wheel(menu)])
        w.press(3); w.roll(dx: dx, dy: dy, steps: 12); w.release(3)
        check(w.picks.map(\.1) == [place], "rolling toward place \(place) picks it (\(w.picks.map(\.1)))")
    }
    // A flick and release before the ring draws (under 0.18 s): still runs that way.
    let f = Rig([3: .wheel(menu)])
    f.press(3); f.roll(dx: 0, dy: -20, steps: 4, dt: 0.004); f.release(3)
    check(f.picks.map(\.1) == [0], "a flick up and release before the ring draws runs up")
    // Rolled out, then back to the centre: nothing.
    let c = Rig([3: .wheel(menu)])
    c.press(3); c.roll(dx: 5, dy: 0, steps: 12); c.roll(dx: -5, dy: 0, steps: 12); c.release(3)
    check(c.picks.isEmpty && c.taps.isEmpty, "rolled back to the centre: nothing runs, no tap")
    // Rolled far one way, then the other way: the clamp makes it come back at once.
    let far = Rig([3: .wheel(menu)])
    far.press(3); far.roll(dx: 5, dy: 0, steps: 200); far.roll(dx: -5, dy: 0, steps: 40); far.release(3)
    check(far.picks.map(\.1) == [6], "after rolling far right, rolling left soon lights left (\(far.picks.map(\.1)))")
    // Another trackball button: dismissed.
    let d = Rig([3: .wheel(menu)])
    d.press(3); d.roll(dx: 5, dy: 0, steps: 12); d.press(1); d.release(1); d.release(3)
    check(d.picks.isEmpty && d.taps.isEmpty, "another button dismisses the Wheel: nothing runs")
    // Esc.
    let e = Rig([3: .wheel(menu)])
    e.press(3); e.roll(dx: 5, dy: 0, steps: 12); e.machine.dismissWheel(); e.roll(dx: 5, dy: 0, steps: 12); e.release(3)
    check(e.picks.isEmpty && e.taps.isEmpty, "Esc dismisses the Wheel: nothing runs, even rolling on")
    // The ring: steps of the ring job while held, never a slot, never the tap.
    let g = Rig([3: .wheel(menu)])
    g.press(3)
    for _ in 0..<5 { g.advance(0.06); g.ring(-1) }
    for _ in 0..<3 { g.advance(0.06); g.ring(1) }
    g.release(3)
    check(g.ringSteps.map(\.0) == Array(repeating: ButtonAction.media(.volumeUp), count: 5) + Array(repeating: .media(.volumeDown), count: 3),
          "the ring steps volume up clockwise, down the other way (\(g.ringSteps.map(\.0)))")
    check(g.picks.isEmpty && g.taps.isEmpty, "a release after only ring turns runs nothing")
    // At most 20 ring steps a second; the rest are dropped.
    let fast = Rig([3: .wheel(menu)])
    fast.press(3)
    for _ in 0..<40 { fast.advance(0.01); fast.ring(-1) }
    fast.release(3)
    check(fast.ringSteps.count <= 9 && fast.ringSteps.count >= 7, "fast ring turns: at most 20 steps a second (\(fast.ringSteps.count) in 0.4 s)")
    // Ring and a slot: the slot still runs at the release.
    let both = Rig([3: .wheel(menu)])
    both.press(3); both.roll(dx: 0, dy: 5, steps: 12); both.advance(0.06); both.ring(1); both.release(3)
    check(both.picks.map(\.1) == [4] && both.ringSteps.count == 1, "a lit slot still runs after a ring turn")
    // Every way out without its release: nothing runs.
    for reason in [GestureCancel.pause, .quit, .unplug, .tapDisabled, .sleep, .lostRelease, .timeout] {
        let x = Rig([3: .wheel(menu)])
        x.press(3); x.roll(dx: 5, dy: 0, steps: 12); x.cancel(reason); x.release(3)
        check(x.picks.isEmpty && x.taps.isEmpty && !x.frozen, "\(reason.rawValue) ends a Wheel hold: nothing runs, pointer free")
    }
    // The 30 s limit.
    let t = Rig([3: .wheel(menu)])
    t.press(3); t.roll(dx: 5, dy: 0, steps: 12); t.advance(31); t.tick(); t.release(3)
    check(t.picks.isEmpty && !t.frozen, "past the time limit: ended, nothing runs")
    // Never on the primary button, alone or in a combo.
    let p = Rig([0: .wheel(menu)])
    p.press(0); p.roll(dx: 5, dy: 0, steps: 12); p.release(0)
    check(p.picks.isEmpty && p.freezeOns == 0 && p.primaryPasses == 1, "the primary button is never a Wheel")
    let pc = Rig([:], chords: [Chord(buttons: [0, 2], action: .wheel(menu))])
    pc.combo([0, 2]); pc.roll(dx: 5, dy: 0, steps: 12); pc.release(0); pc.release(2)
    check(pc.picks.isEmpty && pc.freezeOns == 0, "a combo with the primary button is never a Wheel")
    // On a combo: the first button up ends it and runs the slot.
    let cb = Rig([:], chords: [Chord(buttons: [1, 3], action: .wheel(menu))])
    cb.combo([1, 3]); cb.roll(dx: -5, dy: 0, steps: 12); cb.release(3); cb.release(1)
    check(cb.picks.map(\.1) == [6] && !cb.frozen, "a Wheel combo: the first button up runs the slot, once")
    // A gesture and a Wheel are never held at once.
    let mix = Rig([2: .gesture(.standard), 3: .wheel(menu)])
    mix.press(3); mix.press(2); mix.roll(dx: 5, dy: 0, steps: 12); mix.release(2); mix.release(3)
    check(mix.fired.isEmpty && mix.picks.isEmpty && mix.freezeOns == 1, "a gesture press during a Wheel hold is ignored (and dismisses it)")
    // Empty slots are skipped: two filled slots split the circle between them.
    var two = WheelMenu()
    two[0] = .shortcut(.copy); two[4] = .shortcut(.paste)
    let tw = Rig([3: .wheel(two)])
    tw.press(3); tw.roll(dx: 5, dy: -1.5, steps: 12); tw.release(3)
    check(tw.picks.map(\.1) == [0], "with only up and down filled, a roll right-and-up picks up (\(tw.picks.map(\.1)))")
    // Eight slots use the diagonals.
    var eight = WheelMenu.standard
    eight.eight = true
    eight[1] = .shortcut(.newTab)
    let ei = Rig([3: .wheel(eight)])
    ei.press(3); ei.roll(dx: 4, dy: -4, steps: 12); ei.release(3)
    check(ei.picks.map(\.1) == [1], "eight slots: up-right picks the diagonal (\(ei.picks.map(\.1)))")
    var four = eight
    four.eight = false
    let fo = Rig([3: .wheel(four)])
    fo.press(3); fo.roll(dx: 4, dy: -4.4, steps: 12); fo.release(3)
    check(fo.picks.map(\.1) == [0], "four slots: the hidden diagonal is never picked (\(fo.picks.map(\.1)))")
    // Hold-type actions never run from a slot.
    var holdy = WheelMenu()
    holdy[2] = .precisionHold; holdy[6] = .holdShortcut(.wisprFlow); holdy[0] = .dragLock
    let h = Rig([3: .wheel(holdy)])
    h.press(3); h.roll(dx: 5, dy: 0, steps: 12); h.release(3)
    h.press(3); h.roll(dx: -5, dy: 0, steps: 12); h.release(3)
    h.press(3); h.roll(dx: 0, dy: -5, steps: 12); h.release(3)
    // (Only the shortcut's slot counts as filled, so every way picks it: empty slots are skipped.)
    check(h.picks.map(\.0) == Array(repeating: .shortcut(.wisprFlow), count: 3) && h.picks.allSatisfy { $0.1 == 6 },
          "slots: a hold becomes a quick press, modes that hold never run (\(h.picks.map(\.0)))")
    // The tap: a held shortcut is a quick press; a Wheel or a hold mode does nothing.
    var tapW = menu
    tapW.tap = .holdShortcut(.copy)
    let tp = Rig([3: .wheel(tapW)])
    tp.press(3); tp.release(3)
    check(tp.taps.map(\.0) == [.shortcut(.copy)], "a held-shortcut tap is a quick press")
    // Geometry: the select distance grows with Gesture distance and Steady hands.
    let geo = WheelGeometry(GestureTuning.for(distance: .normal, steadyHands: false))
    check(geo.release < geo.select && geo.select < geo.reach, "release < select < reach")
    check(geo.pick(x: 0, y: -geo.select + 1, current: nil, filled: [0, 2, 4, 6]) == nil, "just short of the slot distance: nothing lit")
    check(geo.pick(x: 0, y: -geo.select - 1, current: nil, filled: [0, 2, 4, 6]) == 0, "just past it: up")
    check(geo.pick(x: 30, y: -32, current: 0, filled: [0, 2, 4, 6]) == 0, "a lit slot stays lit across the border (stickiness)")
    check(geo.pick(x: .nan, y: 3, current: nil, filled: [0]) == nil, "NaN: nothing")
    // Hostile numbers through the machine.
    let n = Rig([3: .wheel(menu)])
    n.press(3); n.ball(.infinity, 3); n.ball(.nan, .nan); n.ball(-1e308, 1e308); n.release(3)
    check(!n.frozen && n.picks.count <= 1, "infinite and NaN rolls: no crash, at most one pick")
    // Random Wheel holds: rules after every event (invariants), and at most one pick per hold.
    var seed: UInt64 = 0x5EED
    func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
    for _ in 0..<3000 {
        var m = WheelMenu.standard
        m.eight = rnd() < 0.5
        for place in 0..<8 where rnd() < 0.3 { m[place] = rnd() < 0.2 ? nil : [.back, .forward, .shortcut(.copy), .media(.mute), .precisionHold, .precisionToggle][Int(rnd() * 6)] }
        m.ring = RingJob.allCases[Int(rnd() * Double(RingJob.allCases.count))]
        let z = Rig([3: .wheel(m), 2: .wheel(m)], chords: rnd() < 0.3 ? [Chord(buttons: [1, 3], action: .wheel(m))] : [])
        var holds = 0
        for _ in 0..<60 {
            let before = z.picks.count
            switch Int(rnd() * 9) {
            case 0: z.press(Int(rnd() * 4)); if z.machine.isHeld { holds += 1 }
            case 1: z.release(Int(rnd() * 4))
            case 2, 3: z.roll(dx: rnd() * 20 - 10, dy: rnd() * 20 - 10, steps: 1 + Int(rnd() * 6))
            case 4: z.ring(rnd() < 0.5 ? 1 : -1)
            case 5: if rnd() < 0.9 { z.advance(rnd() * 0.2) } else { z.now += 31 }; z.tick(); z.advance(0)
            case 6: z.machine.dismissWheel()
            case 7: if rnd() < 0.2 { z.cancel([.pause, .sleep, .unplug, .tapDisabled][Int(rnd() * 4)]) }
            default: z.advance(0.01)
            }
            check(z.picks.count - before <= 1, "never two slots from one event")
        }
        for b in 0..<4 { z.release(b) }
        check(!z.frozen, "random Wheel holds: pointer free at the end")
    }
}

section("old Wheels and gestures load as Gestures (settings files)")
do {
    // A Wheel as betas 24 to 27 wrote it: every setting, through a real settings file.
    var w = WheelMenu.standard
    w.eight = true
    w[1] = .openApp(bundleID: "com.apple.Safari")
    w[3] = .holdShortcut(.wisprFlow)
    w.ring = .custom
    w.ringUp = .shortcut(.redo)
    w.ringDown = .back
    w.tap = .media(.playPause)
    var old = GlideConfig()
    old.buttons[3] = .wheel(w)
    old.buttons[2] = .wheel(WheelMenu.keeping(.middleClick))
    old.chords = [Chord(buttons: [1, 3], action: .wheel(.standard))]
    var p = AppProfile(bundleID: "com.example.app", name: "Example")
    p.buttons = [1: .wheel(.standard)]
    old.appProfiles = [p]
    // Encode it as the old build did (the config's own decode would already migrate it).
    let oldFile = try! JSONEncoder().encode(GlideSettingsFile(config: old, exportedFrom: "Test"))
    check(String(data: oldFile, encoding: .utf8)!.contains("\"wheel\""), "the old file really has Wheels in it")
    let loaded = try! JSONDecoder().decode(GlideSettingsFile.self, from: oldFile).config
    guard case .gesture(let g)? = loaded.buttons[3] else { check(false, "an old Wheel loads as Gestures"); fatalError() }
    check(g.show == .atOnce, "an old Wheel shows its ring right away, as it did")
    check(g.eight && g.ring == .custom && g.ringUp == .shortcut(.redo) && g.ringDown == .back && !g.reverse && g.tap == .media(.playPause),
          "its four or eight, ring job (own pair), tap are kept")
    check(g[.up]?.action == .shortcut(.missionControl) && g[.upRight]?.action == .openApp(bundleID: "com.apple.Safari")
          && g[.right]?.action == .shortcut(.nextSpace) && g[.downRight]?.action == .holdShortcut(.wisprFlow)
          && g[.down]?.action == .shortcut(.appExpose) && g[.left]?.action == .shortcut(.previousSpace) && g[.downLeft] == nil,
          "each slot is the same direction")
    check(GestureDirection.allCases.allSatisfy { g[$0].map { !$0.repeats && !$0.once && !$0.isMore } ?? true },
          "each slot runs once at the release, as it did (no step repeats)")
    check(g.distance == nil, "it follows the gesture distance, as the Wheel did")
    check(loaded.buttons[2] == .gesture(ButtonGesture(wheel: WheelMenu.keeping(.middleClick))), "a second Wheel button too")
    check(loaded.chords.first?.action == .gesture(ButtonGesture(wheel: .standard)), "a Wheel combo too")
    check(loaded.appProfiles.first?.buttons?[1] == .gesture(ButtonGesture(wheel: .standard)), "and an app setup's Wheel")
    check(!loaded.anyAction(\.isWheel), "nothing is left a Wheel")
    // It behaves as the Wheel did: roll right and let go runs the right slot; a still press taps.
    let r = Rig([3: loaded.buttons[3]!])
    r.press(3); r.advance(0.3); r.roll(dx: 5, dy: 0, steps: 12); r.release(3)
    check(r.picks.map(\.1) == [2] && r.taps.isEmpty && r.fired.isEmpty, "a loaded Wheel: roll right and let go runs Right, once")
    let t = Rig([3: loaded.buttons[3]!])
    t.press(3); t.advance(0.1); t.release(3)
    check(t.taps.map(\.0) == [.media(.playPause)] && t.picks.isEmpty, "a loaded Wheel: a still press is its tap")

    // A gesture as every build before the merge wrote it: loads unchanged, behaves as before.
    let oldGesture = #"{"buttons":{"3":{"gesture":{"_0":{"up":{"action":{"media":{"_0":0}},"repeats":true},"left":{"action":{"shortcut":{"_0":{"keyCode":123,"modifiers":262144,"keyName":"←"}}},"repeats":false,"once":true},"tap":{"system":{}},"distance":"long"}}}}}"#
    let og = try? JSONDecoder().decode(GlideConfig.self, from: Data(oldGesture.utf8))
    guard case .gesture(let gg)? = og?.buttons[3] else { check(false, "an old gesture still loads"); fatalError() }
    check(gg.show == .never && gg.ring == .scroll && !gg.eight && !gg.reverse && gg.ringUp == nil, "an old gesture: never shows a ring, the ring scrolls, four ways")
    check(gg.up == GestureStep(.media(.volumeUp), repeats: true) && gg.left?.once == true && gg.distance == .long && gg.down == nil,
          "its directions, modes and distance are kept")
    let re = String(data: try! JSONEncoder().encode(ButtonAction.gesture(gg)), encoding: .utf8)!
    check(!re.contains("show") && !re.contains("ring") && !re.contains("eight") && !re.contains("reverse") && !re.contains("more"),
          "written back, an old-style gesture has no new fields (older builds read exactly what they wrote)")
    let blind = Rig([3: .gesture(gg)])
    blind.press(3); blind.roll(dx: -4, dy: 0, steps: 24); blind.release(3)
    check(blind.fired.count == 1 && blind.fired[0].1 == .left && blind.picks.isEmpty && !blind.machine.isHeld, "an old gesture fires at once, blind, as before")
    check(!blind.machine.panelHeld, "and Esc isn't taken for it (nothing to dismiss)")

    // Clamping: a Wheel inside a gesture is dropped; hostile slots are cleaned; More is one level.
    var nested = WheelMenu()
    nested[0] = .wheel(.standard)
    nested[2] = .gesture(.standard)
    nested[4] = .modifiedClick(button: 99, modifiers: 0)
    nested.slots += [.back, .back]   // too many places
    if case .gesture(let cg)? = ButtonAction.wheel(nested).clamped() {
        check(cg.up == nil && cg.right == nil && cg.down == nil && cg.show == .atOnce, "a hostile Wheel clamps to Gestures without its impossible slots")
    } else { check(false, "a hostile Wheel still clamps to Gestures") }
    var gw = ButtonGesture.standard
    gw.up = GestureStep(.wheel(.standard))
    check(ButtonAction.gesture(gw).clamped().map { if case .gesture(let x) = $0 { x.up == nil } else { false } } == true, "a Wheel inside a gesture is dropped")
    var deep = ButtonGesture.standard
    deep.up = .moreRing([GestureStep(.back), nil, GestureStep(.gesture(.standard)), nil, GestureStep(.forward)])
    deep.up?.more?[6] = .moreRing([GestureStep(.back)])   // a More inside a More: only a hand-made file says that
    if case .gesture(let dc)? = ButtonAction.gesture(deep).clamped(), let sub = dc.up?.more {
        check(sub.count == 8 && sub[0] == GestureStep(.back) && sub[2] == nil && sub[6] == nil, "More: gestures and Mores inside are dropped")
        check(sub[4] == nil, "More: its way back (opposite) is always empty")
    } else { check(false, "a More still clamps to a More") }
    // Import: a shared old Wheel is sanitized as Gestures (its apps and keys are listed).
    check(ButtonAction.wheel(w).needsCaution, "an old Wheel that opens an app or presses keys is listed in an import")
    if case .gesture(let sg)? = ButtonAction.wheel(w).sanitized() { check(sg.show == .atOnce && sg.eight, "a shared old Wheel imports as Gestures shown right away") }
    else { check(false, "a shared old Wheel imports as Gestures") }
    check(ButtonAction.wheel(w).sanitized(nested: true) == nil, "sanitized: dropped when nested")
    var moreShare = ButtonGesture.standard
    moreShare.right = .moreRing([GestureStep(.openApp(bundleID: "com.example.x"))])
    check(ButtonAction.gesture(moreShare).needsCaution, "an app opened from inside a More is listed in an import")
}

section("Gestures settings: new fields, older builds, sync")
do {
    var g = ButtonGesture.keeping(.back)
    check(g.show == .afterPause && g.ring == .volume && g.tap == .back, "a new Gestures button: ring after a pause, volume on the ring, the old action as the tap")
    g.eight = true
    g[.upRight] = GestureStep(.shortcut(.newTab))
    g[.down] = .moreRing([nil, nil, GestureStep(.media(.mute)), nil, GestureStep(.shortcut(.screenshot), repeats: false, once: true)])
    g.reverse = true
    g.ring = .custom
    g.ringUp = .forward
    g.ringDown = .back
    var c = GlideConfig()
    c.buttons[3] = .gesture(g)
    c.chords = [Chord(buttons: [1, 3], action: .gesture(g))]
    check(c.requiredFileVersion == 2, "Gestures make the file version 2, as gestures always did")
    let data = try! JSONEncoder().encode(GlideSettingsFile(config: c, exportedFrom: "Test"))
    let back = try! JSONDecoder().decode(GlideSettingsFile.self, from: data)
    check(back.config == c, "a file with every new Gestures field round-trips without loss")
    // What a Glideball from before the merge reads: the four straight ways (More doing nothing), tap, distance.
    struct OldStep: Decodable { var action: ButtonAction; var repeats: Bool?; var once: Bool? }
    struct OldGesture: Decodable { var up, down, left, right: OldStep?; var tap: ButtonAction? }
    struct OldWrap: Decodable { var gesture: Inner?; struct Inner: Decodable { var _0: OldGesture } }
    let one = try! JSONEncoder().encode(ButtonAction.gesture(g))
    let seen = try? JSONDecoder().decode(OldWrap.self, from: one).gesture?._0
    check(seen != nil, "an older build still reads it as a gesture")
    check(seen?.down?.action == .disabled && seen?.up?.action == .shortcut(.missionControl) && seen?.tap == .back,
          "an older build: More is a direction that does nothing, the rest as they are")
    check(g.asOlderBuildSees.down == GestureStep(.disabled) && g.asOlderBuildSees.upRight == nil && g.asOlderBuildSees.show == .never,
          "asOlderBuildSees matches what it would write back")
    // ...and sync puts the rest back after it.
    var older = c
    older.buttons[3] = .gesture(g.asOlderBuildSees)
    older.chords[0].action = .gesture(g.asOlderBuildSees)
    check(GlideSettingsFile.predatesGesturesMerge("2.10-beta.27") && !GlideSettingsFile.predatesGesturesMerge(GlideSettingsFile.gesturesMergeSince)
          && !GlideSettingsFile.predatesGesturesMerge("2.10") && !GlideSettingsFile.predatesGesturesMerge(nil), "which betas predate the merge")
    let merged = older.keepingGesturesMerge(from: c)
    check(merged.kept && merged.config == c, "sync puts back what an older beta dropped (button and combo)")
    let same = c.keepingGesturesMerge(from: c)
    check(!same.kept && same.config == c, "and changes nothing when nothing was dropped")
    var changed = older
    var edited = g.asOlderBuildSees
    edited.tap = .forward   // the older Mac changed it: that wins
    changed.buttons[3] = .gesture(edited)
    check(changed.keepingGesturesMerge(from: c).config.buttons[3] == .gesture(edited), "a gesture the older one changed wins")
    // A newer Glideball's fields and values: unknown ones fall back, never the whole button.
    let newer = #"{"buttons":{"3":{"gesture":{"_0":{"up":{"action":{"back":{}},"repeats":false},"upRight":{"action":{"teleport":{}}},"left":{"action":{"disabled":{}},"more":[{"action":{"forward":{}},"repeats":false},{"action":{"rocket":{}}},null]},"show":"hologram","ring":"spaceship","eight":true,"reverse":7,"hue":3}}}}}"#
    let n = try? JSONDecoder().decode(GlideConfig.self, from: Data(newer.utf8))
    if case .gesture(let ng)? = n?.buttons[3] {
        check(ng.up?.action == .back && ng.upRight == nil && ng.eight, "a newer Glideball's Gestures: unknown actions leave just that way empty")
        check(ng.show == .never && ng.ring == .scroll && !ng.reverse, "unknown Show and ring job fall back to how gestures were")
        check(ng.left?.more?[0]?.action == .forward && ng.left?.more?[1] == nil, "More: an unknown action empties just its place")
    } else {
        check(false, "a newer Glideball's Gestures still load")
    }
}

section("Gestures: Show the ring, More, Reverse, eight blind")
do {
    /// The engine looks every 50 ms while an After a pause hold waits (`Engine.beginHold`).
    func wait(_ r: Rig, _ seconds: Double) {
        var t = 0.0
        while t < seconds - 1e-9 { r.advance(0.05); t += 0.05; _ = r.machine.wheelOverlay(now: r.now) }
    }
    var pause = ButtonGesture.standard
    pause.show = .afterPause
    pause.ring = .volume
    // A quick flick and release never brings the ring up, and fires at once.
    let f = Rig([3: .gesture(pause)])
    f.press(3)
    for _ in 0..<6 { f.advance(0.005); f.ball(0, -30); _ = f.machine.wheelOverlay(now: f.now) }
    let shownDuringFlick = f.machine.wheelHeld
    f.release(3)
    check(!shownDuringFlick && f.fired.map(\.1) == [.up] && f.picks.isEmpty, "After a pause: a quick flick fires at once and never shows the ring")
    // Held still: the ring comes up; roll right and let go runs Right.
    let p = Rig([3: .gesture(pause)])
    p.press(3); wait(p, 0.2)
    let early = p.machine.wheelHeld
    wait(p, 0.1)
    check(!early && p.machine.wheelHeld && p.machine.wheelOverlay(now: p.now) != nil, "After a pause: the ring shows once the ball has been still for a moment")
    p.roll(dx: 5, dy: 0, steps: 12); p.release(3)
    check(p.picks.map(\.1) == [2] && p.fired.isEmpty, "After a pause: then rolling right and letting go runs Right, once")
    // A slow roll that never stops long enough: blind all the way.
    let s = Rig([3: .gesture(pause)])
    s.press(3)
    for _ in 0..<40 { s.advance(0.05); s.ball(1.5, 0); _ = s.machine.wheelOverlay(now: s.now) }
    check(!s.machine.wheelHeld && s.fired.map(\.1) == [.right], "After a pause: a slow, steady roll fires blind (it never paused)")
    s.release(3)
    // Still and let go: the tap, whether or not the ring came up.
    let t1 = Rig([3: .gesture(pause)]); t1.press(3); wait(t1, 0.1); t1.release(3)
    let t2 = Rig([3: .gesture(pause)]); t2.press(3); wait(t2, 0.4); t2.release(3)
    check(t1.taps.count == 1 && t2.taps.count == 1 && t2.picks.isEmpty, "After a pause: a still press is the tap, ring or no ring")
    // Something fired: the ring never comes up in that hold.
    let n = Rig([3: .gesture(pause)]); n.press(3); n.roll(dx: 0, dy: -6, steps: 12); wait(n, 0.5)
    check(!n.machine.wheelHeld && n.fired.count == 1, "After a pause: once something fired, holding still doesn't bring the ring up")
    n.release(3)

    // More and Back (beta 32; Levi on beta 31: More "feels way too eager", "a little jumpy").
    // Lighting More only lights it: it opens after staying on it a moment (`confirmDwell`) or a
    // longer roll out (`pushFraction` of the reach). Its ring, and the first one after Back, settle,
    // then need a longer roll from the middle (`carefulScale`); one-shots run only at the release.
    /// Time passing with the button held, as the engine sees it: a look every 50 ms (`wheelTick`).
    func dwell(_ r: Rig, _ seconds: Double) {
        var t = 0.0
        while t < seconds - 1e-9 { r.advance(0.05); t += 0.05; r.tickRing(); _ = r.machine.wheelOverlay(now: r.now) }
    }
    var more = ButtonGesture.standard
    more.show = .atOnce
    more.up = .moreRing([nil, nil, GestureStep(.shortcut(.screenshot)), nil, nil, nil, GestureStep(.shortcut(.lockScreen))])
    // Lighting More doesn't open it.
    let lit = Rig([3: .gesture(more)])
    lit.press(3); dwell(lit, 0.3); lit.roll(dx: 0, dy: -5, steps: 12)
    let litModel = lit.machine.wheelOverlay(now: lit.now)
    check(lit.machine.hold?.wheel?.level == nil && lit.machine.hold?.wheel?.selected == 0 && litModel?.opening == 0,
          "More: rolling onto it lights it (filling up), it doesn't open yet")
    lit.release(3)
    check(lit.picks.isEmpty && lit.taps.isEmpty && lit.fired.isEmpty && lit.ringRepeats.isEmpty, "More lit, not opened, let go: nothing runs")
    // Crossing it on the way somewhere else doesn't open it either.
    let cross = Rig([3: .gesture(more)])
    cross.press(3); dwell(cross, 0.3); cross.roll(dx: 0, dy: -5, steps: 8); cross.roll(dx: 5, dy: 0, steps: 14)
    let crossLevel = cross.machine.hold?.wheel?.level
    cross.release(3)
    check(crossLevel == nil && cross.picks.map(\.1) == [2] && cross.picks.first?.0 == .shortcut(.nextSpace),
          "More crossed on the way to Right: More never opens, Right runs (level \(String(describing: crossLevel)))")
    // A moment on More opens it: centred, nothing lit, settling.
    let m = Rig([3: .gesture(more)])
    m.press(3); dwell(m, 0.3); m.roll(dx: 0, dy: -5, steps: 12); dwell(m, 0.4)
    check(m.machine.hold?.wheel?.level == 0 && m.machine.hold?.wheel?.selected == nil, "More: staying on it a moment opens its ring, nothing lit, centred")
    let mm = m.machine.wheelOverlay(now: m.now)
    check(mm?.sub == true && mm?.slots[4] == .back && mm?.level == 0 && mm?.behind?[0] == .more, "More: its ring shows, Back opposite, the first ring behind it")
    check(m.fired.isEmpty && m.picks.isEmpty && m.ringRepeats.isEmpty, "More: opening it runs nothing")
    // Highlight then let go runs exactly one.
    dwell(m, 0.2); m.roll(dx: 5, dy: 0, steps: 20); m.release(3)
    check(m.picks.count == 1 && m.picks[0].0 == .shortcut(.screenshot) && m.ringRepeats.isEmpty && m.fired.isEmpty,
          "More: highlight Right in its ring and let go runs it, exactly once (\(m.picks.count))")
    // Its ring needs a longer roll than the first one: a first-ring distance lights nothing in it.
    let short = Rig([3: .gesture(more)])
    short.press(3); dwell(short, 0.3); short.roll(dx: 0, dy: -5, steps: 12); dwell(short, 0.6)
    short.roll(dx: 5, dy: 0, steps: 9)   // 45 counts: past the first ring's 36, short of More's 54
    let shortLit = short.machine.hold?.wheel?.selected
    short.release(3)
    check(shortLit == nil && short.picks.isEmpty, "More's ring: a first-ring-sized roll lights nothing (lit \(String(describing: shortLit)))")
    // Open More, then let go in the middle: nothing.
    let mc = Rig([3: .gesture(more)])
    mc.press(3); dwell(mc, 0.3); mc.roll(dx: 0, dy: -5, steps: 12); dwell(mc, 0.4); mc.release(3)
    check(mc.picks.isEmpty && mc.taps.isEmpty && mc.fired.isEmpty, "More opened, let go in the middle of its ring: nothing runs")
    // Roll on through More without stopping: the long roll opens it, the rest of the roll is ignored.
    let through = Rig([3: .gesture(more)])
    through.press(3); dwell(through, 0.3); through.roll(dx: 0, dy: -6, steps: 60)
    let throughLevel = through.machine.hold?.wheel?.level, throughLit = through.machine.hold?.wheel?.selected
    through.release(3)
    check(throughLevel == 0 && throughLit == nil && through.picks.isEmpty && through.ringRepeats.isEmpty && through.fired.isEmpty,
          "More rolled straight through: it opens, and nothing in its ring lights or runs (level \(String(describing: throughLevel)), lit \(String(describing: throughLit)))")
    // Back: lit, then a moment on it, returns to the first ring (careful from then on).
    let mb = Rig([3: .gesture(more)])
    mb.press(3); dwell(mb, 0.3); mb.roll(dx: 0, dy: -5, steps: 12); dwell(mb, 0.6)
    mb.roll(dx: 0, dy: 5, steps: 14)
    let backLit = mb.machine.hold?.wheel?.selected, backStill = mb.machine.hold?.wheel?.level
    dwell(mb, 0.4)
    check(backLit == 4 && backStill == 0 && mb.machine.hold?.wheel?.level == nil && mb.machine.hold?.wheel?.careful == true,
          "Back: lighting it waits; a moment on it returns to the first ring (lit \(String(describing: backLit)))")
    dwell(mb, 0.2); mb.roll(dx: 5, dy: 0, steps: 20); mb.release(3)
    check(mb.picks.map(\.1) == [2] && mb.picks[0].0 == .shortcut(.nextSpace), "Back, then Right and let go runs the first ring's Right, once")
    let md = Rig([3: .gesture(more)])
    md.press(3); dwell(md, 0.3); md.roll(dx: 0, dy: -5, steps: 12); dwell(md, 0.6); md.machine.dismissWheel(); md.roll(dx: 5, dy: 0, steps: 20); md.release(3)
    check(md.picks.isEmpty && md.taps.isEmpty, "More: Esc in its ring: nothing runs")
    for reason in [GestureCancel.pause, .unplug, .sleep, .tapDisabled, .quit] {
        let x = Rig([3: .gesture(more)])
        x.press(3); dwell(x, 0.3); x.roll(dx: 0, dy: -5, steps: 12); dwell(x, 0.6); x.roll(dx: 5, dy: 0, steps: 20); x.cancel(reason); x.release(3)
        check(x.picks.isEmpty && !x.frozen && x.machine.wheelOverlay(now: x.now) == nil, "More: \(reason.rawValue) mid-hold: nothing runs, nothing shows, pointer free")
    }
    // Blind (Never): More still works without looking: a longer roll that way, then the other way.
    var blindMore = more
    blindMore.show = .never
    let bq = Rig([3: .gesture(blindMore)])
    bq.press(3); bq.roll(dx: 0, dy: -6, steps: 10)
    check(bq.machine.hold?.wheel?.level == nil && bq.machine.wheelOverlay(now: bq.now) == nil, "More, blind: just past the distance it's lit, unseen, not open")
    bq.release(3)
    check(bq.picks.isEmpty && bq.fired.isEmpty && bq.taps.isEmpty, "More, blind, lit and let go: nothing runs")
    let bm = Rig([3: .gesture(blindMore)])
    bm.press(3); bm.roll(dx: 0, dy: -6, steps: 30)
    check(bm.machine.hold?.wheel?.level == 0 && bm.machine.wheelOverlay(now: bm.now) != nil, "More, blind: rolling on up opens it, and its ring shows")
    bm.roll(dx: -6, dy: 0, steps: 30); bm.release(3)
    check(bm.picks.count == 1 && bm.picks[0].0 == .shortcut(.lockScreen) && bm.fired.isEmpty, "More, blind: up then left (one turning roll) runs More's Left")
    // Fast blind use of the other directions is as it was.
    let fast = Rig([3: .gesture(blindMore)])
    fast.press(3); fast.roll(dx: 6, dy: 0, steps: 10); fast.release(3)
    check(fast.fired.map(\.1) == [.right] && fast.machine.hold == nil, "More, blind: a flick another way fires at once, as before")

    // Rolling into More and on, then Back and on: never carries into the place that way.
    var side = ButtonGesture.standard
    side.show = .atOnce
    side.right = .moreRing([GestureStep(.media(.volumeUp), repeats: true), nil, GestureStep(.shortcut(.screenshot)), nil, nil, nil, nil])   // More on the right
    side[.left] = GestureStep(.shortcut(.lockScreen))
    side[.up] = GestureStep(.media(.volumeUp), repeats: true)
    let carry = Rig([3: .gesture(side)])
    carry.press(3); dwell(carry, 0.3)
    carry.roll(dx: 6, dy: 0, steps: 60)   // into More and on, without stopping, for half a second
    let litWhileCarrying = carry.machine.hold?.wheel?.selected
    carry.release(3)
    check(carry.picks.isEmpty && carry.fired.isEmpty && carry.ringRepeats.isEmpty && litWhileCarrying == nil,
          "More with the roll carrying on: nothing in its ring lights or runs (\(carry.picks.count) picks, lit \(String(describing: litWhileCarrying)))")
    let carryOn = Rig([3: .gesture(side)])
    carryOn.press(3); dwell(carryOn, 0.3); carryOn.roll(dx: 6, dy: 0, steps: 20)
    let settling = carryOn.machine.wheelOverlay(now: carryOn.now)?.settling == true
    dwell(carryOn, 0.3)
    let armedAfterRest = carryOn.machine.wheelOverlay(now: carryOn.now)?.settling == false
    carryOn.roll(dx: 6, dy: 0, steps: 20); carryOn.release(3)
    check(settling && armedAfterRest && carryOn.picks.map(\.0) == [.shortcut(.screenshot)],
          "More: after a rest, rolling on the same way runs its place that way (settling \(settling), armed \(armedAfterRest))")
    let back = Rig([3: .gesture(side)])
    back.press(3); dwell(back, 0.3); back.roll(dx: 6, dy: 0, steps: 20); dwell(back, 0.3)
    back.roll(dx: -6, dy: 0, steps: 60)   // back to Back and on, without stopping
    let backLevel = back.machine.hold?.wheel?.level, backLit2 = back.machine.hold?.wheel?.selected
    back.release(3)
    check(backLevel == nil && backLit2 == nil && back.picks.isEmpty && back.ringRepeats.isEmpty,
          "Back with the roll carrying on: the first ring, in its middle, and nothing in it runs (level \(String(describing: backLevel)), lit \(String(describing: backLit2)))")
    let quick = Rig([3: .gesture(side)])
    quick.press(3); dwell(quick, 0.3); quick.roll(dx: 6, dy: 0, steps: 20); quick.roll(dx: -6, dy: 0, steps: 20)
    quick.release(3)
    check(quick.picks.isEmpty && quick.ringRepeats.isEmpty, "More, then straight back inside the settle: nothing runs")
    // A repeating place in More's ring: lighting it only lights it; rolling on its way starts it,
    // and then it goes on continuously while held (no let-go needed).
    let rep = Rig([3: .gesture(side)])
    rep.press(3); dwell(rep, 0.3); rep.roll(dx: 6, dy: 0, steps: 20); dwell(rep, 0.3)
    rep.roll(dx: 0, dy: -5, steps: 12)   // 60 counts up: lit
    let repLit = rep.machine.hold?.wheel?.selected, repBefore = rep.ringRepeats.count
    rep.roll(dx: 0, dy: -5, steps: 40)   // on up: starts, then repeats every step
    let repWhileHeld = rep.ringRepeats.count
    rep.release(3)
    check(repLit == 0 && repBefore == 0 && repWhileHeld >= 2 && rep.ringRepeats.count == repWhileHeld && rep.picks.isEmpty,
          "More's ring: a repeating place lights first, then runs continuously as you roll on (\(repBefore) at the light, \(repWhileHeld) held)")
    let repDwell = Rig([3: .gesture(side)])
    repDwell.press(3); dwell(repDwell, 0.3); repDwell.roll(dx: 6, dy: 0, steps: 20); dwell(repDwell, 0.3)
    repDwell.roll(dx: 0, dy: -5, steps: 12); dwell(repDwell, 0.4)
    check(repDwell.ringRepeats.count == 1, "More's ring: staying on a repeating place a moment starts it (\(repDwell.ringRepeats.count))")
    repDwell.release(3)
    check(blindMore.mayShowRing && !ButtonGesture.standard.mayShowRing, "a Never gesture with a More can still show a ring; one without can't")

    // A place that repeats as you roll, on a showing ring: runs as it lights, then every step its way.
    var vol = ButtonGesture.media
    vol.show = .atOnce
    let v = Rig([3: .gesture(vol)])
    v.press(3); v.advance(0.3); v.roll(dx: 0, dy: -5, steps: 40); v.release(3)
    check(v.ringRepeats.count >= 2 && v.ringRepeats.allSatisfy { $0.0 == .media(.volumeUp) && $0.1 == 0 } && v.picks.isEmpty,
          "a repeating place on the ring runs as it lights and again as you keep rolling, and not again at the release (\(v.ringRepeats.count))")

    // The ring job and Reverse.
    var rev = ButtonGesture.standard
    rev.ring = .volume
    let rr = Rig([3: .gesture(rev)])
    rr.press(3); rr.advance(0.1); rr.ring(-1); rr.advance(0.1); rr.release(3)
    rev.reverse = true
    let rv = Rig([3: .gesture(rev)])
    rv.press(3); rv.advance(0.1); rv.ring(-1); rv.advance(0.1); rv.release(3)
    check(rr.ringSteps.map(\.0) == [.media(.volumeUp)] && rv.ringSteps.map(\.0) == [.media(.volumeDown)], "Reverse swaps which way of the ring does what")
    check(rr.taps.isEmpty && rv.taps.isEmpty, "a release after turning the ring is no tap")
    let scroll = Rig([3: .gesture(.standard)])
    scroll.press(3)
    check(!scroll.machine.ringTaken, "Scrolls as usual (an old gesture's): the ring isn't taken")
    scroll.release(3)
    check(ButtonGesture(wheel: .standard).ringActions.clockwise == .media(.volumeUp), "an old Wheel's ring job is the same way round")

    // Eight directions, blind.
    var eight = ButtonGesture.standard
    eight.eight = true
    eight[.upRight] = GestureStep(.shortcut(.newTab))
    let e = Rig([3: .gesture(eight)])
    e.press(3); e.roll(dx: 4, dy: -4, steps: 12); e.release(3)
    check(e.fired.map(\.1) == [.upRight], "eight, blind: rolling up and right fires up right")
    let e2 = Rig([3: .gesture(eight)])
    e2.press(3); e2.roll(dx: 0, dy: -5, steps: 12); e2.release(3)
    check(e2.fired.map(\.1) == [.up], "eight, blind: straight up still fires up")
    var sparse = ButtonGesture()
    sparse.eight = true
    sparse[.upRight] = GestureStep(.shortcut(.newTab))
    sparse[.downLeft] = GestureStep(.shortcut(.closeTab))
    let sp = Rig([3: .gesture(sparse)])
    sp.press(3); sp.roll(dx: 1, dy: -5, steps: 12); sp.release(3)
    check(sp.fired.map(\.1) == [.upRight], "eight, blind: empty ways are skipped, so the rest are wide targets")
    var eightVol = ButtonGesture()
    eightVol.eight = true
    eightVol[.upRight] = GestureStep(.media(.volumeUp), repeats: true)
    eightVol[.downLeft] = GestureStep(.media(.volumeDown), repeats: true)
    let ev = Rig([3: .gesture(eightVol)])
    ev.press(3); ev.roll(dx: 4, dy: -4, steps: 40); ev.roll(dx: -4, dy: 4, steps: 40); ev.release(3)
    let ups = ev.fired.filter { $0.1 == .upRight }.count, downs = ev.fired.filter { $0.1 == .downLeft }.count
    check(ups >= 3 && downs >= 2, "eight, blind: a diagonal that repeats keeps going, and rolling back runs its opposite (\(ups) up, \(downs) down)")
    // The Gestures switch covers every Gestures button now, ring or not.
    var ringOn = ButtonGesture.standard
    ringOn.show = .atOnce
    let off = GestureRoute.decide(action: .gesture(ringOn), buttons: [3], enabled: false, canReadBall: true, gestureHeld: false)
    check(off == .tapInstead(.system), "the Gestures switch off: a ring Gestures button does its tap")
}

// MARK: - The Switcher

section("the Switcher")
do {
    let sw = ButtonAction.switcher(.standard)
    // A quick still press (before the panel shows): the tap, no switch.
    let r = Rig([3: sw])
    r.press(3); r.advance(0.1); r.release(3)
    check(r.taps.count == 1 && r.taps[0].0 == .system && r.switches.isEmpty, "a quick still Switcher press is the tap")
    check(!r.frozen, "pointer free after")
    // Held still until the panel shows, then let go: the previous app (place 1), like ⌘-Tab.
    let h = Rig([3: sw])
    h.press(3); h.advance(0.1)
    check(h.switcherPanel == nil, "no panel before the delay")
    h.advance(0.15)
    check(h.switcherPanel?.selected == 1, "the panel shows with the previous app lit (\(String(describing: h.switcherPanel?.selected)))")
    h.release(3)
    check(h.switches.map(\.index) == [1] && h.taps.isEmpty, "hold and release flips to the previous app (\(h.switches.map(\.index)))")
    // Rolling right two steps: place 3; the release switches once.
    let ro = Rig([3: sw])
    ro.press(3); ro.roll(dx: 4, dy: 0, steps: 24)   // 96 counts: two steps at Normal
    check(ro.switches.isEmpty, "nothing switches while held")
    check(ro.machine.hold?.switcher?.index == 3, "two steps right from the previous app (\(String(describing: ro.machine.hold?.switcher?.index)))")
    ro.release(3)
    check(ro.switches.map(\.index) == [3], "the release switches to the lit app, once")
    // A flick and release before the delay: the panel came up on the roll, so it switches.
    let fl = Rig([3: sw])
    fl.press(3); fl.roll(dx: 12, dy: 0, steps: 5, dt: 0.004); fl.release(3)
    check(fl.switches.map(\.index) == [2] && fl.taps.isEmpty, "a flick right and release switches one past the previous app (\(fl.switches.map(\.index)))")
    // The ball stops at the ends (beta 33): left twice from the previous app stays on the first,
    // never wrapping round to the last.
    let wl = Rig([3: sw])
    wl.press(3); wl.roll(dx: -4, dy: 0, steps: 24); wl.release(3)
    check(wl.switches.map(\.index) == [0], "left twice from the previous app stops at the first (\(wl.switches.map(\.index)))")
    let wr = Rig([3: sw])
    wr.press(3); wr.roll(dx: 4, dy: 0, steps: 120); wr.release(3)
    check(wr.switches.map(\.index) == [5], "rolling far right stops on the last app (\(wr.switches.map(\.index)))")
    // The ring: one app per report, clockwise forward; it never runs anything while held.
    let rg = Rig([3: sw])
    rg.press(3); rg.advance(0.05)
    for _ in 0..<3 { rg.advance(0.01); rg.ring(-1) }
    rg.ring(1)
    check(rg.machine.hold?.switcher?.index == 3 && rg.ringSteps.isEmpty, "the ring steps the highlight: three forward, one back (\(String(describing: rg.machine.hold?.switcher?.index)))")
    rg.release(3)
    check(rg.switches.map(\.index) == [3] && rg.taps.isEmpty, "and the release switches there, no tap")
    // Esc and another button: dismissed, nothing switches.
    let e = Rig([3: sw])
    e.press(3); e.roll(dx: 4, dy: 0, steps: 24); e.machine.dismissWheel(); e.roll(dx: 4, dy: 0, steps: 12)
    check(e.switcherPanel == nil, "Esc takes the panel down")
    e.release(3)
    check(e.switches.isEmpty && e.taps.isEmpty, "Esc: nothing switches, no tap")
    let d = Rig([3: sw])
    d.press(3); d.advance(0.3); d.press(0); d.release(0); d.release(3)
    check(d.switches.isEmpty && d.taps.isEmpty && d.primaryPasses == 1, "the primary button dismisses it, and is still a plain click")
    // Another button before the panel shows: dismissed, as before (nothing to hide yet).
    let early = Rig([3: sw])
    early.press(3); early.advance(0.05); early.press(1); early.release(1); early.release(3)
    check(early.switches.isEmpty && early.taps.isEmpty && early.hides.isEmpty, "another button before the panel shows dismisses it")
    // Every way out without its release: nothing switches.
    for reason in [GestureCancel.pause, .quit, .unplug, .tapDisabled, .sleep, .lostRelease, .timeout, .configChanged] {
        let x = Rig([3: sw])
        x.press(3); x.advance(0.3); x.roll(dx: 4, dy: 0, steps: 12); x.cancel(reason); x.release(3)
        check(x.switches.isEmpty && x.taps.isEmpty && !x.frozen, "\(reason.rawValue) ends a Switcher hold: nothing switches, pointer free")
    }
    let t = Rig([3: sw])
    t.press(3); t.advance(0.3); t.advance(31); t.tick(); t.release(3)
    check(t.switches.isEmpty && !t.frozen, "past the time limit: ended, nothing switches")
    // Never on the primary button, alone or in a combo.
    let p = Rig([0: sw])
    p.press(0); p.advance(0.3); p.release(0)
    check(p.switches.isEmpty && p.freezeOns == 0 && p.primaryPasses == 1, "the primary button is never a Switcher")
    let pc = Rig([:], chords: [Chord(buttons: [0, 2], action: sw)])
    pc.combo([0, 2]); pc.advance(0.3); pc.release(0); pc.release(2)
    check(pc.switches.isEmpty && pc.freezeOns == 0, "a combo with the primary button is never a Switcher")
    let cb = Rig([:], chords: [Chord(buttons: [1, 3], action: sw)])
    cb.combo([1, 3]); cb.advance(0.2); cb.release(3); cb.release(1)
    check(cb.switches.count == 1 && !cb.frozen, "a Switcher combo: the first button up switches, once")
    // Never two at once: a Wheel or gesture press during a Switcher hold is ignored.
    let mix = Rig([2: .wheel(.standard), 1: .gesture(.standard), 3: sw])
    mix.press(3); mix.press(2); mix.press(1); mix.roll(dx: 5, dy: 0, steps: 12); mix.release(2); mix.release(1); mix.release(3)
    check(mix.picks.isEmpty && mix.fired.isEmpty && mix.freezeOns == 1 && mix.switches.isEmpty, "nothing else starts during a Switcher hold (and the presses dismiss it)")
    // The list comes late: what was rolled meanwhile still counts (up to three steps).
    let late = Rig([3: sw])
    late.switcherReadyAfter = 0.5
    late.press(3); late.roll(dx: 4, dy: 0, steps: 12)
    check(late.switcherPanel == nil, "no panel until the list arrives")
    late.advance(0.5)
    check(late.machine.hold?.switcher?.index == 2, "the roll before the list arrived still moved the highlight (\(String(describing: late.machine.hold?.switcher?.index)))")
    late.release(3)
    check(late.switches.map(\.index) == [2], "and the release switches there")
    // The list never comes: a quick still press is still the tap; a long hold switches nothing.
    let never = Rig([3: sw])
    never.switcherGrid = nil
    never.press(3); never.advance(0.1); never.release(3)
    check(never.taps.count == 1 && never.switches.isEmpty, "no list: the tap still works")
    never.press(3); never.roll(dx: 4, dy: 0, steps: 24); never.advance(1); never.release(3)
    check(never.switches.isEmpty && never.taps.count == 1, "no list: a roll and release switches nothing")
    // Only the front app: the highlight stays on it.
    let one = Rig([3: sw])
    one.switcherGrid = SwitcherGrid.fitting(count: 1, maxColumns: 8, maxRows: 3)
    one.press(3); one.advance(0.3); one.roll(dx: 4, dy: 4, steps: 30); one.ring(-1); one.release(3)
    check(one.switches.map(\.index) == [0], "a single app: it stays lit (\(one.switches.map(\.index)))")
    // The tap: a held shortcut is a quick press.
    let tp = Rig([3: .switcher(AppSwitcher(tap: .holdShortcut(.copy)))])
    tp.press(3); tp.release(3)
    check(tp.taps.map(\.0) == [.shortcut(.copy)], "a held-shortcut tap is a quick press")
    // Hostile numbers.
    let n = Rig([3: sw])
    n.press(3); n.ball(.infinity, 3); n.ball(.nan, .nan); n.ball(-1e308, 1e308); n.advance(0.3); n.release(3)
    check(!n.frozen && n.switches.count <= 1, "infinite and NaN rolls: no crash, at most one switch")
}

section("the Switcher's grid")
do {
    // Sizes: one row while they fit, then rows as even as they can be.
    check(SwitcherGrid.fitting(count: 5, maxColumns: 8, maxRows: 3) == SwitcherGrid(count: 5, columns: 5, visibleRows: 1), "five apps: one row")
    check(SwitcherGrid.fitting(count: 10, maxColumns: 8, maxRows: 3).columns == 5, "ten apps with room for eight: two rows of five")
    let g24 = SwitcherGrid.fitting(count: 24, maxColumns: 8, maxRows: 2)
    check(g24.columns == 8 && g24.rows == 3 && g24.visibleRows == 2, "24 apps, room for two rows: three rows of eight, two on screen")
    check(SwitcherGrid.fitting(count: 0, maxColumns: 8, maxRows: 3).count == 0, "no apps: an empty grid")
    // Moves in a 3 × 4 grid with 10 apps (the last row has 2).
    let g = SwitcherGrid(count: 10, columns: 4, visibleRows: 3)
    check(g.moved(3, .right) == 4 && g.moved(9, .right) == 0 && g.moved(0, .left) == 9, "left and right run in order and wrap")
    check(g.moved(1, .down) == 5 && g.moved(5, .down) == 9 && g.moved(9, .down) == 1, "down keeps the column and wraps to the top")
    check(g.moved(7, .down) == 9, "down into a short last row with nothing under: its last app")
    check(g.moved(1, .up) == 9 && g.moved(3, .up) == 7 && g.moved(5, .up) == 1, "up from the top wraps to the bottom, or the row above a short last row")
    for i in 0..<10 { for m in [SwitcherGrid.Move.left, .right, .up, .down] { check((0..<10).contains(g.moved(i, m)), "every move stays in the grid") } }
    // Scrolling rows: the lit row always on screen, moving as little as possible.
    let s = SwitcherGrid(count: 24, columns: 8, visibleRows: 2)
    check(s.firstRow(showing: 17, from: 0) == 1 && s.firstRow(showing: 9, from: 1) == 1 && s.firstRow(showing: 2, from: 1) == 0, "rows scroll to keep the lit app on screen")
    // A random walk through many shapes: never off the grid, every app reachable.
    var seed: UInt64 = 0x5717C4
    func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
    for _ in 0..<500 {
        let grid = SwitcherGrid.fitting(count: 1 + Int(rnd() * 30), maxColumns: 1 + Int(rnd() * 9), maxRows: 1 + Int(rnd() * 4))
        var i = Int(rnd() * Double(grid.count)), first = 0
        var seen: Set<Int> = [i]
        for _ in 0..<200 {
            i = grid.moved(i, [.left, .right, .up, .down][Int(rnd() * 4)])
            first = grid.firstRow(showing: i, from: first)
            seen.insert(i)
            check(i >= 0 && i < grid.count, "random moves stay in the grid")
            check(i / grid.columns >= first && i / grid.columns < first + grid.visibleRows, "random moves keep the lit row on screen")
        }
        var walk = 0
        var all: Set<Int> = []
        for _ in 0..<grid.count { all.insert(walk); walk = grid.moved(walk, .right) }
        check(all.count == grid.count, "right reaches every app")
    }
    // Random Switcher holds: rules after every event (invariants), and at most one switch per hold.
    for _ in 0..<3000 {
        let z = Rig([3: .switcher(.standard), 2: .wheel(.standard)],
                    chords: rnd() < 0.3 ? [Chord(buttons: [1, 3], action: .switcher(.standard))] : [])
        z.switcherGrid = rnd() < 0.1 ? nil : SwitcherGrid.fitting(count: Int(rnd() * 26), maxColumns: 2 + Int(rnd() * 7), maxRows: 1 + Int(rnd() * 3))
        z.switcherReadyAfter = rnd() < 0.5 ? 0 : rnd() * 0.6
        for _ in 0..<60 {
            let before = z.switches.count
            switch Int(rnd() * 9) {
            case 0: z.press(Int(rnd() * 4))
            case 1: z.release(Int(rnd() * 4))
            case 2, 3: z.roll(dx: rnd() * 20 - 10, dy: rnd() * 20 - 10, steps: 1 + Int(rnd() * 6))
            case 4: z.ring(rnd() < 0.5 ? 1 : -1)
            case 5: if rnd() < 0.9 { z.advance(rnd() * 0.3) } else { z.now += 31 }; z.tick(); z.advance(0)
            case 6: z.machine.dismissWheel()
            case 7: if rnd() < 0.2 { z.cancel([.pause, .sleep, .unplug, .tapDisabled][Int(rnd() * 4)]) }
            default: _ = z.switcherPanel; z.advance(0.01)
            }
            check(z.switches.count - before <= 1, "never two switches from one event")
        }
        for b in 0..<4 { z.release(b) }
        check(!z.frozen, "random Switcher holds: pointer free at the end")
    }
}

section("the Switcher holds still (beta 33: \"sometimes it jumps around\")")
do {
    let sw = ButtonAction.switcher(.standard)
    // The ball is a puck: it stops at the edges; the ring is a dial and goes round.
    let g = SwitcherGrid(count: 10, columns: 4, visibleRows: 3)
    check(g.stepped(3, .right) == 3 && g.stepped(4, .left) == 4 && g.stepped(2, .right) == 3, "left and right stay in their row")
    check(g.stepped(1, .up) == 1 && g.stepped(9, .down) == 9 && g.stepped(7, .down) == 9 && g.stepped(5, .down) == 9, "up and down stop at the top and bottom (a short last row: its last app)")
    for i in 0..<10 { for m in [SwitcherGrid.Move.left, .right, .up, .down] { check((0..<10).contains(g.stepped(i, m)), "every ball step stays in the grid") } }
    // Most of a step, a rest, then the jiggle of letting go: the light stays put.
    let j = Rig([3: sw])
    j.press(3); j.advance(0.3); j.roll(dx: 4, dy: 0, steps: 11)   // 44 of 48 counts
    j.advance(0.3); j.roll(dx: 3, dy: 0, steps: 2)                // the hand settling
    check(j.machine.hold?.switcher?.index == 1, "a rest forgets most of a step: the jiggle after it moves nothing (\(String(describing: j.machine.hold?.switcher?.index)))")
    j.release(3)
    check(j.switches.map(\.index) == [1], "and the release switches to the app that was lit")
    // Without the rest, the same roll carries on into a step (rolling is rolling).
    let c = Rig([3: sw])
    c.press(3); c.advance(0.3); c.roll(dx: 4, dy: 0, steps: 11); c.roll(dx: 3, dy: 0, steps: 2)
    check(c.machine.hold?.switcher?.index == 2, "a roll that keeps going still steps")
    c.release(3)
    // A hard flick moves the light a step or two, never across the panel.
    let f = Rig([3: sw])
    f.switcherGrid = SwitcherGrid.fitting(count: 8, maxColumns: 8, maxRows: 3)
    f.press(3); f.advance(0.3); f.roll(dx: 120, dy: 0, steps: 6, dt: 0.008)   // 720 counts in 48 ms
    let flung = (f.machine.hold?.switcher?.index ?? 0) - 1
    check(flung >= 1 && flung <= 2, "a flick moves one or two apps (\(flung))")
    f.release(3)
    // Never two steps closer than 50 ms, however fast the ball goes.
    let r = Rig([3: sw])
    r.switcherGrid = SwitcherGrid.fitting(count: 24, maxColumns: 24, maxRows: 1)
    r.press(3); r.advance(0.3)
    var last = r.machine.hold?.switcher?.index ?? 0, lastAt = -1.0
    for _ in 0..<60 {
        r.advance(0.008); r.ball(40, 0)
        let now = r.machine.hold?.switcher?.index ?? 0
        if now != last { check(lastAt < 0 || r.now - lastAt >= SwitcherHold.minStepInterval - 1e-9, "steps never closer than 50 ms"); last = now; lastAt = r.now }
    }
    r.release(3)
    // On a grid of rows, a roll along a row that drifts a little never changes rows.
    let d = Rig([3: sw])
    d.switcherGrid = SwitcherGrid(count: 12, columns: 4, visibleRows: 3)
    d.press(3); d.advance(0.3); d.roll(dx: 4, dy: 2.5, steps: 36)   // mostly right, some down
    check((d.machine.hold?.switcher?.index ?? 0) / 4 == 0, "a drifting roll along the row stays in it (\(String(describing: d.machine.hold?.switcher?.index)))")
    d.release(3)
    // A diagonal is no clear way: nothing moves until one way leads.
    let dg = Rig([3: sw])
    dg.switcherGrid = SwitcherGrid(count: 12, columns: 4, visibleRows: 3)
    dg.press(3); dg.advance(0.3); dg.roll(dx: 4, dy: 4, steps: 20)
    check(dg.machine.hold?.switcher?.index == 1, "a diagonal moves nothing")
    dg.release(3)
    // A single row ignores up and down altogether.
    let one = Rig([3: sw])
    one.press(3); one.advance(0.3); one.roll(dx: 0, dy: 6, steps: 40); one.roll(dx: 4, dy: 3, steps: 12)
    check(one.machine.hold?.switcher?.index == 2, "one row: up and down never block or move (\(String(describing: one.machine.hold?.switcher?.index)))")
    one.release(3)
    // The app in front hidden from this Switcher: the first app in the list is lit, not the second.
    let nf = Rig([3: sw])
    nf.switcherGrid = SwitcherGrid.fitting(count: 5, maxColumns: 8, maxRows: 3, frontFirst: false)
    nf.press(3); nf.advance(0.3); nf.release(3)
    check(nf.switches.map(\.index) == [0], "without the app in front, a hold and release goes to the first app")
}

section("hiding apps from the Switcher")
do {
    let sw = ButtonAction.switcher(.standard)
    // Top left with the previous app (place 1) lit: hidden, the rest close up, the light stays.
    let h = Rig([3: sw])
    h.press(3); h.advance(0.3); h.press(2)
    check(h.hides == [.hid(1)], "another button hides the lit app (\(h.hides))")
    check(h.overrides[2] == "swallow", "its press and release are the Switcher's (nothing reaches apps)")
    check(h.switcherPanel?.grid.count == 5 && h.switcherPanel?.hidden == [1] && h.switcherPanel?.undoable == true, "the row closes up and Undo is offered")
    check(h.switcherPanel?.selected == 1, "the light stays where it was (on the next app)")
    h.release(2)
    check(h.machine.isHeld && h.switches.isEmpty, "letting go of it changes nothing")
    h.release(3)
    check(h.switches.map(\.index) == [2], "the release switches to the app that took its place (place 2 in the list) (\(h.switches.map(\.index)))")
    check(!h.frozen && h.taps.isEmpty, "pointer free, no tap")
    // Pressed again before the light moves: it comes back, lit.
    let u = Rig([3: sw])
    u.press(3); u.advance(0.3); u.press(2); u.release(2); u.press(1); u.release(1)
    check(u.hides == [.hid(1), .restored(1)], "pressing again brings it back (any free button) (\(u.hides))")
    check(u.switcherPanel?.grid.count == 6 && u.switcherPanel?.hidden == [] && u.switcherPanel?.undoable == false, "the row opens again")
    u.release(3)
    check(u.switches.map(\.index) == [1], "and the release switches to it")
    // After the light moves, a press hides the newly lit app instead.
    let m = Rig([3: sw])
    m.press(3); m.advance(0.3); m.press(2); m.release(2); m.roll(dx: 4, dy: 0, steps: 12); m.press(2); m.release(2)
    check(m.hides == [.hid(1), .hid(3)], "after a move, the next press hides the lit app (\(m.hides))")
    check(m.switcherPanel?.grid.count == 4, "two hidden")
    m.release(3)
    check(m.switches.map(\.index) == [4], "places stay the list's own: the release names the right app (\(m.switches.map(\.index)))")
    // Hiding down to one app: the last one can't go.
    let l = Rig([3: sw])
    l.switcherGrid = SwitcherGrid.fitting(count: 1, maxColumns: 8, maxRows: 3)
    l.press(3); l.advance(0.3); l.press(2); l.release(2)
    check(l.hides == [.nothing], "the last app showing can't be hidden (\(l.hides))")
    l.release(3)
    check(l.switches.map(\.index) == [0], "it switches to it")
    let two = Rig([3: sw])
    two.switcherGrid = SwitcherGrid.fitting(count: 2, maxColumns: 8, maxRows: 3)
    two.press(3); two.advance(0.3); two.press(2); two.release(2); two.roll(dx: 4, dy: 0, steps: 14); two.press(1); two.release(1)
    check(two.hides == [.hid(1), .restored(1)], "one app left, it can't move, so the next press is still Undo (\(two.hides))")
    two.release(3)
    // The primary button never hides: it dismisses, and its click goes through.
    let p = Rig([3: sw])
    p.press(3); p.advance(0.3); p.press(0); p.release(0); p.release(3)
    check(p.hides.isEmpty && p.switches.isEmpty && p.primaryPasses == 1 && p.primaryReleases == 1, "the primary button never hides an app, and stays a plain click")
    // On a combo: its own buttons never hide (a repeat press of one is the hold's), a free one does.
    let cb = Rig([:], chords: [Chord(buttons: [1, 3], action: sw)])
    cb.combo([1, 3]); cb.advance(0.3); cb.press(2); cb.release(2)
    check(cb.hides == [.hid(1)], "a combo Switcher: the free button hides")
    cb.release(3); cb.release(1)
    check(cb.switches.map(\.index) == [2] && !cb.frozen, "and the first of its buttons up switches")
    // Esc after a hide: nothing switches; the hide was already saved (it's the engine's job to say so).
    let e = Rig([3: sw])
    e.press(3); e.advance(0.3); e.press(2); e.release(2); e.machine.dismissWheel(); e.press(1); e.release(1); e.release(3)
    check(e.switches.isEmpty && e.hides == [.hid(1)], "dismissed: no switch, and no more hides (\(e.hides))")
    // Every way out mid-hide: pointer free, nothing switches.
    for reason in [GestureCancel.pause, .quit, .unplug, .tapDisabled, .sleep, .timeout] {
        let x = Rig([3: sw])
        x.press(3); x.advance(0.3); x.press(2); x.cancel(reason); x.release(2); x.release(3)
        check(x.switches.isEmpty && !x.frozen, "\(reason.rawValue) with the hide button down: nothing switches, pointer free")
    }
    // The grid after hides: one row closes up, several keep their width.
    let row = SwitcherGrid.fitting(count: 6, maxColumns: 8, maxRows: 3)
    check(row.keeping(5) == SwitcherGrid(count: 5, columns: 5, visibleRows: 1), "a single row loses a column")
    let rows = SwitcherGrid(count: 10, columns: 5, visibleRows: 2)
    check(rows.keeping(9).columns == 5 && rows.keeping(9).count == 9, "several rows keep their width")
    // Random hides and rolls: the light always on an app showing, the release on a place in the list never hidden.
    var seed: UInt64 = 0x41DE
    func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
    for _ in 0..<2000 {
        let z = Rig([3: sw])
        z.switcherGrid = SwitcherGrid.fitting(count: 1 + Int(rnd() * 20), maxColumns: 2 + Int(rnd() * 7), maxRows: 1 + Int(rnd() * 3))
        z.press(3); z.advance(0.25)
        for _ in 0..<40 {
            switch Int(rnd() * 5) {
            case 0: let b = [1, 2][Int(rnd() * 2)]; z.press(b); z.release(b)
            case 1, 2: z.roll(dx: rnd() * 16 - 8, dy: rnd() * 16 - 8, steps: 1 + Int(rnd() * 8))
            case 3: z.ring(rnd() < 0.5 ? 1 : -1)
            default: z.advance(rnd() * 0.2)
            }
            if let s = z.machine.hold?.switcher, let g = s.grid {
                check(g.count == (z.switcherGrid?.count ?? 0) - s.hidden.count && g.count >= 1, "what's showing is the list less what's hidden")
                check(Set(s.hidden).count == s.hidden.count, "nothing hidden twice")
            }
        }
        let hiddenNow = z.machine.hold?.switcher?.hidden ?? []
        z.release(3)
        if let sw = z.switches.last { check(!hiddenNow.contains(sw.index), "never switches to an app hidden this hold") }
        check(!z.frozen, "random hides: pointer free at the end")
    }
}

section("a Switcher's hidden apps in settings")
do {
    var c = GlideConfig()
    c.buttons[3] = .switcher(AppSwitcher(hidden: ["com.apple.Music", "com.example.Chat"]))
    let data = try! JSONEncoder().encode(GlideSettingsFile(config: c, exportedFrom: "Test"))
    let back = try! JSONDecoder().decode(GlideSettingsFile.self, from: data)
    check(back.config == c, "hidden apps round-trip in a settings file")
    var plain = GlideConfig()
    plain.buttons[3] = .switcher(.standard)
    let plainData = try! JSONEncoder().encode(plain)
    check(!String(decoding: plainData, as: UTF8.self).contains("hidden"), "a Switcher hiding nothing writes no hidden field (older files unchanged)")
    // An older build's file (no field) loads with none hidden; a file with junk is cleaned.
    let old = try? JSONDecoder().decode(GlideConfig.self, from: Data(#"{"buttons":{"3":{"switcher":{"_0":{"tap":{"system":{}}}}}}}"#.utf8))
    check(old?.buttons[3] == .switcher(.standard), "an older Switcher loads with nothing hidden")
    let junk = try? JSONDecoder().decode(GlideConfig.self, from: Data(#"{"buttons":{"3":{"switcher":{"_0":{"hidden":["com.ok.App","../etc","com.ok.App","",5,"a b"]}}}}}"#.utf8))
    check(junk?.buttons[3] == nil || junk?.buttons[3] == .switcher(AppSwitcher(hidden: ["com.ok.App"])) || junk?.buttons[3] == .switcher(.standard),
          "junk in the hidden list never loads as an app (\(String(describing: junk?.buttons[3])))")
    let many = AppSwitcher(hidden: (0..<200).map { "com.example.app\($0)" })
    check(many.hidden.count == AppSwitcher.maxHidden, "at most \(AppSwitcher.maxHidden) hidden apps")
    check(ButtonAction.switcher(AppSwitcher(hidden: ["com.ok.App", "bad id"])).clamped() == .switcher(AppSwitcher(hidden: ["com.ok.App"])), "clamped keeps only real bundle IDs")
    check(ButtonAction.switcher(AppSwitcher(hidden: ["com.ok.App"])).sanitized() == .switcher(AppSwitcher(hidden: ["com.ok.App"])), "your own imported settings keep them")
    // Hiding from the panel: the main setup's Switcher, or the app setup's own when it has one.
    var main = GlideConfig()
    main.buttons[3] = .switcher(.standard)
    main.chords = [Chord(buttons: [1, 2], action: .switcher(.standard))]
    var setup = AppProfile(bundleID: "com.example.Editor", name: "Editor")
    setup.buttons = [3: .switcher(AppSwitcher(tap: .back))]
    main.appProfiles = [setup]
    let a = main.settingSwitcherApp("com.apple.Music", hidden: true, buttons: [3], appSetup: nil)
    check(a?.buttons[3] == .switcher(AppSwitcher(hidden: ["com.apple.Music"])), "hidden in the main setup's Switcher")
    check(a?.settingSwitcherApp("com.apple.Music", hidden: true, buttons: [3], appSetup: nil) == nil, "hiding it twice changes nothing")
    check(a?.settingSwitcherApp("com.apple.Music", hidden: false, buttons: [3], appSetup: nil)?.buttons[3] == .switcher(.standard), "and shown again")
    let s = main.settingSwitcherApp("com.apple.Music", hidden: true, buttons: [3], appSetup: "com.example.Editor")
    check(s?.appProfiles[0].buttons?[3] == .switcher(AppSwitcher(tap: .back, hidden: ["com.apple.Music"])) && s?.buttons[3] == .switcher(.standard),
          "with an app setup's own Switcher in effect, that one")
    let k = main.settingSwitcherApp("com.apple.Music", hidden: true, buttons: [2, 1], appSetup: "com.example.Editor")
    check(k?.chords.first?.action == .switcher(AppSwitcher(hidden: ["com.apple.Music"])), "a combo Switcher (the app setup has no combos of its own)")
    check(main.settingSwitcherApp("com.apple.Music", hidden: true, buttons: [2], appSetup: nil) == nil, "no Switcher on that button: nothing changes")
    // Sharing with someone: hidden apps stay on this Mac. Backups and settings files keep them.
    var shared = GlideConfig()
    shared.buttons[3] = .switcher(AppSwitcher(tap: .back, hidden: ["com.apple.Music"]))
    shared.chords = [Chord(buttons: [1, 2], action: .switcher(AppSwitcher(hidden: ["com.apple.TV"])))]
    var p2 = AppProfile(bundleID: "com.example.Editor", name: "Editor")
    p2.buttons = [3: .switcher(AppSwitcher(hidden: ["com.apple.Mail"]))]
    shared.appProfiles = [p2]
    check(shared.switchersHidingApps.count == 3, "every Switcher hiding apps is found (\(shared.switchersHidingApps.count))")
    // Sync after a beta before hidden apps: they come back where it left the Switcher alone.
    var older = shared
    older.buttons[3] = .switcher(AppSwitcher(tap: .back))
    older.chords[0].action = .switcher(.standard)
    older.appProfiles[0].buttons = [3: .switcher(.standard)]
    let merged = older.keepingSwitcherHidden(from: shared)
    check(merged.kept && merged.config == shared, "sync puts hidden apps back after an older beta")
    var changedTap = older
    changedTap.buttons[3] = .switcher(AppSwitcher(tap: .forward))
    check(changedTap.keepingSwitcherHidden(from: shared).config.buttons[3] == .switcher(AppSwitcher(tap: .forward)), "a Switcher the older one changed wins")
    check(GlideSettingsFile.predatesSwitcherHidden("2.10-beta.32") && !GlideSettingsFile.predatesSwitcherHidden(GlideSettingsFile.switcherHiddenSince)
          && !GlideSettingsFile.predatesSwitcherHidden(nil), "which betas predate hidden apps")
    check(!shared.keepingSwitcherHidden(from: shared).kept, "nothing to put back: nothing changes")
}

section("the Switcher in settings files")
do {
    var c = GlideConfig()
    c.buttons[3] = .switcher(.standard)
    c.buttons[2] = .switcher(AppSwitcher.keeping(.middleClick))
    c.chords = [Chord(buttons: [1, 3], action: .switcher(AppSwitcher(tap: .shortcut(.copy))))]
    var p = AppProfile(bundleID: "com.example.app", name: "Example")
    p.buttons = [1: .switcher(.standard)]
    c.appProfiles = [p]
    check(c.requiredFileVersion == 2, "a Switcher makes the file version 2 (older Glideballs leave it alone)")
    let file = GlideSettingsFile(config: c, exportedFrom: "Test")
    let data = try! JSONEncoder().encode(file)
    let back = try! JSONDecoder().decode(GlideSettingsFile.self, from: data)
    check(back.config == c, "a file with Switchers round-trips without loss")
    check(back.version == 2 && (try? back.validatedConfig()) == c, "and is accepted as version 2")
    check(AppSwitcher.keeping(.middleClick).tap == .middleClick, "turning a button into a Switcher keeps what it did as the tap")
    check(AppSwitcher.keeping(.wheel(WheelMenu.keeping(.back))).tap == .back, "from a Wheel it keeps the Wheel's tap")
    check(WheelMenu.keeping(.switcher(AppSwitcher(tap: .back))).tap == .back, "and a Wheel made from a Switcher keeps its tap")
    // A Glideball before the Switcher (a beta with the Wheel, say): skips just those buttons.
    let text = String(data: data, encoding: .utf8)!.replacingOccurrences(of: "\"switcher\"", with: "\"switcherFromTheFuture\"")
    let old = try? JSONDecoder().decode(GlideSettingsFile.self, from: Data(text.utf8))
    check(old != nil, "a file a build without the Switcher can't read still opens")
    check(old?.config.buttons[3] == nil && old?.config.buttons[2] == nil && old?.config.chords.isEmpty == true
          && old?.config.appProfiles.first?.buttons?.isEmpty == true, "it skips just the Switcher buttons and combos")
    if let older = old?.config {
        check(GlideSettingsFile.predatesSwitcher("2.10-beta.24") && !GlideSettingsFile.predatesSwitcher(GlideSettingsFile.switcherSince)
              && !GlideSettingsFile.predatesSwitcher("2.10") && GlideSettingsFile.predatesSwitcher(nil), "which betas predate the Switcher")
        let merged = older.keepingSwitchers(from: c)
        check(merged.kept && merged.config == c, "sync puts the Switchers an older beta dropped back")
        check(!c.keepingSwitchers(from: c).kept, "and changes nothing when nothing was dropped")
        var changed = older
        changed.buttons[3] = .back
        check(changed.keepingSwitchers(from: c).config.buttons[3] == .back, "a button the older one set explicitly wins")
        check(older.keepingNewerFeatures(from: c).config.buttons[3] == c.buttons[3], "a Glideball before 2.10 dropping it: put back too")
    }
    // Older settings with no Switcher load unchanged and stay version 1 when nothing newer is used.
    let plain = GlideConfig()
    check(plain.requiredFileVersion == 1, "settings without a Switcher stay version 1")
    // A newer Glideball's Switcher: unknown fields ignored, an unknown tap falls back.
    let newer = #"{"buttons":{"3":{"switcher":{"_0":{"tap":{"rocket":{}},"rows":7,"hue":2}}}}}"#
    let n = try? JSONDecoder().decode(GlideConfig.self, from: Data(newer.utf8))
    check(n?.buttons[3] == .switcher(.standard), "a newer Switcher with unknown fields loads with the defaults")
    let bare = try? JSONDecoder().decode(GlideConfig.self, from: Data(#"{"buttons":{"2":{"switcher":{"_0":{}}}}}"#.utf8))
    check(bare?.buttons[2] == .switcher(.standard), "a Switcher with no fields loads")
    // Clamping and import: never nested, the tap made safe.
    check(ButtonAction.switcher(AppSwitcher(tap: .wheel(.standard))).clamped() == .switcher(.standard), "a Wheel as a Switcher's tap is dropped")
    var g = ButtonGesture.standard
    g.up = GestureStep(.switcher(.standard))
    check(ButtonAction.gesture(g).clamped().map { if case .gesture(let x) = $0 { x.up == nil } else { false } } == true, "a Switcher inside a gesture is dropped")
    var w = WheelMenu()
    w[0] = .switcher(.standard)
    check(ButtonAction.wheel(w).clamped().map { if case .gesture(let x) = $0 { x.up == nil } else { false } } == true, "a Switcher in an old Wheel's slot is dropped")
    check(ButtonAction.switcher(.standard).sanitized() != nil && ButtonAction.switcher(.standard).sanitized(nested: true) == nil, "sanitized: kept at the top, dropped when nested")
    check(ButtonAction.switcher(AppSwitcher(tap: .shortcut(.copy))).needsCaution && !ButtonAction.switcher(.standard).needsCaution,
          "a Switcher is listed in an import only when its tap presses keys")
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

section("rolling back (beta 17: down only below where the hold started)")
do {
    // Levi, beta 17, up and down set to volume (repeating), Short: "to turn it up my mouse has to
    // be above the spot I clicked and to turn it down it has to be below". The way back was
    // measured from the last fire's origin, so it first had to undo the rest of the forward roll
    // (up to a whole step): after one or two steps up, down came near or past the starting spot.
    // Now the way back is measured from where the ball turned: the first fire the other way
    // comes within one step plus the threshold of the turn, whatever came before.
    let repeating = ButtonGesture.media
    var chained = repeating
    chained.up?.repeats = false
    chained.down?.repeats = false
    let kinds: [(String, ButtonGesture)] = [("repeating", repeating), ("chained", chained), ("once per hold", oncePerHold(chained))]
    var worst = 0.0
    for d in GestureDistance.allCases {
        for steady in [false, true] {
            let t = GestureTuning.for(distance: d, steadyHands: steady)
            for (name, g) in kinds {
                for steps in 1...5 {
                    for extra in [0.0, 0.5, 0.95] {
                        for per in [1.0, 2.0, 5.0] {
                            let r = Rig([1: .gesture(g)])
                            r.config.gestureDistance = d
                            r.config.gestureSteadyHands = steady
                            r.press(1)
                            // Up: the first fire, then `steps - 1` more steps' worth, then part of one.
                            let up = t.commit + Double(steps - 1) * t.step + (extra * t.step).rounded(.down)
                            var rolled = 0.0
                            while rolled < up { let s = min(per, up - rolled); r.advance(0.008); r.ball(0, -s); rolled += s }
                            let upFires = r.fired.count
                            check(upFires >= 1 && r.fired.allSatisfy { $0.1 == .up }, "\(d.rawValue)\(steady ? " steady" : "") \(name): rolling up fired up (\(upFires))")
                            // Down, a count at a time, until it fires (or three steps go by).
                            r.advance(0.3)   // a turn takes a moment (and lets a chained cool-down pass)
                            var back = 0.0
                            while r.fired.count == upFires, back < 3 * t.step { r.advance(0.008); r.ball(0, 1); back += 1 }
                            let fired = r.fired.count > upFires && r.fired[upFires].1 == .down
                            check(fired, "\(d.rawValue)\(steady ? " steady" : "") \(name), \(steps) up (+\(extra) step): rolling back fires down")
                            check(back <= t.step + t.commit,
                                  "\(d.rawValue)\(steady ? " steady" : "") \(name), up \(Int(up)) in \(per)s: down needs \(Int(back)) counts back from the turn (at most \(Int(t.step + t.commit)))")
                            check(back >= min(t.commit, t.step) - 1, "\(d.rawValue) \(name): down never fires sooner than the threshold (\(Int(back)))")
                            worst = max(worst, back / t.step)
                            r.release(1)
                        }
                    }
                }
            }
        }
    }
    check(worst <= 1.01, "the way back from a turn is at most one step (worst \(String(format: "%.2f", worst)) steps)")

    // Levi's own setup: button 1, Short, volume up/down repeating, tracks left/right chained.
    var levi = ButtonGesture.media
    levi.distance = .short
    let r = Rig([1: .gesture(levi)])
    r.press(1)
    r.roll(dx: 0, dy: -2, steps: 20)       // 40 up: one volume up (32), not yet a second (32 + 44)
    check(r.fired.map(\.1) == [.up], "one volume up (\(r.fired.map(\.1)))")
    r.roll(dx: 0, dy: 2, steps: 22)        // 44 back: still 4 above where the hold started
    check(r.fired.map(\.1) == [.up, .down], "one step back turns it down while still above the start (\(r.fired.map(\.1)))")

    // A wobble back smaller than the tap slop keeps the forward roll: the next step up comes on time.
    let w = Rig([1: .gesture(levi)])
    w.press(1)
    w.roll(dx: 0, dy: -2, steps: 30)       // 60 up: one fire at 32, 28 toward the next (76)
    w.roll(dx: 0, dy: 1, steps: 6)         // a 6-count wobble back
    w.roll(dx: 0, dy: -2, steps: 10)       // 20 more up: 74 from the start, net of the wobble
    check(w.fired.map(\.1) == [.up], "a small wobble back fires nothing (\(w.fired.map(\.1)))")
    w.roll(dx: 0, dy: -2, steps: 4)        // past 76 net
    check(w.fired.map(\.1) == [.up, .up], "and the next step up still comes one step after the last (\(w.fired.map(\.1)))")
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
