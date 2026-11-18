import CoreGraphics
import Foundation

// The ring of a Gestures button: hold a button (or a combo) and its directions can show as a
// ring of chips around the pointer (Show the ring: after a pause, or right away), and a
// direction can be More, which opens a second ring in place. This file is the ring's half of
// the decision (where the ball has "rolled" to, which place that lights, when the ring
// appears, More and the way back); `GestureMachine` (Gestures.swift) owns the hold itself, so
// a hold with its ring up starts, freezes the pointer and ends exactly the way a blind gesture
// does, by every path. (The code still says "Wheel" for the ring: it was the Wheel action
// in 2.10 betas 24 to 27, and renaming it everywhere would be churn.)
//
// Foundation and CoreGraphics only, on purpose: scripts/gesture-sim and
// scripts/engine-fuzz compile this file.

/// The numbers behind picking a place, in raw ball counts (about 16 counts per mm).
struct WheelGeometry: Equatable {
    /// Past this far from the centre a place lights (about 2 mm with Normal distance).
    var select: Double
    /// Back inside this, nothing is lit: rolling back to the centre cancels.
    var release: Double
    /// The rolled-to point never goes further than this from the centre, so rolling the
    /// other way comes back at once however far the ball went.
    var reach: Double
    /// A lit place stays lit until another one is this much closer (degrees), so a roll
    /// right along the border between two places doesn't flicker between them.
    var stickiness = 12.0
    /// Below this much roll a release can still be the tap.
    var tapSlop: Double

    init(_ t: GestureTuning) {
        tapSlop = t.tapSlop
        select = max(t.commit * 0.75, t.tapSlop + 12)
        release = min(t.tapSlop * 1.25, select - 8)
        reach = select * 2.5
    }

    /// Which used place the point (x, y) picks among `filled`, given the one lit now.
    /// Straight up is place 0, then clockwise every 45°. Empty places are skipped, so with
    /// two or three filled places each one is a wide target.
    func pick(x: Double, y: Double, current: Int?, filled: [Int]) -> Int? {
        guard !filled.isEmpty, x.isFinite, y.isFinite else { return nil }
        let r = (x * x + y * y).squareRoot()
        if r < release { return nil }
        if current == nil && r < select { return nil }
        let angle = Self.angle(x: x, y: y)
        guard let best = filled.min(by: { Self.gap(angle, $0) < Self.gap(angle, $1) }) else { return nil }
        if let current, filled.contains(current), Self.gap(angle, current) <= Self.gap(angle, best) + stickiness { return current }
        return best
    }

    /// Degrees between `angle` and place `p`.
    static func gap(_ angle: Double, _ p: Int) -> Double {
        let d = abs(angle - Double(p) * 45).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    /// Degrees clockwise from straight up (+y is toward you, so up is −y).
    static func angle(x: Double, y: Double) -> Double {
        let a = atan2(x, -y) * 180 / .pi
        return a < 0 ? a + 360 : a
    }
}

/// A hold's ring, while it's in play (inside `GestureMachine.Hold`): picking by place, the
/// release runs what's lit. Nil while a Gestures hold is blind (rolling fires at once).
struct WheelHold: Equatable {
    /// The ring shown: nil the first one, or the place whose More is open.
    var level: Int?
    /// The steps of this ring by place (0 up, clockwise), as `ButtonGesture.steps(level:)` has them.
    var steps: [GestureStep?]
    var eight: Bool
    var geometry: WheelGeometry
    /// The rolled-to point (clamped to `geometry.reach`), from this ring's centre.
    var x = 0.0, y = 0.0
    /// The farthest the ball got from where the hold started (unclamped), for the tap.
    var travel = 0.0
    var rawX = 0.0, rawY = 0.0
    /// The place lit now.
    var selected: Int?
    /// The ring is drawn (`revealDelay` after the press, a roll past the slop or a ring turn,
    /// for Right away; at once for After a pause and More).
    var revealed = false
    /// Esc or another button: nothing runs, and the ring goes away until the release.
    var dismissed = false
    /// A lit place that repeats as you roll ("Repeats as you roll"): how far the ball has rolled
    /// its way since it last fired. It fired when it lit, then every `GestureTuning.step`.
    var runProgress = 0.0
    var running: Int?

