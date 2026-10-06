// Generates linux/tests/fixtures/scroll_golden.json and the Mac settings fixtures
// from the real Mac sources, so the Python port is checked against Swift.
// Run: linux/tools/make-golden.sh (macOS only).
import CoreGraphics
import Foundation

enum Engine { static let syntheticTag: Int64 = 0 }

func spin(rate: Double, count: Int, start: Double = 0.05) -> [Double] {
    var out: [Double] = []
    var t = start
    for _ in 0..<count {
        out.append((t / 0.008).rounded() * 0.008)
        t += 1 / rate
    }
    return out
}

func simulate(ticks: [Double], until end: Double, config: GlideConfig, directions: [Double]?) -> [Double] {
    let s = SmoothScroller()
    s.config = config
    var now = 0.0
    s.clock = { now }
    var acc = 0.0
    s.output = { d in acc += d }
    var frames: [Double] = []
    var nextTick = 0
    var t = 0.0
    while t <= end {
        while nextTick < ticks.count && ticks[nextTick] <= t {
            now = ticks[nextTick]
            s.addTicks(directions?[nextTick] ?? 1, flags: [])
            nextTick += 1
        }
        now = t
        s.frame(at: t)
        frames.append(acc)
        acc = 0
        t += 1 / 120.0
    }
    return frames
}

struct Scenario {
    let name: String; let mode: String; let ticks: [Double]; let dirs: [Double]?; let until: Double
    var reach = 0.5          // flyReach (the default); the original scenarios use it as-is
}
let flick = spin(rate: 45, count: 10)
var scenarios: [Scenario] = []
for mode in ["follow", "flywheel"] {
    scenarios += [
        Scenario(name: "one tick", mode: mode, ticks: [0.05], dirs: nil, until: 0.6),
        Scenario(name: "nudge", mode: mode, ticks: spin(rate: 40, count: 2), dirs: nil, until: 0.6),
        Scenario(name: "slow 7", mode: mode, ticks: spin(rate: 7, count: 10), dirs: nil, until: 2.2),
        Scenario(name: "medium 16", mode: mode, ticks: spin(rate: 16, count: 12), dirs: nil, until: 1.6),
        Scenario(name: "typical flick", mode: mode, ticks: spin(rate: 41, count: 10), dirs: nil, until: 2.0),
        Scenario(name: "big flick", mode: mode, ticks: spin(rate: 62, count: 25), dirs: nil, until: 2.5),
        Scenario(name: "short flick", mode: mode, ticks: spin(rate: 62, count: 4), dirs: nil, until: 1.5),
        Scenario(name: "catch", mode: mode, ticks: flick + [flick.last! + 0.2],
                 dirs: Array(repeating: 1, count: 10) + [-1], until: 2.0),
        Scenario(name: "reverse", mode: mode, ticks: spin(rate: 20, count: 8) + spin(rate: 20, count: 4, start: 0.5),
                 dirs: Array(repeating: 1, count: 8) + Array(repeating: -1, count: 4), until: 1.5),
        Scenario(name: "aiming", mode: mode, ticks: [0.05, 0.074, 0.098, 0.122, 0.146, 0.17, 0.202, 0.25, 0.322],
                 dirs: nil, until: 1.5),
    ]
}
// How far hard spins go (real spins on the Expert Mouse reach 70-130+ ticks/s): the same spin with
// the old hard limit (reach 0) and the default (reach 0.5), as in scripts/scroll-sim/main.swift.
for (name, rate, count) in [("20 ticks @ 45 t/s", 45.0, 20), ("20 ticks @ 70 t/s", 70.0, 20), ("20 ticks @ 100 t/s", 100.0, 20),
                            ("30 ticks @ 130 t/s", 130.0, 30), ("6 ticks @ 120 t/s", 120.0, 6)] {
    for reach in [0.0, 0.5] {
        scenarios.append(Scenario(name: "reach \(reach): \(name)", mode: "flywheel", ticks: spin(rate: rate, count: count),
                                  dirs: nil, until: 3.0, reach: reach))
    }
}
var out: [[String: Any]] = []
for s in scenarios {
    var c = GlideConfig()
    c.scrollMode = ScrollMode(rawValue: s.mode)!
    c.flyReach = s.reach
    out.append(["name": s.name, "mode": s.mode, "ticks": s.ticks, "dirs": s.dirs ?? s.ticks.map { _ in 1.0 },
                "until": s.until, "flyReach": s.reach, "frames": simulate(ticks: s.ticks, until: s.until, config: c, directions: s.dirs)])
}
let dir = CommandLine.arguments[1]
let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
try! data.write(to: URL(fileURLWithPath: dir + "/scroll_golden.json"))

// Real Mac settings files, encoded exactly like Glideball's export and backups.
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
encoder.dateEncodingStrategy = .iso8601
try! encoder.encode(GlideSettingsFile(config: GlideConfig(), exportedFrom: "Test Mac"))
    .write(to: URL(fileURLWithPath: dir + "/mac_default.glide-settings"))
var cfg = GlideConfig()
cfg.trackingSpeed = 12
cfg.buttons[1] = .modifiedClick(button: 0, modifiers: CGEventFlags.maskControl.rawValue)
cfg.buttons[3] = .holdShortcut(.wisprFlow)
cfg.chords.append(Chord(buttons: [2, 3], action: .dragLock))
var profile = AppProfile(bundleID: "com.apple.Safari", name: "Safari")
profile.trackingSpeed = 9
cfg.appProfiles = [profile]
cfg.globalShortcuts.precision = KeyShortcut(keyCode: 35, modifiers: CGEventFlags([.maskControl, .maskAlternate]).rawValue, keyName: "P")
try! encoder.encode(GlideSettingsFile(config: cfg, exportedFrom: "Test Mac"))
    .write(to: URL(fileURLWithPath: dir + "/mac_example.glide-settings"))
print("wrote \(out.count) scenarios")
