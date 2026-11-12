import AppKit
import Observation
import SwiftUI

// The app's side of Commands.swift, ExternalControl.swift and StatusFile.swift:
// the real `CommandTarget`, and the center that takes glideball:// URLs from
// AppDelegate and keeps status.json while "Allow Raycast and scripts" is on.
// Nothing here runs in `--render-ui` or `--self-test` (Sandbox.isActive).

/// Commands act on the real app through this.
final class AppCommandTarget: CommandTarget {
    static let shared = AppCommandTarget()
    private init() {}

    private var model: AppModel { AppModel.shared }
    private var delegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    var isPaused: Bool { !model.config.enabled }

    func setPaused(_ paused: Bool) {
        // AppModel.config's didSet releases held keys and modes on a pause.
        if model.config.enabled == paused { model.config.enabled = !paused }
    }

    func isOn(_ mode: GlideMode) -> Bool {
        switch mode {
        case .precision: model.modes.precision
        case .ballScroll: model.modes.ballScrolling
        case .dragLock: model.modes.dragLocked
        }
    }

    func setMode(_ mode: GlideMode, on: Bool?, done: ((Bool?) -> Void)?) {
        let engineMode: Engine.ToggleMode = switch mode {
        case .precision: .precision
        case .ballScroll: .ballScroll
        case .dragLock: .dragLock
        }
        model.engine.setMode(engineMode, on: on, done: done)
    }

    var scrollMode: ScrollMode { model.config.scrollMode }
    func setScrollMode(_ mode: ScrollMode) { model.config.scrollMode = mode }

    var pointerSpeed: Double { model.config.trackingSpeed }
    func setPointerSpeed(_ speed: Double) { model.config.trackingSpeed = speed }

    var gesturesEnabled: Bool { model.config.gesturesEnabled }
    func setGesturesEnabled(_ on: Bool) { model.config.gesturesEnabled = on }

    var perDisplaySpeed: Bool { model.config.displaySpeeds.enabled }
    func setPerDisplaySpeed(_ on: Bool) { model.config.displaySpeeds.enabled = on }

    var appSetups: [CommandAppSetup] { model.config.appProfiles.map { CommandAppSetup(bundleID: $0.bundleID, name: $0.name) } }
    var pinnedAppSetup: String? { model.pinnedProfileID }
    var activeAppSetupName: String? { model.activeProfile?.name }
    func pinAppSetup(_ bundleID: String?) { model.pinnedProfileID = bundleID }

    func openTab(_ tab: CommandWindowTab?) {
        delegate?.showWindow()
        guard let tab else { return }
        let page: GlideTab = switch tab {
        case .overview: .overview
        case .pointer: .pointer
        case .scrolling: .scroll
        case .buttons: .buttons
        case .apps: .apps
        case .sync: .backup
        }
        model.requestTab(page)
    }

    func openSettings(_ tab: CommandSettingsTab?) {
        delegate?.showSettings(tab.flatMap { SettingsPane(rawValue: $0.rawValue) })
    }

    func checkForUpdates() { delegate?.showUpdatePanel() }

    func sendFeedback() {
        delegate?.showWindow()
        model.showingFeedback = true
    }
}

/// Takes glideball:// URLs and keeps status.json. Main thread.
final class ExternalControlCenter {
    static let shared = ExternalControlCenter()
    private init() {}

    private lazy var control = ExternalControl(
        target: AppCommandTarget.shared,
        isAllowed: { AppModel.shared.allowExternalControl },
        now: { ProcessInfo.processInfo.systemUptime },
        log: { AppModel.shared.engine.note($0) },
        explain: { [weak self] in self?.explainSwitch() })

    private var writer: StatusFileWriter?
    private var statsTimer: Timer?
    /// Bumped whenever status.json stops, so an old observation doesn't re-arm itself.
    private var generation = 0

