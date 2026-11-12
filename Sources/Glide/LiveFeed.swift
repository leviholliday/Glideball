import Observation
import QuartzCore
import simd
import SwiftUI

/// How much Glideball animates its window. Per-Mac; the input handling never changes.
enum PerformanceMode: String, CaseIterable, Identifiable {
    case smooth, efficient, minimal
    var id: String { rawValue }

    static let defaultsKey = "GlidePerformance"
    static var saved: PerformanceMode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(PerformanceMode.init) ?? .efficient
    }

    var title: String {
        switch self {
        case .smooth: String(localized: "Smoothest", comment: "Performance mode: animate the window at full rate")
        case .efficient: String(localized: "Efficient", comment: "Performance mode: easy on the CPU")
        case .minimal: String(localized: "Minimal", comment: "Performance mode: almost nothing animates")
        }
    }

    /// Seconds between live-graph samples (and redraws) while the window is visible.
    /// With no trackball connected there's nothing to graph, so the window just idles.
    func sampleInterval(windowIsKey: Bool, deviceConnected: Bool) -> Double {
        guard deviceConnected else { return 1 }
        return switch self {
        case .smooth: 1.0 / 30
        case .efficient: windowIsKey ? 1.0 / 20 : 1.0 / 8
        case .minimal: windowIsKey ? 1.0 / 5 : 1.0 / 2
        }
    }

    /// Redraws per second for the idle trackball's slow drift; 0 holds it still.
    /// Only Smoothest drifts at all (a few frames a second is plenty for something that slow),
    /// and only while the window is the one in use with a trackball connected.
    func idleDriftFPS(windowIsKey: Bool, deviceConnected: Bool) -> Double {
        guard deviceConnected, windowIsKey else { return 0 }
        return self == .smooth ? 12 : 0
    }
}

/// The window's fast-changing live readings: ball speed, ring rate, and the graph history.
///
/// These change dozens of times a second. Publishing each change through the observable
/// `AppModel` made SwiftUI re-evaluate whole screens every time — most of the app's CPU use.
/// So this is read only from inside `LiveTimeline`, which redraws just the one animated view,
/// and pauses entirely once nothing is moving. Only `isActive`, `interval` and `lightAwake`
/// are observed.
///
/// It also keeps the picture's physics: which way the drawn ball is turned (rolled
/// exactly the way the real ball rolls, with a little momentum so it coasts to a
/// stop, `BallSpin`) and how far the drawn ring has turned.
@Observable
final class LiveFeed {
    /// Something is moving, or its trace hasn't scrolled off the graphs yet.
    private(set) var isActive = false
    /// Seconds between samples, and so between redraws.
    private(set) var interval = 1.0 / 20

    /// The light the hand makes (`LightField`). It swells with the input (about
    /// 120 ms) and breathes out slowly (most of it gone in about 0.9 s).
    /// `lightAwake` (observed) is true while any of it is lit, so the views that
    /// draw the light run a timeline only then, and an idle trackball costs nothing.
    private(set) var lightAwake = false
    @ObservationIgnored private var light = LightField()
    /// Renders hold the light where the last sample left it (no clock in a picture).
    @ObservationIgnored var lightClockFrozen = false
    /// How bright the hand's light gets, 0…1 (`AppModel.lightIntensity`).
    @ObservationIgnored var lightIntensity = AppModel.defaultLightIntensity {
        didSet { light.gain = LightField.gain(for: lightIntensity) }
    }

    @ObservationIgnored private(set) var ballSpeed = 0.0        // inches / second
    @ObservationIgnored private(set) var notchRate = 0.0        // ring notches / second
    /// Which way the ball is rolling (inches / second; + = right, + = toward you).
    @ObservationIgnored private(set) var rollX = 0.0
    @ObservationIgnored private(set) var rollY = 0.0
    /// The ring's turn, signed (notches / second; + = clockwise as you look down at it).
    @ObservationIgnored private(set) var ringVelocity = 0.0
    /// How fast the drawn ring turns (degrees / second): the real turn, capped so it never looks frantic.
    @ObservationIgnored private var ringDegreesPerSecond = 0.0
    @ObservationIgnored private var angle = 0.0                  // ring rotation, degrees
    /// The drawn ball's turn, and how fast it's turning (radians / second, view space).
    @ObservationIgnored private var orientation = BallSpin.identity
    @ObservationIgnored private(set) var spin = SIMD3<Double>.zero
    @ObservationIgnored private var stamp = CACurrentMediaTime()
    @ObservationIgnored private var history: [(ball: Double, notch: Double)]
    @ObservationIgnored private var head = 0                     // oldest entry
    @ObservationIgnored private var nonZero = 0
    @ObservationIgnored private var quietTicks = 0

