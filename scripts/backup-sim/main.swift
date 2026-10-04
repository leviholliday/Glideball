import Foundation

// Simulates a year and a half of use against the real BackupStore, with a fake
// clock and a scratch folder, and checks the retention rules hold every day.
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("glide-backup-sim-\(UUID().uuidString)")
let defaults = UserDefaults(suiteName: "glide-backup-sim-\(UUID().uuidString)")!
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone.current
var clock = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 9))!
let store = BackupStore(folder: folder, defaults: defaults, calendar: cal, now: { clock })

var config = GlideConfig()
var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL:", msg()) }
}
func age(_ d: Date) -> Int { cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: clock)).day! }

var rng = SystemRandomNumberGenerator()
var maxCount = 0, maxBytes = 0
var morning: [Date: GlideConfig] = [:]   // what the settings were as each day began
for day in 0..<540 {
    // Glide launches in the morning; settings change on ~60% of days (a quiet stretch in the middle).
    morning[cal.startOfDay(for: clock)] = config
    store.start(current: config)
    let quiet = (200..<260).contains(day)
    clock = cal.date(byAdding: .hour, value: 5, to: clock)!   // changes happen in the afternoon
    if !quiet && Int.random(in: 0..<10, using: &rng) < 6 {
        for _ in 0..<Int.random(in: 1...40, using: &rng) {   // a slider drag = many changes
            let old = config
            config.trackingSpeed = Double.random(in: 1...100, using: &rng)
            store.willChange(from: old)
        }
    }
    if day % 37 == 0 { store.checkpoint(config, kind: .beforeImport) }
    if day % 11 == 0 { store.checkpoint(config, kind: .manual) }

    clock = cal.date(byAdding: .hour, value: -5, to: clock)!
    let b = store.backups
    maxCount = max(maxCount, b.count); maxBytes = max(maxBytes, store.totalBytes)
    // Rules
    check(b.first != nil, "day \(day): no backups at all")
    let newest = b.first!
    check(b.allSatisfy { age($0.date) <= BackupStore.keepDays || $0.url == newest.url }, "day \(day): something older than a year survived")
    let dailiesRecent = b.filter { $0.kind == .daily && age($0.date) < BackupStore.dailyWindowDays }
    check(Set(dailiesRecent.map { cal.startOfDay(for: $0.date) }).count == dailiesRecent.count, "day \(day): two dailies on one day")
    let old = b.filter { age($0.date) >= BackupStore.dailyWindowDays && $0.url != newest.url }
    let months = old.map { cal.dateComponents([.year, .month], from: $0.date) }
    check(Set(months).count == months.count, "day \(day): two backups in one old month")
    // Every morning of the last two weeks can be restored: the newest backup taken
    // by that morning holds exactly that morning's settings.
    for back in 0..<min(BackupStore.dailyWindowDays, day + 1) {
        let d = cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: clock))!
        let morningTime = cal.date(bySettingHour: 9, minute: 0, second: 0, of: d)!   // not +9 h: DST
        guard let backup = b.first(where: { $0.date <= morningTime }) else {
            check(false, "day \(day): nothing restores \(back) days ago"); continue
        }
        var want = morning[d]!; want.enabled = true
        check(store.load(backup) == want, "day \(day): \(back) days ago restores the wrong settings")
    }
    clock = cal.date(byAdding: .day, value: 1, to: clock)!
}
// The start-of-day rule: the daily holds the settings from *before* the first change that day.
clock = cal.date(byAdding: .day, value: 1, to: clock)!
let before = config
store.start(current: config)
var changed = config; changed.trackingSpeed = 3.21
store.willChange(from: config); config = changed
store.willChange(from: config)
let todays = store.backups.first { $0.kind == .daily && cal.isDate($0.date, inSameDayAs: clock) }
check(todays.flatMap(store.load)?.trackingSpeed == before.trackingSpeed || todays == nil,
      "today's daily should hold the start-of-day settings")

let sample = store.backups.first!
print("backups now: \(store.backups.count), max ever: \(maxCount), max folder size: \(maxBytes) bytes, one file: \(sample.size) bytes")
print(store.backups.map { "\($0.date.formatted(date: .abbreviated, time: .omitted)) \($0.kind.rawValue)" }.joined(separator: "\n"))
try? FileManager.default.removeItem(at: folder)
print(failures == 0 ? "ALL GOOD" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
