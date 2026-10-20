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

    /// Redraws per second for the slowly drifting background; 0 holds it still.
    /// (Measured: 1–2 a second is free, but around 6 a second costs a third of a CPU core,
    /// because every redraw re-renders the glass on top — so Efficient stays at 2.)
    func backgroundFPS(windowIsKey: Bool, deviceConnected: Bool) -> Double {
        guard deviceConnected else { return 0 }
        return switch self {
        case .smooth: 20
        case .efficient: windowIsKey ? 2 : 0
        case .minimal: 0
        }
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

    @ObservationIgnored private(set) var ballSpeed = 0.0        // inches / second
    @ObservationIgnored private(set) var notchRate = 0.0        // ring notches / second
    @ObservationIgnored private var angle = 0.0                  // ring rotation, degrees
    @ObservationIgnored private var phase = 0.0                  // ball highlight drift
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
    func push(ball: Double, notch: Double, dt: Double, interval newInterval: Double) {
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
        angle += notch * 9 * dt
        phase += ball * 1.4 * dt
        stamp = CACurrentMediaTime()

        // Stay active until the trace has left the graphs, plus a couple of ticks so the
        // last drawn frame is the resting one.
        quietTicks = nonZero > 0 ? 0 : quietTicks + 1
        let active = nonZero > 0 || quietTicks <= 2
        if active != isActive { isActive = active }
    }

    /// Ring angle (degrees) now, carried on from the last sample so motion looks smooth
    /// between samples.
    func ringAngle(at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        angle + notchRate * 9 * min(max(now - stamp, 0), 0.25)
    }

    func ballPhase(at now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        phase + ballSpeed * 1.4 * min(max(now - stamp, 0), 0.25)
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
        if isActive { isActive = false }
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