    /// The graphs always show this many seconds, whatever the sample rate.
    static let historySeconds = 8.0

    init() {
        history = Array(repeating: (0, 0), count: Int(Self.historySeconds * 20))
        light.gain = LightField.gain(for: lightIntensity)
    }

    /// Records one sample. `dt` is the time since the last one.
    func push(ball: Double, notch: Double, rollX: Double = 0, rollY: Double = 0, ringVelocity: Double? = nil,
              dt: Double, interval newInterval: Double) {
        let capacity = max(Int(Self.historySeconds / newInterval), 16)
        if capacity != history.count { resize(to: capacity) }
        if interval != newInterval { interval = newInterval }

        let old = history[head]
        if old.ball > 0 || old.notch > 0 { nonZero -= 1 }
        history[head] = (ball, notch)
        head = (head + 1) % history.count
        if ball > 0 || notch > 0 { nonZero += 1 }

        let step = min(max(dt, 0), 0.25)
        // Carry the picture on to now with the motion it had (what was on screen), then take the new motion.
        angle = (angle + ringDegreesPerSecond * step).truncatingRemainder(dividingBy: 360)
        orientation = BallSpin.turned(orientation, by: spin * step)
        spin = BallSpin.follow(spin, toward: BallSpin.target(rollX: rollX, rollY: rollY), dt: step)
        ringDegreesPerSecond = Self.cappedRing(ringVelocity ?? notch)

        ballSpeed = ball
        notchRate = notch
        self.rollX = rollX
        self.rollY = rollY
        self.ringVelocity = ringVelocity ?? notch
        stamp = CACurrentMediaTime()

        // A gentle curve, so a slow roll already warms the room.
        func level(_ v: Double, full: Double) -> Double { min(1, (max(v, 0) / full).squareRoot()) }
        light.update(ball: level(ball, full: 4), ring: level(notch, full: 24),
                     roll: CGVector(dx: rollX, dy: rollY), ringSign: self.ringVelocity >= 0 ? 1 : -1,
                     dt: step, at: stamp)
        updateAwake()

        // Stay active until the trace has left the graphs, plus a couple of ticks so the
        // last drawn frame is the resting one.
        quietTicks = nonZero > 0 ? 0 : quietTicks + 1
        let active = nonZero > 0 || quietTicks <= 2
        if active != isActive { isActive = active }
    }

    /// The ring's drawn speed (degrees / second): 9° a notch, softly capped at 240°/s.
    static func cappedRing(_ notchesPerSecond: Double) -> Double {
        let raw = notchesPerSecond * 9, cap = 240.0
        return cap * tanh(raw / cap)
    }

    /// A button was clicked since the last sample: a soft amber swell.
    func pulseClick() {
        light.pulseAmber(at: CACurrentMediaTime())
        updateAwake()
    }

    /// The light right now (carried on from the last sample).
    func lightLevels(at now: CFTimeInterval = CACurrentMediaTime()) -> LightField.Levels {
        light.levels(at: lightClockFrozen ? light.stamp : now)
    }

    /// Awake while anything is lit; asleep (no timelines) once it's all dark. Samples
    /// keep coming while the window shows, so this is checked often enough.
    private func updateAwake() {
        let awake = lightClockFrozen ? !light.levels(at: light.stamp).isDark : !light.isSettled(at: CACurrentMediaTime())
        if awake != lightAwake { lightAwake = awake }
    }

    /// Puts the light out at once (renders, a reset).
    func darkenLight() {
        let gain = light.gain
        light = LightField()
        light.gain = gain
        if lightAwake { lightAwake = false }
    }

    /// Ring angle (degrees) now, carried on from the last sample so motion looks smooth
    /// between samples.
    func ringAngle(at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        angle + ringDegreesPerSecond * (lightClockFrozen ? 0 : min(max(now - stamp, 0), 0.25))
    }

    /// The drawn ball's turn now, carried on from the last sample.
    func ballOrientation(at now: CFTimeInterval = CACurrentMediaTime()) -> BallSpin.Quaternion {
        let since = lightClockFrozen ? 0 : min(max(now - stamp, 0), 0.25)
        return BallSpin.turned(orientation, by: spin * since)
    }

    /// Oldest first, for the graphs.
    var ballHistory: [Double] { ordered(\.ball) }
    var notchHistory: [Double] { ordered(\.notch) }

