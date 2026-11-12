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
            if case .splash? = launch.show {
                try check(launch.revealAt + 0.4 <= 1.3, "the short animation takes \(launch.revealAt + 0.4) s (1.3 s at most)")
            }
            var drawn = 0
            for t in [0.3, 1.4, 3.0, 3.75, 3.97, 4.2, 5.6] {
                try draw(IntroScene(t: t, calm: false), "intro at \(t) s", size: RenderUI.windowSize, allowBlank: t < 1); drawn += 1
            }
            try draw(IntroScene(t: 1.0, calm: true), "intro, Reduce Motion", size: RenderUI.windowSize); drawn += 1
            for variant in SplashVariant.allCases {
                for t in [0.2, 0.8] {
                    // Early frames may be almost empty by design; the last must show something.
                    try draw(SplashScene(variant: variant, t: t, calm: false), "splash \(variant) at \(t) s", size: RenderUI.windowSize, allowBlank: t < 0.5); drawn += 1
                }
            }
            try draw(SplashScene(variant: .ringSpin, t: 0.3, calm: true), "quick fade", size: RenderUI.windowSize); drawn += 1
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
            let items = window.toolbar?.items.count ?? 0
            try check(items == SettingsPane.allCases.count, "\(items) Settings tabs in the toolbar")
            let content = try unwrap(window.contentView, "Settings has no content")
            for pane in SettingsPane.allCases {
                controller.select(pane, animated: false)
                Offscreen.settleDown(content, seconds: 0.05)
                let rep = try unwrap(Offscreen.draw(window, content: content, chrome: .titled, scale: 1), "Settings › \(pane.rawValue) didn't draw")
                try check(!Offscreen.isBlank(rep), "Settings › \(pane.rawValue) is blank")
            }
            try check(!window.isVisible, "the Settings window is on screen")
            window.close()
            return "\(SettingsPane.allCases.count) tabs drawn, never shown"
        }

        step("share pictures") {
            // The way Share… makes them in the app: drawn offscreen, never shown.
            let overview = try unwrap(ShareImage.render(.overview, delight: model.delight), "the share picture didn't draw")
            try check(!Offscreen.isBlank(overview), "the share picture is blank")
            let m = Milestone.all[0]
            let badge = try unwrap(ShareImage.render(.badge(m, Date()), delight: model.delight), "the badge picture didn't draw")
            try check(!Offscreen.isBlank(badge), "the badge picture is blank")
            try check(ShareImage.png(overview)?.isEmpty == false, "the share picture has no PNG")
            return "\(overview.pixelsWide)×\(overview.pixelsHigh) and a badge, PNG ready"
        }

        step("welcome tour") {
            for s in WelcomeTourView.Step.allCases {
                try draw(WelcomeTourView(model: model, step: s), "tour step \(s.rawValue + 1)", size: RenderUI.windowSize)
            }
            try draw(WelcomeTourView(model: model, step: .buttons, found: [0, 2]), "tour, two buttons found", size: RenderUI.windowSize)
            return "\(WelcomeTourView.Step.allCases.count) steps drawn, and a step part-done"
        }

        step("sheets and panels") {
            try draw(AboutView(model: model), "About & Help")
            try draw(FeedbackView(model: model), "Send Feedback")
            try draw(SmallFavorCard(model: model), "A small favor", size: RenderUI.windowSize)
            try draw(UpdatePanelView(updates: model.updates) {}, "Software Update")
            try draw(BackupHistorySection(model: model, store: model.backups).frame(width: 900), "Backups")
            return "About, Feedback, A small favor, Software Update, Backups drawn"
        }

        step("quit card and shortcuts") {
            // ⌘Q asks first by default; a second ⌘Q, asking turned off, or anything modal quits straight away.
            try check(model.confirmQuit, "asking before quitting should be on by default")
            try check(QuitConfirm.decide(confirm: true, showing: false, modal: false) == .ask, "⌘Q didn't ask")
            try check(QuitConfirm.decide(confirm: true, showing: true, modal: false) == .quit, "a second ⌘Q didn't quit")
            try check(QuitConfirm.decide(confirm: false, showing: false, modal: false) == .quit, "⌘Q asked with asking off")
            try check(QuitConfirm.decide(confirm: true, showing: false, modal: true) == .quit, "⌘Q asked over something modal")
            // Glideball's own Quit items go to the question; the updater and the system don't come this way.
            let items = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] } + (delegate.statusMenu?.items ?? [])
            let quits = items.filter { $0.keyEquivalent == "q" }
            try check(quits.count == 2 && quits.allSatisfy { $0.action == #selector(AppDelegate.quitGlide(_:)) },
                      "the Quit items don't ask first")
            try check(items.contains { $0.keyEquivalent == "/" && $0.action == #selector(AppDelegate.showShortcuts(_:)) },
                      "no Help › Keyboard Shortcuts (⌘/)")
            // Asking here puts nothing on screen (the sandbox draws it instead) and quits nothing.
            QuitConfirm.ask()
            try check(!QuitConfirm.isShowing && NSApp.windows.allSatisfy { !$0.isVisible }, "the quit card went on screen")
            try draw(QuitConfirm.preview(), "the quit card")
            try draw(QuitConfirm.preview(dontAsk: true), "the quit card, don't ask again")
            try draw(ShortcutsSheet(model: model), "the shortcuts sheet")
            // The setting the other way round, and back.
            model.confirmQuit = false
            try check(UserDefaults.standard.object(forKey: AppModel.confirmQuitKey) as? Bool == false, "Don't ask again wasn't saved")
            model.confirmQuit = true
            try check(model.lightIntensity == AppModel.defaultLightIntensity, "the Light setting doesn't start at its default")
            return "⌘Q asks, ⌘Q again quits, never over a modal; card and shortcuts sheet drawn, nothing shown"
        }

        step("what's new") {
            // The table: at most five items a version, each with words in it.
            for e in WhatsNew.entries {
                try check(!e.items.isEmpty && e.items.count <= 5, "What's New \(e.version) has \(e.items.count) items (1–5)")
                try check(e.items.allSatisfy { !$0.title.isEmpty && !$0.text.isEmpty }, "What's New \(e.version) has an empty item")
                try check(Set(e.items.map(\.id)).count == e.items.count, "What's New \(e.version) repeats an item id")
            }
            // When it's due: once per major.minor, never without an entry.
            try check(WhatsNew.majorMinor("2.10-beta.7") == "2.10" && WhatsNew.majorMinor("2.10.1") == "2.10"
                      && WhatsNew.majorMinor("3") == "3", "majorMinor reads versions wrong")
            try check(WhatsNew.isDue(seen: nil, version: "2.10-beta.7"), "2.10 isn't due for someone who's never seen one")
            try check(WhatsNew.isDue(seen: "2.9", version: "2.10"), "2.10 isn't due after 2.9")
            try check(!WhatsNew.isDue(seen: "2.10", version: "2.10.1"), "2.10 is due twice")
            try check(!WhatsNew.isDue(seen: nil, version: "0.1"), "a version with no entry is due")
            // What this launch decided.
            let hasEntry = WhatsNew.entry(for: WhatsNew.currentVersion) != nil
            if returning {
                try check(WhatsNew.isPending == hasEntry, "after an update, What's New should\(hasEntry ? "" : "n't") be waiting")
            } else {
                try check(!WhatsNew.isPending, "a fresh install should never get What's New")
            }
            try draw(WhatsNewView(model: model), "What's New", size: RenderUI.windowSize)
            try draw(IconChoicePrompt(model: model), "Glideball has a new look", size: RenderUI.windowSize)
            return (returning ? (hasEntry ? "waiting after an update" : "no entry for this version")
                              : "not shown on a fresh install") + "; drawn, with the icon question"
        }

        step("one thing at a time") {
            let launch = LaunchExperience.shared
            // Never over the launch animation (the short one may already have
            // played out while the tabs were drawn; the intro is still going)…
            var shown: [String] = []
            if launch.show != nil {
                try check(model.presentNextPrompt(ignoringWindow: true) == nil, "a prompt showed over the launch animation")
                // …which ends on a click (the real path: reveal, then finish).
                launch.skip()
                let until = Date().addingTimeInterval(1.5)
                while launch.show != nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                try check(launch.show == nil, "the launch animation didn't end after a skip")
            }
            let icons = AppIconChoice.shared
            if returning {
                // After an update from the classic icon: What's New, then "Glideball has
                // a new look", then the small favor, each on its own (here each one is
                // answered before the next is asked for; in the app the next waits for
                // the next time the window opens).
                // The demo settings answered the small favor long ago; unanswered here, as on
                // a Mac updating from before it existed, so all three take their turns.
                let share = ShareData.shared
                let answered = (share.choice, share.asked)
                share.choice = .nothing
                share.asked = false
                defer { share.choice = answered.0; share.asked = answered.1 }
                try check(icons.promptDue && icons.style == .classic,
                          "an update from the classic icon should keep it and ask (style \(icons.style), asked \(!icons.promptDue))")
                let first = model.presentNextPrompt(ignoringWindow: true)
                if WhatsNew.entry(for: WhatsNew.currentVersion) != nil {
                    try check(first == .whatsNew && model.showingWhatsNew, "What's New didn't come first after an update")
                    try check(!WhatsNew.isPending, "What's New wasn't marked seen")
                    try check(model.presentNextPrompt(ignoringWindow: true) == nil, "something showed on top of What's New")
                    model.closeWhatsNew()
                    shown.append("What's New")
                } else {
                    try check(first != .whatsNew, "What's New showed for a version without one")
                }
                try check(!model.showingWhatsNew, "What's New didn't close")
                let second = WhatsNew.entry(for: WhatsNew.currentVersion) != nil
                    ? model.presentNextPrompt(ignoringWindow: true) : first
                try check(second == .iconChoice && model.showingIconChoice, "the icon question didn't come after What's New (got \(String(describing: second)))")
                try check(model.presentNextPrompt(ignoringWindow: true) == nil, "something showed on top of the icon question")
                // Help › What's New while it's up: the question steps aside and stays due.
                model.showWhatsNew()
                try check(!model.showingIconChoice && icons.promptDue, "What's New by hand didn't put the icon question aside")
                model.closeWhatsNew()
                try check(model.presentNextPrompt(ignoringWindow: true) == .iconChoice, "the icon question didn't come back")
                icons.choose(.classic)   // "Keep the classic one"
                model.showingIconChoice = false
                try check(!icons.promptDue, "the icon question is still due after an answer")
                shown.append("the icon question")
                // Not over a sheet.
                model.showingAbout = true
                try check(model.presentNextPrompt(ignoringWindow: true) == nil, "a prompt showed over a sheet")
                model.showingAbout = false
                let third = model.presentNextPrompt(ignoringWindow: true)
                try check(third == .smallFavor && model.showingSmallFavor, "after the icon question came \(String(describing: third))")
                try check(model.presentNextPrompt(ignoringWindow: true) == nil, "two prompts at once")
                shown.append("the small favor")
            } else {
                // A fresh install: the Orb, no icon question, the tour first and nothing on top of it.
                try check(icons.style == .orb && !icons.promptDue, "a fresh install should get the Orb and no icon question")
                model.showWelcomeTour()
                try check(model.presentNextPrompt(ignoringWindow: true) == nil, "a prompt showed over the Welcome Tour")
                shown.append("the tour")
                model.closeWelcomeTour()
                let next = model.presentNextPrompt(ignoringWindow: true)
                try check(next == (ShareData.shared.shouldAsk ? .smallFavor : nil), "after the tour came \(String(describing: next))")
                try check(next != .whatsNew, "What's New showed on a fresh install")
                try check(next != .iconChoice, "the icon question showed on a fresh install")
                if next == .smallFavor {
                    try check(model.presentNextPrompt(ignoringWindow: true) == nil, "two prompts at once")
                    shown.append("the small favor")
                }
            }
            model.showingSmallFavor = false
            model.showingWhatsNew = false
            model.showingIconChoice = false
            return (shown.isEmpty ? "nothing due" : shown.joined(separator: ", then ") + ", one at a time") + "; never over the launch"
        }

        step("crash report scrubbing") {
            // The same cases as the server's (website/tests/usage.test.mjs), so neither can be got round.
            let cases: [(String, String)] = [
                ("/Users/jane.doe/Desktop/x and /home/bob/y", "/Users/~/Desktop/x and /home/~/y"),
                ("on /Volumes/Backup/z", "on /Volumes/~/z"),
                ("/Users/o'brien/x", "/Users/~/x"),
                ("write to a.b@c.org now", "write to (email) now"),
                ("/Us\u{1}ers/jane/x", "/Users/~/x"),
                ("/Users/ja\u{200B}ne/x", "/Users/~/x"),
                ("/users/jane/x", "/users/~/x"),
                ("/USERS/Jane/x", "/USERS/~/x"),
                ("on /Volumes/Jane Doe's Passport/z", "on /Volumes/~/z"),
                ("on /volumes/My Drive/z", "on /Volumes/~/z"),
                ("j\u{200B}ane@exa\u{2}mple.com", "(email)"),
                ("JANE@EXAMPLE.COM", "(email)"),
                ("a\u{202E}b\u{2066}c\u{FEFF}", "abc"),
                ("line one\nline two", "line one line two"),
            ]
            for (input, expected) in cases {
                let got = CrashReports.scrub(input, max: 200)
                try check(got == expected, "scrub(\(input.debugDescription)) gave \(got.debugDescription), not \(expected.debugDescription)")
            }
            try check(CrashReports.scrub(String(repeating: "x", count: 50), max: 10).count == 10, "scrub doesn't stop at max")
            return "\(cases.count + 1) cases: invisible characters, any case, drive names with spaces"
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