    /// The ring appears this long after the press if nothing else brought it up (Right away).
    static let revealDelay = 0.18

    /// Where a More ring's way back is: opposite the More that opened it.
    var back: Int? { level.map { ($0 + 4) % 8 } }

    /// The places in use: 0, 2, 4, 6 with four; all eight with eight.
    var usedPlaces: [Int] { eight ? Array(0..<8) : [0, 2, 4, 6] }

    /// The places the ball can light: what fires or opens More, and a More ring's way back.
    var selectable: [Int] {
        usedPlaces.filter { p in p == back || (steps.indices.contains(p) && steps[p]?.isUsable == true) }
    }
}

/// What the ring's overlay shows (`EngineIO.showWheel`), made fresh on each change.
struct WheelOverlayModel: Equatable {
    /// What each place shows, clockwise from up (nil: empty or not in use).
    var slots: [Slot?]
    var eight: Bool
    /// A More ring (drawn a little smaller), and its way back.
    var sub = false
    /// Whether the ring itself shows (false: only the ring job's readout, for a blind hold).
    var showsRing = true
    /// The place lit in the ball's blue.
    var selected: Int?
    /// Where the ball has rolled to, -1…1 of the ring's reach each way (+y down), in steps
    /// of 1/16 so a slow roll doesn't redraw it for every count.
    var dot: CGPoint
    /// The ring job's readout, once the ring has been turned this hold.
    var ring: RingReadout?

    enum Slot: Equatable {
        case action(ButtonAction)
        /// Opens More.
        case more
        /// A More ring's way back to the first one.
        case back
    }

    struct RingReadout: Equatable {
        var job: RingJob
        var clockwise: Bool
        /// Changes with every step, so the readout can pulse.
        var steps: Int
    }

    var usedPlaces: [Int] { eight ? Array(0..<8) : [0, 2, 4, 6] }
    /// The places that can light.
    var selectable: [Int] { usedPlaces.filter { slots.indices.contains($0) && slots[$0] != nil } }
}

extension WheelHold {
    /// The ring as it should look now; nil while it's hidden.
    func overlay(readout: WheelOverlayModel.RingReadout?) -> WheelOverlayModel? {
        guard revealed, !dismissed else { return nil }
        let q = 16.0
        func step(_ v: Double) -> CGFloat { CGFloat((max(-1, min(1, v / geometry.reach)) * q).rounded() / q) }
        let slots: [WheelOverlayModel.Slot?] = (0..<8).map { p in
            guard usedPlaces.contains(p) else { return nil }
            if p == back { return .back }
            guard let s = steps.indices.contains(p) ? steps[p] : nil else { return nil }
            if s.isMore { return .more }
            return s.firable.map { _ in .action(s.action) }
        }
        return WheelOverlayModel(slots: slots, eight: eight, sub: level != nil, showsRing: true, selected: selected,
                                 dot: CGPoint(x: step(x), y: step(y)), ring: readout)
    }
}

extension WheelOverlayModel {
    /// The ring a hold of `gesture` shows at `level` (nil: the first ring), lit and turned as
    /// given: for pictures (render-ui) and the simulators.
    static func of(_ gesture: ButtonGesture, level: Int?, selected: Int?, dot: CGPoint, ring: RingReadout?) -> WheelOverlayModel {
        var w = WheelHold(level: level, steps: gesture.steps(level: level), eight: gesture.eight, geometry: WheelGeometry(GestureTuning()))
        w.revealed = true
        w.selected = selected
        var m = w.overlay(readout: ring) ?? WheelOverlayModel(slots: [], eight: gesture.eight, dot: .zero)
        m.dot = dot
        return m
    }
}

/// Draws the ring's overlay (the app's `WheelOverlayPanel`). Main thread only.
protocol WheelPresenting: AnyObject {
    /// Shows the ring centred on `point` (global Quartz coordinates), or updates it.
    func showWheel(_ model: WheelOverlayModel, at point: CGPoint)
    func hideWheel()
}
