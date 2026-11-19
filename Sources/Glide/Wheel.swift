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

    init(_ t: GestureTuning, careful: Bool = false) {
        tapSlop = t.tapSlop
        select = max(t.commit * 0.75, t.tapSlop + 12)
        release = min(t.tapSlop * 1.25, select - 8)
        reach = select * 2.5
        if careful {
            // A More's ring, or the first ring after Back: a choice needs a longer roll from the
            // middle, so the hand settling (or a roll that's still on its way) lights nothing.
            let base = select
            select = base * WheelHold.carefulScale
            release = min(release * WheelHold.carefulScale, select - 8)
            reach = max(reach, select * 1.8)
        }
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
    /// A ring that just opened (More) or came back (Back) starts in the middle with nothing lit,
    /// and the roll that brought it there can't carry on into it (Levi, beta 30: rolling into a
    /// More on the right ran the sub ring's right; rolling back to Back ran the first ring's left).
    /// Until it's armed the ball moves nothing: for `settle` all movement is ignored; after that it
    /// arms once the ball has been at rest for `restToArm`, or has rolled `armTurn` × the tap slop in
    /// a clearly different way from the one it came in by (more than `entryCone` off it). Rolling on
    /// the way it came is ignored until a rest, so going on that way needs a deliberate pause.
    var armed = true
    var settleUntil = -Double.infinity
    /// The way the roll came in (a unit vector, +y toward you), and the roll since the settle.
    var entryX = 0.0, entryY = 0.0
    var probeX = 0.0, probeY = 0.0
    /// A More's ring, or the first ring after Back (beta 32): a choice needs `carefulScale` times
    /// the usual roll from the middle, and a place that repeats as you roll only lights at first;
    /// it starts once you roll on its way a step, or stay on it for `repeatDwell`.
    var careful = false
    /// When the lit place lit (for a More or Back to open, or a careful repeat to start, by dwelling).
    var litSince = -Double.infinity
    /// A careful ring's repeating place has started (fired once since it lit).
    var runStarted = false
    /// Never shown until a More opens (a blind hold, Show the ring: Never, that rolled into a More).
    var quiet = false

    /// The ring appears this long after the press if nothing else brought it up (Right away).
    static let revealDelay = 0.18

    // How More and Back behave (beta 32, Levi on beta 31: "way too eager", "a little jumpy").
    // All tunable here; docs/DEVELOPING.md says the same in words.
    /// Lighting More (or Back) only lights it. It opens once it has stayed lit this long...
    static let confirmDwell = 0.35
    /// ...or at once if the roll goes on out to this share of the ring's reach (a longer roll).
    static let pushFraction = 0.9
    /// A careful ring's distances, times the first ring's.
    static let carefulScale = 1.5
    /// A careful ring's repeating place starts after this long lit, if the roll hasn't started it.
    static let repeatDwell = 0.3
    /// A ring that just opened or came back ignores all movement for this long...
    static let settle = 0.2
    /// ...then arms once the ball has been at rest this long...
    static let restToArm = 0.12
    /// ...or has rolled `armTurn` × the tap slop more than `entryCone` degrees off the way it came in.
    static let entryCone = 60.0
    static let armTurn = 2.0

    /// Where a More ring's way back is: opposite the More that opened it.
    var back: Int? { level.map { ($0 + 4) % 8 } }

    /// The places in use: 0, 2, 4, 6 with four; all eight with eight.
    var usedPlaces: [Int] { eight ? Array(0..<8) : [0, 2, 4, 6] }

    /// Starts this ring unarmed, centred, nothing lit, having come in from `place`'s way.
    mutating func settle(cameFrom place: Int, now: Double) {
        armed = false
        settleUntil = now + Self.settle
        let v = GestureDirection(place: place).vector
        entryX = v.x
        entryY = v.y
        probeX = 0
        probeY = 0
        x = 0
        y = 0
        selected = nil
        running = nil
        runStarted = false
        litSince = -.infinity
    }

    /// Whether place `p` opens something rather than running it: a More (first ring) or the way back.
    func opens(_ p: Int) -> Bool {
        p == back || (level == nil && steps.indices.contains(p) && steps[p]?.isMore == true)
    }

    /// The lit More or Back has been confirmed: it stayed lit `confirmDwell`, or the roll went on out
    /// to `pushFraction` of the reach.
    func confirmed(now: Double) -> Bool {
        guard armed, let s = selected, opens(s) else { return false }
        return now - litSince >= Self.confirmDwell || (x * x + y * y).squareRoot() >= geometry.reach * Self.pushFraction
    }

    /// Something only time can bring: a ring settling, a lit More or Back waiting to open, a careful
    /// ring's repeating place waiting to start. The engine looks every 50 ms while it's so.
    var waiting: Bool {
        guard !dismissed else { return false }
        if !armed { return true }
        guard let s = selected else { return false }
        return opens(s) || (careful && running == s && !runStarted)
    }

    /// Arms the ring by time alone: the settle is over and the ball has been at rest (`quietFor`).
    mutating func armIfRested(quietFor: Double, now: Double) {
        guard !armed, now >= settleUntil, quietFor >= Self.restToArm else { return }
        armed = true
        x = 0
        y = 0
    }

    /// Movement (dx, dy) while unarmed. True once the ring is armed, with the point placed so
    /// that this movement can be added to it as usual; false while it's still settling.
    mutating func arm(dx: Double, dy: Double, quietFor: Double, now: Double) -> Bool {
        if now < settleUntil {
            probeX = 0
            probeY = 0
            return false
        }
        if quietFor >= Self.restToArm {
            // The hand came to rest: this movement starts fresh from the centre.
            armed = true
            x = 0
            y = 0
            return true
        }
        probeX += dx
        probeY += dy
        let r = (probeX * probeX + probeY * probeY).squareRoot()
        guard r >= geometry.tapSlop * Self.armTurn else { return false }
        if (probeX * entryX + probeY * entryY) / r > cos(Self.entryCone * .pi / 180) {
            // Still the roll that brought the ring here: ignored.
            probeX = 0
            probeY = 0
            return false
        }
        // A clear turn: the ring is armed and the turn so far counts.
        armed = true
        x = probeX - dx
        y = probeY - dy
        probeX = 0
        probeY = 0
        return true
    }

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
    /// A ring that just opened or came back and can't light anything yet (`WheelHold.armed`).
    var settling = false
    /// A More's ring: the place of the More that opened it (its chips grow out of that chip, and
    /// shrink back into it on Back), and the first ring's slots, drawn dimmed behind it.
    var level: Int?
    var behind: [Slot?]?
    /// The lit place is a More or Back that opens once it has stayed lit `WheelHold.confirmDwell`
    /// (the chip fills up meanwhile).
    var opening: Int?
    /// Counts each run of a repeating place this hold, so its chip can pulse.
    var pulse = 0
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
    /// The ring as it should look now; nil while it's hidden. `first`: the first ring's steps, drawn
    /// behind a More's ring.
    func overlay(readout: WheelOverlayModel.RingReadout?, first: [GestureStep?]? = nil, pulse: Int = 0) -> WheelOverlayModel? {
        guard revealed, !dismissed, !quiet else { return nil }
        let q = 16.0
        func step(_ v: Double) -> CGFloat { CGFloat((max(-1, min(1, v / geometry.reach)) * q).rounded() / q) }
        var m = WheelOverlayModel(slots: Self.slots(steps, eight: eight, back: back), eight: eight, sub: level != nil, showsRing: true,
                                  selected: selected, settling: !armed, dot: CGPoint(x: step(x), y: step(y)), ring: readout)
        m.level = level
        if level != nil, let first { m.behind = Self.slots(first, eight: eight, back: nil) }
        if armed, let s = selected, opens(s) { m.opening = s }
        m.pulse = pulse
        return m
    }

    /// What each place shows, for a ring of `steps` (with its way back at `back`).
    static func slots(_ steps: [GestureStep?], eight: Bool, back: Int?) -> [WheelOverlayModel.Slot?] {
        let used = eight ? Array(0..<8) : [0, 2, 4, 6]
        return (0..<8).map { p in
            guard used.contains(p) else { return nil }
            if p == back { return .back }
            guard let s = steps.indices.contains(p) ? steps[p] : nil else { return nil }
            if s.isMore { return .more }
            return s.firable.map { _ in .action(s.action) }
        }
    }
}

extension WheelOverlayModel {
    /// The ring a hold of `gesture` shows at `level` (nil: the first ring), lit and turned as
    /// given: for pictures (render-ui) and the simulators.
    static func of(_ gesture: ButtonGesture, level: Int?, selected: Int?, dot: CGPoint, ring: RingReadout?) -> WheelOverlayModel {
        var w = WheelHold(level: level, steps: gesture.steps(level: level), eight: gesture.eight, geometry: WheelGeometry(GestureTuning()))
        w.revealed = true
        w.selected = selected
        var m = w.overlay(readout: ring, first: gesture.steps(level: nil)) ?? WheelOverlayModel(slots: [], eight: gesture.eight, dot: .zero)
        m.dot = dot
        return m
    }
}

/// Draws the ring's overlay (the app's `WheelOverlayPanel`). Main thread only.
protocol WheelPresenting: AnyObject {
    /// Shows the ring centred on `point` (global Quartz coordinates), or updates it.
    func showWheel(_ model: WheelOverlayModel, at point: CGPoint)
    func hideWheel()
    /// The release ran the place lit at `place` (its chip pulses as the ring goes).
    func wheelRan(place: Int)
}
