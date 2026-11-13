import AppKit
import ApplicationServices
import IOKit.hid
import Observation
import ServiceManagement
import UniformTypeIdentifiers

@Observable
final class AppModel {
    static let shared = AppModel()

    var config: GlideConfig {
        didSet {
            guard config != oldValue else { return }
            backups.willChange(from: oldValue)
            config.save()
            if !config.enabled && oldValue.enabled {
                engine.releaseHeldKeys()
                engine.releaseAll()
                pinnedProfileID = nil   // a pause hands app setups back to the app in front
            }
            pushToEngine()
            if config.globalShortcuts != oldValue.globalShortcuts { GlobalHotKeys.shared.apply(config.globalShortcuts) }
            if !applyingRemoteConfig {
                sync.localConfigChanged(config)
                delight.configChanged(from: oldValue, to: config)
            }
        }
    }

    var status = Engine.Status() {
        didSet {
            if status.deviceConnected != oldValue.deviceConnected { updateSampling() }
            if status.batteryPercent != oldValue.batteryPercent {
                batteryNotifier.update(percent: status.batteryPercent, deviceName: status.deviceName, enabled: lowBatteryAlerts)
            }
        }
    }
    /// Connected displays, for the Pointer tab's per-display speeds (`refreshDisplays`).
    var displays: [DisplayInfo] = []
    /// "Low battery alerts" for wireless trackballs. Per-Mac, never synced, off by
    /// default; turning it on asks for notification permission.
    var lowBatteryAlerts = LowBatteryAlertSetting.isEnabled {
        didSet {
            guard lowBatteryAlerts != oldValue else { return }
            UserDefaults.standard.set(lowBatteryAlerts, forKey: LowBatteryAlertSetting.defaultsKey)
            if lowBatteryAlerts { batteryNotifier.requestPermission() }
        }
    }
    @ObservationIgnored private let batteryNotifier = LowBatteryNotifier()
    /// Precision / Drag lock / Scroll with ball, while one is on.
    var modes = Engine.Modes()
    var hasAccessibility = AXIsProcessTrusted()
    var hasInputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    var pressed: Set<Int> = []
    /// Fast-changing readings for the animated views; see `LiveFeed` for why they aren't here.
    @ObservationIgnored let live = LiveFeed()
    var totals = Telemetry.Totals()
    var launchAtLogin = SMAppService.mainApp.status == .enabled

    // Backup: a transient notice, an import waiting for confirmation, and a tab
    // the UI should switch to (e.g. after double-clicking a settings file).
    var toast: Toast?
    var pendingImport: PendingImport?
    /// A shared setup (link or file) or KensingtonWorks' settings, waiting in its
    /// preview sheet. One at a time (AppModel+Sharing.swift).
    var pendingIncoming: IncomingSetup?
    /// One opened while the launch animation, the tour, a sheet or another card
    /// was up: it takes its turn in `nextPrompt` (WhatsNew.swift).
    var queuedIncoming: IncomingSetup?
    /// The self-test's receiving step, run while a long launch animation is still up.
    @ObservationIgnored var incomingIgnoresLaunch = false
    /// Share…: the sheet that makes a link, file or picture of part of your setup.
    var shareRequest: ShareRequest?
    /// The ball color before an import that changed it, for Undo.
    @ObservationIgnored var lookBeforeImport: ShareLook?
    /// The Sounds settings before an import that changed them, for Undo.
    @ObservationIgnored var soundsBeforeImport: ShareSounds?
    /// When the last preview closed (`systemUptime`): links that come right after are dropped.
    @ObservationIgnored var lastIncomingClosed = -Double.infinity
    /// A page asked for before the main window's content was there to show it.
    /// Use `requestTab`, which goes straight to the window when it can.
    var requestedTab: GlideTab?
    /// The main window's page switcher, while its content exists (set by its RootView).
    @ObservationIgnored var showTab: ((GlideTab) -> Void)?

