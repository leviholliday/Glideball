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
            config.trackingSpeed = Double.random(in: 1...80, using: &rng)
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

// Backups in the same second. Names carry whole seconds, so these tie on the name's time, and
// the one written last must still be the newest: in the store that wrote it, and in a new
// store that only has the folder to go by.
func sameSecond(_ title: String, _ body: (BackupStore, URL, inout Double) -> Void) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glide-backup-sim-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let before = failures
    var speed = 2.0   // each save adds 1; inside the slider's range, or loading would clamp it
    body(BackupStore(folder: dir, defaults: defaults, calendar: cal, now: { clock }), dir, &speed)
    if failures != before { print("  (in: \(title))") }
}
/// Saves a checkpoint of settings no backup holds yet and checks it's the newest, here and on disk.
func saveAndCheck(_ s: BackupStore, _ dir: URL, _ speed: inout Double, _ kind: BackupStore.Kind, _ what: String) {
    speed += 1
    var c = GlideConfig(); c.trackingSpeed = speed
    check(s.checkpoint(c, kind: kind), "\(what): the \(kind.rawValue) checkpoint wasn't written")
    for (name, list) in [("the store", s.backups),
                         ("a new store on the same folder", BackupStore(folder: dir, defaults: defaults, calendar: cal, now: { clock }).backups)] {
        let first = list.first
        check(first?.kind == kind && first.flatMap(s.load)?.trackingSpeed == speed,
              "\(what): \(name) lists \(first?.url.lastPathComponent ?? "nothing") as the newest, not the \(kind.rawValue) just saved")
    }
    // Every file is one an older Glideball can read: the 19-character time, then the kind.
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    check(files.allSatisfy { BackupStore.parse(($0 as NSString).deletingPathExtension) != nil } && files.count == s.backups.count,
          "\(what): a file name older versions can't read, or a file the list doesn't show: \(files.sorted())")
    // Names stay honest: never more than a few seconds ahead of the clock.
    check(s.backups.allSatisfy { $0.date.timeIntervalSince(clock) < 10 }, "\(what): a backup is stamped \(s.backups.map { Int($0.date.timeIntervalSince(clock)) }.max() ?? 0) s ahead of the clock")
}
let kinds: [BackupStore.Kind] = [.beforeImport, .beforeRestore, .beforePreset, .beforeAI, .manual]
clock = cal.date(byAdding: .day, value: 3, to: clock)!
// Two checkpoints of different kinds in one second, every pair in both orders
// (an import's checkpoint, then Undo Last Import's "before restore").
for a in kinds {
    for b in kinds where a != b {
        sameSecond("\(a.rawValue), then \(b.rawValue)") { s, dir, speed in
            saveAndCheck(s, dir, &speed, a, "first of two in a second")
            clock += 0.2
            saveAndCheck(s, dir, &speed, b, "second of two in a second")
            clock -= 0.2
        }
    }
}
// The day's own backup and a checkpoint in the same second (a first launch that imports at once).
sameSecond("daily, then before import") { s, dir, speed in
    s.start(current: GlideConfig())
    check(s.backups.first?.kind == .daily, "no daily on a first launch")
    saveAndCheck(s, dir, &speed, .beforeImport, "a checkpoint in the daily's second")
}
// The same kind twice in a second: both kept, the second one newest.
sameSecond("before import twice") { s, dir, speed in
    saveAndCheck(s, dir, &speed, .beforeImport, "first of a kind")
    saveAndCheck(s, dir, &speed, .beforeImport, "second of a kind in the same second")
    check(s.backups.count == 2, "two of a kind in one second: \(s.backups.count) kept")
}
// A burst: twenty checkpoints in two seconds (the self-test's steps do this), of two kinds in
// turn and then of every kind. Each is the newest as it lands.
sameSecond("a burst of two kinds") { s, dir, speed in
    let start = clock
    for i in 0..<20 {
        saveAndCheck(s, dir, &speed, i % 2 == 0 ? .beforeAI : .beforeRestore, "burst, checkpoint \(i + 1)")
        clock += 0.1
    }
    clock = start
}
sameSecond("a burst of every kind") { s, dir, speed in
    let start = clock
    for i in 0..<20 {
        saveAndCheck(s, dir, &speed, kinds[i % kinds.count], "burst of every kind, checkpoint \(i + 1)")
        clock += 0.1
    }
    clock = start
}
// After a burst, a pause, then one more: it's stamped with the clock again.
sameSecond("a checkpoint after a burst") { s, dir, speed in
    let start = clock
    for _ in 0..<6 { saveAndCheck(s, dir, &speed, .beforeImport, "burst of one kind") }
    clock += 30
    saveAndCheck(s, dir, &speed, .beforeRestore, "30 s after a burst")
    check(abs((s.backups.first?.date ?? .distantPast).timeIntervalSince(clock)) < 1, "30 s after a burst, the new backup isn't stamped with the clock")
    clock = start
}

let sample = store.backups.first!
print("backups now: \(store.backups.count), max ever: \(maxCount), max folder size: \(maxBytes) bytes, one file: \(sample.size) bytes")
print(store.backups.map { "\($0.date.formatted(date: .abbreviated, time: .omitted)) \($0.kind.rawValue)" }.joined(separator: "\n"))
try? FileManager.default.removeItem(at: folder)
print(failures == 0 ? "ALL GOOD" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
