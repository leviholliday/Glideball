import Foundation

// Gesture buttons: hold a button (or a combo) and roll the ball. This file is the
// whole decision: when a press becomes a gesture, which way the ball went, when a
// direction fires, when the release is a tap, and how every way out of a hold
// ends it. The engine only feeds it events and carries out what it returns.
//
// Foundation only, on purpose: scripts/gesture-sim compiles this file (with
// Config.swift) and drives it with scripted button and ball events.
//
// The feel follows what people praise in Logitech's gesture button and Mac Mouse
// Fix's "click and drag": a direction fires the moment the roll crosses the
// threshold (not on release), a clear dead zone so a click with a wobble is still
// a click, and the axis is decided by whichever way clearly dominates (OpenLogi's
// dead zone is max(40, 35% of the dominant axis); Mac Mouse Fix moved its
// threshold from 5 to 7 px to stop accidental drags).
//
// Chained gestures: one hold can fire many commands. Every fire re-centers the
// origin where the ball is, so the next direction (or the same one again) is
// measured from there: left, up, left in one hold is three commands, with no
// need to let go or roll back first. What keeps a wobble from firing:
//   - hysteresis: the next fire needs the full threshold again, from the new origin;
//   - a 120 ms cool-down after a chained fire, during which the origin follows the
//     ball (the tail of the same flick never counts toward the next one);
//   - a dominant axis per fire (2× for the first, a gentler 1.6× after it, or the
//     larger axis once the roll is past twice the threshold);
//   - never more than 20 fires a second, whatever the mix.
// Continuous directions (volume, zoom) keep repeating every further `step` along
// their axis, as before; rolling across breaks out into the other axis's direction.

/// The numbers behind a gesture, in raw ball counts (the Expert Mouse reports
/// about 400 counts per inch of ball surface: 1 mm is about 16 counts).
struct GestureTuning: Equatable {
    /// Total travel below which a release is still a tap (about 1 mm).
    var tapSlop = 16.0
    /// Travel along one axis that fires a direction (about 3 mm). Between
    /// `tapSlop` and this, a release does nothing: the band that keeps a
    /// near-gesture from turning into a click, and a wobbly click from turning
    /// into a gesture. After a fire, the next one needs this much again.
    var commit = 48.0
    /// The first fire's axis must have this many times the other's travel...
    var dominance = 2.0
    /// ...later fires in the same hold, this many (the hold is clearly a gesture by then)...
    var chainDominance = 1.6
    /// ...unless the roll has gone this far (× commit), then the larger axis wins.
    var forceCommitFactor = 2.0
    /// Continuous gestures: further travel along the axis per repeat.
    var step = 64.0
    /// Never two fires closer than this (seconds): at most 20 a second.
    var minRepeatInterval = 0.05
    /// After a chained (not continuous) fire: nothing more for this long, and the
    /// origin follows the ball meanwhile.
    var chainCooldown = 0.12
    /// A hold never lasts longer than this, whatever the button seems to be doing.
    var maxHold: Double = 30

    /// The tuning for a distance setting, with or without Steady hands.
    /// Short ≈ 2 mm, Normal ≈ 3 mm, Long ≈ 4.5 mm of ball surface to fire.
    static func `for`(distance: GestureDistance, steadyHands: Bool) -> GestureTuning {
        var t = GestureTuning()
        switch distance {
        case .short:
            t.tapSlop = 12
            t.commit = 32
            t.step = 44
        case .normal:
            break
        case .long:
            t.commit = 72
            t.step = 96
        }
        if steadyHands {
            // A wider dead zone (about 2 mm), a clearer axis, a longer pause between fires.
            t.tapSlop = 28
            t.commit = max(t.commit, 48)
            t.step = max(t.step, 64)
            t.dominance = 2.5
            t.chainDominance = 2.0
            t.chainCooldown = 0.2
        }
        return t
    }
}

/// What the engine must do. Applied in order.
enum GestureEffect: Equatable {
    /// Freeze (true) or free (false) the pointer.
    case freeze(Bool)
    /// A direction fired while the hold was blind (no ring up): press and release this action now.
    case fire(ButtonAction, GestureDirection)
    /// The hold was a tap: perform this action for these buttons.
    case tap(ButtonAction, buttons: [Int])
    /// Let go with a place lit on the ring: run that place's action now (once, on release only).
    case wheelPick(ButtonAction, place: Int)
    /// A place that repeats as you roll, lit on the ring: run it now (while held: when it lights,
    /// then every further stretch of rolling its way).
    case ringRepeat(ButtonAction, place: Int)
    /// The scroll ring turned one step while a Gestures button is held: run its ring job's action
    /// for that way.
    case ringStep(ButtonAction, clockwise: Bool)
    /// A Switcher was let go with its panel up: switch to app `index` of `session`'s list
    /// (once, on release only).
    case switchApp(session: Int, index: Int)
}

