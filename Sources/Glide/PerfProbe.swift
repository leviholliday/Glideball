import AppKit
import os

/// How often the window's big views are rebuilt, for chasing jank (a page that
/// rebuilds while you scroll, say). Off unless asked for, and then it costs a
/// dictionary increment per rebuild:
///
///     defaults write com.leviholliday.glide GlidePerfProbe -bool YES   (then relaunch)
///     log stream --predicate 'subsystem == "com.leviholliday.glide" && category == "perf"'
///
/// Once a second it logs what was rebuilt ("RootView 0, TabPage 0, Group 3…"),
/// and each count is also a signpost (Instruments › Points of Interest). While
/// you scroll a page, everything should stay at 0 except the live light and the
/// trackball, which only redraw themselves and keep going while the page scrolls
/// (the graphs, `LiveTimeline frame`, hold still then).
/// `defaults delete … GlidePerfProbe` turns it off. `--scroll-bench` reads the counts itself.
///
/// It also carries the two numbers a press is judged by ("Press primes everything"): from the
/// engine deciding to show the ring to its first frame (`ringFirstFrame`; the designed 180 ms and
/// 0.25 s waits come before that and aren't in it), and from a release to its action being sent
/// (`releaseToAction`). `PressTiming` takes them whether the probe is on or not (two timestamps
/// each); with the probe on they're logged once a second beside the rebuilds. Both should stay
/// under one frame of the display (`frame`): the self-test fails when the ring's doesn't, the
/// engine fuzzer when the release's doesn't.
enum PerfProbe {
    static let enabled: Bool = Sandbox.mode == .scrollBench
        || (!Sandbox.isActive && UserDefaults.standard.bool(forKey: "GlidePerfProbe"))
    /// `--scroll-bench` reads the counts itself (`take()`): no log, no signposts, no timer.
    private static let benchOnly = Sandbox.mode == .scrollBench

    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    private static let log = Logger(subsystem: "com.leviholliday.glide", category: "perf")
    private static let signposter = OSSignposter(subsystem: "com.leviholliday.glide", category: .pointsOfInterest)

    /// One rebuild of `name`. Free when the probe is off.
    @inline(__always)
    static func count(_ name: StaticString) {
        guard enabled else { return }
        record(name)
    }

    private static func record(_ name: StaticString) {
        if !benchOnly { signposter.emitEvent("rebuild", "\(name, privacy: .public)") }
        lock.lock()
        counts["\(name)", default: 0] += 1
        if timer == nil && !benchOnly { startReporting() }
        lock.unlock()
    }

    /// The counts since the last call, and starts again from zero (`--scroll-bench`).
    static func take() -> [String: Int] {
        lock.lock()
        defer { counts = [:]; lock.unlock() }
        return counts.filter { $0.value > 0 }
    }

    // MARK: The press's two numbers

    struct Press: Equatable {
        /// The engine asked for the ring → its first frame committed.
        var ringFirstFrame: PressTiming.Stat?
        /// A button's release → what it does posted.
        var releaseToAction: PressTiming.Stat?
    }

    static func press(_ timing: PressTiming = .shared) -> Press {
        Press(ringFirstFrame: timing.stat(.drawRing), releaseToAction: timing.stat(.releaseToAction))
    }

    /// One frame of the display the menu bar is on (60 Hz if there's no display to ask).
    @MainActor static var frame: Double {
        PressTiming.frame(hz: NSScreen.main?.maximumFramesPerSecond ?? 60)
    }

    private static func pressLine() -> String {
        let p = press()
        func part(_ name: String, _ s: PressTiming.Stat?) -> String? {
            s.map { "\(name) \($0.count)× med \(PressTiming.ms($0.median)) worst \(PressTiming.ms($0.worst)) ms" }
        }
        return [part("ring first frame", p.ringFirstFrame), part("release→action", p.releaseToAction)].compactMap { $0 }.joined(separator: ", ")
    }

    /// Called with the lock held.
    private static func startReporting() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler {
            lock.lock()
            let snapshot = counts
            for k in counts.keys { counts[k] = 0 }
            lock.unlock()
            let line = snapshot.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            log.debug("rebuilds/s: \(line, privacy: .public)")
            let press = pressLine()
            if !press.isEmpty { log.debug("press: \(press, privacy: .public)") }
        }
        t.resume()
        timer = t
    }
}