    /// Shows a page in the main window: the sidebar's rows, ⇧1…⇧6, ⌘1…⌘6, the View
    /// menu, glideball://open and the buttons that lead to a page all come here.
    /// Straight to the window (a request left in an observed property for the window
    /// to notice could be missed when a second one came quickly after it).
    func requestTab(_ tab: GlideTab) {
        if let showTab { showTab(tab) } else { requestedTab = tab }
    }
    /// The main window is full screen (no toolbar: the layout makes its own room at the top).
    var fullScreen = false
    /// The Send Feedback sheet over the main window.
    var showingFeedback = false
    /// The About & Help sheet over the main window.
    var showingAbout = false
    /// The Welcome Tour over the main window (see WelcomeTour.swift).
    var showingWelcomeTour = false
    /// The "A small favor" card over the main window (see `showNextPrompt()`).
    var showingSmallFavor = false
    /// What's New over the main window (see WhatsNew.swift).
    var showingWhatsNew = false
    /// "Glideball has a new look" over the main window (see `AppIconChoice`).
    var showingIconChoice = false
    /// Work with Kensington's other trackballs. Per-Mac, never synced — see
    /// `OtherTrackballs`. Takes effect immediately.
    var otherTrackballs = OtherTrackballs.isEnabled {
        didSet {
            guard otherTrackballs != oldValue else { return }
            UserDefaults.standard.set(otherTrackballs, forKey: OtherTrackballs.defaultsKey)
            engine.setBetaProgram(otherTrackballs)
        }
    }
    /// "Allow Raycast and scripts": glideball:// URLs may change things, and
    /// status.json is kept. Per-Mac, never synced, off by default — see ExternalControl.swift.
    var allowExternalControl = ExternalControlSetting.isEnabled {
        didSet {
            guard allowExternalControl != oldValue else { return }
            UserDefaults.standard.set(allowExternalControl, forKey: ExternalControlSetting.defaultsKey)
            ExternalControlCenter.shared.settingChanged()
        }
    }
    /// Offer prerelease updates. Per-Mac, never synced — see `EarlyUpdates`.
    var earlyUpdates = EarlyUpdates.isEnabled {
        didSet {
            guard earlyUpdates != oldValue else { return }
            UserDefaults.standard.set(earlyUpdates, forKey: EarlyUpdates.defaultsKey)
            updates.includePrereleases = earlyUpdates
            updates.check()
        }
    }
    /// Shares settings with the user's other Macs through iCloud Drive.
    /// (`--render-ui` and `--self-test` give it a temp folder instead: Sandbox.swift.)
    let sync = SettingsSync(onRemoteConfig: { AppModel.shared.applyRemoteConfig($0) }, folder: Sandbox.syncFolder)
    /// Daily snapshots of the settings, kept two weeks, then monthly for a year.
    let backups = BackupStore(folder: Sandbox.backupsFolder)

    /// The menu-bar icon (on unless turned off in Settings › General). Per-Mac.
    static var showMenuBarIcon: Bool {
        UserDefaults.standard.object(forKey: "GlideShowMenuBarIcon") as? Bool ?? true
    }
    var menuBarIcon: Bool = AppModel.showMenuBarIcon {
        didSet {
            UserDefaults.standard.set(menuBarIcon, forKey: "GlideShowMenuBarIcon")
            (NSApp.delegate as? AppDelegate)?.updateStatusItemVisibility()
            if !menuBarIcon && !showInDock { showInDock = true }   // never leave Glideball with no way back in
        }
    }

    /// "Menu bar icon style": Mono (a template, like Apple's icons) or Color (the
    /// ball in the ball color). Per-Mac. The icon follows it (AppDelegate tracks it).
    var menuBarIconStyle: MenuBarIcon.Style = MenuBarIcon.Style.saved {
        didSet { UserDefaults.standard.set(menuBarIconStyle.rawValue, forKey: MenuBarIcon.Style.defaultsKey) }
    }