    /// ~/Library/Application Support/Glide/status.json (the data folder keeps the old name).
    static var statusURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glide/status.json")
    }

    /// URLs that arrived before launch finished (a URL that launches Glideball
    /// can come before `applicationDidFinishLaunching`): run by `start()`.
    private var early: [URL] = []
    private var started = false

    /// At launch, once AppModel exists.
    func start() {
        guard !Sandbox.isActive, !started else { return }
        started = true
        settingChanged()
        let waiting = early
        early = []
        waiting.forEach { control.handle($0) }
    }

    func handle(_ url: URL) {
        guard !Sandbox.isActive else { return }
        guard started else {
            // Nothing may touch AppModel before launch has set things up. A few is plenty.
            if early.count < 20 { early.append(url) }
            return
        }
        control.handle(url)
    }

    /// "Allow Raycast and scripts" changed (or launch): keep status.json, or delete it.
    func settingChanged() {
        guard !Sandbox.isActive else { return }
        if AppModel.shared.allowExternalControl {
            startStatus()
        } else {
            stopStatus(wait: false)
            // Also clears a file a crash left behind.
            try? FileManager.default.removeItem(at: Self.statusURL)
        }
    }

    /// Quitting: the file goes with the app.
    func stop() {
        guard !Sandbox.isActive else { return }
        stopStatus(wait: true)
    }

    // MARK: status.json

    private func startStatus() {
        guard writer == nil else { return }
        let w = StatusFileWriter(url: Self.statusURL, now: { ProcessInfo.processInfo.systemUptime },
                                 snapshot: { ExternalControlCenter.snapshot() })
        writer = w
        w.writeIfChanged()
        observe(generation)
        // Today's numbers change with every click and roll; they're read every
        // few seconds rather than observed (they live on the input thread).
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.writer?.setNeedsWrite() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        statsTimer = t
    }

    private func stopStatus(wait: Bool) {
        generation += 1
        statsTimer?.invalidate()
        statsTimer = nil
        writer?.stopAndRemove(wait: wait)
        writer = nil
    }

    /// Writes (debounced) whenever something status.json shows changes.
    private func observe(_ gen: Int) {
        guard gen == generation, writer != nil else { return }
        withObservationTracking {
            _ = Self.snapshot()
        } onChange: {
            DispatchQueue.main.async { ExternalControlCenter.shared.changed(gen) }
        }
    }

    private func changed(_ gen: Int) {
        guard gen == generation else { return }
        writer?.setNeedsWrite()
        observe(gen)
    }

    private static func snapshot() -> GlideStatus {
        let model = AppModel.shared
        var s = GlideStatus()
        s.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        s.pid = ProcessInfo.processInfo.processIdentifier
        s.paused = !model.config.enabled
        s.trackballConnected = model.status.deviceConnected
        s.trackballs = model.status.deviceName.map { [$0] } ?? []
        s.scrollMode = model.config.scrollMode.rawValue
        s.pointerSpeed = model.config.trackingSpeed
        s.modes = .init(precision: model.modes.precision, ballScroll: model.modes.ballScrolling,
                        dragLock: model.modes.dragLocked)
        if let profile = model.activeProfile {
            s.activeAppSetup = .init(name: profile.name, pinned: model.pinnedProfileID == profile.bundleID)
        }
        let totals = model.engine.telemetry.totals
        s.today = .init(clicks: totals.clicks,
                        ballMeters: GlideStatus.rounded(totals.ballCounts * Tally.metersPerBallCount),
                        scrollMeters: GlideStatus.rounded(totals.scrollPoints * Tally.metersPerScrollPoint))
        return s
    }

    // MARK: The switch is off

    private var notice: NSWindow?

    /// Shown the first time per launch that a URL tries to change something
    /// with "Allow Raycast and scripts" off. Never again until Glideball relaunches.
    /// Open Settings goes to Settings › General and points at the switch.
    private func explainSwitch() {
        DispatchQueue.main.async { [weak self] in   // after the URL's Apple event has been answered
            guard let self else { return }
            if self.notice == nil {
                let close: () -> Void = { [weak self] in self?.notice?.close() }
                let view = ExternalControlNoticeView(openSettings: {
                    close()
                    (NSApp.delegate as? AppDelegate)?.showSettings(.general, spotlight: "external-control")
                }, close: close)
                let controller = NSHostingController(rootView: view)
                controller.sizingOptions = [.preferredContentSize]
                let w = NSWindow(contentViewController: controller)
                w.styleMask = [.titled, .closable, .fullSizeContentView]
                w.titlebarAppearsTransparent = true
                w.titleVisibility = .hidden
                w.title = String(localized: "Something tried to control Glideball")
                w.isReleasedWhenClosed = false
                w.collectionBehavior.insert([.fullScreenAuxiliary, .moveToActiveSpace])
                w.center()
                self.notice = w
            }
            NSApp.activate()
            self.notice?.makeKeyAndOrderFront(nil)
        }
    }
}
