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
            if !config.enabled && oldValue.enabled {
                engine.releaseHeldKeys()
                engine.releaseAll()
            }
            pushToEngine()
            if config.globalShortcuts != oldValue.globalShortcuts { GlobalHotKeys.shared.apply(config.globalShortcuts) }
            if !applyingRemoteConfig {
                sync.localConfigChanged(config)
                delight.configChanged(from: oldValue, to: config)
            }
        }
    }

    var status = Engine.Status()
    /// Precision / Drag lock / Scroll with ball, while one is on.
    var modes = Engine.Modes()
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

    // Backup: a transient notice, an import waiting for confirmation, and a tab
    // the UI should switch to (e.g. after double-clicking a settings file).
    var toast: Toast?
    var pendingImport: PendingImport?
    var requestedTab: GlideTab?
    /// The Send Feedback sheet over the main window.
    var showingFeedback = false
    /// The Welcome Tour over the main window (see WelcomeTour.swift).
    var showingWelcomeTour = false
    /// Try Kensington's other trackballs and prerelease updates. Per-Mac,
    /// never synced — see `BetaProgram`. Takes effect immediately.
    var betaProgram = BetaProgram.isEnabled {
        didSet {
            guard betaProgram != oldValue else { return }
            UserDefaults.standard.set(betaProgram, forKey: BetaProgram.defaultsKey)
            engine.setBetaProgram(betaProgram)
            updates.includePrereleases = betaProgram
            updates.check()
        }
    }
    /// Shares settings with the user's other Macs through iCloud Drive.
    let sync = SettingsSync(onRemoteConfig: { AppModel.shared.applyRemoteConfig($0) })

    var permissionsOK: Bool { hasAccessibility && hasInputMonitoring }

    static let settingsType = UTType(exportedAs: "com.leviholliday.glide.settings", conformingTo: .json)
    private static let settingsFileTypes: [UTType] = [settingsType, .json]

    // MARK: Quick assign — press trackball button(s), then a shortcut

    enum AssignStep: Equatable {
        case idle
        case waitingForButtons
        case waitingForAction(Set<Int>)
    }

    var assignStep: AssignStep = .idle
    /// The app setup Quick assign writes to; nil = the main setup.
    @ObservationIgnored private var assignProfileID: String?

    func beginAssign(for profileID: String? = nil) {
        assignProfileID = profileID
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
        if let id = assignProfileID, let p = config.appProfiles.firstIndex(where: { $0.id == id }) {
            // Assigning inside an app setup customizes that area if it wasn't already.
            var profile = config.appProfiles[p]
            var map = profile.buttons ?? config.buttons
            var chords = profile.chords ?? config.chords
            if Self.assign(action, to: buttons, buttons: &map, chords: &chords) {
                profile.chords = chords
            } else if buttons != [0] {
                profile.buttons = map
            }
            config.appProfiles[p] = profile
        } else {
            var c = config
            Self.assign(action, to: buttons, buttons: &c.buttons, chords: &c.chords)
            config = c
        }
        assignStep = .idle
        assignProfileID = nil
    }

    /// Returns true when it made or changed a combo.
    @discardableResult
    private static func assign(_ action: ButtonAction, to buttons: Set<Int>,
                               buttons map: inout [Int: ButtonAction], chords: inout [Chord]) -> Bool {
        if buttons == [0] {
            // Keep the primary click available even when assigning shortcuts.
            return false
        } else if buttons.count == 1, let b = buttons.first {
            map[b] = action
            return false
        }
        let sorted = buttons.sorted()
        if let i = chords.firstIndex(where: { $0.buttons == sorted }) {
            chords[i].action = action
        } else {
            chords.append(Chord(buttons: sorted, action: action))
        }
        return true
    }

    func cancelAssign() {
        engine.learnNextPress(nil)
        assignStep = .idle
        assignProfileID = nil
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
    let updates = UpdateChecker()
    /// Milestones, records, the setup checklist and their celebrations.
    @ObservationIgnored let delight: DelightCenter
    @ObservationIgnored private var sampler: Timer?
    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var sampleIndex = 0
    @ObservationIgnored private var smoothedBall = 0.0
    @ObservationIgnored private var smoothedNotch = 0.0
    @ObservationIgnored private var saveCounter = 0
    @ObservationIgnored private var applyingRemoteConfig = false

    private init() {
        let cfg = GlideConfig.load()
        config = cfg
        let front = NSWorkspace.shared.frontmostApplication
        let frontIsGlide = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        glideIsFrontmost = frontIsGlide
        frontmostBundleID = front?.bundleIdentifier
        let initial = cfg.resolved(for: frontIsGlide ? nil : front?.bundleIdentifier)
        pushedConfig = initial
        engine = Engine(config: initial)
        engine.telemetry.restore(Self.loadTotals())
        delight = DelightCenter(config: cfg)
        engine.onStatus = { [weak self] s in self?.status = s }
        engine.onModes = { [weak self] m in self?.modes = m }
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
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            self?.frontmostChanged(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        delight.reloadHistory(currentKey: totalsDay)
        delight.present = { [weak self] in self?.show($0) }
        delight.canCelebrate = { [weak self] in self?.showingWelcomeTour == false }
        startSampling()
        sync.syncNow(current: cfg)   // pick up changes made on other Macs while Glide was closed
        updates.start()
    }

    // MARK: App setups — follow the frontmost app

    /// The app in front, and whether that's Glide itself.
    private(set) var frontmostBundleID: String?
    private(set) var glideIsFrontmost = false
    /// The setup selected on the Apps tab (kept across tab switches).
    var selectedProfileID: String? {
        didSet { if selectedProfileID != oldValue { pushToEngine() } }
    }
    /// True while the Apps tab is on screen. With Glide in front, the selected
    /// setup is then previewed so its changes can be felt as you make them.
    var isEditingProfiles = false {
        didSet { if isEditingProfiles != oldValue { pushToEngine() } }
    }
    @ObservationIgnored private var pushedConfig = GlideConfig()
    /// While the Welcome Tour asks you to press each button, run without remaps or combos.
    @ObservationIgnored var mappingsSuspended = false

    /// Whose setup the engine should run: the frontmost app's, or — while
    /// Glide itself is in front — the one open on the Apps tab, else the main setup.
    private var profileTarget: String? {
        glideIsFrontmost ? (isEditingProfiles ? selectedProfileID : nil) : frontmostBundleID
    }

    /// The app setup in effect right now, if any.
    var activeProfile: AppProfile? { config.profile(for: profileTarget) }

    private func frontmostChanged(_ app: NSRunningApplication?) {
        let isGlide = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let id = app?.bundleIdentifier
        if glideIsFrontmost != isGlide { glideIsFrontmost = isGlide }
        if frontmostBundleID != id { frontmostBundleID = id }
        pushToEngine()
    }

    /// Sends the setup for whoever's in front to the engine, if it changed.
    func pushToEngine() {
        var resolved = config.resolved(for: profileTarget)
        if mappingsSuspended {
            resolved.buttons = [:]
            resolved.chords = []
        }
        guard resolved != pushedConfig else { return }
        pushedConfig = resolved
        engine.update(resolved)
    }

    /// Adds a setup for an app (or selects it if it already has one).
    func addProfile(bundleID: String, name: String) {
        if !config.appProfiles.contains(where: { $0.bundleID == bundleID }) {
            config.appProfiles.append(AppProfile(bundleID: bundleID, name: name))
        }
        selectedProfileID = bundleID
    }

    func deleteProfile(_ id: String) {
        guard let i = config.appProfiles.firstIndex(where: { $0.id == id }) else { return }
        config.appProfiles.remove(at: i)
        if selectedProfileID == id {
            selectedProfileID = config.appProfiles.indices.contains(i) ? config.appProfiles[i].id : config.appProfiles.last?.id
        }
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

    // MARK: Backup — export, import with preview, undo

    struct Toast: Identifiable, Equatable {
        enum Action: Equatable { case undoImport, reveal(URL) }
        let id = UUID()
        let symbol: String
        let text: String
        var action: Action? = nil
        var isError = false
        /// A second, quieter line (celebrations).
        var detail: String? = nil
        /// A milestone, record or finished step — drawn a little more festive.
        var celebration = false
    }

    struct PendingImport: Identifiable {
        let id = UUID()
        let fileName: String
        let file: GlideSettingsFile
    }

    @ObservationIgnored private var configBeforeImport: GlideConfig?
    @ObservationIgnored private var toastDismissal: DispatchWorkItem?

    func show(_ toast: Toast) {
        self.toast = toast
        toastDismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in
            if self?.toast?.id == toast.id { self?.toast = nil }
        }
        toastDismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (toast.action != nil ? 7 : toast.celebration ? 5 : 3.5), execute: work)
    }

    private static var defaultExportName: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return "Glide Settings – \(f.string(from: Date())).\(GlideSettingsFile.fileExtension)"
    }

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(GlideSettingsFile(config: config))
    }

    /// A fresh copy of the current settings in a temporary file, for dragging
    /// out of the window or sharing.
    func exportToTemporaryFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(Self.defaultExportName)
        do {
            try exportData().write(to: url, options: .atomic)
            return url
        } catch {
            return nil   // may run off the main thread (drag & share); the caller reports failure
        }
    }

    func exportSettings() {
        let panel = NSSavePanel()
        panel.title = "Export Glide Settings"
        panel.message = "Save your Glide setup to a file you can back up or open on another Mac."
        panel.nameFieldStringValue = Self.defaultExportName
        panel.allowedContentTypes = [Self.settingsType]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try exportData().write(to: url, options: .atomic)
            show(.init(symbol: "checkmark.circle.fill", text: "Saved “\(url.deletingPathExtension().lastPathComponent)”", action: .reveal(url)))
        } catch {
            show(.init(symbol: "exclamationmark.triangle.fill", text: "Couldn’t export: \(error.localizedDescription)", isError: true))
        }
    }

    func importSettings() {
        let panel = NSOpenPanel()
        panel.title = "Import Glide Settings"
        panel.message = "Choose a Glide settings file. You’ll see what’s in it before anything changes."
        panel.allowedContentTypes = Self.settingsFileTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        previewImport(url)
    }

    /// Reads a settings file and shows what it contains — nothing changes until confirmed.
    func previewImport(_ url: URL) {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = try Data(contentsOf: url)
            let file: GlideSettingsFile
            if let iso = try? decoder.decode(GlideSettingsFile.self, from: data) {
                file = iso
            } else {
                file = try JSONDecoder().decode(GlideSettingsFile.self, from: data)   // older files
            }
            _ = try file.validatedConfig()
            pendingImport = PendingImport(fileName: url.deletingPathExtension().lastPathComponent, file: file)
            requestedTab = .backup
        } catch {
            show(.init(symbol: "exclamationmark.triangle.fill",
                       text: "That doesn’t look like a Glide settings file.", isError: true))
        }
    }

    func confirmImport() {
        guard let pending = pendingImport, var incoming = try? pending.file.validatedConfig() else { return }
        incoming.enabled = config.enabled            // the pause switch belongs to this Mac
        configBeforeImport = config
        config = incoming
        pendingImport = nil
        show(.init(symbol: "arrow.down.doc.fill", text: "Imported “\(pending.fileName)”", action: .undoImport))
    }

    func undoImport() {
        guard let previous = configBeforeImport else { return }
        config = previous
        configBeforeImport = nil
        show(.init(symbol: "arrow.uturn.backward.circle.fill", text: "Restored your previous settings"))
    }

    /// Takes settings synced from another Mac without echoing them back as a local change.
    private func applyRemoteConfig(_ remote: GlideConfig) {
        applyingRemoteConfig = true
        config = remote
        applyingRemoteConfig = false
    }

    // MARK: Live activity (only while the window is visible)

    func startSampling() {
        guard sampler == nil else { return }
        saveTotals()   // catches a new day that began while the window was closed
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
        if saveCounter % Int(Self.sampleRate) == 0 {
            delight.tick(totals: s.totals, peaks: engine.telemetry.takePeaks())
        }
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
            delight.reloadHistory(currentKey: totalsDay)
        }
    }
}