    /// Show Glideball in the Dock and the ⌘-Tab switcher. Off = it runs purely in the
    /// background and is reopened from its menu-bar icon. Per-Mac.
    static var showInDockSaved: Bool {
        // Hidden from the Dock needs the menu-bar icon; without it there'd be no way back in.
        UserDefaults.standard.object(forKey: "GlideShowInDock") as? Bool ?? true || !showMenuBarIcon
    }
    var showInDock: Bool = AppModel.showInDockSaved {
        didSet {
            guard showInDock != oldValue else { return }
            UserDefaults.standard.set(showInDock, forKey: "GlideShowInDock")
            if !showInDock && !menuBarIcon { menuBarIcon = true }
            NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
            if showInDock { NSApp.activate() }   // the window stays in front through the switch
        }
    }

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
        Sounds.shared.play(.tick)
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
        switch b {
        case 0: String(localized: "Bottom left", comment: "Trackball button position")
        case 1: String(localized: "Bottom right", comment: "Trackball button position")
        case 2: String(localized: "Top left", comment: "Trackball button position")
        case 3: String(localized: "Top right", comment: "Trackball button position")
        default: String(localized: "Button \(b + 1)")
        }
    }

    /// What a button does without Glide.
    static func buttonDefault(_ b: Int) -> String {
        switch b {
        case 0: String(localized: "Left click")
        case 1: String(localized: "Right click")
        case 2: String(localized: "Middle click")
        default: String(localized: "Back", comment: "Browser back: what the top-right button does by default")
        }
    }

    /// Kensington Expert Mouse sensor: ~400 counts per inch of ball travel.
    static let countsPerInch = 400.0

    @ObservationIgnored let engine: Engine
    let updates = UpdateChecker()
    /// Milestones, records, the setup checklist and their celebrations.
    @ObservationIgnored let delight: DelightCenter
    @ObservationIgnored private var sampler: Timer?
    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var lastSampleTime = CACurrentMediaTime()
    @ObservationIgnored private var lastTotalsPublish = 0.0
    @ObservationIgnored private var smoothedBall = 0.0
    @ObservationIgnored private var smoothedNotch = 0.0
    @ObservationIgnored private var smoothedRollX = 0.0
    @ObservationIgnored private var smoothedRollY = 0.0
    @ObservationIgnored private var smoothedRing = 0.0
    @ObservationIgnored private var applyingRemoteConfig = false

    private init() {
        ActionCatalog.install()
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
        delight.reloadHistory(currentKey: totalsDay)
        delight.present = { [weak self] in self?.show($0) }
        delight.canCelebrate = { [weak self] in
            self?.showingWelcomeTour == false && self?.showingWhatsNew == false && self?.showingIconChoice == false
        }
        // The "Saved" pill is silent: a tick on every save got old fast.
        live.lightIntensity = lightIntensity
        backups.currentConfig = { AppModel.shared.config }
        sync.onOlderMac = { [weak self] gestures in
            self?.show(Toast(symbol: "arrow.triangle.2.circlepath",
                             text: gestures
                                ? String(localized: "Another Mac is on an older Glideball, so gestures weren’t synced to it.")
                                : String(localized: "Another Mac is on an older Glideball, so your newest settings weren’t synced to it."),
                             isError: true))
        }
        refreshDisplays()   // read-only, so the Pointer tab can list them in a render too
        // `--render-ui` and `--self-test`: a model with nothing live — no engine,
        // timers, observers, sync or update checks (see Sandbox.swift).
        guard !Sandbox.isActive else { return }
        engine.start()
        engine.setDisplays(displayRegions)
        // A display connected, disconnected, moved or changed resolution.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.refreshDisplays()
            self.engine.setDisplays(self.displayRegions)
        }

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.engine.reconcileDevices()   // a removal can go missing while asleep
            self?.engine.reapplyPointer()
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                                            object: nil, queue: .main) { [weak self] _ in
            self?.engine.reconcileDevices()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            self?.frontmostChanged(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        updateSampling()   // the slow housekeeping tick, until the window opens
        backups.start(current: cfg)   // before sync, so today's backup is this Mac's own settings
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
    /// An app setup chosen with glideball://app-setup: it's used whatever app is
    /// in front, until "automatic", a pause or a quit. Never saved.
    var pinnedProfileID: String? {
        didSet { if pinnedProfileID != oldValue { pushToEngine() } }
    }
    /// While the Welcome Tour asks you to press each button, run without remaps or combos.
    @ObservationIgnored var mappingsSuspended = false

    /// Whose setup the engine should run: the frontmost app's, or — while
    /// Glide itself is in front — the one open on the Apps tab, else the main setup.
    /// A pinned setup (`pinnedProfileID`) wins over the app in front, not over the Apps tab.
    private var profileTarget: String? {
        if glideIsFrontmost && isEditingProfiles { return selectedProfileID }
        if let pinned = pinnedProfileID, config.profile(for: pinned) != nil { return pinned }
        return glideIsFrontmost ? nil : frontmostBundleID
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

    /// `--render-ui` only: says who's in front (Glideball itself, or another app), as the
    /// workspace notification would in the real app.
    func sandboxFrontmost(glide: Bool, bundleID: String? = nil) {
        guard Sandbox.isActive else { return }
        glideIsFrontmost = glide
        frontmostBundleID = bundleID
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

    // MARK: Displays (per-display pointer speed)

    @ObservationIgnored private var displayRegions: [DisplayRegion] = []

    /// Reads the connected displays: a stable key, a name, and where each one is.
    func refreshDisplays() {
        var infos: [DisplayInfo] = []
        var regions: [DisplayRegion] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
            let key = DisplayKey.make(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                                      serial: CGDisplaySerialNumber(id),
                                      uuid: uuid.flatMap { CFUUIDCreateString(nil, $0) as String? })
            infos.append(DisplayInfo(key: key, name: screen.localizedName, isMain: CGDisplayIsMain(id) != 0,
                                     frame: CGDisplayBounds(id)))
            regions.append(DisplayRegion(key: key, bounds: CGDisplayBounds(id)))
        }
        displayRegions = regions
        if infos != displays { displays = infos }
    }

    /// The speed a display uses with per-display speeds on: its own, or the main speed until it has one.
    func displaySpeed(for display: DisplayInfo) -> Double {
        config.displaySpeeds.speeds[display.key] ?? config.trackingSpeed
    }

    func setDisplaySpeed(_ speed: Double, for display: DisplayInfo) {
        var speeds = config.displaySpeeds
        speeds.speeds[display.key] = speed
        speeds.names[display.key] = display.name
        config.displaySpeeds = speeds
    }

    /// "Use main speed": the display follows the main tracking speed again.
    func clearDisplaySpeed(for display: DisplayInfo) {
        var speeds = config.displaySpeeds
        speeds.speeds[display.key] = nil
        config.displaySpeeds = speeds
    }

    // MARK: Gestures

    /// "Try it" on the Buttons page: gestures show what they'd do without doing it
    /// (two minutes at most; the engine ends it itself after that).
    func setGesturePractice(_ on: Bool) {
        engine.setGesturePractice(on)
        if Sandbox.isActive { modes.gesturePractice = on }
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
        guard !Sandbox.isActive else { return }   // never a login-item change from a render or self-test
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Glideball: launch at login failed: \(error)")
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
        /// The part a celebration is about: its icon takes that part's color.
        var part: Metric? = nil
    }

    struct PendingImport: Identifiable {
        let id = UUID()
        let fileName: String
        let file: GlideSettingsFile
    }

    @ObservationIgnored var configBeforeImport: GlideConfig?
    @ObservationIgnored private var toastDismissal: DispatchWorkItem?

    // What's New, "Glideball has a new look" and the "A small favor" card take
    // turns: see `showNextPrompt()` in WhatsNew.swift.

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
        return String(localized: "Glideball Settings – \(f.string(from: Date()))", comment: "Exported file name; %@ is the date")
            + ".\(GlideSettingsFile.fileExtension)"
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
        panel.title = String(localized: "Export Glideball Settings")
        panel.message = String(localized: "Save your Glideball setup to a file you can back up or open on another Mac.")
        panel.nameFieldStringValue = Self.defaultExportName
        panel.allowedContentTypes = [Self.settingsType]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try exportData().write(to: url, options: .atomic)
            show(.init(symbol: "checkmark.circle.fill", text: String(localized: "Saved “\(url.deletingPathExtension().lastPathComponent)”"), action: .reveal(url)))
        } catch {
            show(.init(symbol: "exclamationmark.triangle.fill", text: String(localized: "Couldn’t export: \(error.localizedDescription)"), isError: true))
        }
    }

    func importSettings() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Glideball Settings")
        panel.message = String(localized: "Choose a Glideball settings file. You’ll see what’s in it before anything changes.")
        panel.allowedContentTypes = Self.settingsFileTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        previewImport(url)
    }

    /// Reads a settings file and shows what it contains — nothing changes until confirmed.
    func previewImport(_ url: URL) {
        do {
            let name = ImportText.clean(url.deletingPathExtension().lastPathComponent)
            switch try ImportFile.read(url) {   // checked by scripts/file-fuzz and scripts/import-sim
            case .share(let share):
                receiveShare(share, from: .file(name))
                return
            case .settings(let file):
                pendingImport = PendingImport(fileName: name, file: file)
            }
            requestTab(.backup)
        } catch {
            show(.init(symbol: "exclamationmark.triangle.fill",
                       text: String(localized: "That doesn’t look like a Glideball settings file."), isError: true))
        }
    }

    func confirmImport() {
        guard let pending = pendingImport, var incoming = try? pending.file.validatedConfig() else { return }
        incoming = incoming.sanitizedForImport()
        incoming.enabled = config.enabled            // the pause switch belongs to this Mac
        backups.checkpoint(config, kind: .beforeImport)
        configBeforeImport = config
        lookBeforeImport = nil; soundsBeforeImport = nil
        config = incoming
        pendingImport = nil
        show(.init(symbol: "arrow.down.doc.fill", text: String(localized: "Imported “\(pending.fileName)”"), action: .undoImport))
    }

    /// A button preset from the Buttons tab: one click sets every button and
    /// combo. What was there is saved first (a "Before preset" backup), and Undo
    /// in the toast (like an import) puts it back.
    func applyPreset(_ preset: ButtonPreset) {
        var updated = config
        updated.apply(preset)
        guard updated != config else { return }
        backups.checkpoint(config, kind: .beforePreset)
        configBeforeImport = config; lookBeforeImport = nil; soundsBeforeImport = nil
        config = updated
        delight.explored(.preset)
        show(.init(symbol: preset.symbol, text: String(localized: "Applied “\(preset.title)”", comment: "Toast; the name of a button preset"),
                   action: .undoImport))
    }

    func undoImport() {
        guard let previous = configBeforeImport else { return }
        config = previous
        configBeforeImport = nil
        if let look = lookBeforeImport { BallThemeStore.shared.use(look) }
        lookBeforeImport = nil
        soundsBeforeImport?.use()
        soundsBeforeImport = nil
        show(.init(symbol: "arrow.uturn.backward.circle.fill", text: String(localized: "Restored your previous settings")))
    }

    /// Puts back the settings from an automatic backup, after saving the current
    /// ones as a checkpoint. Undo works the same as for an import.
    func restoreBackup(_ backup: BackupStore.Backup) {
        guard var restored = backups.load(backup) else {
            show(.init(symbol: "exclamationmark.triangle.fill", text: String(localized: "That backup couldn’t be read."), isError: true))
            backups.reload()
            return
        }
        restored.enabled = config.enabled
        guard restored != config else {
            show(.init(symbol: "checkmark.circle.fill", text: String(localized: "Your settings already match that backup")))
            return
        }
        backups.checkpoint(config, kind: .beforeRestore)
        configBeforeImport = config; lookBeforeImport = nil; soundsBeforeImport = nil
        config = restored
        let when = backup.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        show(.init(symbol: "clock.arrow.circlepath", text: String(localized: "Restored the backup from \(when)", comment: "Toast; the date and time of the backup"), action: .undoImport))
    }

    func backUpNow() {
        if backups.checkpoint(config, kind: .manual) {
            show(.init(symbol: "checkmark.circle.fill", text: String(localized: "Backed up your settings")))
        } else {
            let reason = backups.lastError ?? String(localized: "unknown error")
            show(.init(symbol: "exclamationmark.triangle.fill",
                       text: String(localized: "Couldn’t back up: \(reason)"), isError: true))
        }
    }

    /// Takes settings synced from another Mac without echoing them back as a local change.
    private func applyRemoteConfig(_ remote: GlideConfig) {
        applyingRemoteConfig = true
        config = remote
        applyingRemoteConfig = false
    }

    // MARK: Live activity (only while the window is visible)

    /// How much the window animates. Per-Mac; takes effect at once.
    var performance = PerformanceMode.saved {
        didSet {
            guard performance != oldValue else { return }
            UserDefaults.standard.set(performance.rawValue, forKey: PerformanceMode.defaultsKey)
            updateSampling()
        }
    }

    /// "Light": how bright the room gets when the hand moves (0 none … 1 full). Per-Mac.
    /// Settings › Look & Sound shows it as a slider.
    static let lightIntensityKey = "GlideLightIntensity"
    static let defaultLightIntensity = 0.6
    static var lightIntensitySaved: Double {
        let d = UserDefaults.standard
        guard d.object(forKey: lightIntensityKey) != nil else { return defaultLightIntensity }
        return min(max(d.double(forKey: lightIntensityKey), 0), 1)
    }
    var lightIntensity = AppModel.lightIntensitySaved {
        didSet {
            let v = min(max(lightIntensity, 0), 1)
            if v != lightIntensity { lightIntensity = v; return }
            UserDefaults.standard.set(v, forKey: Self.lightIntensityKey)
            live.lightIntensity = v
        }
    }

    /// ⌘Q asks first (`QuitConfirm`). Per-Mac; the card's "Always quit" turns it off,
    /// Settings › General turns it back on.
    static let confirmQuitKey = "GlideConfirmQuit"
    var confirmQuit = UserDefaults.standard.object(forKey: AppModel.confirmQuitKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(confirmQuit, forKey: Self.confirmQuitKey) }
    }

    /// The keyboard shortcuts sheet (? in the window, Help › Keyboard Shortcuts).
    var showingShortcuts = false
    /// The window is the one being used (observed, so the background can drift more slowly otherwise).
    private(set) var windowIsKey = false
    /// The window is actually on screen (not closed, minimized, covered, or on a sleeping display).
    private(set) var windowVisible = false
    /// The menu-bar panel is open (`setPanelOpen`).
    private(set) var panelOpen = false
    @ObservationIgnored private var samplerInterval = 0.0
    @ObservationIgnored private var lastDelightTick = 0.0
    /// The page is scrolling: today's numbers and the badges hold still (for up to a
    /// couple of seconds) so the gauges, charts and badge grid aren't rebuilt mid-scroll.
    @ObservationIgnored var pageScrolling = false
    @ObservationIgnored private var lastClickCount = Int.max
    @ObservationIgnored private var lastSave = 0.0

    /// Told by the window's delegate whenever it's shown, hidden, covered, or gains/loses focus.
    func windowStateChanged(visible: Bool, key: Bool) {
        if windowIsKey != key { windowIsKey = key }
        let changed = visible != windowVisible
        let becameVisible = visible && changed
        if changed { windowVisible = visible }
        if changed { saveTotals() }   // catches a day that began while hidden
        updateSampling()
        if becameVisible { sample() }                                            // fresh numbers on the first frame
    }

    /// The menu-bar panel is open (MenuBarPanel.swift): its little trackball and
    /// today's numbers want live samples too, as the window's do.
    func setPanelOpen(_ open: Bool) {
        guard open != panelOpen else { return }
        panelOpen = open
        updateSampling()
        if open { sample() }
    }

    /// Someone's looking: the window, or the menu-bar panel.
    private var watched: Bool { windowVisible || panelOpen }

    /// One timer, at the rate the window needs: fast while it's showing, and a slow
    /// housekeeping tick (saving totals, rolling the day) when nobody's looking.
    private func updateSampling() {
        let wanted = watched ? performance.sampleInterval(windowIsKey: windowIsKey || panelOpen, deviceConnected: status.deviceConnected) : 10
        guard sampler == nil || wanted != samplerInterval else { return }
        sampler?.invalidate()
        samplerInterval = wanted
        let t = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in self?.sample() }
        t.tolerance = wanted * 0.15   // lets macOS coalesce wakeups
        RunLoop.main.add(t, forMode: .common)
        sampler = t
        if !watched { live.reset(); smoothedBall = 0; smoothedNotch = 0; smoothedRollX = 0; smoothedRollY = 0; smoothedRing = 0 }
    }

    private func sample() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastSampleTime, 0.001), 1)
        lastSampleTime = now

        guard watched else {                    // nobody's looking: just keep the day's totals saved
            if now - lastSave > 10 { lastSave = now; saveTotals() }
            return
        }
        let s = engine.telemetry.sample()
        // The same smoothing as ever, scaled to however long this step was.
        let kBall = pow(0.6, dt * 30), kNotch = pow(0.7, dt * 30)
        smoothedBall = smoothedBall * kBall + (s.ballSpeed / Self.countsPerInch) * (1 - kBall)
        smoothedNotch = smoothedNotch * kNotch + s.notchRate * (1 - kNotch)
        smoothedRollX = smoothedRollX * kBall + (s.ballVX / Self.countsPerInch) * (1 - kBall)
        smoothedRollY = smoothedRollY * kBall + (s.ballVY / Self.countsPerInch) * (1 - kBall)
        smoothedRing = smoothedRing * kNotch + s.notchVelocity * (1 - kNotch)
        if smoothedBall < 0.01 { smoothedBall = 0; smoothedRollX = 0; smoothedRollY = 0 }
        if smoothedNotch < 0.05 { smoothedNotch = 0; smoothedRing = 0 }
        // HID wheel values are + for scrolling up, which is turning the ring anticlockwise.
        live.push(ball: smoothedBall, notch: smoothedNotch, rollX: smoothedRollX, rollY: smoothedRollY,
                  ringVelocity: -smoothedRing, dt: dt, interval: samplerInterval)

        if s.pressed != pressed { pressed = s.pressed }
        // Every click flashes the room amber (even one too quick to be caught down by a sample).
        if s.totals.clicks > lastClickCount { live.pulseClick() }
        lastClickCount = s.totals.clicks
        // Totals tick up with every click and scroll; the tiles don't need more than a few updates a second.
        // While the page scrolls, a few times less often (scrolling with the ring changes them all the time).
        let wait = pageScrolling ? 2.0 : 0.25
        if s.totals != totals, now - lastTotalsPublish > wait { lastTotalsPublish = now; totals = s.totals }

        if now - lastSave > 10 { lastSave = now; saveTotals() }
        if now - lastDelightTick >= (pageScrolling ? 3 : 1) {
            lastDelightTick = now
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
        guard let d = SavedDayTotals(UserDefaults.standard.object(forKey: todayKey)) else { return .init() }
        return .init(clicks: d.clicks, ballCounts: d.ballCounts, scrollPoints: d.scrollPoints)
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
