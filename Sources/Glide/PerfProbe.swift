import Foundation
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
/// trackball, which only redraw themselves. `defaults delete … GlidePerfProbe` turns it off.
enum PerfProbe {
    static let enabled: Bool = !Sandbox.isActive && UserDefaults.standard.bool(forKey: "GlidePerfProbe")

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
        signposter.emitEvent("rebuild", "\(name, privacy: .public)")
        lock.lock()
        counts["\(name)", default: 0] += 1
        if timer == nil { startReporting() }
        lock.unlock()
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
        }
        t.resume()
        timer = t
    }
}
