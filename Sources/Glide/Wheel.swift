import CoreGraphics
import Foundation

// The Wheel: hold a button (or a combo) and a ring of slots appears around the pointer.
// The ball picks a slot, letting go runs it; the scroll ring does the Wheel's ring job
// while it's held; a quick press does the tap. This file is the Wheel's half of the
// decision (where the ball has "rolled" to, which slot that lights, when the ring
// appears); `GestureMachine` (Gestures.swift) owns the hold itself, so a Wheel hold
// starts, freezes the pointer and ends exactly the way a gesture hold does, by every path.
//
// Foundation and CoreGraphics only, on purpose: scripts/gesture-sim and
// scripts/engine-fuzz compile this file.

/// The numbers behind picking a slot, in raw ball counts (about 16 counts per mm).
struct WheelGeometry: Equatable {
    /// Past this far from the centre a slot lights (about 2 mm with Normal distance).
    var select: Double
    /// Back inside this, nothing is lit: rolling back to the centre cancels.
    var release: Double
    /// The rolled-to point never goes further than this from the centre, so rolling the
    /// other way comes back at once however far the ball went.
    var reach: Double
    /// A lit slot stays lit until another one is this much closer (degrees), so a roll
    /// right along the border between two slots doesn't flicker between them.
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
    /// two or three filled slots each one is a wide target.
    func pick(x: Double, y: Double, current: Int?, filled: [Int]) -> Int? {
        guard !filled.isEmpty, x.isFinite, y.isFinite else { return nil }
        let r = (x * x + y * y).squareRoot()
        if r < release { return nil }
        if current == nil && r < select { return nil }
        let angle = Self.angle(x: x, y: y)
        func gap(_ p: Int) -> Double {
            let d = abs(angle - Double(p) * 45).truncatingRemainder(dividingBy: 360)
            return min(d, 360 - d)
        }
        guard let best = filled.min(by: { gap($0) < gap($1) }) else { return nil }
        if let current, filled.contains(current), gap(current) <= gap(best) + stickiness { return current }
        return best
    }

    /// Degrees clockwise from straight up (+y is toward you, so up is −y).
    static func angle(x: Double, y: Double) -> Double {
        let a = atan2(x, -y) * 180 / .pi
        return a < 0 ? a + 360 : a
    }
}

/// A Wheel hold's own state, inside `GestureMachine.Hold`.
struct WheelHold: Equatable {
    var menu: WheelMenu
    var geometry: WheelGeometry
    /// The rolled-to point (clamped to `geometry.reach`).
    var x = 0.0, y = 0.0
    /// The farthest the ball got from where it started (unclamped), for the tap.
    var travel = 0.0
    var rawX = 0.0, rawY = 0.0
    /// The place lit now.
    var selected: Int?
    /// The ring appeared (after `revealDelay`, a roll past the slop, or a ring turn).
    var revealed = false
    /// The ring was turned during the hold: its release runs no tap.
    var ringUsed = false
    var ringSteps = 0
    var lastRingStep = -Double.infinity
    var lastRingClockwise: Bool?
    /// Esc or another button: nothing runs, and the ring goes away until the release.
    var dismissed = false

    /// The ring appears this long after the press if nothing else brought it up.
    static let revealDelay = 0.18
}

/// What the Wheel's overlay shows (`EngineIO.showWheel`), made fresh on each change.
struct WheelOverlayModel: Equatable {
    var menu: WheelMenu
    /// The place lit in the ball's blue.
    var selected: Int?
    /// Where the ball has rolled to, -1…1 of the ring's reach each way (+y down), in steps
    /// of 1/16 so a slow roll doesn't redraw it for every count.
    var dot: CGPoint
    /// The ring job's readout, once the ring has been turned this hold.
    var ring: RingReadout?

    struct RingReadout: Equatable {
        var job: RingJob
        var clockwise: Bool
        /// Changes with every step, so the readout can pulse.
        var steps: Int
    }
}

extension WheelHold {
    /// The overlay as it should look now; nil while it's hidden.
    var overlay: WheelOverlayModel? {
        guard revealed, !dismissed else { return nil }
        let q = 16.0
        func step(_ v: Double) -> CGFloat { CGFloat((max(-1, min(1, v / geometry.reach)) * q).rounded() / q) }
        let readout = ringUsed ? lastRingClockwise.map { WheelOverlayModel.RingReadout(job: menu.ring, clockwise: $0, steps: ringSteps) } : nil
        return WheelOverlayModel(menu: menu, selected: selected, dot: CGPoint(x: step(x), y: step(y)), ring: readout)
    }
}

/// Draws the Wheel's overlay (the app's `WheelOverlayPanel`). Main thread only.
protocol WheelPresenting: AnyObject {
    /// Shows the ring centred on `point` (global Quartz coordinates), or updates it.
    func showWheel(_ model: WheelOverlayModel, at point: CGPoint)
    func hideWheel()
}
