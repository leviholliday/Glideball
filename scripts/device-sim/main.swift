// Checks per-display pointer speed (DisplayTracking.swift), connection types
// and low-battery notices (DeviceBattery.swift) with scripted displays, pointer
// paths and battery readings. Run: scripts/device-sim/run.sh (exits 1 on failure).
import CoreGraphics
import Foundation

var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: UInt = #line) {
    checks += 1
    if !ok { failures += 1; print("  ✗ \(what()) (line \(line))") }
}
func section(_ name: String) { print("▸ \(name)") }

// Two displays side by side, a third above the second.
let builtIn = DisplayRegion(key: "1552-41001-0", bounds: CGRect(x: 0, y: 0, width: 1512, height: 982))
let studio = DisplayRegion(key: "1552-44051-12345", bounds: CGRect(x: 1512, y: -300, width: 2560, height: 1440))
let above = DisplayRegion(key: "uuid-ABC", bounds: CGRect(x: 1512, y: -1380, width: 1920, height: 1080))

section("display keys")
do {
    check(DisplayKey.make(vendor: 1552, model: 44051, serial: 12345, uuid: "X") == "1552-44051-12345", "a serial number makes the key")
    check(DisplayKey.make(vendor: 1552, model: 44051, serial: 0, uuid: "ABC") == "uuid-ABC", "no serial: macOS's own UUID")
    check(DisplayKey.make(vendor: 1552, model: 44051, serial: 0, uuid: nil) == "1552-44051-0", "neither: vendor and model")
}

section("which display, and what it costs")
do {
    var t = DisplayTracker()
    check(t.setRegions([builtIn], pointer: nil) && t.current == builtIn.key, "one display: that's the one, no pointer needed")
    check(!t.needsWatching, "one display is never watched")

    t.setRegions([builtIn, studio], pointer: CGPoint(x: 100, y: 100))
    check(t.current == builtIn.key && t.needsWatching, "two displays: found from the pointer, and watched")

    // A minute of rolling at 1,000 reports a second on the built-in display.
    let start = t.lookups
    var now = 0.0, checksDone = 0, changes = 0
    for i in 0..<60_000 {
        now += 0.001
        if t.due(now: now) {
            checksDone += 1
            if t.update(point: CGPoint(x: 200 + Double(i % 900), y: 300)) { changes += 1 }
        }
    }
    check(checksDone <= 1_201, "at most 20 looks a second (\(checksDone) in 60 s)")
    check(t.lookups == start && changes == 0, "staying on one display never walks the list")

    // Cross to the studio display and back.
    check(t.update(point: CGPoint(x: 2000, y: 0)) && t.current == studio.key, "crossing right switches")
    check(!t.update(point: CGPoint(x: 2100, y: 500)), "moving on it doesn't")
    check(t.update(point: CGPoint(x: 10, y: 10)) && t.current == builtIn.key, "and back")

    // A point on no display (a gap) keeps the last one.
    check(!t.update(point: CGPoint(x: -5000, y: -5000)) && t.current == builtIn.key, "off every display: stays put")

    // A display appears (above), the pointer is on it.
    check(t.setRegions([builtIn, studio, above], pointer: CGPoint(x: 1600, y: -1000)) && t.current == above.key,
          "a new display under the pointer takes over")
    // It goes away: back to the display the pointer lands on.
    check(t.setRegions([builtIn, studio], pointer: CGPoint(x: 1600, y: -200)) && t.current == studio.key,
          "a display that disappears hands over to the one the pointer is on")
    // Pointer position unknown: stay on the same display if it's still there.
    check(!t.setRegions([builtIn, studio], pointer: nil) && t.current == studio.key, "unknown pointer: same display")
    // Everything but the built-in unplugged.
    check(t.setRegions([builtIn], pointer: nil) && t.current == builtIn.key, "down to one display")

    // Rate limit: due() twice in the same instant is once.
    var r = DisplayTracker()
    check(r.due(now: 1) && !r.due(now: 1.01) && r.due(now: 1.06), "at most one look per 50 ms")
}

