// Drives the real SmoothScroller with synthetic scroll-ring tick patterns —
// shaped like the Expert Mouse's real logs — and reports how smooth the
// output is. Run: scripts/scroll-sim/run.sh
import CoreGraphics
import Foundation

enum Engine { static let syntheticTag: Int64 = 0 }

struct Frame { let t: Double; let delta: Double }

func simulate(_ name: String, ticks: [Double], until end: Double, config: GlideConfig = GlideConfig(), verbose: Bool = false,
              directions: [Double]? = nil) {
    let s = SmoothScroller()
    s.config = config
    var now = 0.0
    s.clock = { now }
    var events: [Frame] = []
    s.output = { d in events.append(Frame(t: now, delta: d)) }

    let fps = 120.0
    var frames: [Frame] = []
    var nextTick = 0
    var t = 0.0
    while t <= end {
        while nextTick < ticks.count && ticks[nextTick] <= t {
            now = ticks[nextTick]
            s.addTicks(directions?[nextTick] ?? 1, flags: [])
            nextTick += 1
        }
        now = t
        let before = events.count
        s.frame(at: t)
        frames.append(Frame(t: t, delta: events[before...].reduce(0) { $0 + $1.delta }))
        t += 1 / fps
    }

    let first = ticks.first ?? 0, last = ticks.last ?? 0
    let total = events.reduce(0) { $0 + $1.delta }
    let backward = events.filter { $0.delta < 0 }.reduce(0) { $0 + $1.delta }
    let afterRelease = events.filter { $0.t > last + 0.05 }.reduce(0) { $0 + $1.delta }
    let firstMove = events.first?.t ?? .nan
    let lastMove = events.last?.t ?? .nan
    let active = frames.filter { $0.t >= first + 0.03 && $0.t <= last }
    let stalls = active.filter { $0.delta == 0 }.count
    let mid = active.filter { $0.t > first + (last - first) * 0.3 && $0.t < first + (last - first) * 0.8 }
    let speeds = mid.map { $0.delta * fps }
    let mean = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
    let sd = speeds.isEmpty ? 0 : (speeds.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(speeds.count)).squareRoot()

    if directions != nil { print(String(format: "  (net %.0f pt, of which %.0f pt backward)", total, backward)) }
    print(String(format: "%@\n  %d ticks → %.0f pt  (coast after release %.0f pt)  latency %.0f ms  settles %.0f ms after last tick  stalls %d/%d  steady %.0f±%.0f pt/s",
                 name, ticks.count, total, afterRelease, (firstMove - first) * 1000, (lastMove - last) * 1000,
                 stalls, active.count, mean, sd))
    if verbose {
        let line = frames.filter { $0.t < last + 0.5 }.map { String(format: "%.0f", $0.delta) }.joined(separator: " ")
        print("  pt per frame: \(line)")
    }
}

/// Ticks at a steady rate, snapped to the trackball's 8 ms USB polling.
func spin(rate: Double, count: Int, start: Double = 0.05, jitter: Double = 0) -> [Double] {
    var out: [Double] = []
    var t = start
    for _ in 0..<count {
        out.append((t / 0.008).rounded() * 0.008)
        t += (1 / rate) * (1 + (jitter > 0 ? Double.random(in: -jitter...jitter) : 0))
    }
    return out
}

let cfg = GlideConfig()
print("Config: \(cfg.scrollDistance) pt/tick, follow \(cfg.scrollSmoothness), accel \(cfg.scrollAcceleration), throw \(cfg.throwEnabled) \(cfg.throwAmount)\n")
simulate("One tick", ticks: [0.05], until: 0.6, verbose: true)
simulate("Two quick ticks (a nudge)", ticks: spin(rate: 40, count: 2), until: 0.6, verbose: true)
simulate("Slow careful turn, 7 t/s", ticks: spin(rate: 7, count: 10, jitter: 0.2), until: 2.2)
simulate("Medium turn, 16 t/s", ticks: spin(rate: 16, count: 12, jitter: 0.2), until: 1.6, verbose: true)
simulate("Typical flick, 10 ticks @ 41 t/s", ticks: spin(rate: 41, count: 10), until: 2.0, verbose: true)
simulate("Big flick, 25 ticks @ 62 t/s", ticks: spin(rate: 62, count: 25), until: 2.5)
simulate("Short fast flick, 4 ticks @ 62 t/s", ticks: spin(rate: 62, count: 4), until: 1.5)