/// Why a hold ended without its release.
enum GestureCancel: String {
    case pause, quit, unplug, tapDisabled, sleep, lostRelease, timeout, configChanged
}

/// What kind of hold a press starts (`GestureRoute.begin`).
enum HoldKind: Equatable {
    case gesture(ButtonGesture)
    case switcher(AppSwitcher)

    /// An old Wheel is Gestures, shown right away (`ButtonGesture(wheel:)`): `clamped()` turns
    /// every one into that before the engine sees it, and this does the same for any it didn't.
    init?(_ action: ButtonAction) {
        switch action {
        case .gesture(let g): self = .gesture(g)
        case .wheel(let w): self = .gesture(ButtonGesture(wheel: w))
        case .switcher(let a): self = .switcher(a)
        default: return nil
        }
    }

    var tapAction: ButtonAction {
        switch self {
        case .gesture(let g): g.tapAction
        case .switcher(let a): a.tapAction
        }
    }
}

/// How a button press is handled, decided before anything happens.
enum GestureRoute: Equatable {
    /// Not a gesture press (or the primary button, which is never one).
    case notGesture
    /// Start a gesture hold.
    case begin
    /// Gestures can't work right now (switched off, the ball can't be read):
    /// the press does the tap action, as an ordinary button would.
    case tapInstead(ButtonAction)
    /// Another gesture is already held: this press does nothing (and so does its release).
    case ignore

    /// Precedence (the engine asks only once a press has got past combos):
    /// 0. Combos first. A button that belongs to a combo waits for its partners
    ///    (70 ms, up to 0.16 s while a three-button combo is still possible). If the
    ///    combo forms, its action runs and its buttons' own actions (gestures included)
    ///    never start; if it doesn't, each button does its own. A gesture combo starts
    ///    its hold the moment it forms, and the first of its buttons to come up ends it
    ///    (the others' releases do nothing), in whatever order they lift.
    /// 1. The primary button (0) is never a gesture: alone it's a left click, and a
    ///    combo that includes it does the gesture's tap action instead (the editor
    ///    doesn't offer gestures there). A gesture freezes the pointer and takes the
    ///    ball, which with the left button down would be a drag that can't move, or a
    ///    left press that never reaches apps: neither is safe for the click you rely on.
    /// 2. Only one gesture at a time; a second gesture button while one is held is ignored.
    /// 3. Gestures off, or no way to read the ball: the tap action, at once.
    ///
    /// Every Gestures button follows the Gestures switch (`enabled`), ring or no ring. The
    /// Switcher (`ButtonAction.switcher`) follows the same rules and shares the one hold, but
    /// follows `wheelsEnabled` (always on in the app today).
    static func decide(action: ButtonAction, buttons: [Int], enabled: Bool, canReadBall: Bool,
                       gestureHeld: Bool, wheelsEnabled: Bool = true) -> GestureRoute {
        guard let kind = HoldKind(action) else { return .notGesture }
        if buttons.contains(0) { return buttons.count == 1 ? .notGesture : .tapInstead(kind.tapAction) }
        if gestureHeld { return .ignore }
        let on = if case .gesture = kind { enabled } else { wheelsEnabled }
        guard on, canReadBall else { return .tapInstead(kind.tapAction) }
        return .begin
    }
}

/// One gesture hold at a time. Not thread-safe: the engine's input thread only.
///
/// A Gestures hold is **blind** (rolling fires a direction the moment it crosses the threshold,
/// chained, continuous or once, as gestures always were) until its ring comes into play
/// (`Hold.wheel`): right away (Show the ring: Right away), when the ball has been still for a
/// moment with nothing fired (After a pause), or when the ball goes into a More. From then on
/// for the rest of the hold it's the ring's way: the ball lights a place, letting go runs it once;
/// a place that repeats as you roll runs as it lights and again every further step its way; More
/// opens its own ring in place, and rolling back through the centre to the way back (opposite the
/// More) returns to the first one. The scroll ring does the ring job all through, unless it's
/// "Scrolls as usual".
final class GestureMachine {
    struct Hold: Equatable {
        var buttons: [Int]
        var gesture: ButtonGesture
        var tuning: GestureTuning
        var start: Double
        var dx = 0.0, dy = 0.0           // travel since the press
        var travel = 0.0                 // farthest the ball got from where it started
        var ox = 0.0, oy = 0.0           // the origin the next fire is measured from
        /// The furthest the ball has rolled since the origin was set, along the last crossing's
        /// axis and in its direction: where it turned back, if it did.
        var peak = 0.0
        /// The last direction the roll crossed the threshold in (fired or not).
        var direction: GestureDirection?
        /// Whether that crossing was a continuous direction (then the axis keeps repeating).
        var continuous = false
        var lastCross = -Double.infinity
        var lastFire = -Double.infinity
        var fired = 0
        /// "Once per hold" directions that have fired.
        var spent: Set<GestureDirection> = []
        var otherPress = false           // another button went down during the hold: no tap
        /// The ring, once it's in play (nil: blind).
        var wheel: WheelHold?
        /// A Switcher hold (nil: a Gestures one). Its `gesture` is then empty but for the tap.
        var switcher: SwitcherHold?
        /// Esc, another trackball button or the ring's overlay lost: nothing more runs this hold.
        var dismissed = false
        /// Runs of repeating places on the ring this hold (the overlay pulses the chip on each).
        var ringRuns = 0
        /// The ring job: turned this hold (then no tap), how many steps, the last one.
        var ringUsed = false
        var ringSteps = 0
        var lastRingStep = -Double.infinity
        var lastRingClockwise: Bool?
        /// The readout couldn't be drawn (or the watchdog took it): it isn't asked for again.
        var readoutLost = false
        /// After a pause: where the ball was last still, and since when.
        var stillX = 0.0, stillY = 0.0
        var lastMove: Double
    }

