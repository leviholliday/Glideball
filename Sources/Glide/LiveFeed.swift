import Observation
import QuartzCore
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

    /// Redraws per second for the idle trackball's slow drift of inner light; 0 holds it still.
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
/// and pauses entirely once nothing is moving. Only `isActive` and `interval` are observed.
@Observable
final class LiveFeed {
    /// Something is moving, or its trace hasn't scrolled off the graphs yet.
    private(set) var isActive = false
    /// Seconds between samples, and so between redraws.
    private(set) var interval = 1.0 / 20

    /// The light the hand makes (the "afterglow engine"). Samples and clicks bump a
    /// few values (blue for rolling, pink for the ring, amber for a click); they hold
    /// while the input keeps coming and then decay on their own, back to dark within
    /// about half a second. `lightAwake` (the only observed part) is true from the
    /// first bump until everything has decayed, so the views that draw the light run
    /// a timeline only then, and an idle trackball costs nothing.
    private(set) var lightAwake = false
    @ObservationIgnored private var light = LightField()
    @ObservationIgnored private var sleepWork: DispatchWorkItem?
    /// Renders hold the light where the last sample left it (no clock in a picture).
    @ObservationIgnored var lightClockFrozen = false

    @ObservationIgnored private(set) var ballSpeed = 0.0        // inches / second
    @ObservationIgnored private(set) var notchRate = 0.0        // ring notches / second
    /// Which way the ball is rolling (inches / second; + = right, + = toward you).
    @ObservationIgnored private(set) var rollX = 0.0
    @ObservationIgnored private(set) var rollY = 0.0
    /// The ring's turn, signed (notches / second; + = clockwise as you look down at it).
    @ObservationIgnored private(set) var ringVelocity = 0.0
    @ObservationIgnored private var angle = 0.0                  // ring rotation, degrees
    @ObservationIgnored private var phase = 0.0                  // ball's inner light, radians
    @ObservationIgnored private var stamp = CACurrentMediaTime()
    @ObservationIgnored private var history: [(ball: Double, notch: Double)]
    @ObservationIgnored private var head = 0                     // oldest entry
    @ObservationIgnored private var nonZero = 0
    @ObservationIgnored private var quietTicks = 0

    /// The graphs always show this many seconds, whatever the sample rate.
    static let historySeconds = 8.0

    init() {
        history = Array(repeating: (0, 0), count: Int(Self.historySeconds * 20))
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

        ballSpeed = ball
        notchRate = notch
        self.rollX = rollX
        self.rollY = rollY
        self.ringVelocity = ringVelocity ?? notch
        angle += self.ringVelocity * 9 * dt
        phase += ball * 0.9 * dt
        stamp = CACurrentMediaTime()

        // A gentle curve, so a slow roll already warms the room.
        func level(_ v: Double, full: Double) -> Double { min(1, (max(v, 0) / full).squareRoot()) }
        let b = level(ball, full: 4), r = level(notch, full: 24)
        if b > 0.02 || r > 0.02 {
            light.bump(ball: b, ring: r, roll: CGVector(dx: rollX, dy: rollY), ringSign: self.ringVelocity >= 0 ? 1 : -1,
                       hold: newInterval * 1.6, at: stamp)
            wake()
        }

        // Stay active until the trace has left the graphs, plus a couple of ticks so the
        // last drawn frame is the resting one.
        quietTicks = nonZero > 0 ? 0 : quietTicks + 1
        let active = nonZero > 0 || quietTicks <= 2
        if active != isActive { isActive = active }
    }

    /// A button was clicked since the last sample: an amber flash.
    func pulseClick() {
        light.bumpAmber(at: CACurrentMediaTime())
        wake()
    }

    /// The light right now (decayed since the last bump).
    func lightLevels(at now: CFTimeInterval = CACurrentMediaTime()) -> LightField.Levels {
        light.levels(at: lightClockFrozen ? light.lastBump : now)
    }