let flick = spin(rate: 45, count: 10)
simulate("Flick, then catch it with one tick back 200 ms later", ticks: flick + [flick.last! + 0.2], until: 2.0,
         verbose: true, directions: Array(repeating: 1, count: 10) + [-1])
simulate("Scroll down, then reverse up", ticks: spin(rate: 20, count: 8) + spin(rate: 20, count: 4, start: 0.5), until: 1.5,
         verbose: true, directions: Array(repeating: 1, count: 8) + Array(repeating: -1, count: 4))
simulate("Flick but slow down before letting go (aiming)", ticks: [0.05, 0.074, 0.098, 0.122, 0.146, 0.17, 0.202, 0.25, 0.322], until: 1.5)

var yourCfg = GlideConfig()
yourCfg.scrollDistance = 5; yourCfg.scrollSmoothness = 0.15; yourCfg.scrollAcceleration = 0.25; yourCfg.throwAmount = 0.3
print("\n--- with your current settings (5 pt, follow 0.15, accel 0.25, throw 0.3) ---")
simulate("Typical flick, 10 ticks @ 41 t/s", ticks: spin(rate: 41, count: 10), until: 2.0, config: yourCfg)
simulate("Big flick, 25 ticks @ 62 t/s", ticks: spin(rate: 62, count: 25), until: 2.5, config: yourCfg)
simulate("Medium turn, 16 t/s", ticks: spin(rate: 16, count: 12, jitter: 0.2), until: 1.6, config: yourCfg)

var fly = GlideConfig()
fly.scrollMode = .flywheel
print("\n--- Flywheel (\(fly.flyDistance) pt slow tick, accel \(fly.flyAcceleration), glide \(fly.flyGlide)) — Kensington measured: 1 tick ≈ 4 pt, 10-tick flick ≈ 2300 pt, coast ≈ 0.5 s ---")
simulate("One tick", ticks: [0.05], until: 0.6, config: fly, verbose: true)
simulate("Slow careful turn, 7 t/s", ticks: spin(rate: 7, count: 10, jitter: 0.2), until: 2.2, config: fly)
simulate("Medium turn, 16 t/s", ticks: spin(rate: 16, count: 12, jitter: 0.2), until: 1.6, config: fly, verbose: true)
simulate("Typical flick, 10 ticks @ 41 t/s", ticks: spin(rate: 41, count: 10), until: 2.0, config: fly, verbose: true)
simulate("Big flick, 25 ticks @ 62 t/s", ticks: spin(rate: 62, count: 25), until: 2.5, config: fly)
simulate("Short fast flick, 4 ticks @ 62 t/s", ticks: spin(rate: 62, count: 4), until: 1.5, config: fly)
simulate("Flick, then catch it with one tick back", ticks: flick + [flick.last! + 0.12], until: 2.0, config: fly,
         directions: Array(repeating: 1, count: 10) + [-1])

// How far hard spins go (real spins on the Expert Mouse reach 70–130+ ticks/s).
print("\n--- Fast-spin reach: the same spin with the old hard limit (reach 0) and the new default (reach 0.5) ---")
var oldFly = fly; oldFly.flyReach = 0
for (name, rate, count) in [("20 ticks @ 45 t/s", 45.0, 20), ("20 ticks @ 70 t/s", 70.0, 20), ("20 ticks @ 100 t/s", 100.0, 20),
                            ("30 ticks @ 130 t/s", 130.0, 30), ("6 ticks @ 120 t/s (a short hard flick)", 120.0, 6)] {
    print(name)
    simulate("  reach 0 (old limit)", ticks: spin(rate: rate, count: count), until: 3.0, config: oldFly)
    simulate("  reach 0.5 (default)", ticks: spin(rate: rate, count: count), until: 3.0, config: fly)
}