    /// After a pause: the ring comes up once the ball has been this still (counts) for this long.
    static let pauseSlop = 4.0
    static let pauseToShow = 0.25

    /// The defaults; each hold gets its own (`begin`'s `tuning`) for its distance.
    var tuning = GestureTuning()
    private(set) var hold: Hold?
    /// Whether this machine has the pointer frozen (what its effects last said).
    private(set) var frozen = false

    var isHeld: Bool { hold != nil }
    /// A Gestures hold with its ring in play (shown, or about to be: Right away's short delay).
    var wheelHeld: Bool { hold?.wheel != nil }
    /// A Switcher is held.
    var switcherHeld: Bool { hold?.switcher != nil }
    /// Something on screen (or that may come up) Esc can dismiss: a ring or a Switcher.
    var panelHeld: Bool {
        guard let h = hold else { return false }
        return h.switcher != nil || h.wheel != nil || h.gesture.mayShowRing
    }
    /// The scroll ring is the hold's (a ring job, or the Switcher's highlight): it never scrolls.
    var ringTaken: Bool {
        guard let h = hold else { return false }
        return h.switcher != nil || h.gesture.takesRing
    }
    /// A ring waiting on time alone: settling after More or Back, a lit More or Back about to open,
    /// a careful ring's repeating place about to start (the engine looks every 50 ms and calls `wheelTick`).
    var wheelWaiting: Bool { hold?.wheel?.waiting ?? false }
    /// An After a pause hold still waiting for its pause (the engine looks again every so often).
    var waitsForPause: Bool {
        guard let h = hold else { return false }
        return h.switcher == nil && h.wheel == nil && h.gesture.show == .afterPause && !h.dismissed && h.fired == 0
    }

    /// Which way the roll is heading, for the UI's compass only (it decides nothing):
    /// the larger axis (or, with eight, the nearest way that does something) from the origin
    /// once the ball has moved past the tap slop from it, otherwise the last direction that
    /// fired (nil while it's still a tap). Blind holds only.
    var leaning: GestureDirection? {
        guard let h = hold, h.wheel == nil, h.switcher == nil else { return nil }
        let rx = h.dx - h.ox, ry = h.dy - h.oy
        if (rx * rx + ry * ry).squareRoot() >= h.tuning.tapSlop {
            if h.gesture.eight {
                let angle = WheelGeometry.angle(x: rx, y: ry)
                return h.gesture.usedDirections.min { WheelGeometry.gap(angle, $0.place) < WheelGeometry.gap(angle, $1.place) }
            }
            let horizontal = abs(rx) >= abs(ry)
            return Self.direction(axisHorizontal: horizontal, sign: horizontal ? rx : ry)
        }
        return h.direction
    }

    /// Starts a hold. Refuses (no effects) for the primary button or while another is held.
    func begin(buttons: [Int], gesture: ButtonGesture, now: Double, tuning: GestureTuning? = nil) -> [GestureEffect] {
        guard hold == nil, !buttons.isEmpty, !buttons.contains(0) else { return [] }
        var t = tuning ?? self.tuning
        t.maxHold = min(t.maxHold, self.tuning.maxHold)
        var h = Hold(buttons: buttons.sorted(), gesture: gesture, tuning: t, start: now, lastMove: now)
        if gesture.show == .atOnce { h.wheel = Self.ring(h, level: nil) }
        hold = h
        frozen = true
        return [.freeze(true)]
    }

    /// Starts an old Wheel's hold: Gestures shown right away (`ButtonGesture(wheel:)`).
    func beginWheel(buttons: [Int], menu: WheelMenu, now: Double, tuning: GestureTuning? = nil) -> [GestureEffect] {
        begin(buttons: buttons, gesture: ButtonGesture(wheel: menu), now: now, tuning: tuning)
    }

