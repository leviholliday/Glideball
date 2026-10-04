import Foundation
import QuartzCore
import os

/// Lock-protected counters written by the input thread and sampled by the UI.
final class Telemetry: @unchecked Sendable {
    struct Totals: Equatable {
        var clicks = 0
        var ballCounts = 0.0      // raw sensor counts
        var scrollPoints = 0.0    // points scrolled
    }

    struct Sample {
        var ballSpeed: Double     // counts / second
        var notchRate: Double     // notches / second
        var pressed: Set<Int>
        var totals: Totals
    }

    private struct State {
        var ball = 0.0
        var notches = 0.0
        var pressed = Set<Int>()
        var totals = Totals()
        var lastSample = CACurrentMediaTime()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func addBall(dx: Int, dy: Int) {
        let d = (Double(dx * dx + dy * dy)).squareRoot()
        state.withLock { $0.ball += d; $0.totals.ballCounts += d }
    }

    func addNotch() { state.withLock { $0.notches += 1 } }

    func addScroll(points: Double) { state.withLock { $0.totals.scrollPoints += abs(points) } }

    func button(_ index: Int, down: Bool) {
        state.withLock {
            if down {
                if $0.pressed.insert(index).inserted { $0.totals.clicks += 1 }
            } else {
                $0.pressed.remove(index)
            }
        }
    }

    func restore(_ totals: Totals) { state.withLock { $0.totals = totals } }

    var totals: Totals { state.withLock { $0.totals } }

    /// Closes the current bin and returns rates since the previous call.
    func sample() -> Sample {
        state.withLock { s in
            let now = CACurrentMediaTime()
            let dt = max(now - s.lastSample, 1.0 / 240)
            s.lastSample = now
            let out = Sample(ballSpeed: s.ball / dt, notchRate: s.notches / dt, pressed: s.pressed, totals: s.totals)
            s.ball = 0
            s.notches = 0
            return out
        }
    }
}
