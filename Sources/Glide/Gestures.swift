import Foundation

// Gesture buttons: hold a button and roll the ball. This file is the whole
// decision: when a press becomes a gesture, which way the ball went, when a
// direction fires, when the release is a tap, and how every way out of a hold
// ends it. The engine only feeds it events and carries out what it returns.
//
// Foundation only, on purpose: scripts/gesture-sim compiles this file (with
// Config.swift) and drives it with scripted button and ball events.
//
// The feel follows what people praise in Logitech's gesture button and Mac Mouse
// Fix's "click and drag": a direction fires the moment the roll crosses the
// threshold (not on release), one action per hold, a clear dead zone so a click
// with a wobble is still a click, and the axis is decided by whichever way
// clearly dominates (OpenLogi's dead zone is max(40, 35% of the dominant axis);
// Mac Mouse Fix moved its threshold from 5 to 7 px to stop accidental drags).

/// The numbers behind a gesture, in raw ball counts (the Expert Mouse reports
/// about 400 counts per inch of ball surface).
struct GestureTuning: Equatable {
    /// Total travel below which a release is still a tap (about 1 mm).
    var tapSlop = 16.0
    /// Travel along one axis that fires a direction (about 3 mm). Between
    /// `tapSlop` and this, a release does nothing: the hysteresis band that
    /// keeps a near-gesture from turning into a click, and a wobbly click from
    /// turning into a gesture.
    var commit = 48.0
    /// The winning axis must have this many times the other's travel...
    var dominance = 2.0
    /// ...unless the roll has gone this far (× commit), then the larger axis wins.
    var forceCommitFactor = 2.0
    /// Continuous gestures: further travel along the locked axis per repeat.
    var step = 64.0
    /// Continuous gestures: never faster than this (seconds between repeats).
    var minRepeatInterval = 0.05
    /// A hold never lasts longer than this, whatever the button seems to be doing.
    var maxHold: Double = 30
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

    /// Precedence (the engine asks only once a press has got past combos: a button
    /// that belongs to a combo waits for its partners first, and a combo that forms
    /// wins over the gestures of its buttons).
    /// 1. The primary button (0) is never a gesture: alone it's a left click, and a
    ///    combo that includes it does the gesture's tap action instead.
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
        var start: Double
        var dx = 0.0, dy = 0.0           // travel since the press
        var travel = 0.0                 // farthest the ball got from where it started
        var direction: GestureDirection?  // set once a direction fired (the axis is locked)
        var offset = 0.0                 // continuous: travel along the axis since the last repeat
        var lastFire = -Double.infinity
        var fired = 0
        var otherPress = false           // another button went down during the hold: no tap
    }

    var tuning = GestureTuning()
    private(set) var hold: Hold?
    /// Whether this machine has the pointer frozen (what its effects last said).
    private(set) var frozen = false

    var isHeld: Bool { hold != nil }

    /// Starts a hold. Refuses (no effects) for the primary button or while another is held.
    func begin(buttons: [Int], gesture: ButtonGesture, now: Double) -> [GestureEffect] {
        guard hold == nil, !buttons.isEmpty, !buttons.contains(0) else { return [] }
        hold = Hold(buttons: buttons.sorted(), gesture: gesture, start: now)
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
        h.dx += dx
        h.dy += dy
        h.travel = max(h.travel, (h.dx * h.dx + h.dy * h.dy).squareRoot())
        var effects: [GestureEffect] = []
        if let dir = h.direction {
            // Locked to an axis: only a continuous gesture does anything more.
            let along = (dir == .left || dir == .right) ? dx : dy
            if h.gesture[dir]?.repeats == true {
                h.offset += along
                if abs(h.offset) >= tuning.step {
                    let way = Self.direction(axisHorizontal: dir == .left || dir == .right, sign: h.offset)
                    if now - h.lastFire >= tuning.minRepeatInterval,
                       let step = h.gesture[way], step.repeats, let action = step.firable {
                        effects.append(.fire(action, way))
                        h.lastFire = now
                        h.fired += 1
                    }
                    // One step consumed either way; rolling faster than the rate limit is dropped, not queued.
                    h.offset = h.offset.truncatingRemainder(dividingBy: tuning.step)
                }
            }
        } else {
            let ax = abs(h.dx), ay = abs(h.dy)
            let major = max(ax, ay), minor = min(ax, ay)
            if major >= tuning.commit && (major >= tuning.dominance * minor || major >= tuning.commit * tuning.forceCommitFactor) {
                let horizontal = ax >= ay
                let way = Self.direction(axisHorizontal: horizontal, sign: horizontal ? h.dx : h.dy)
                h.direction = way
                h.offset = 0
                if let action = h.gesture[way]?.firable {
                    effects.append(.fire(action, way))
                    h.lastFire = now
                    h.fired += 1
                }
            }
        }
        hold = h
        return effects
    }

    /// A button came up. Ends the hold if it's one of the hold's buttons: frees
    /// the pointer, then taps if the ball stayed (nearly) still.
    func release(button: Int, now: Double) -> [GestureEffect] {
        guard let h = hold, h.buttons.contains(button) else { return [] }
        hold = nil
        frozen = false
        var effects: [GestureEffect] = [.freeze(false)]
        if h.direction == nil, !h.otherPress, h.travel < tuning.tapSlop, now - h.start < tuning.maxHold {
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
        guard let h = hold, now - h.start >= tuning.maxHold else { return [] }
        return cancel(.timeout)
    }

    private static func direction(axisHorizontal: Bool, sign: Double) -> GestureDirection {
        axisHorizontal ? (sign < 0 ? .left : .right) : (sign < 0 ? .up : .down)
    }
}