    /// Keeps `lightAwake` true until the last bump has fully decayed, then lets it sleep.
    private func wake() {
        if !lightAwake { lightAwake = true }
        sleepWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.lightClockFrozen else { return }
            if self.light.isDark(at: CACurrentMediaTime()) { self.lightAwake = false } else { self.wake() }
        }
        sleepWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LightField.settleTime, execute: work)
    }

    /// Puts the light out at once (renders, a reset).
    func darkenLight() {
        sleepWork?.cancel()
        light = LightField()
        if lightAwake { lightAwake = false }
    }

    /// Ring angle (degrees) now, carried on from the last sample so motion looks smooth
    /// between samples.
    func ringAngle(at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        angle + ringVelocity * 9 * min(max(now - stamp, 0), 0.25)
    }

    func ballPhase(at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        phase + ballSpeed * 0.9 * min(max(now - stamp, 0), 0.25)
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
    func reset() {
        for i in 0..<history.count { history[i] = (0, 0) }
        nonZero = 0
        ballSpeed = 0
        notchRate = 0
        rollX = 0
        rollY = 0
        ringVelocity = 0
        darkenLight()
        if isActive { isActive = false }
    }
}

/// A handful of light values bumped by input, each holding while input keeps
/// coming and then decaying exponentially. Pure arithmetic: nothing runs between
/// reads.
struct LightField {
    struct Levels {
        var ball = 0.0, ring = 0.0, amber = 0.0
        /// Which way the ball last rolled (unit vector; +x right, +y toward you).
        var roll = CGVector.zero
        /// Which way the ring last turned (+1 clockwise).
        var ringSign = 1.0
        var isDark: Bool { ball < 0.004 && ring < 0.004 && amber < 0.004 }
    }

    /// Decay time constants: the ring coasts a little longer than the ball, a click is a flash.
    static let tauBall = 0.15, tauRing = 0.2, tauAmber = 0.12
    /// Longest it can take to go dark after the last bump (hold + decay to ~0.4%), plus a little.
    static let settleTime = 1.3

    private var ball = 0.0, ring = 0.0, amber = 0.0
    private var ballAt = 0.0, ringAt = 0.0, amberAt = 0.0
    private var holdBall = 0.0, holdRing = 0.0
    private var roll = CGVector.zero
    private var ringSign = 1.0
    private(set) var lastBump = 0.0

    private static func decay(_ v: Double, from t0: Double, hold: Double, tau: Double, at t: Double) -> Double {
        let dt = t - t0 - hold
        return dt <= 0 ? v : v * exp(-dt / tau)
    }

    mutating func bump(ball b: Double, ring r: Double, roll dir: CGVector, ringSign sign: Double, hold: Double, at t: Double) {
        let curBall = Self.decay(ball, from: ballAt, hold: holdBall, tau: Self.tauBall, at: t)
        let curRing = Self.decay(ring, from: ringAt, hold: holdRing, tau: Self.tauRing, at: t)
        // Rising input takes over at once; falling input lets the light coast down at its own pace.
        // (A steady slower input catches up again once the light has decayed to it.)
        if b >= curBall && b > 0.02 { ball = b; ballAt = t; holdBall = hold }
        if r >= curRing && r > 0.02 { ring = r; ringAt = t; holdRing = hold }
        let len = (dir.dx * dir.dx + dir.dy * dir.dy).squareRoot()
        if len > 0.05 { roll = CGVector(dx: dir.dx / len, dy: dir.dy / len) }
        if r > 0.02 { ringSign = sign }
        lastBump = t
    }

    mutating func bumpAmber(at t: Double) {
        amber = 1
        amberAt = t
        lastBump = t
    }

    func levels(at t: Double) -> Levels {
        Levels(ball: Self.decay(ball, from: ballAt, hold: holdBall, tau: Self.tauBall, at: t),
               ring: Self.decay(ring, from: ringAt, hold: holdRing, tau: Self.tauRing, at: t),
               amber: Self.decay(amber, from: amberAt, hold: 0.05, tau: Self.tauAmber, at: t),
               roll: roll, ringSign: ringSign)
    }

    func isDark(at t: Double) -> Bool { levels(at: t).isDark }
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
