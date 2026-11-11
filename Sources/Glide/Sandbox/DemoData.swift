import AppKit
import Carbon.HIToolbox

/// Believable data for `--render-ui` (and the self-test): a month of use on a
/// connected Kensington Expert Mouse, a few app setups and combos, milestones
/// part-way, sync on with two Macs, and a history of backups. Everything goes
/// into the sandbox's in-memory settings and temp folder (Sandbox.swift), the
/// same places the real app reads them from, so the screens load it the way
/// they load anyone's settings.
@MainActor
enum DemoData {
    static let today = Telemetry.Totals(clicks: 2_140,
                                        ballCounts: 41.0 / Tally.metersPerBallCount,
                                        scrollPoints: 63.0 / Tally.metersPerScrollPoint)

    /// Before `AppModel.shared` exists: settings, history, ledger, files.
    static func seed() {
        let d = UserDefaults.standard
        precondition(d === Sandbox.defaults, "demo data only ever goes into the sandbox's settings")
        let cal = Calendar.current
        let now = Date()

        d.set(true, forKey: WelcomeTour.doneKey)
        d.set(true, forKey: "GlideStockButtonDefaults")
        d.set(true, forKey: LaunchExperience.introPlayedKey)
        d.set(1.0, forKey: "GlideScrollDirection")
        if let data = try? JSONEncoder().encode(config) { d.set(data, forKey: "GlideConfig") }

        // A month of days, a little different each day (fixed, so pictures don't change between runs).
        var rng = SplitMix(seed: 2026)
        for back in 1...30 {
            guard let day = cal.date(byAdding: .day, value: -back, to: now) else { continue }
            let weekend = cal.isDateInWeekend(day)
            let scale = weekend ? 0.35 : 1.0
            let clicks = Int((1_500 + rng.next() * 2_300) * scale)
            let ball = (25 + rng.next() * 45) * scale
            let scroll = (30 + rng.next() * 90) * scale
            d.set(["clicks": clicks, "ball": ball / Tally.metersPerBallCount, "scroll": scroll / Tally.metersPerScrollPoint],
                  forKey: DelightCenter.key(for: day))
        }
        d.set(["clicks": today.clicks, "ball": today.ballCounts, "scroll": today.scrollPoints],
              forKey: DelightCenter.key(for: now))

        // Milestones part-way: the early ones earned over the month, the big ones still ahead.
        var ledger = DelightLedger()
        ledger.started = cal.date(byAdding: .day, value: -30, to: now)
        let earned = ["scroll-10": 29, "scroll-93": 27, "scroll-330": 22, "scroll-1k": 12,
                      "ball-10": 29, "ball-100": 27, "ball-400": 21, "ball-1k": 6,
                      "clicks-100": 30, "clicks-1k": 29, "clicks-10k": 25]
        for (id, back) in earned { ledger.earned[id] = cal.date(byAdding: .day, value: -back, to: now) }
        ledger.records = [RecordKind.spin.rawValue: 38, RecordKind.flick.rawValue: 2.4, RecordKind.roll.rawValue: 21]
        for k in RecordKind.allCases { ledger.recordDates[k.rawValue] = cal.date(byAdding: .day, value: -4, to: now) }
        ledger.checklist = [.speed, .scroll, .button]
        if let data = try? JSONEncoder().encode(ledger) { d.set(data, forKey: DelightCenter.ledgerKey) }

        // Settings › Privacy: crash reports on, with an install ID.
        d.set(ShareChoice.crashes.rawValue, forKey: ShareData.choiceKey)
        d.set(true, forKey: ShareData.askedKey)
        d.set(RandomID.format(Array(0..<20).map { UInt8(($0 * 37 + 11) % 256) }), forKey: ShareData.installIDKey)

        // Feedback: the name and email someone filled in last time.
        d.set("Sam Rivera", forKey: "GlideFeedbackName")
        d.set("sam@example.com", forKey: "GlideFeedbackEmail")

        // Sync on, with another Mac's heartbeat already in the (temp) iCloud Drive folder.
        d.set(true, forKey: "GlideSyncEnabled")
        if let folder = Sandbox.syncFolder {
            let devices = folder.appendingPathComponent("devices", isDirectory: true)
            try? FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
            let others: [(String, String, Double)] = [("6A1F0C2E-IMAC", "Office iMac", -3_600 * 5),
                                                     ("9C44B1D0-STUDIO", "Studio Mac", -86_400 * 2)]
            for (id, name, ago) in others {
                let json = """
                {"name": "\(name)", "lastSeen": \(now.addingTimeInterval(ago).timeIntervalSinceReferenceDate)}
                """
                try? Data(json.utf8).write(to: devices.appendingPathComponent("\(id).json"))
            }
        }

        // Backups: dailies over the last two weeks, two checkpoints, then monthly ones.
        if let folder = Sandbox.backupsFolder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var older = config
            older.trackingSpeed = 4.5
            var entries: [(Date, BackupStore.Kind, GlideConfig)] = [(now.addingTimeInterval(-60), .daily, config)]
            for back in [1, 2, 4, 6, 9, 13] {
                if let day = cal.date(byAdding: .day, value: -back, to: now) { entries.append((day, .daily, back < 5 ? config : older)) }
            }
            if let day = cal.date(byAdding: .day, value: -3, to: now) { entries.append((day.addingTimeInterval(1_800), .manual, config)) }
            if let day = cal.date(byAdding: .day, value: -9, to: now) { entries.append((day.addingTimeInterval(3_600), .beforeImport, older)) }
            for month in 1...5 {
                if let day = cal.date(byAdding: .month, value: -month, to: now) { entries.append((day, .daily, older)) }
            }
            for (date, kind, c) in entries {
                if let data = try? BackupStore.encode(c) {
                    try? data.write(to: folder.appendingPathComponent(BackupStore.fileName(for: date, kind: kind)))
                }
            }
        }
    }

    /// The main setup: Spaces + Wispr Flow on the top buttons, a second combo,
    /// a faster pointer, three app setups and a Precision shortcut.
    static var config: GlideConfig {
        var c = GlideConfig()
        c.trackingSpeed = 5.5
        c.scrollMode = .flywheel
        c.applySpacesAndWisprFlow()
        c.buttons[1] = .rightClick
        c.chords.append(Chord(buttons: [1, 3], action: .shortcut(.missionControl)))
        c.globalShortcuts.precision = KeyShortcut.make(kVK_ANSI_P, "P", [.maskControl, .maskAlternate, .maskCommand])

        var safari = AppProfile(bundleID: "com.apple.Safari", name: "Safari")
        var scroll = c.scrollSettings
        scroll.scrollMode = .follow
        safari.scroll = scroll
        var chrome = AppProfile(bundleID: "com.google.Chrome", name: "Google Chrome")
        chrome.trackingSpeed = 7
        chrome.buttons = [2: .back, 3: .forward]
        var excel = AppProfile(bundleID: "com.microsoft.Excel", name: "Microsoft Excel")
        excel.trackingSpeed = 3.5
        excel.chords = [Chord(buttons: [2, 3], action: .shortcut(.copy))]
        c.appProfiles = [safari, chrome, excel]
        return c
    }

    /// After `AppModel.shared` exists: what the engine would have reported.
    static func prime(_ model: AppModel) {
        model.status = connected
        model.hasAccessibility = true
        model.hasInputMonitoring = true
        model.engine.telemetry.restore(today)
        model.totals = today
        model.delight.tick(totals: today, peaks: Telemetry.Peaks())
        feedLiveGraphs(model.live)
        model.selectedProfileID = "com.apple.Safari"
    }

    static let connected = Engine.Status(deviceConnected: true, tapActive: true, listening: true,
                                         deviceName: "Kensington Expert Mouse",
                                         kensingtonModels: [.init(name: "Expert Mouse", productID: 0x1020)])

    /// Eight seconds of someone rolling the ball and giving the ring a couple of spins.
    static func feedLiveGraphs(_ live: LiveFeed) {
        live.reset()
        let n = 160, dt = LiveFeed.historySeconds / Double(n)
        for i in 0..<n {
            let t = Double(i) / Double(n)
            let ball = max(0, 3.2 * sin(t * .pi * 3.1) + 1.4 * sin(t * .pi * 11) + 0.8) * (t < 0.92 ? 1 : 0.3)
            let spin = t > 0.45 && t < 0.62 ? 26 * sin((t - 0.45) / 0.17 * .pi)
                : t > 0.78 && t < 0.88 ? 14 * sin((t - 0.78) / 0.10 * .pi) : 0
            live.push(ball: ball, notch: max(0, spin), dt: dt, interval: dt)
        }
    }

    /// A small deterministic random number generator.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
    }
}
