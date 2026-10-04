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

    /// The best moments since the last `takePeaks()` — the raw material for
    /// personal records. Tracked on the input thread so a record set while
    /// Glide's window is closed still counts.
    struct Peaks: Equatable {
        var spinRate = 0.0       // scroll ring, notches / second (over a 0.2 s window)
        var rollRate = 0.0       // ball, counts / second (over a 0.1 s window)
        var flickPoints = 0.0    // points scrolled in one unbroken scroll
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
        var tapped = Set<Int>()   // pressed since the last sample, even if already let go
        var totals = Totals()
        var lastSample = CACurrentMediaTime()
        var peaks = Peaks()
        var notchBinStart = 0.0, notchBin = 0.0
        var ballBinStart = 0.0, ballBin = 0.0
        var lastScroll = 0.0, scrollRun = 0.0
    }

    static let notchWindow = 0.2
    static let ballWindow = 0.1
    /// A pause longer than this ends one "flick" and starts the next.
    static let flickGap = 0.35

    private let state = OSAllocatedUnfairLock(initialState: State())

    func addBall(dx: Int, dy: Int) {
        let d = (Double(dx * dx + dy * dy)).squareRoot()
        let now = CACurrentMediaTime()
        state.withLock { s in
            s.ball += d
            s.totals.ballCounts += d
            if now - s.ballBinStart >= Self.ballWindow {
                s.peaks.rollRate = max(s.peaks.rollRate, s.ballBin / Self.ballWindow)
                s.ballBinStart = now
                s.ballBin = 0
            }
            s.ballBin += d
        }
    }

    func addNotch() {
        let now = CACurrentMediaTime()
        state.withLock { s in
            s.notches += 1
            if now - s.notchBinStart >= Self.notchWindow {
                s.peaks.spinRate = max(s.peaks.spinRate, s.notchBin / Self.notchWindow)
                s.notchBinStart = now
                s.notchBin = 0
            }
            s.notchBin += 1
        }
    }

    func addScroll(points: Double) {
        let now = CACurrentMediaTime()
        state.withLock { s in
            s.totals.scrollPoints += abs(points)
            if now - s.lastScroll > Self.flickGap { s.scrollRun = 0 }
            s.lastScroll = now
            s.scrollRun += abs(points)
            s.peaks.flickPoints = max(s.peaks.flickPoints, s.scrollRun)
        }
    }

    /// Returns the peaks since the last call and starts collecting afresh.
    func takePeaks() -> Peaks {
        state.withLock { s in
            let out = s.peaks
            s.peaks = Peaks()
            return out
        }
    }

    func button(_ index: Int, down: Bool) {
        state.withLock {
            if down {
                if $0.pressed.insert(index).inserted { $0.totals.clicks += 1 }
                $0.tapped.insert(index)
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
            // A click shorter than one sample still shows for a frame.
            let out = Sample(ballSpeed: s.ball / dt, notchRate: s.notches / dt,
                             pressed: s.pressed.union(s.tapped), totals: s.totals)
            s.tapped = []
            s.ball = 0
            s.notches = 0
            return out
        }
    }
}