    /// Starts a Switcher hold, like `begin`. `session` names this hold's app list (the engine
    /// numbers them). Refuses (no effects) for the primary button or while anything is held.
    func beginSwitcher(buttons: [Int], switcher: AppSwitcher, session: Int, now: Double, tuning: GestureTuning? = nil) -> [GestureEffect] {
        guard hold == nil, !buttons.isEmpty, !buttons.contains(0) else { return [] }
        var t = tuning ?? self.tuning
        t.maxHold = min(t.maxHold, self.tuning.maxHold)
        var h = Hold(buttons: buttons.sorted(), gesture: ButtonGesture(tap: switcher.tap), tuning: t, start: now, lastMove: now)
        h.switcher = SwitcherHold(session: session, step: t.commit, tapSlop: t.tapSlop)
        hold = h
        frozen = true
        return [.freeze(true)]
    }

    /// The ring for this hold at `level` (nil: the first one), centred where the ball is now.
    /// `careful`: a More's ring, or the first one after Back (`WheelHold.careful`).
    private static func ring(_ h: Hold, level: Int?, careful: Bool = false) -> WheelHold {
        var w = WheelHold(level: level, steps: h.gesture.steps(level: level), eight: h.gesture.eight,
                          geometry: WheelGeometry(h.tuning, careful: careful))
        w.careful = careful
        w.travel = h.travel
        w.rawX = h.dx
        w.rawY = h.dy
        return w
    }

    /// The main thread built the list for `session`: its grid. Ignored unless that hold is
    /// still the one held.
    func switcherReady(session: Int, grid: SwitcherGrid) {
        guard var h = hold, var s = h.switcher, s.session == session, s.grid == nil else { return }
        s.ready(grid)
        h.switcher = s
        hold = h
    }

    /// The Switcher's panel as it should look now (nil: hidden, or no Switcher held). Lets it
    /// show once `SwitcherHold.revealDelay` has passed since the press.
    func switcherOverlay(now: Double) -> SwitcherOverlayModel? {
        guard var h = hold, var s = h.switcher else { return nil }
        if !s.revealed, now - h.start >= SwitcherHold.revealDelay {
            s.revealed = true
            h.switcher = s
            hold = h
        }
        return s.overlay
    }

    /// Another button went down while a gesture is held: the release won't be a tap.
    /// A hold that has (or may get) a ring is dismissed: nothing more runs, and the ring goes
    /// away. `dismissesWheel`: the trackball's own button does; another mouse's click doesn't
    /// (its press never changes what the trackball holds, beyond the tap).
    func otherPress(_ button: Int, dismissesWheel: Bool = true) {
        guard var h = hold, !h.buttons.contains(button) else { return }
        h.otherPress = true
        if dismissesWheel, h.switcher != nil { h.switcher?.dismissed = true }
        if dismissesWheel, h.switcher == nil, h.wheel != nil || h.gesture.mayShowRing { Self.dismiss(&h) }
        hold = h
    }

    /// Esc while a ring (or the chance of one) or a Switcher is held, or the ring's overlay was
    /// lost: as another button would.
    func dismissWheel() {
        guard var h = hold, h.wheel != nil || h.switcher != nil || h.gesture.mayShowRing else { return }
        h.otherPress = true
        Self.dismiss(&h)
        h.switcher?.dismissed = true
        hold = h
    }

    /// The ring job's readout (alone, for a blind hold) couldn't be drawn: don't ask again.
    /// Gestures go on as they were.
    func readoutLost() {
        guard var h = hold else { return }
        h.readoutLost = true
        hold = h
    }

    private static func dismiss(_ h: inout Hold) {
        h.dismissed = true
        h.wheel?.dismissed = true
        h.wheel?.selected = nil
        h.wheel?.running = nil
    }

    /// The ring's overlay as it should look now (nil: hidden, or nothing to show). Brings the
    /// ring up once `WheelHold.revealDelay` has passed since the press (Right away), or once the
    /// ball has been still for `pauseToShow` with nothing fired (After a pause). A blind hold
    /// shows only the ring job's readout, once the ring has been turned.
    func wheelOverlay(now: Double) -> WheelOverlayModel? {
        guard var h = hold, h.switcher == nil else { return nil }
        if h.wheel == nil, waitsForPause, now - h.lastMove >= Self.pauseToShow {
            // Held still: the ring comes up around the pointer, lit where the ball has got to.
            var w = Self.ring(h, level: nil)
            w.revealed = true
            Self.place(&w, dx: h.dx - h.ox, dy: h.dy - h.oy)
            w.selected = w.geometry.pick(x: w.x, y: w.y, current: nil, filled: w.selectable)
            w.litSince = now
            h.wheel = w
        }
        if var w = h.wheel, !w.revealed, !w.quiet, now - h.start >= WheelHold.revealDelay {
            w.revealed = true
            h.wheel = w
        }
        hold = h
        let readout = h.ringUsed ? h.lastRingClockwise.map { WheelOverlayModel.RingReadout(job: h.gesture.ring, clockwise: $0, steps: h.ringSteps) } : nil
        if let w = h.wheel { return w.overlay(readout: readout, first: h.gesture.steps(level: nil), pulse: h.ringRuns) }
        guard let readout, !h.dismissed, !h.readoutLost else { return nil }
        return WheelOverlayModel(slots: Array(repeating: nil, count: 8), eight: h.gesture.eight, showsRing: false,
                                 selected: nil, dot: .zero, ring: readout)
    }

