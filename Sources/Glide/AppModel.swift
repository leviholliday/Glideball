import AppKit
import ApplicationServices
import IOKit.hid
import Observation
import ServiceManagement
import UniformTypeIdentifiers

struct ActivityPoint: Identifiable {
    let id: Int
    let time: Double
    let ballSpeed: Double     // inches / second of ball surface
    let notchRate: Double     // notches / second
}

@Observable
final class AppModel {
    static let shared = AppModel()

    var config: GlideConfig {
        didSet {
            guard config != oldValue else { return }
            config.save()
            if !config.enabled && oldValue.enabled { engine.releaseHeldKeys() }
            engine.update(config)
        }
    }

    var status = Engine.Status()
    var hasAccessibility = AXIsProcessTrusted()
    var hasInputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    var pressed: Set<Int> = []
    var activity: [ActivityPoint] = []
    var liveBallSpeed = 0.0
    var liveNotchRate = 0.0
    var ringAngle = 0.0
    var ballPhase = 0.0
    var totals = Telemetry.Totals()
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var settingsMessage: String?

    var permissionsOK: Bool { hasAccessibility && hasInputMonitoring }

    private static let settingsFileTypes: [UTType] = [
        UTType(filenameExtension: "glide-settings"),
        .json,
    ].compactMap { $0 }

    // MARK: Quick assign — press trackball button(s), then a shortcut

    enum AssignStep: Equatable {
        case idle
        case waitingForButtons
        case waitingForAction(Set<Int>)
    }

    var assignStep: AssignStep = .idle

