// Generates golden data for the Windows port's tests from the real Mac sources:
//   - scroll-golden.json: per-frame output of SmoothScroller for the
//     scroll-sim scenarios (random jitter replaced by a deterministic LCG).
//   - mac-sample.glide-settings: a settings file exactly as the Mac exports it.
// Run: windows/tools/golden/run.sh   (macOS + swiftc)
import CoreGraphics
import Foundation

enum Engine { static let syntheticTag: Int64 = 0 }

/// Deterministic jitter, mirrored in C# (`Lcg` in ScrollGoldenTests).
struct Lcg {
    var state: UInt64
    mutating func next() -> Double {   // [0, 1)
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
}

func spin(rate: Double, count: Int, start: Double = 0.05, jitter: Double = 0, seed: UInt64 = 1) -> [Double] {
    var rng = Lcg(state: seed)
    var out: [Double] = []
    var t = start
    for _ in 0..<count {
        out.append((t / 0.008).rounded() * 0.008)
        t += (1 / rate) * (1 + (jitter > 0 ? (rng.next() * 2 - 1) * jitter : 0))
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
        acc = 0
        s.frame(at: t)
        frames.append(acc)
        t += 1.0 / 120
    }
    return frames
}

struct Scenario: Encodable {
    let name: String
    let mode: String
    let scrollDistance: Double
    let scrollSmoothness: Double
    let scrollAcceleration: Double
    let throwAmount: Double
    let ticks: [Double]
    let directions: [Double]?
    let until: Double
    let frames: [Double]
}

var scenarios: [Scenario] = []
func add(_ name: String, _ ticks: [Double], until: Double, config: GlideConfig, directions: [Double]? = nil) {
    scenarios.append(Scenario(name: name, mode: config.scrollMode.rawValue,
                              scrollDistance: config.scrollDistance, scrollSmoothness: config.scrollSmoothness,
                              scrollAcceleration: config.scrollAcceleration, throwAmount: config.throwAmount,
                              ticks: ticks, directions: directions, until: until,
                              frames: simulate(ticks: ticks, until: until, config: config, directions: directions)))
}

var follow = GlideConfig()
follow.scrollMode = .follow
var yours = follow
yours.scrollDistance = 5; yours.scrollSmoothness = 0.15; yours.scrollAcceleration = 0.25; yours.throwAmount = 0.3
let fly = GlideConfig()   // Flywheel is the default
let flick = spin(rate: 45, count: 10)

for (label, cfg) in [("follow", follow), ("flywheel", fly)] {
    add("\(label): One tick", [0.05], until: 0.6, config: cfg)
    add("\(label): Two quick ticks", spin(rate: 40, count: 2), until: 0.6, config: cfg)
    add("\(label): Slow careful turn 7 t/s", spin(rate: 7, count: 10, jitter: 0.2, seed: 7), until: 2.2, config: cfg)
    add("\(label): Medium turn 16 t/s", spin(rate: 16, count: 12, jitter: 0.2, seed: 16), until: 1.6, config: cfg)
    add("\(label): Typical flick 10 @ 41", spin(rate: 41, count: 10), until: 2.0, config: cfg)
    add("\(label): Big flick 25 @ 62", spin(rate: 62, count: 25), until: 2.5, config: cfg)
    add("\(label): Short fast flick 4 @ 62", spin(rate: 62, count: 4), until: 1.5, config: cfg)
    add("\(label): Flick then catch", flick + [flick.last! + 0.2], until: 2.0, config: cfg,
        directions: Array(repeating: 1, count: 10) + [-1])
    add("\(label): Down then reverse up", spin(rate: 20, count: 8) + spin(rate: 20, count: 4, start: 0.5), until: 1.5,
        config: cfg, directions: Array(repeating: 1, count: 8) + Array(repeating: -1, count: 4))
    add("\(label): Flick but slow down (aiming)", [0.05, 0.074, 0.098, 0.122, 0.146, 0.17, 0.202, 0.25, 0.322],
        until: 1.5, config: cfg)
}
add("yours: Typical flick 10 @ 41", spin(rate: 41, count: 10), until: 2.0, config: yours)
add("yours: Big flick 25 @ 62", spin(rate: 62, count: 25), until: 2.5, config: yours)
add("yours: Medium turn 16 t/s", spin(rate: 16, count: 12, jitter: 0.2, seed: 16), until: 1.6, config: yours)

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let enc = JSONEncoder()
enc.outputFormatting = [.sortedKeys]
try enc.encode(scenarios).write(to: out.appendingPathComponent("scroll-golden.json"))

// A Mac-format settings file that uses every kind of value.
var c = GlideConfig()
c.trackingSpeed = 6.5
c.buttons[1] = .modifiedClick(button: 0, modifiers: CGEventFlags.maskControl.rawValue)
c.buttons[4] = .holdShortcut(.wisprFlow)
c.buttons[5] = .precisionHold
c.chords.append(Chord(id: UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!, buttons: [2, 3], action: .dragLock))
var p = AppProfile(bundleID: "com.apple.Safari", name: "Safari")
p.trackingSpeed = 3
p.buttons = [2: .back, 3: .forward]
c.appProfiles = [p]
c.globalShortcuts.precision = KeyShortcut.make(35, "P", [.maskControl, .maskAlternate, .maskCommand])
let file = GlideSettingsFile(config: c, exportedFrom: "Levi's MacBook Pro")
let fenc = JSONEncoder()
fenc.outputFormatting = [.prettyPrinted, .sortedKeys]
fenc.dateEncodingStrategy = .iso8601
try fenc.encode(file).write(to: out.appendingPathComponent("mac-sample.glide-settings"))
print("wrote \(scenarios.count) scenarios")