    /// What only time brings to a ring (the engine calls this every 50 ms while `wheelWaiting`):
    /// a ring settling after More or Back arms once the hand has rested; a lit More or Back that
    /// has stayed lit `WheelHold.confirmDwell` opens; a careful ring's lit repeating place that has
    /// stayed lit `WheelHold.repeatDwell` starts (and goes on as you roll, as any repeating place).
    func wheelTick(now: Double) -> [GestureEffect] {
        guard var h = hold, var w = h.wheel, !w.dismissed, !h.dismissed else { return [] }
        w.armIfRested(quietFor: now - h.lastMove, now: now)
        var effects: [GestureEffect] = []
        if w.armed, let s = w.selected {
            if w.opens(s) {
                if w.confirmed(now: now) { Self.open(&h, &w, s, now: now) }
            } else if w.careful, w.running == s, !w.runStarted, now - w.litSince >= WheelHold.repeatDwell,
                      let step = w.steps[s], step.repeats, let action = step.firable {
                w.runStarted = true
                w.runProgress = 0
                effects = Self.repeatFire(&h, action, place: s, now: now)
            }
        }
        h.wheel = w
        hold = h
        return effects
    }

    /// Opens the lit More (its ring, in place) or goes Back (the first ring), settling either way.
    private static func open(_ h: inout Hold, _ w: inout WheelHold, _ s: Int, now: Double) {
        if s == w.back {
            // Back: the first ring again, in its middle, nothing lit, careful from now on, and the
            // roll that got here can't carry on into it.
            w = ring(h, level: nil, careful: true)
        } else {
            // More: its ring opens in place, centred where the first one was, settling the same way.
            w = ring(h, level: s, careful: true)
        }
        w.revealed = true
        w.settle(cameFrom: s, now: now)
    }

    /// One report from the scroll ring while something is held: the Switcher's highlight, or a
    /// step of the Gestures button's ring job each way, at most one per `minRepeatInterval` (the
    /// rest are dropped, never queued). It never picks a place. Nothing when the ring job is
    /// "Scrolls as usual" (the engine lets it scroll then).
    func ring(ticks: Int, now: Double) -> [GestureEffect] {
        if var h = hold, var s = h.switcher {
            // A Switcher: one app forward (clockwise) or back per report. Nothing runs.
            guard ticks != 0 else { return [] }
            s.ring(clockwise: ticks < 0)
            h.switcher = s
            hold = h
            return []
        }
        guard var h = hold, h.gesture.takesRing, ticks != 0, !h.dismissed else { return [] }
        defer { hold = h }
        // Clockwise on the Expert Mouse's ring reports negative ticks (it scrolls down).
        let clockwise = ticks < 0
        h.ringUsed = true
        h.lastRingClockwise = clockwise
        h.wheel?.revealed = true   // Right away: a ring turn brings it up at once, as the Wheel did
        let pair = h.gesture.ringActions
        guard let action = clockwise ? pair.clockwise : pair.counterclockwise,
              now - h.lastRingStep >= h.tuning.minRepeatInterval else { return [] }
        h.lastRingStep = now
        h.ringSteps += 1
        return [.ringStep(action, clockwise: clockwise)]
    }

    /// Raw ball movement (+x right, +y toward you).
    func ball(dx: Double, dy: Double, now: Double) -> [GestureEffect] {
        guard var h = hold, dx.isFinite, dy.isFinite else { return [] }
        if var s = h.switcher {
            // A Switcher: the ball moves the highlight across the grid. Nothing runs until the release.
            s.ball(dx: dx, dy: dy)
            h.travel = max(h.travel, s.travel)
            h.switcher = s
            hold = h
            return []
        }
        h.dx += dx
        h.dy += dy
        h.travel = max(h.travel, (h.dx * h.dx + h.dy * h.dy).squareRoot())
        let quietFor = now - h.lastMove   // how long the ball had been at rest before this movement
        // After a pause: any real movement starts the wait again.
        let sx = h.dx - h.stillX, sy = h.dy - h.stillY
        if sx * sx + sy * sy > Self.pauseSlop * Self.pauseSlop {
            h.stillX = h.dx
            h.stillY = h.dy
            h.lastMove = now
        }
        defer { hold = h }
        if var w = h.wheel {
            let effects = Self.ringBall(&h, &w, dx: dx, dy: dy, quietFor: quietFor, now: now)
            h.wheel = w
            return effects
        }
        guard !h.dismissed else { return [] }
        return h.gesture.eight ? Self.blindEight(&h, now: now) : Self.blindFour(&h, now: now)
    }