    func beginAssign() {
        assignStep = .waitingForButtons
        // Never wait forever: give up after 10 seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.assignStep == .waitingForButtons { self?.cancelAssign() }
        }
        engine.learnNextPress { [weak self] buttons in
            guard let self, self.assignStep == .waitingForButtons, !buttons.isEmpty else { return }
            self.assignStep = .waitingForAction(buttons)
        }
    }

    func finishAssign(_ action: ButtonAction) {
        guard case .waitingForAction(let buttons) = assignStep else { return }
        if buttons == [0] {
            // Keep the primary click available even when assigning shortcuts.
        } else if buttons.count == 1, let b = buttons.first {
            config.buttons[b] = action
        } else {
            let sorted = buttons.sorted()
            if let i = config.chords.firstIndex(where: { $0.buttons == sorted }) {
                config.chords[i].action = action
            } else {
                config.chords.append(Chord(buttons: sorted, action: action))
            }
        }
        assignStep = .idle
    }

    func cancelAssign() {
        engine.learnNextPress(nil)
        assignStep = .idle
    }

    static func buttonName(_ b: Int) -> String {
        ["Bottom left", "Bottom right", "Top left", "Top right"].indices.contains(b)
            ? ["Bottom left", "Bottom right", "Top left", "Top right"][b] : "Button \(b + 1)"
    }

    /// Kensington Expert Mouse sensor: ~400 counts per inch of ball travel.
    static let countsPerInch = 400.0
    static let historySeconds = 8.0
    static let sampleRate = 30.0

    @ObservationIgnored let engine: Engine
    @ObservationIgnored private var sampler: Timer?
    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var sampleIndex = 0
    @ObservationIgnored private var smoothedBall = 0.0
    @ObservationIgnored private var smoothedNotch = 0.0
    @ObservationIgnored private var saveCounter = 0

    private init() {
        let cfg = GlideConfig.load()
        config = cfg
        engine = Engine(config: cfg)
        engine.telemetry.restore(Self.loadTotals())
        engine.onStatus = { [weak self] s in self?.status = s }
        engine.start()

        // Seed an empty chart so it doesn't pop in.
        let n = Int(Self.historySeconds * Self.sampleRate)
        activity = (0..<n).map { ActivityPoint(id: $0, time: Double($0 - n) / Self.sampleRate, ballSpeed: 0, notchRate: 0) }
        sampleIndex = n

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.engine.reapplyPointer()
        }
        startSampling()
    }

    // MARK: Permissions

    func refreshPermissions() {
        let ax = AXIsProcessTrusted()
        let im = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if ax != hasAccessibility { hasAccessibility = ax }
        if im != hasInputMonitoring { hasInputMonitoring = im }
    }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    func requestInputMonitoring() {
        if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Glide: launch at login failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Settings transfer

    func exportSettings() {
        let panel = NSSavePanel()
        panel.title = "Export Glide Settings"
        panel.nameFieldStringValue = "Glide Settings.glide-settings"
        panel.allowedContentTypes = Self.settingsFileTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(GlideSettingsFile(config: config))
            try data.write(to: url, options: .atomic)
            settingsMessage = "Settings exported successfully."
        } catch {
            settingsMessage = "Couldn’t export settings: \(error.localizedDescription)"
        }
    }

    func importSettings() {
        let panel = NSOpenPanel()
        panel.title = "Import Glide Settings"
        panel.message = "Choose a settings file previously exported from Glide."
        panel.allowedContentTypes = Self.settingsFileTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(GlideSettingsFile.self, from: data)
            config = try file.validatedConfig()
            settingsMessage = "Settings imported successfully."
        } catch {
            settingsMessage = "Couldn’t import settings: \(error.localizedDescription)"
        }
    }

    // MARK: Live activity (only while the window is visible)

    func startSampling() {
        guard sampler == nil else { return }
        let t = Timer(timeInterval: 1 / Self.sampleRate, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common)
        sampler = t
    }

    func stopSampling() {
        sampler?.invalidate()
        sampler = nil
        saveTotals()
    }

    private func sample() {
        let s = engine.telemetry.sample()
        let ball = s.ballSpeed / Self.countsPerInch
        smoothedBall = smoothedBall * 0.6 + ball * 0.4
        smoothedNotch = smoothedNotch * 0.7 + s.notchRate * 0.3
        if smoothedBall < 0.01 { smoothedBall = 0 }
        if smoothedNotch < 0.05 { smoothedNotch = 0 }

        sampleIndex += 1
        var a = activity
        a.removeFirst()
        a.append(ActivityPoint(id: sampleIndex, time: 0, ballSpeed: smoothedBall, notchRate: smoothedNotch))
        // Re-time so the newest sample sits at 0 and older ones are negative seconds.
        let count = a.count
        activity = a.enumerated().map { i, p in
            ActivityPoint(id: p.id, time: Double(i - count + 1) / Self.sampleRate, ballSpeed: p.ballSpeed, notchRate: p.notchRate)
        }
        liveBallSpeed = smoothedBall
        if smoothedNotch > 0 { ringAngle += smoothedNotch * 9 / Self.sampleRate }
        if smoothedBall > 0 { ballPhase += smoothedBall * 1.4 / Self.sampleRate }
        liveNotchRate = smoothedNotch
        if s.pressed != pressed { pressed = s.pressed }
        if s.totals != totals { totals = s.totals }

        saveCounter += 1
        if saveCounter % 300 == 0 { saveTotals() }
    }

    // MARK: Daily totals

    private static var todayKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "GlideTotals-" + f.string(from: Date())
    }

    private static func loadTotals() -> Telemetry.Totals {
        guard let d = UserDefaults.standard.dictionary(forKey: todayKey) else { return .init() }
        return .init(clicks: d["clicks"] as? Int ?? 0,
                     ballCounts: d["ball"] as? Double ?? 0,
                     scrollPoints: d["scroll"] as? Double ?? 0)
    }

    @ObservationIgnored private var totalsDay = AppModel.todayKey

    func saveTotals() {
        let t = engine.telemetry.totals
        UserDefaults.standard.set(["clicks": t.clicks, "ball": t.ballCounts, "scroll": t.scrollPoints],
                                  forKey: totalsDay)
        // New day: start counting from zero.
        if Self.todayKey != totalsDay {
            totalsDay = Self.todayKey
            engine.telemetry.restore(.init())
        }
    }
}
