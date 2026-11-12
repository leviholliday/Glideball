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
    /// A direction fired: press and release this action now.
    case fire(ButtonAction, GestureDirection)
    /// The hold was a tap: perform this action for these buttons.
    case tap(ButtonAction, buttons: [Int])
}

/// Why a hold ended without its release.
enum GestureCancel: String {
    case pause, quit, unplug, tapDisabled, sleep, lostRelease, timeout, configChanged
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
    static func decide(action: ButtonAction, buttons: [Int], enabled: Bool, canReadBall: Bool,
                       gestureHeld: Bool) -> GestureRoute {
        guard case .gesture(let g) = action else { return .notGesture }
        if buttons.contains(0) { return buttons.count == 1 ? .notGesture : .tapInstead(g.tapAction) }
        if gestureHeld { return .ignore }
        guard enabled, canReadBall else { return .tapInstead(g.tapAction) }
        return .begin
    }
}

/// One gesture hold at a time. Not thread-safe: the engine's input thread only.
final class GestureMachine {
    struct Hold: Equatable {
        var buttons: [Int]
        var gesture: ButtonGesture
        var tuning: GestureTuning
        var start: Double
        var dx = 0.0, dy = 0.0           // travel since the press
        var travel = 0.0                 // farthest the ball got from where it started
        var ox = 0.0, oy = 0.0           // the origin the next fire is measured from
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
    }

    /// The defaults; each hold gets its own (`begin`'s `tuning`) for its distance.
    var tuning = GestureTuning()
    private(set) var hold: Hold?
    /// Whether this machine has the pointer frozen (what its effects last said).
    private(set) var frozen = false

    var isHeld: Bool { hold != nil }

    /// Which way the roll is heading, for the UI's compass only (it decides nothing):
    /// the larger axis from the origin once the ball has moved past the tap slop
    /// from it, otherwise the last direction that fired (nil while it's still a tap).
    var leaning: GestureDirection? {
        guard let h = hold else { return nil }
        let rx = h.dx - h.ox, ry = h.dy - h.oy
        if (rx * rx + ry * ry).squareRoot() >= h.tuning.tapSlop {
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
        hold = Hold(buttons: buttons.sorted(), gesture: gesture, tuning: t, start: now)
        frozen = true
        return [.freeze(true)]
    }

    /// Another button went down while a gesture is held: the release won't be a tap.
    func otherPress(_ button: Int) {
        guard var h = hold, !h.buttons.contains(button) else { return }
        h.otherPress = true
        hold = h
    }

    /// Raw ball movement (+x right, +y toward you).
    func ball(dx: Double, dy: Double, now: Double) -> [GestureEffect] {
        guard var h = hold, dx.isFinite, dy.isFinite else { return [] }
        let t = h.tuning
        h.dx += dx
        h.dy += dy
        h.travel = max(h.travel, (h.dx * h.dx + h.dy * h.dy).squareRoot())
        defer { hold = h }

        // Just after a chained fire: the origin follows the ball, so the rest of
        // the same flick can't count toward the next fire.
        if h.direction != nil, !h.continuous, now - h.lastCross < t.chainCooldown {
            h.ox = h.dx
            h.oy = h.dy
            return []
        }

        let rx = h.dx - h.ox, ry = h.dy - h.oy
        let ax = abs(rx), ay = abs(ry)
        let horizontal = ax >= ay
        let major = max(ax, ay), minor = min(ax, ay)
        let way = Self.direction(axisHorizontal: horizontal, sign: horizontal ? rx : ry)

        // A continuous run carries on along its axis: every `step`, the larger axis is enough.
        if let last = h.direction, h.continuous, Self.isHorizontal(last) == horizontal, h.gesture[way]?.repeats == true {
            guard major >= t.step else { return [] }
            // Steps consumed whether or not they fire: rolling faster than the rate
            // limit is dropped, not queued. The origin keeps the remainder along the
            // axis, and starts fresh across it.
            let consumed = (major / t.step).rounded(.down) * t.step * (horizontal ? (rx < 0 ? -1 : 1) : (ry < 0 ? -1 : 1))
            if horizontal { h.ox += consumed; h.oy = h.dy } else { h.oy += consumed; h.ox = h.dx }
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
        h.ox = h.dx
        h.oy = h.dy
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

    /// A button came up. Ends the hold if it's one of the hold's buttons: frees
    /// the pointer, then taps if the ball stayed (nearly) still.
    func release(button: Int, now: Double) -> [GestureEffect] {
        guard let h = hold, h.buttons.contains(button) else { return [] }
        hold = nil
        frozen = false
        var effects: [GestureEffect] = [.freeze(false)]
        if h.direction == nil, h.fired == 0, !h.otherPress, h.travel < h.tuning.tapSlop, now - h.start < h.tuning.maxHold {
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