    /// Puts the ring's point at (dx, dy) from its centre, within its reach.
    private static func place(_ w: inout WheelHold, dx: Double, dy: Double) {
        w.x = dx
        w.y = dy
        let r = (w.x * w.x + w.y * w.y).squareRoot()
        if r > w.geometry.reach { w.x *= w.geometry.reach / r; w.y *= w.geometry.reach / r }
    }

    /// The ring in play: the ball moves a point around the centre and the place it points at
    /// lights. More opens its ring, the way back returns; a place that repeats runs as it lights.
    private static func ringBall(_ h: inout Hold, _ w: inout WheelHold, dx: Double, dy: Double, quietFor: Double, now: Double) -> [GestureEffect] {
        w.rawX += dx
        w.rawY += dy
        w.travel = h.travel
        if w.travel >= w.geometry.tapSlop, !w.quiet { w.revealed = true }
        // Just opened or came back: nothing moves, lights or runs until it's armed.
        guard w.armed || w.arm(dx: dx, dy: dy, quietFor: quietFor, now: now) else { return [] }
        place(&w, dx: w.x + dx, dy: w.y + dy)
        guard !w.dismissed else { return [] }
        let before = w.selected
        w.selected = w.geometry.pick(x: w.x, y: w.y, current: w.selected, filled: w.selectable)
        guard let s = w.selected else { w.running = nil; w.runStarted = false; return [] }
        if s != before {
            w.running = nil
            w.runStarted = false
            w.litSince = now
            // More and Back only light: they open once they've stayed lit a moment, or the roll
            // goes on out (`WheelHold.confirmed`), never just for crossing into them (beta 32).
            if w.opens(s) {
                if w.confirmed(now: now) { open(&h, &w, s, now: now) }
                return []
            }
            guard let step = w.steps[s], step.repeats, let action = step.firable else { return [] }
            w.running = s
            w.runProgress = 0
            // A careful ring's repeating place only lights; rolling on its way (or staying) starts it.
            if w.careful { return [] }
            w.runStarted = true
            return repeatFire(&h, action, place: s, now: now)
        }
        if w.opens(s) {
            if w.confirmed(now: now) { open(&h, &w, s, now: now) }
            return []
        }
        guard w.running == s, let step = w.steps[s], step.repeats, let action = step.firable else { return [] }
        let v = GestureDirection(place: s).vector
        w.runProgress = max(0, w.runProgress + dx * v.x + dy * v.y)
        guard w.runProgress >= h.tuning.step else { return [] }
        // Steps consumed whether or not they fire: faster than the rate limit is dropped, not queued.
        w.runProgress = w.runProgress.truncatingRemainder(dividingBy: h.tuning.step)
        w.runStarted = true
        return repeatFire(&h, action, place: s, now: now)
    }

    private static func repeatFire(_ h: inout Hold, _ action: ButtonAction, place: Int, now: Double) -> [GestureEffect] {
        guard now - h.lastFire >= h.tuning.minRepeatInterval else { return [] }
        h.lastFire = now
        h.fired += 1
        h.ringRuns += 1
        return [.ringRepeat(action, place: place)]
    }

    /// A blind hold rolled into a More (`rx`, `ry` from where the roll started): the first ring
    /// comes into play with More lit, the point where the roll got to. More opens the way it does on
    /// a showing ring: after staying on it a moment, or rolling on further (beta 32; before, crossing
    /// the distance opened it at once). With Show the ring: Never, the first ring stays hidden and only
    /// the More's ring shows (a More ring always shows).
    private static func lightMore(_ h: inout Hold, _ direction: GestureDirection, rx: Double, ry: Double, now: Double) {
        var w = ring(h, level: nil)
        w.quiet = h.gesture.show == .never
        w.revealed = !w.quiet
        place(&w, dx: rx, dy: ry)
        w.selected = direction.place
        w.litSince = now
        if w.confirmed(now: now) { open(&h, &w, direction.place, now: now) }
        h.wheel = w
    }