section("speed precedence")
do {
    var c = GlideConfig()
    c.trackingSpeed = 4
    c.precisionSpeed = 1
    c.displaySpeeds.speeds = [studio.key: 8]
    check(PointerSpeed.effective(c, display: studio.key, precision: false) == 4, "off: the main speed")
    c.displaySpeeds.enabled = true
    check(PointerSpeed.effective(c, display: studio.key, precision: false) == 8, "on: the display's speed")
    check(PointerSpeed.effective(c, display: builtIn.key, precision: false) == 4, "a display without one: the main speed")
    check(PointerSpeed.effective(c, display: nil, precision: false) == 4, "unknown display: the main speed")
    check(PointerSpeed.effective(c, display: studio.key, precision: true) == 1, "Precision wins over everything")

    var withSpeed = AppProfile(bundleID: "com.example.cad", name: "CAD")
    withSpeed.trackingSpeed = 2
    let withoutSpeed = AppProfile(bundleID: "com.example.mail", name: "Mail")
    c.appProfiles = [withSpeed, withoutSpeed]
    check(PointerSpeed.effective(c.resolved(for: "com.example.cad"), display: studio.key, precision: false) == 2,
          "an app setup's own speed wins over the display's")
    check(PointerSpeed.effective(c.resolved(for: "com.example.mail"), display: studio.key, precision: false) == 8,
          "an app setup without its own speed: the display's")
    check(PointerSpeed.effective(c.resolved(for: nil), display: studio.key, precision: false) == 8, "no app setup: the display's")
    check(c.resolved(for: "com.example.cad").displaySpeeds.speeds == c.displaySpeeds.speeds,
          "the app setup only switches display speeds off, it doesn't lose them")
}

section("connection types")
do {
    check(DeviceConnection.classify(transport: "USB", name: "Kensington Expert Mouse", productID: 0x1020) == .usb, "the wired Expert Mouse is USB")
    check(DeviceConnection.classify(transport: "Bluetooth Low Energy", name: "SlimBlade Pro", productID: 0x80D7) == .bluetooth, "BLE is Bluetooth")
    check(DeviceConnection.classify(transport: "Bluetooth", name: "Expert Wireless TB", productID: nil) == .bluetooth, "classic Bluetooth too")
    check(DeviceConnection.classify(transport: "USB", name: "Kensington Expert Wireless TB Mouse", productID: 0x8018) == .receiver, "a wireless name over USB is the receiver")
    check(DeviceConnection.classify(transport: "USB", name: "Slimblade Trackball", productID: 0x2041) == .usb, "a plain USB trackball is USB")
    check(DeviceConnection.classify(transport: nil, name: "x", productID: 1) == nil, "no transport: unknown")
    check(DeviceConnection.classify(transport: "SPI", name: "x", productID: 1) == nil, "anything else: unknown")
    check(!DeviceConnection.usb.isWireless && DeviceConnection.bluetooth.isWireless && DeviceConnection.receiver.isWireless, "only USB is wired")
}

section("battery readings")
do {
    check(DeviceBattery.isBatteryUsage(page: 0x06, usage: 0x20), "Battery Strength")
    check(DeviceBattery.isBatteryUsage(page: 0x85, usage: 0x65) && DeviceBattery.isBatteryUsage(page: 0x85, usage: 0x66), "state of charge")
    check(!DeviceBattery.isBatteryUsage(page: 0x01, usage: 0x30), "not the ball")
    check(DeviceBattery.percent(value: 50, logicalMin: 0, logicalMax: 100) == 50, "0…100")
    check(DeviceBattery.percent(value: 127, logicalMin: 0, logicalMax: 255) == 50, "0…255 scales")
    check(DeviceBattery.percent(value: 300, logicalMin: 0, logicalMax: 255) == nil, "out of range is unknown")
    check(DeviceBattery.percent(value: 1, logicalMin: 0, logicalMax: 0) == nil, "no range is unknown")
}

section("low-battery notices")
do {
    func run(_ levels: [Int?]) -> [Int] {
        var a = LowBatteryAlerts()
        return levels.compactMap { a.update(percent: $0) }
    }
    check(run(Array(stride(from: 100, through: 0, by: -1))) == [15, 5], "a full discharge: 15% once, 5% once")
    check(run([30, 4]) == [5], "a jump past both: one notice, the lower")
    check(run([16, 15, 16, 15, 14, 15, 16]) == [15], "hovering around 15% is one notice")
    check(run([14, 6, 5, 6, 5, 4]) == [15, 5], "hovering around 5% is one notice")
    check(run([14, 12, 25, 14]) == [15, 15], "charged past 20% re-arms the 15% notice")
    check(run([4, 9, 4]) == [5], "charging to 9% doesn't re-arm 5%")
    check(run([4, 11, 4, 12, 13, 14, 15]) == [5, 5], "charging to 10% re-arms 5% only")
    check(run([nil, nil, 50, nil, 10]) == [15], "unknown readings change nothing")
    check(run([-1, 101, 200]) == [], "nonsense readings are ignored")
    var a = LowBatteryAlerts()
    _ = a.update(percent: 10)
    let saved = try! JSONEncoder().encode(a)
    var b = try! JSONDecoder().decode(LowBatteryAlerts.self, from: saved)
    check(b.update(percent: 9) == nil && b.update(percent: 5) == 5, "the state survives a relaunch")
}

print(failures == 0 ? "✓ device-sim: all \(checks) checks passed" : "✗ device-sim: \(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