    private func ordered(_ key: KeyPath<(ball: Double, notch: Double), Double>) -> [Double] {
        var out = [Double]()
        out.reserveCapacity(history.count)
        for i in 0..<history.count { out.append(history[(head + i) % history.count][keyPath: key]) }
        return out
    }

    private func resize(to capacity: Int) {
        let current = (0..<history.count).map { history[(head + $0) % history.count] }
        history = current.count >= capacity
            ? Array(current.suffix(capacity))
            : Array(repeating: (0, 0), count: capacity - current.count) + current
        head = 0
        nonZero = history.reduce(0) { $0 + ($1.ball > 0 || $1.notch > 0 ? 1 : 0) }
    }

    /// Forgets everything (a new day's reset, or the window coming back after a long time).
    /// The ball keeps the way it's turned: it's the same ball when the window comes back.
    func reset() {
        for i in 0..<history.count { history[i] = (0, 0) }
        nonZero = 0
        ballSpeed = 0
        notchRate = 0
        rollX = 0
        rollY = 0
        ringVelocity = 0
        ringDegreesPerSecond = 0
        spin = .zero
        darkenLight()
        if isActive { isActive = false }
    }
}

/// The drawn ball's physics: a real sphere, turned by a quaternion.
///
/// The real ball's surface moves under your hand at the speed the sensor reads
/// (inches a second), so it turns at that speed over its radius. The picture
/// turns the same way, so what's on top of the drawn ball travels the way your
/// hand moved it: roll right and its colors go right, roll away from you and
/// they go up. Fast flicks are capped (just under a turn a second) so it never
/// looks frantic, and when you let go it coasts to a stop over a few tenths of
/// a second instead of snapping still.
enum BallSpin {
    typealias Quaternion = simd_quatd

    static let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    /// The Expert Mouse's ball is 55 mm across: 1.08 inches from its center to its surface.
    static let ballRadiusInches = 1.08
    /// Never turn faster than this (radians / second; 5.5 is just under a turn a second).
    static let maxSpin = 5.5
    /// Catching up with the hand (seconds), and coasting down after it.
    static let tauFollow = 0.05, tauCoast = 0.3

    /// How fast the ball turns for a roll (inches / second; + = right, + = toward you).
    /// View space: x right, y up, z out of the screen. Turning about +y carries the
    /// front of the ball to the right; turning about +x carries it down.
    static func target(rollX: Double, rollY: Double) -> SIMD3<Double> {
        let w = SIMD3(rollY, rollX, 0) / ballRadiusInches
        let m = simd_length(w)
        guard m > 1e-6 else { return .zero }
        return w * (maxSpin * tanh(m / maxSpin) / m)
    }

    /// Follows the hand quickly when it speeds up or changes direction, and lets the
    /// ball coast down slowly when it slows or stops.
    static func follow(_ current: SIMD3<Double>, toward target: SIMD3<Double>, dt: Double) -> SIMD3<Double> {
        let cur = simd_length(current), tgt = simd_length(target)
        let speeding = tgt >= cur * 0.98 || simd_dot(target, current) < 0.5 * cur * tgt
        let next = target + (current - target) * exp(-dt / (speeding ? tauFollow : tauCoast))
        return simd_length(next) < 0.02 && tgt == 0 ? .zero : next
    }

    /// `q`, turned further by the rotation vector `r` (axis × radians, view space).
    static func turned(_ q: Quaternion, by r: SIMD3<Double>) -> Quaternion {
        let a = simd_length(r)
        guard a > 1e-9 else { return q }
        return simd_normalize(simd_quatd(angle: a, axis: r / a) * q)
    }

    /// The slow idle drift (Smoothest only): a turn about every 90 seconds, about a tilted axis.
    static func drift(at seconds: Double) -> Quaternion {
        let angle = (seconds * 0.07).truncatingRemainder(dividingBy: 2 * .pi)
        return simd_quatd(angle: angle, axis: simd_normalize(SIMD3(0.35, 1, 0.15)))
    }

    /// The turn after rolling `distance` ball radii along `direction` (+x right, +y down the screen).
    static func rolled(_ distance: Double, direction: CGVector = CGVector(dx: 1, dy: 0)) -> Quaternion {
        turned(identity, by: SIMD3(Double(direction.dy), Double(direction.dx), 0) * distance)
    }
}