    /// Four directions, blind: exactly as gestures always were.
    private static func blindFour(_ h: inout Hold, now: Double) -> [GestureEffect] {
        let t = h.tuning
        // Just after a chained fire: the origin follows the ball, so the rest of
        // the same flick can't count toward the next fire.
        if let last = h.direction, !h.continuous, now - h.lastCross < t.chainCooldown {
            h.ox = h.dx
            h.oy = h.dy
            h.peak = isHorizontal(last) ? h.dx : h.dy
            return []
        }

        // Rolling back: the way back is measured from where the ball turned, not from the last
        // fire. Otherwise the opposite direction needed the rest of the forward roll undone first
        // (up to a whole step more): after a step or two of volume up, down only came once the
        // ball was back near where the hold started (Levi, beta 17). A turn smaller than the tap
        // slop is a wobble, and keeps the forward roll toward the next step.
        if let last = h.direction {
            let horizontal = isHorizontal(last)
            let sign: Double = last == .right || last == .down ? 1 : -1
            let pos = horizontal ? h.dx : h.dy
            let origin = horizontal ? h.ox : h.oy
            if (pos - h.peak) * sign > 0 {
                h.peak = pos
            } else if (h.peak - pos) * sign > t.tapSlop, (h.peak - origin) * sign > 0 {
                if horizontal { h.ox = h.peak } else { h.oy = h.peak }
            }
        }

        let rx = h.dx - h.ox, ry = h.dy - h.oy
        let ax = abs(rx), ay = abs(ry)
        let horizontal = ax >= ay
        let major = max(ax, ay), minor = min(ax, ay)
        let way = direction(axisHorizontal: horizontal, sign: horizontal ? rx : ry)

        // A continuous run carries on along its axis: every `step`, the larger axis is enough.
        if let last = h.direction, h.continuous, isHorizontal(last) == horizontal, h.gesture[way]?.repeats == true {
            guard major >= t.step else { return [] }
            // Steps consumed whether or not they fire: rolling faster than the rate
            // limit is dropped, not queued. The origin keeps the remainder along the
            // axis, and starts fresh across it.
            let consumed = (major / t.step).rounded(.down) * t.step * (horizontal ? (rx < 0 ? -1 : 1) : (ry < 0 ? -1 : 1))
            if horizontal { h.ox += consumed; h.oy = h.dy } else { h.oy += consumed; h.ox = h.dx }
            h.peak = horizontal ? h.dx : h.dy
            h.direction = way
            h.lastCross = now
            guard now - h.lastFire >= t.minRepeatInterval, let action = h.gesture[way]?.firable else { return [] }
            h.lastFire = now
            h.fired += 1
            return [.fire(action, way)]
        }

        // Otherwise a fresh crossing, from the origin.
        let dominance = h.direction == nil ? t.dominance : t.chainDominance
        guard major >= t.commit, major >= dominance * minor || major >= t.commit * t.forceCommitFactor else { return [] }
        let step = h.gesture[way]
        if step?.isMore == true {
            lightMore(&h, way, rx: rx, ry: ry, now: now)
            return []
        }
        h.ox = h.dx
        h.oy = h.dy
        h.peak = horizontal ? h.dx : h.dy
        h.direction = way
        h.continuous = step?.repeats == true
        h.lastCross = now
        guard let step, let action = step.firable, !(step.once && h.spent.contains(way)),
              now - h.lastFire >= t.minRepeatInterval else { return [] }
        if step.once { h.spent.insert(way) }
        h.lastFire = now
        h.fired += 1
        return [.fire(action, way)]
    }

    /// Eight directions, blind: the same rules by angle. A fresh crossing needs the whole
    /// distance from the origin, toward a way that does something (empty ones are skipped, so
    /// the rest are wider), and a clear winner (10° nearer than the next, 8° once the hold has
    /// fired, or twice the distance); a continuous way carries on every `step` along it, and
    /// rolling back a step fires its opposite if that one repeats too.
    private static func blindEight(_ h: inout Hold, now: Double) -> [GestureEffect] {
        let t = h.tuning
        if h.direction != nil, !h.continuous, now - h.lastCross < t.chainCooldown {
            h.ox = h.dx
            h.oy = h.dy
            return []
        }
        var rx = h.dx - h.ox, ry = h.dy - h.oy
        if let last = h.direction, h.continuous, h.gesture[last]?.repeats == true {
            let v = last.vector
            var along = rx * v.x + ry * v.y
            // Rolling back: measured from where the ball turned (past a wobble), not the last fire.
            if along > h.peak {
                h.peak = along
            } else if h.peak - along > t.tapSlop, h.peak > 0 {
                h.ox += h.peak * v.x
                h.oy += h.peak * v.y
                h.peak = 0
                rx = h.dx - h.ox
                ry = h.dy - h.oy
                along = rx * v.x + ry * v.y
            }
            let across = abs(-rx * v.y + ry * v.x)
            let opposite = GestureDirection(place: last.place + 4)
            var way: GestureDirection?
            if along >= t.step, along >= across { way = last }
            else if -along >= t.step, -along >= across, h.gesture[opposite]?.repeats == true { way = opposite }
            if let way, let step = h.gesture[way], let action = step.firable {
                let u = way.vector
                let a = rx * u.x + ry * u.y
                // The remainder stays along the way; across it starts fresh.
                let keep = a - (a / t.step).rounded(.down) * t.step
                h.ox = h.dx - keep * u.x
                h.oy = h.dy - keep * u.y
                h.peak = keep
                h.direction = way
                h.lastCross = now
                guard now - h.lastFire >= t.minRepeatInterval else { return [] }
                h.lastFire = now
                h.fired += 1
                return [.fire(action, way)]
            }
            if along > -t.tapSlop, across < t.commit { return [] }   // still on its way: nothing fresh yet
        }
        let r = (rx * rx + ry * ry).squareRoot()
        guard r >= t.commit else { return [] }
        let usable = h.gesture.usedDirections.filter { h.gesture[$0]?.isUsable == true }
        let angle = WheelGeometry.angle(x: rx, y: ry)
        let ranked = usable.sorted { WheelGeometry.gap(angle, $0.place) < WheelGeometry.gap(angle, $1.place) }
        guard let best = ranked.first, let step = h.gesture[best] else { return [] }
        let margin = h.direction == nil ? 10.0 : 8.0
        let next = ranked.count > 1 ? WheelGeometry.gap(angle, ranked[1].place) : 180
        guard WheelGeometry.gap(angle, best.place) + margin <= next || r >= t.commit * t.forceCommitFactor else { return [] }
        if step.isMore {
            lightMore(&h, best, rx: rx, ry: ry, now: now)
            return []
        }
        h.ox = h.dx
        h.oy = h.dy
        h.peak = 0
        h.direction = best
        h.continuous = step.repeats
        h.lastCross = now
        guard let action = step.firable, !(step.once && h.spent.contains(best)),
              now - h.lastFire >= t.minRepeatInterval else { return [] }
        if step.once { h.spent.insert(best) }
        h.lastFire = now
        h.fired += 1
        return [.fire(action, best)]
    }

