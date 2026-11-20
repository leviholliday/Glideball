import Foundation
import QuartzCore

/// How long the hand waits: measurement only, nothing reads it to decide anything.
///
/// - **To the action.** From a button's press or release, or the ball or ring report that
///   committed a direction, as macOS stamped it, to Glideball having posted what it does (the
///   keys, the click, the media key, the app switch asked for). Combo waits and other designed
///   delays aren't in it: a press that waited for a partner is replayed from a timer and isn't
///   measured.
/// - **To the ring or the Switcher's panel.** From the press to its window being ordered in
///   and its first frame committed to the window server (about a frame before the glass shows
///   it). That includes the designed wait (the ring's 180 ms, the panel's 0.2 s, "After a
///   pause"), so the line also says how much of it was drawing: from the engine asking for the
///   window to that commit. And how long building the Switcher's app list took.
///
/// One compact line goes into the scroll log at most once a minute while there's something new
/// (`Engine.maintain`), and at quit: counts, the median and the worst, in milliseconds, over the
/// last `keep` samples of each (the worst is since launch). Times are `CACurrentMediaTime`.
/// Foundation and QuartzCore only: scripts/engine-fuzz compiles this file.
final class PressTiming: @unchecked Sendable {
    static let shared = PressTiming()

    enum Series: Int, CaseIterable {
        case pressToAction, releaseToAction, rollToAction, releaseToSwitch
        case pressToRing, drawRing, pressToSwitcher, drawSwitcher, switcherList

        var label: String {
            switch self {
            case .pressToAction: "press→action"
            case .releaseToAction: "release→action"
            case .rollToAction: "roll→action"
            case .releaseToSwitch: "release→app switch"
            case .pressToRing: "press→ring"
            case .drawRing: "ring drawn in"
            case .pressToSwitcher: "press→switcher"
            case .drawSwitcher: "switcher drawn in"
            case .switcherList: "app list in"
            }
        }
    }

    enum Overlay { case ring, switcher }

    static let keep = 256
    static func now() -> Double { CACurrentMediaTime() }

    /// A CGEvent's own timestamp (nanoseconds since startup) as a `now()` time, when it's a
    /// plausible one (within a second before now); otherwise now.
    static func time(eventNanoseconds ns: UInt64) -> Double {
        let now = now(), t = Double(ns) / 1e9
        return t <= now && now - t < 1 ? t : now
    }

    /// The same for a HID report's timestamp (mach absolute time).
    static func time(hidStamp: UInt64) -> Double {
        let now = now(), t = Double(hidStamp) * machToSeconds
        return t <= now && now - t < 1 ? t : now
    }

    private static let machToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(max(1, info.denom)) / 1e9
    }()

    private struct Samples {
        var recent: [Double] = []
        var next = 0
        var count = 0
        var worst = 0.0
    }

    private let lock = NSLock()
    private var samples = [Samples](repeating: Samples(), count: Series.allCases.count)
    private var fresh = false
    private var lastSummary = -Double.infinity
    private var asked: [(pressedAt: Double, askedAt: Double)?] = [nil, nil]

    /// One measurement: `from` to now. Anything negative or over ten seconds isn't one.
    func add(_ series: Series, from t0: Double, to t1: Double = PressTiming.now()) {
        let d = t1 - t0
        guard d >= 0, d < 10 else { return }
        lock.lock()
        defer { lock.unlock() }
        var s = samples[series.rawValue]
        if s.recent.count < Self.keep { s.recent.append(d) } else { s.recent[s.next] = d }
        s.next = (s.next + 1) % Self.keep
        s.count += 1
        s.worst = max(s.worst, d)
        samples[series.rawValue] = s
        fresh = true
    }

    /// The engine asked for a hold's ring or panel for the first time (input thread).
    func askedFor(_ overlay: Overlay, pressedAt: Double) {
        lock.lock()
        asked[overlay == .ring ? 0 : 1] = (pressedAt, Self.now())
        lock.unlock()
    }

    /// Its window is in and its first frame committed (main thread).
    func shown(_ overlay: Overlay) {
        lock.lock()
        let i = overlay == .ring ? 0 : 1
        let a = asked[i]
        asked[i] = nil
        lock.unlock()
        guard let a else { return }
        let now = Self.now()
        add(overlay == .ring ? .pressToRing : .pressToSwitcher, from: a.pressedAt, to: now)
        add(overlay == .ring ? .drawRing : .drawSwitcher, from: a.askedAt, to: now)
    }

    /// The summary line, if there's something new and the last one was over `every` seconds ago.
    func summary(every: Double = 60, now: Double = PressTiming.now()) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard fresh, now - lastSummary >= every else { return nil }
        fresh = false
        lastSummary = now
        let parts: [String] = Series.allCases.compactMap { series in
            let s = samples[series.rawValue]
            guard s.count > 0 else { return nil }
            let sorted = s.recent.sorted()
            let median = sorted[sorted.count / 2]
            return "\(series.label) \(s.count)× med \(Self.ms(median)) worst \(Self.ms(s.worst))"
        }
        return "timing (ms): " + parts.joined(separator: " · ")
    }

    /// One series so far: how many, the median of the last `keep` and the worst since launch (seconds).
    struct Stat: Equatable {
        var count: Int
        var median: Double
        var worst: Double
    }

    func stat(_ series: Series) -> Stat? {
        lock.lock()
        defer { lock.unlock() }
        let s = samples[series.rawValue]
        guard s.count > 0 else { return nil }
        let sorted = s.recent.sorted()
        return Stat(count: s.count, median: sorted[sorted.count / 2], worst: s.worst)
    }

    /// One frame of a display that refreshes `hz` times a second: what the ring's first frame
    /// and a release's action each have to stay under ("Press primes everything").
    static func frame(hz: Int = 60) -> Double { 1 / Double(max(1, hz)) }

    /// The two numbers a press is judged by, and whether either is past one frame: the ring's
    /// first frame (from the engine asking for it; the designed waits before that don't count)
    /// and a release's action. Judged on the median, with the worst said beside it: one sample
    /// on a busy Mac isn't a slip. Nil: both in time (or not measured).
    func slipped(frame: Double = PressTiming.frame()) -> String? {
        let late: [String] = [Series.drawRing, .releaseToAction].compactMap { series in
            guard let s = stat(series), s.median > frame else { return nil }
            return "\(series.label) med \(Self.ms(s.median)) ms (worst \(Self.ms(s.worst))) is past one frame (\(Self.ms(frame)) ms)"
        }
        return late.isEmpty ? nil : late.joined(separator: "; ")
    }

    static func ms(_ seconds: Double) -> String {
        let v = seconds * 1000
        return v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v)
    }

    /// Runs `work` once the main run loop has finished this turn's drawing: after Core
    /// Animation's own commit (its observer runs at 2,000,000; this one last). Main thread.
    static func afterThisCommit(_ work: @escaping () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in work() }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Tests: start again from nothing.
    func reset() {
        lock.lock()
        samples = [Samples](repeating: Samples(), count: Series.allCases.count)
        fresh = false
        lastSummary = -.infinity
        asked = [nil, nil]
        lock.unlock()
    }
}
