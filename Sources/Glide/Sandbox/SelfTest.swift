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
/// per step; exits 0 if all pass, 1 on any failure, crash or timeout (30 s; it catches hangs, not slowness).
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
        var timeout = 30.0
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

        step("sharing") {
            // Overview › Share… and a badge › Share…, earned and not yet, end to end:
            // the panel as each opens it (the badge's details turning into the panel,
            // which crashed 2.10 beta 10), the picture, and everything handed out.
            let earnedBadge = try unwrap(Milestone.all.first { model.delight.ledger.earned[$0.id] != nil } ?? (returning ? nil : Milestone.all.first),
                                         "the demo settings have no earned badge")
            let lockedBadge = try unwrap(Milestone.all.first { model.delight.ledger.earned[$0.id] == nil }, "every badge is earned")
            let before = SharePanel.drawnCount
            try draw(SharePanel(card: .overview), "Overview's share panel")
            try draw(BadgeDetail(milestone: earnedBadge, delight: model.delight, sharing: true), "an earned badge's share panel")
            try draw(BadgeDetail(milestone: lockedBadge, delight: model.delight, sharing: true), "a badge-to-earn's share panel")
            try check(SharePanel.drawnCount - before == 3, "the share panels drew \(SharePanel.drawnCount - before) pictures, not 3")
            var posts = 0
            for card in [ShareCard.overview, .badge(earnedBadge, model.delight.ledger.earned[earnedBadge.id] ?? Date()), .badge(lockedBadge, nil)] {
                let image = try unwrap(ShareImage.render(card, delight: model.delight), "the \(card.fileName) picture didn't draw")
                try check(image.pixelsWide == 1200 && image.pixelsHigh == 750, "\(card.fileName) is \(image.pixelsWide)×\(image.pixelsHigh), not 1200×750")
                try check(!Offscreen.isBlank(image), "\(card.fileName) is blank")
                let items = try unwrap(ShareItems(card: card, image: image, delight: model.delight), "\(card.fileName): no share items")
                try check(items.png.starts(with: [0x89, 0x50, 0x4E, 0x47]), "\(card.fileName): not a PNG")
                try check(FileManager.default.fileExists(atPath: items.file.path), "\(card.fileName): the share sheet's file wasn't written")
                try check(!items.text.isEmpty && items.text.count <= 250, "\(card.fileName): the post is \(items.text.count) characters")
                for site in SocialSite.allCases {
                    let url = try unwrap(items.composers[site], "\(card.fileName): no \(site.name) link")
                    try check(url.scheme == "https" && url.host?.isEmpty == false, "\(card.fileName): \(site.name)'s link is \(url)")
                    posts += 1
                }
                let x = URLComponents(url: items.composers[.x]!, resolvingAgainstBaseURL: false)
                try check(x?.queryItems?.first { $0.name == "text" }?.value == items.text, "\(card.fileName): X doesn't get the words as written")
                try? FileManager.default.removeItem(at: items.file)
            }
            // Instagram's copy in Downloads (here: the sandbox's folder), under a fresh name each time.
            let image = try unwrap(ShareImage.render(.overview, delight: model.delight), "the picture didn't draw")
            let a = try unwrap(ShareImage.save(image, name: ShareCard.overview.fileName, in: ShareImage.downloads), "couldn't save to Downloads")
            let b = try unwrap(ShareImage.save(image, name: ShareCard.overview.fileName, in: ShareImage.downloads), "couldn't save a second copy")
            try check(a != b && a.path.hasPrefix(Sandbox.folder.path), "the saved copies collide or left the sandbox")
            return "3 panels drawn (Overview, an earned badge, one to earn); 3 pictures with PNG, file, words and \(posts) post links checked"
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
            // On the card: Return and Enter quit, Esc cancels; nothing else answers (Space can't press anything).
            try check(QuitConfirm.answer(keyCode: 36, modifiers: []) == .quit, "Return didn't quit")
            try check(QuitConfirm.answer(keyCode: 76, modifiers: []) == .quit, "Enter didn't quit")
            try check(QuitConfirm.answer(keyCode: 53, modifiers: []) == .cancel, "Esc didn't cancel")
            try check(QuitConfirm.answer(keyCode: 49, modifiers: []) == .none, "Space answered the card")
            try check(QuitConfirm.answer(keyCode: 36, modifiers: .shift) == .none, "⇧Return quit")
            try draw(QuitConfirm.preview(), "the quit card")
            try draw(ShortcutsSheet(model: model), "the shortcuts sheet")
            // Every in-window shortcut on the sheet is a real key in the menus (or handled by the window).
            for s in AppShortcuts.all where s.menuKey != nil {
                try check(items.contains { $0.keyEquivalent == s.menuKey && $0.keyEquivalentModifierMask == s.menuModifiers },
                          "\(s.title) isn't in the menus with its keys")
            }
            // "Always quit" turns asking off, and the setting is saved; then back on.
            model.confirmQuit = false
            try check(UserDefaults.standard.object(forKey: AppModel.confirmQuitKey) as? Bool == false, "Always quit's setting wasn't saved")
            model.confirmQuit = true
            try check(model.lightIntensity == AppModel.defaultLightIntensity, "the Light setting doesn't start at its default")
            return "⌘Q asks, ⌘Q again or Return quits, Esc cancels, never over a modal; card and shortcuts sheet drawn, nothing shown"
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

        step("switching pages") {
            // The real main window (built, never shown): pages asked for faster than the
            // 0.18 s transition, every page, twice, in both orders; the last one asked for shows.
            let window = try unwrap(delegate.window as? MainWindow, "the main window isn't a MainWindow")
            let content = try unwrap(window.contentView, "the main window has no content")
            Offscreen.settleDown(content, seconds: 0.05)
            try check(model.showTab != nil, "the main window doesn't take page requests directly")
            var asked = 0
            for order in [GlideTab.allCases, GlideTab.allCases.reversed()] {
                for _ in 0..<2 {
                    for tab in order {
                        model.requestTab(tab)   // where the rows, ⌘1…⌘6, ⇧1…⇧6 and the View menu go
                        RunLoop.main.run(until: Date().addingTimeInterval(0.012))
                        asked += 1
                    }
                    Offscreen.settleDown(content, seconds: 0.35)   // the last fade has finished
                    try check(TabPage.showing == [order.last!] && TabPage.onScreen[order.last!] == 1,
                              "after \(asked) quick switches the window shows \(TabPage.onScreen), not just \(order.last!)")
                }
            }
            // ⇧1…⇧6 through the window's own key handling (what a key nothing else wanted reaches).
            for (i, tab) in GlideTab.allCases.enumerated().reversed() {
                let e = try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, characters: "!",
                                                    charactersIgnoringModifiers: "!", isARepeat: false,
                                                    keyCode: AppShortcuts.pageKeyCodes[i]), "couldn't make a key event")
                window.keyDown(with: e)
                Offscreen.settleDown(content, seconds: 0.35)
                try check(TabPage.showing == [tab] && TabPage.onScreen[tab] == 1, "⇧\(i + 1) shows \(TabPage.onScreen), not just \(tab)")
            }
            try check(AppShortcuts.page(keyCode: 18, modifiers: [.shift, .command]) == nil, "⇧⌘1 was taken for a page")
            try check(AppShortcuts.page(keyCode: 18, modifiers: []) == nil, "1 on its own was taken for a page")
            try check(AppShortcuts.page(keyCode: 22, modifiers: .shift) == .backup, "⇧6 isn't Sync")
            model.requestTab(.overview)
            Offscreen.settleDown(content, seconds: 0.25)
            return "\(asked) switches faster than the transition, then ⇧6…⇧1: the page asked for last shows every time"
        }

        step("settings hint") {
            // Gone after five different days, or two weeks after it was first shown, or its ×; never back.
            let d0 = Date(timeIntervalSince1970: 1_800_000_000)
            let day = { (n: Int) in SettingsHintMemory.dayKey(d0.addingTimeInterval(Double(n) * 86_400)) }
            try check(SettingsHintMemory.isDue(firstShown: nil, days: [], gone: false, today: day(0), now: d0), "it doesn't show the first time")
            try check(SettingsHintMemory.isDue(firstShown: d0, days: (0..<5).map(day), gone: false, today: day(4), now: d0 + 4 * 86_400),
                      "it's gone during its fifth day")
            try check(!SettingsHintMemory.isDue(firstShown: d0, days: (0..<5).map(day), gone: false, today: day(5), now: d0 + 5 * 86_400),
                      "it showed on a sixth day")
            try check(!SettingsHintMemory.isDue(firstShown: d0, days: [day(0), day(1)], gone: false, today: day(14), now: d0 + 14 * 86_400),
                      "it showed two weeks after it was first shown")
            try check(!SettingsHintMemory.isDue(firstShown: d0, days: [day(0)], gone: true, today: day(0), now: d0), "it showed after ×")
            let memory = MemoryDefaults()
            try check(SettingsHintMemory.isDue(now: d0, defaults: memory), "it doesn't show on a fresh Mac")
            for n in 0..<5 { SettingsHintMemory.seen(now: d0 + Double(n) * 86_400, defaults: memory) }
            try check(!SettingsHintMemory.isDue(now: d0 + 6 * 86_400, defaults: memory), "seen on five days, it still shows")
            try check(!SettingsHintMemory.isDue(now: d0, defaults: memory), "it came back when the clock went back")
            return "five days or two weeks, whichever first, or ×; never comes back"
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