    /// A button came up. Ends the hold if it's one of the hold's buttons: frees
    /// the pointer, then runs what the ring has lit, or taps if the ball stayed (nearly) still.
    func release(button: Int, now: Double) -> [GestureEffect] {
        guard let h = hold, h.buttons.contains(button) else { return [] }
        hold = nil
        frozen = false
        var effects: [GestureEffect] = [.freeze(false)]
        if var s = h.switcher {
            // A Switcher: with its panel up (or due), the lit app, once. Before that, a still
            // press is the tap. Dismissed or past the time limit: nothing.
            guard !s.dismissed, now - h.start < h.tuning.maxHold else { return effects }
            if now - h.start >= SwitcherHold.revealDelay { s.revealed = true }
            if s.shown {
                effects.append(.switchApp(session: s.session, index: s.index))
            } else if !s.ringUsed, !h.otherPress, s.travel < s.tapSlop {
                let tap = h.gesture.tapAction
                if tap != .disabled { effects.append(.tap(tap, buttons: h.buttons)) }
            }
            return effects
        }
        guard !h.dismissed, now - h.start < h.tuning.maxHold else { return effects }
        if let w = h.wheel {
            // The ring: the lit place runs, once (one that repeats already ran as it lit); or, if
            // the ball stayed put, the ring wasn't turned and nothing ran, the tap. Rolled back to
            // the centre: nothing.
            if let place = w.selected, place != w.back, let step = w.steps[place], !step.isMore, !step.repeats,
               let action = step.firable {
                effects.append(.wheelPick(action, place: place))
            } else if w.level == nil, !h.ringUsed, !h.otherPress, h.fired == 0, h.travel < w.geometry.tapSlop {
                let tap = h.gesture.tapAction
                if tap != .disabled { effects.append(.tap(tap, buttons: h.buttons)) }
            }
            return effects
        }
        if h.direction == nil, h.fired == 0, !h.otherPress, !h.ringUsed, h.travel < h.tuning.tapSlop {
            let tap = h.gesture.tapAction
            if tap != .disabled { effects.append(.tap(tap, buttons: h.buttons)) }
        }
        return effects
    }

    /// Ends a hold without its release (pause, quit, unplug, the tap switched
    /// off by macOS, sleep, a lost release, a timeout). Nothing fires.
    func cancel(_ reason: GestureCancel) -> [GestureEffect] {
        let wasFrozen = frozen || hold != nil
        hold = nil
        frozen = false
        return wasFrozen ? [.freeze(false)] : []
    }

    /// Called by the engine's hold check (only while something is held). Ends a
    /// hold that has gone on longer than `maxHold`.
    func tick(now: Double) -> [GestureEffect] {
        guard let h = hold, now - h.start >= h.tuning.maxHold else { return [] }
        return cancel(.timeout)
    }

    private static func isHorizontal(_ d: GestureDirection) -> Bool { d == .left || d == .right }

    private static func direction(axisHorizontal: Bool, sign: Double) -> GestureDirection {
        axisHorizontal ? (sign < 0 ? .left : .right) : (sign < 0 ? .up : .down)
    }
}
