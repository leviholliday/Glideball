import AppKit
import SwiftUI

/// `Glide --self-test [--returning] [--timeout <s>]`
///
/// Proves a build launches: runs the real launch path (`AppDelegate`'s
/// applicationWillFinishLaunching / applicationDidFinishLaunching: the menus,
/// the model, hot keys, the launch animation, the main window) with nothing
/// live (Sandbox.swift), then builds and draws, offscreen, everything else a
/// session shows — every tab, the Settings window, the Welcome Tour, the
/// sheets, the launch animations — and finally runs the quit path. One line
/// per step; exits 0 if all pass, 1 on any failure, crash or timeout (10 s).
///
/// `--returning` starts from a returning user's settings (DemoData) instead of
/// a brand-new Mac's, so the launch takes the short-animation path instead of
/// the first-launch intro. `scripts/self-test.sh` runs both.
@MainActor
enum SelfTest {
    private static var started = Date()
    private static var number = 0
    private static var failures: [String] = []
    private static var delegate: AppDelegate?
    private static var returning = false
    nonisolated(unsafe) fileprivate static let crashLine = UnsafeMutablePointer<CChar>.allocate(capacity: 256)

    static func start() {
        started = Date()
        let args = CommandLine.arguments
        returning = args.contains("--returning")
        var timeout = 10.0
        if let i = args.firstIndex(of: "--timeout"), i + 1 < args.count, let t = Double(args[i + 1]), t > 0 { timeout = t }
        let info = Bundle.main.infoDictionary
        print("self-test: Glideball \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?")), "
              + "\(returning ? "returning user" : "first launch"), bundle \(Bundle.main.bundleIdentifier ?? "none")")
        watchdog(timeout)
        catchCrashes()

        step("sandbox") {
            try check(UserDefaults.standard === Sandbox.defaults, "UserDefaults.standard isn't the in-memory store")
            try check(Bundle.main.bundleIdentifier != Sandbox.realBundleID, "running as the real app")
            try check(Diagnostics.url.path.hasPrefix(Sandbox.folder.path), "the scroll log isn't in the sandbox")
            try check(Sandbox.backupsFolder?.path.hasPrefix(Sandbox.folder.path) == true, "backups aren't in the sandbox")
            return "settings in memory; files in \(Sandbox.folder.lastPathComponent); network answered locally"
        }
        if returning { DemoData.seed() }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)   // no Dock icon, never in front
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        setCrashStep("launch path")
        app.run()   // → AppDelegate.applicationDidFinishLaunching → launched(_:)
    }

    /// AppDelegate calls this at the end of applicationDidFinishLaunching.
    static func launched(_ delegate: AppDelegate) {
        step("launch path") {
            "applicationDidFinishLaunching ran in \(ms(Date().timeIntervalSince(started)))"
        }
        // The rest once the run loop has turned, as it would for a real launch.
        // (On a run-loop turn rather than the main queue, so main-queue work can run while it waits.)
        RunLoop.main.perform { MainActor.assumeIsolated { checks(delegate) } }
    }

    // MARK: Checks

    private static func checks(_ delegate: AppDelegate) {
        let model = AppModel.shared

        step("menus") {
            let menu = try unwrap(NSApp.mainMenu, "no main menu")
            try check(menu.items.count >= 5 && menu.items.allSatisfy { $0.submenu != nil }, "the menu bar has \(menu.items.count) menus")
            let items = menu.items.flatMap { $0.submenu?.items ?? [] }
            try check(items.contains { $0.keyEquivalent == "," }, "no Settings… (⌘,)")
            try check(items.contains { $0.keyEquivalent == "q" }, "no Quit (⌘Q)")
            let status = try unwrap(delegate.statusMenu, "the menu-bar icon's menu wasn't built")
            return "\(menu.items.count) menus, \(items.count) items; menu-bar icon menu \(status.items.count) items (not shown)"
        }

        step("model") {
            try check(!model.engine.isRunning, "the engine is running")
            try check(GlobalHotKeys.shared.failed.isEmpty, "hot keys were registered")
            return "AppModel ready; engine never started; \(model.config.appProfiles.count) app setups, \(model.config.chords.count) combos"
        }

        step("main window") {
            let window = try unwrap(delegate.window, "no main window was made")
            try check(!window.isVisible, "the main window is on screen")
            let content = try unwrap(window.contentView, "the main window has no content")
            Offscreen.settleDown(content, seconds: 0.15)
            let rep = try unwrap(Offscreen.draw(window, content: content, chrome: .mainWindow, scale: 1), "the main window didn't draw")
            return "built offscreen, never shown; drew \(Int(rep.size.width))×\(Int(rep.size.height))"
        }

        step("launch animation") {
            let launch = LaunchExperience.shared
            if returning {
                guard case .splash? = launch.show else { throw Failure("a returning launch should play a short animation, got \(String(describing: launch.show))") }
            } else {
                try check(launch.show == .intro, "a first launch should play the intro, got \(String(describing: launch.show))")
            }
            var drawn = 0
            for t in [0.3, 4.2] {
                try draw(IntroScene(t: t, calm: false), "intro at \(t) s", size: RenderUI.windowSize, allowBlank: t < 1); drawn += 1
            }
            try draw(IntroScene(t: 1.0, calm: true), "intro, Reduce Motion", size: RenderUI.windowSize); drawn += 1
            for variant in SplashVariant.allCases {
                for t in [0.4, 1.05] {
                    // Early frames may be almost empty by design; the last must show something.
                    try draw(SplashScene(variant: variant, t: t, calm: false), "splash \(variant) at \(t) s", size: RenderUI.windowSize, allowBlank: t < 1); drawn += 1
                }
            }
            return "\(launch.show == .intro ? "intro" : "short animation") chosen; \(drawn) frames drawn"
        }

        step("tabs") {
            for tab in GlideTab.allCases {
                UserDefaults.standard.set(tab.rawValue, forKey: "GlideInitialTab")
                try draw(RootView(model: model), tab.rawValue, size: RenderUI.windowSize, chrome: .mainWindow)
            }
            UserDefaults.standard.removeObject(forKey: "GlideInitialTab")
            return "\(GlideTab.allCases.count) tabs drawn"
        }

        step("settings window") {
            let controller = SettingsWindowController()
            let window = try unwrap(controller.window, "no Settings window")
            let tabs = try unwrap(window.contentViewController as? NSTabViewController, "Settings has no tabs")
            try check(tabs.tabViewItems.count == SettingsPane.allCases.count, "\(tabs.tabViewItems.count) Settings tabs")
            let content = try unwrap(window.contentView, "Settings has no content")
            for i in tabs.tabViewItems.indices {
                tabs.selectedTabViewItemIndex = i
                Offscreen.settleDown(content, seconds: 0.05)
                let rep = try unwrap(Offscreen.draw(window, content: content, chrome: .titled, scale: 1), "Settings tab \(i) didn't draw")
                try check(!Offscreen.isBlank(rep), "Settings tab \(i) is blank")
            }
            try check(!window.isVisible, "the Settings window is on screen")
            window.close()
            return "\(tabs.tabViewItems.count) tabs drawn, never shown"
        }

        step("welcome tour") {
            for s in WelcomeTourView.Step.allCases {
                try draw(WelcomeTourView(model: model, step: s), "tour step \(s.rawValue + 1)", size: RenderUI.windowSize)
            }
            return "\(WelcomeTourView.Step.allCases.count) steps drawn"
        }

        step("sheets and panels") {
            try draw(AboutView(model: model), "About & Help")
            try draw(FeedbackView(model: model), "Send Feedback")
            try draw(SmallFavorCard(model: model), "A small favor", size: RenderUI.windowSize)
            try draw(UpdatePanelView(updates: model.updates) {}, "Software Update")
            try draw(BackupHistorySection(model: model, store: model.backups).frame(width: 900), "Backups")
            return "About, Feedback, A small favor, Software Update, Backups drawn"
        }

        step("nothing live") {
            try check(!model.engine.isRunning, "the engine started")
            let shown = NSApp.windows.filter(\.isVisible)
            try check(shown.isEmpty, "\(shown.count) window(s) on screen")
            try check(!NSApp.isActive, "Glideball became the active app")
            let asked = SandboxURLProtocol.requested
            return "no windows shown, no engine, \(asked.count) network request(s) (all answered locally)"
        }

        step("quit path") {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            return "applicationWillTerminate ran (nothing to release)"
        }

        finish()
    }

    // MARK: Plumbing

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    private static func check(_ ok: Bool, _ problem: @autoclosure () -> String) throws {
        if !ok { throw Failure(problem()) }
    }

    private static func unwrap<T>(_ value: T?, _ problem: String) throws -> T {
        guard let value else { throw Failure(problem) }
        return value
    }

    /// Hosts and draws `view` offscreen; fails if nothing was drawn (unless `allowBlank`).
    private static func draw<V: View>(_ view: V, _ what: String, size: NSSize? = nil,
                                      chrome: Offscreen.Chrome = .plain, allowBlank: Bool = false) throws {
        let rep = Offscreen.render(view, size: size ?? (chrome == .plain ? nil : RenderUI.windowSize), chrome: chrome,
                                   appearance: nil, scale: 1, settle: 0.02)
        let drawn = try unwrap(rep, "\(what) didn't draw")
        try check(allowBlank || !Offscreen.isBlank(drawn), "\(what) drew nothing")
    }

    private static func step(_ name: String, _ body: () throws -> String) {
        number += 1
        setCrashStep(name)
        let t0 = Date()
        let label = "\(String(number).leftPad(2)) \(name)"
        do {
            let detail = try body()
            print("ok   \(label) — \(detail) (\(ms(Date().timeIntervalSince(t0))))")
        } catch {
            failures.append(name)
            print("FAIL \(label) — \(error)")
        }
    }

    private static func finish() {
        let total = ms(Date().timeIntervalSince(started))
        if failures.isEmpty {
            print("PASS self-test: \(number) steps in \(total)")
            exit(0)
        }
        print("FAIL self-test: \(failures.count) of \(number) steps failed (\(failures.joined(separator: ", "))) in \(total)")
        exit(1)
    }

    private static func ms(_ s: TimeInterval) -> String {
        s < 1 ? "\(Int(s * 1000)) ms" : String(format: "%.1f s", s)
    }

    /// Never hang: a launch that takes too long is a failure.
    private static func watchdog(_ seconds: Double) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            print("FAIL self-test: timed out after \(Int(seconds)) s (stuck in: \(String(cString: crashLine)))")
            exit(1)
        }
    }

    // MARK: Crashes

    /// The step to blame if the process dies, kept where a signal handler can read it.
    private static func setCrashStep(_ name: String) {
        let text = Array("\(name)".utf8CString.prefix(255))
        text.withUnsafeBufferPointer { buf in
            crashLine.update(from: buf.baseAddress!, count: buf.count)
        }
        crashLine[min(text.count, 255)] = 0
    }

    /// A crash prints which step it happened in, then dies as it would have.
    private static func catchCrashes() {
        crashLine[0] = 0
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            signal(sig) { sig in
                let prefix = "FAIL self-test: crashed (signal \(sig)) in: "
                prefix.withCString { _ = write(1, $0, strlen($0)) }
                _ = write(1, SelfTest.crashLine, strlen(SelfTest.crashLine))
                _ = write(1, "\n", 1)
                signal(sig, SIG_DFL)
                raise(sig)
            }
        }
    }
}

private extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