/// The hand's light: blue for rolling, pink for the ring, amber for a click.
/// Each channel low-passes its input (so a ring's separate notches blend into
/// one swell that follows the speed), rises toward it over about 120 ms and
/// breathes out slowly (time constant 0.4 s: mostly gone in 0.9 s). Pure
/// arithmetic: nothing runs between reads, which carry the last sample on to
/// the moment asked for.
struct LightField {
    struct Levels {
        var ball = 0.0, ring = 0.0, amber = 0.0
        /// Which way the ball last rolled (unit vector; +x right, +y toward you).
        var roll = CGVector.zero
        /// Which way the ring last turned (+1 clockwise).
        var ringSign = 1.0
        var isDark: Bool { ball < 0.004 && ring < 0.004 && amber < 0.004 }
    }

    /// The input's low-pass, the swell and the fade (seconds).
    static let tauInput = 0.06, tauRise = 0.08, tauFall = 0.4
    /// A click: a soft swell (about 0.1 s to its peak) and a slow fade.
    static let tauAmberIn = 0.05, tauAmberOut = 0.35, amberPeak = 0.55
    /// How bright the light gets at full input and the default intensity (it used to reach 1).
    static let basePeak = 0.7

    /// The light's overall strength for a Light setting of 0…1 (the default gives `basePeak`).
    static func gain(for intensity: Double) -> Double {
        basePeak * min(max(intensity, 0), 1) / AppModel.defaultLightIntensity
    }

    var gain = basePeak
    private var ballIn = 0.0, ringIn = 0.0
    private var ball = 0.0, ring = 0.0
    private var amberBase = 0.0, amberAt = -10.0
    private var roll = CGVector.zero
    private var ringSign = 1.0
    private(set) var stamp = 0.0

    private static func approach(_ v: Double, _ target: Double, _ dt: Double) -> Double {
        target + (v - target) * exp(-max(dt, 0) / (target > v ? tauRise : tauFall))
    }

    /// A click's own curve, `x` seconds after it (peaks at `amberPeak`).
    private static func amberPulse(_ x: Double) -> Double {
        guard x >= 0 else { return 0 }
        // (1 − e^(−x/a)) e^(−x/b) peaks at about 0.65 for a = 0.05, b = 0.35.
        return amberPeak / 0.65 * (1 - exp(-x / tauAmberIn)) * exp(-x / tauAmberOut)
    }

    private func amber(at t: Double) -> Double {
        let x = t - amberAt
        return max(amberBase * exp(-max(x, 0) / Self.tauAmberOut), Self.amberPulse(x))
    }

    mutating func update(ball b: Double, ring r: Double, roll dir: CGVector, ringSign sign: Double, dt: Double, at t: Double) {
        // Carry the light on over this step with the input it had, then take in the new input.
        ball = Self.approach(ball, ballIn, dt)
        ring = Self.approach(ring, ringIn, dt)
        let k = 1 - exp(-dt / Self.tauInput)
        ballIn += (b - ballIn) * k
        ringIn += (r - ringIn) * k
        if ballIn < 0.002 && b == 0 { ballIn = 0 }
        if ringIn < 0.002 && r == 0 { ringIn = 0 }
        let len = (dir.dx * dir.dx + dir.dy * dir.dy).squareRoot()
        if len > 0.05 { roll = CGVector(dx: dir.dx / len, dy: dir.dy / len) }
        if r > 0.02 { ringSign = sign }
        stamp = t
    }

    mutating func pulseAmber(at t: Double) {
        amberBase = amber(at: t)
        amberAt = t
        stamp = max(stamp, t)
    }

    func levels(at t: Double) -> Levels {
        let dt = min(max(t - stamp, 0), 0.5)
        return Levels(ball: Self.approach(ball, ballIn, dt) * gain,
                      ring: Self.approach(ring, ringIn, dt) * gain,
                      amber: amber(at: t) * gain / Self.basePeak,
                      roll: roll, ringSign: ringSign)
    }

    /// Nothing lit and nothing coming in.
    func isSettled(at t: Double) -> Bool {
        ballIn == 0 && ringIn == 0 && levels(at: t).isDark
    }
}

/// Redraws `content` on a timeline while the feed is active, and holds the last frame
/// while it isn't — so an idle trackball costs the window nothing. Only this view is
/// re-evaluated on each tick, never the screen around it.
struct LiveTimeline<Content: View>: View {
    let feed: LiveFeed
    /// Never redraw faster than this many frames a second (heavy views like charts).
    var maxFPS: Double = 60
    @ViewBuilder var content: (LiveFeed, CFTimeInterval) -> Content

    var body: some View {
        TimelineView(.animation(minimumInterval: max(feed.interval, 1 / maxFPS), paused: !feed.isActive)) { _ in
            content(feed, CACurrentMediaTime())
        }
    }
}
