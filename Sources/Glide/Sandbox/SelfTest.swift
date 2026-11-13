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
/// per step; exits 0 if all pass, 1 on any failure, crash or timeout (60 s; it catches hangs, not slowness).
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
        var timeout = 60.0
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

        // Every tab laid out at three window widths: one column as the window opens,
        // two columns in a big window, three-wide on a 2560 display (PageLayout.swift).
        step("wide layouts") {
            let widths: [(NSSize, Offscreen.Chrome, (PageWidth) -> Bool, String)] = [
                (RenderUI.windowSize, .mainWindow, { $0 == .single }, "one column"),
                (NSSize(width: 1440, height: 900), .mainWindow, { $0 == .double || $0 == .roomy }, "two columns"),
                (NSSize(width: 2560, height: 1440), .mainWindowFullScreen, { $0 == .triple }, "three-wide"),
            ]
            for (size, chrome, expected, what) in widths {
                for tab in GlideTab.allCases {
                    UserDefaults.standard.set(tab.rawValue, forKey: "GlideInitialTab")
                    PageGrid.measured = nil
                    // Laid out, not drawn (the tabs step above draws them): quick at any size.
                    let (window, _) = Offscreen.host(RootView(model: model), size: size, chrome: chrome, appearance: nil, settle: 0.02)
                    window.contentView = nil
                    window.close()
                    let got = try unwrap(PageGrid.measured, "\(tab.rawValue) at \(Int(size.width)) never measured its width")
                    try check(expected(got), "\(tab.rawValue) at \(Int(size.width)) wide is \(got), not \(what)")
                }
            }
            UserDefaults.standard.removeObject(forKey: "GlideInitialTab")
            return "\(GlideTab.allCases.count) tabs × \(widths.count) widths"
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
            try draw(SharePanel(card: .badge(earnedBadge, model.delight.ledger.earned[earnedBadge.id]), done: {}), "an earned badge's share sheet")
            try draw(SharePanel(card: .badge(lockedBadge, nil), done: {}), "a badge-to-earn's share sheet")
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
            // 2.10 beta 13 crashed on Copy in a badge's popover: anything that changes a popover's
            // size after it opens makes AppKit animate a resize in a nested run loop. Every state
            // of the flow (details, Share…, each note Copy, Save and the site buttons leave, Back)
            // must have exactly one size, again and again.
            let notes: [String?] = [nil, String(localized: "Copied. Paste it anywhere."),
                                    String(localized: "Picture copied. Paste it into the post."),
                                    String(localized: "Saved to Downloads. Instagram only takes uploads from its app or site."),
                                    String(localized: "Couldn’t save it to Downloads. Try Save as PNG… instead."),
                                    String(localized: "Saved “\(ShareCard.overview.fileName)”"),
                                    String(localized: "Couldn’t save it: \("The disk is full, and this is a long reason to make the note wrap onto a second line")")]
            SharePanel.sandboxImage = image
            defer { SharePanel.sandboxImage = nil; SharePanel.sandboxDone = nil }
            // A badge's popover is its details only (Share… opens a sheet), and the panel (in
            // Overview's and the recap's popovers, and the sheet) has one size whatever it says.
            var sizes: [String: Set<String>] = [:]
            var measured = 0
            func measure(_ name: String, _ view: some View) {
                let host = NSHostingView(rootView: view)
                host.layoutSubtreeIfNeeded()
                let s = host.fittingSize
                sizes[name, default: []].insert("\(Int(s.width))×\(Int(s.height))")
                measured += 1
            }
            for _ in 0..<3 {
                measure("earned badge", BadgeDetail(milestone: earnedBadge, delight: model.delight))
                measure("badge to earn", BadgeDetail(milestone: lockedBadge, delight: model.delight))
                for note in notes {
                    SharePanel.sandboxDone = note
                    measure("panel", SharePanel(card: .overview))
                    measure("panel", SharePanel(card: .badge(earnedBadge, model.delight.ledger.earned[earnedBadge.id]), done: {}))
                    measure("panel", SharePanel(card: .badge(lockedBadge, nil), done: {}))
                }
            }
            for (name, s) in sizes { try check(s.count == 1, "the \(name) has more than one size: \(s.sorted())") }
            try check(sizes["panel"] == ["\(Int(SharePanel.width))×\(Int(SharePanel.height))"], "the panel isn't its fixed size: \(sizes["panel"] ?? [])")
            // Share… on a badge: the popover closes, then the sheet opens over the window.
            model.sharingPicture = SharePictureRequest(card: .badge(earnedBadge, model.delight.ledger.earned[earnedBadge.id]))
            try draw(RootView(model: model), "the window with a badge's share sheet")
            model.sharingPicture = nil
            return "3 panels drawn (Overview, an earned badge, one to earn); 3 pictures with PNG, file, words and \(posts) post links checked; \(measured) states of the flow, one size"
        }

        step("receiving a shared setup") {
            // A glideball://import link, a shared file and KensingtonWorks' settings, through the
            // app's real receive path: a preview and nothing else until Apply; one at a time; a
            // checkpoint, the change and Undo; the primary button never changes; hostile links refused.
            let before = model.config
            var theirs = before
            theirs.buttons = [0: .disabled, 2: .openApp(bundleID: "com.apple.Notes"), 3: .shortcut(.copy)]
            theirs.chords = [Chord(buttons: [2, 3], action: .shortcut(.missionControl))]
            let share = try unwrap(SharedSetup.make(.buttons, from: theirs, look: nil), "couldn't make a share")
            let web = try unwrap(share.link(), "the share didn't fit in a link")
            try check(web.absoluteString.hasPrefix(SharedSetup.webPrefix), "Copy Link isn't the website's /s/ link")
            let link = try unwrap(share.appLink(), "no glideball:// link")
            try check(web.fragment == URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first?.value,
                      "the website link and the glideball:// link carry different payloads")
            guard case .success(let parsed)? = ExternalControl.parseImport(link) else { throw Failure("a good link was refused") }
            model.lastIncomingClosed = -.infinity
            if LaunchExperience.shared.show != nil {
                // The launch animation is still up: the preview waits its turn ("one thing at a time" covers the order).
                model.receiveShare(parsed, from: .link)
                try check(model.pendingIncoming == nil && model.queuedIncoming != nil, "a link's preview showed over the launch animation")
                model.queuedIncoming = nil
                model.incomingIgnoresLaunch = true
            }
            defer { model.incomingIgnoresLaunch = false }
            // A brand-new Mac with the Welcome Tour up: the link waits, and shows once the tour closes.
            // (What's New and the icon question come before a waiting preview after an update,
            // so the order is only checked on a fresh install; "one thing at a time" covers the rest.)
            if !WhatsNew.isPending && !AppIconChoice.shared.promptDue && !model.showingWelcomeTour {
                defer {
                    model.pendingIncoming = nil
                    model.queuedIncoming = nil
                    model.lastIncomingClosed = -.infinity
                }
                model.showWelcomeTour()
                model.receiveShare(parsed, from: .link)
                try check(model.pendingIncoming == nil && model.queuedIncoming != nil, "a link's preview showed over the Welcome Tour")
                model.closeWelcomeTour()
                try check(model.queuedIncoming != nil && !model.incomingMustWait, "the link that waited for the tour was dropped")
                if LaunchExperience.shared.show == nil {
                    try check(model.presentNextPrompt(ignoringWindow: true) == .importPreview && model.pendingIncoming != nil && model.queuedIncoming == nil,
                              "the link that waited for the tour didn't show after it")
                } else {
                    // The first-launch intro is still playing: it waits for that too (the order is checked in "one thing at a time").
                    try check(model.presentNextPrompt(ignoringWindow: true) == nil && model.queuedIncoming != nil,
                              "the link that waited for the tour showed over the launch animation")
                }
            }
            model.receiveShare(parsed, from: .link)
            let pending = try unwrap(model.pendingIncoming, "a link didn't open a preview")
            try check(model.config == before, "a link changed settings before Apply")
            let changes = model.changes(for: pending)
            try check(changes.contains { $0.caution && $0.after?.contains("com.apple.Notes") == true }, "the Open isn't listed with its bundle ID")
            try check(!changes.contains { $0.title == ImportReview.buttonName(0) }, "the preview offers to change the primary button")
            model.receiveShare(parsed, from: .link)
            try check(model.pendingIncoming?.id == pending.id, "a second link replaced the open preview")
            try draw(IncomingSetupSheet(model: model, incoming: pending), "the preview of a link")
            let backupsBefore = model.backups.backups.count
            model.applyIncoming()
            try check(model.pendingIncoming == nil, "Apply left the preview open")
            try check(model.config.buttons[2] == .openApp(bundleID: "com.apple.Notes") && model.config.buttons[0] == before.buttons[0],
                      "Apply didn't apply, or changed the primary button")
            try check(model.backups.backups.count == backupsBefore + 1, "no checkpoint before Apply")
            try check(model.toast?.action == .undoImport, "no Undo after Apply")
            model.undoImport()
            try check(model.config == before, "Undo didn't put everything back")
            // Leaving parts out in the preview: only the ticked ones change.
            model.lastIncomingClosed = -.infinity
            model.receiveShare(parsed, from: .link)
            try check(model.pendingIncoming != nil, "the link didn't open its preview again")
            model.applyIncoming(parts: [.combos])
            try check(model.config.chords.map(\.buttons) == [[2, 3]] && model.config.buttons == before.buttons,
                      "applying only Combos changed the buttons, or not the combos")
            model.undoImport()
            try check(model.config == before, "Undo after a partial apply didn't put everything back")
            model.receiveShare(parsed, from: .link)
            try check(model.pendingIncoming == nil, "a link right after a preview closed opened another")

            for bad in ["glideball://import?d=AAAA", "glideball://import?d=" + String(repeating: "A", count: 3000),
                        "glideball://import?d=\(SharedSetup.base64url(SharedSetup.deflate(Data(repeating: 0x5B, count: 500_000))!))"] {
                if let url = URL(string: bad), case .success? = ExternalControl.parseImport(url) { throw Failure("a hostile link was accepted") }
            }

            // A shared file opens the same preview (and Cancel changes nothing).
            model.lastIncomingClosed = -.infinity
            let file = try unwrap(model.shareFile(share, name: "Self-test share"), "couldn't write a share file")
            model.previewImport(file)
            try check(model.pendingIncoming?.source == .file("Self-test share"), "a shared file didn't open the share preview")
            model.cancelIncoming()
            try check(model.config == before && model.pendingImport == nil, "Cancel changed something")

            // KensingtonWorks (the sample: a render never reads the real file).
            RenderUI.useSampleKensingtonWorks()
            defer { KensingtonWorksSource.sandboxSettings = nil }
            try check(KensingtonWorksSource.found, "the sample KensingtonWorks settings weren't found")
            model.previewKensingtonWorks()
            let kw = try unwrap(model.pendingIncoming, "no KensingtonWorks preview")
            try check(!kw.notes.isEmpty && !model.changes(for: kw).isEmpty, "the KensingtonWorks preview is empty")
            try draw(IncomingSetupSheet(model: model, incoming: kw), "the KensingtonWorks preview")
            model.cancelIncoming()
            try check(model.config == before, "previewing KensingtonWorks changed something")

            // Share…: the sheet and the picture with its QR code.
            try draw(ShareSetupSheet(model: model, request: ShareRequest(kind: .scrolling)), "Share…")
            let scrollLink = model.share(.scrolling)?.link()?.absoluteString
            try check(scrollLink.flatMap(QRCode.image) != nil, "no QR code for the link")
            let picture = try unwrap(ShareImage.render(.setup(model.setupCard(.scrolling, link: scrollLink)), delight: model.delight), "the setup picture didn't draw")
            try check(picture.pixelsWide == 1200 && !Offscreen.isBlank(picture), "the setup picture is wrong")
            model.lastIncomingClosed = -.infinity
            return "link and file previewed, nothing changed until Apply; checkpoint, Undo; one at a time; 3 hostile links refused; KensingtonWorks previewed; Share… and its picture drawn"
        }

        step("search index") {
            // Every row on every page and Settings tab sits inside a `.findable`, and every
            // Findable is drawn on its page: the index can't drift from the pages.
            let ids = Findable.all.map(\.id)
            let twice = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
            try check(twice.isEmpty, "Findables share ids: \(twice)")
            let known = Set(ids).union(SearchIndex.dynamicAnchors(model))
            // KensingtonWorks' settings on this Mac (the sample), so its Sync row is drawn too.
            RenderUI.useSampleKensingtonWorks()
            defer { KensingtonWorksSource.sandboxSettings = nil }
            FindableAudit.rows = []
            FindableAudit.anchors = []
            FindableAudit.recording = true
            defer { FindableAudit.recording = false }
            let mode = model.config.scrollMode
            for tab in GlideTab.allCases {
                try draw(TabPage(tab: tab, model: model).frame(width: Theme.Space.contentMaxWidth), "the \(tab.rawValue) page")
            }
            for m in ScrollMode.allCases where m != mode {
                model.config.scrollMode = m
                try draw(TabPage(tab: .scroll, model: model).frame(width: Theme.Space.contentMaxWidth), "Scrolling in \(m.rawValue)")
            }
            model.config.scrollMode = mode
            let width = SettingsWindowController.width
            try draw(GeneralSettingsPane(model: model).frame(width: width), "Settings › General")
            try draw(LookSettingsPane(model: model).frame(width: width), "Settings › Look")
            try draw(SoundSettingsPane().frame(width: width), "Settings › Sound")
            try draw(UpdatesSettingsPane(model: model).frame(width: width), "Settings › Updates")
            try draw(PrivacySettingsPane().frame(width: width), "Settings › Privacy")
            try draw(ShortcutsSettingsPane(model: model).frame(width: width), "Settings › Shortcuts")
            FindableAudit.recording = false
            let rows = FindableAudit.rows
            let loose = Set(rows.filter { $0.findable == nil }.map(\.title)).sorted()
            try check(loose.isEmpty, "rows search can't find (give each a Findable): \(loose)")
            let unknown = Set(rows.compactMap(\.findable)).subtracting(known).sorted()
            try check(unknown.isEmpty, "rows inside a Findable the index doesn't have: \(unknown)")
            let undrawn = Findable.all.filter { !$0.sometimes && !FindableAudit.anchors.contains($0.id) }.map(\.id)
            try check(undrawn.isEmpty, "Findables no page drew: \(undrawn)")

            // Typing a setting's name finds it, near the top.
            let items = SearchIndex.items(model)
            func search(_ q: String) -> [PaletteItem] { PaletteResults.search(q, in: items, recent: []).flat }
            for f in Findable.all where SearchIndex.present(f, model) {
                let top = search(f.title).prefix(4).map(\.id)
                try check(top.contains("find:" + f.id), "searching “\(f.title)” doesn't find it near the top (got \(top))")
            }
            // Every command has an entry (the ones shown as part of another, through it).
            for c in Commands.all {
                let id = SearchIndex.commandAliases[c.id] ?? c.id
                try check(items.contains { $0.command == id || $0.command == c.id }, "the \(c.id) command has no search entry")
            }
            // Words people type.
            try check(search("speed").first?.id == "find:tracking-speed", "“speed” doesn't put Tracking speed first (got \(search("speed").first?.title ?? "nothing"))")
            try check(search("dark").isEmpty, "“dark” found \(search("dark").map(\.title))")
            try check(search("qwzx").isEmpty, "nonsense found something")
            try check(search("trakcing").contains { $0.id == "find:tracking-speed" }, "a typo (“trakcing”) loses Tracking speed")
            try check(search("scrol").prefix(3).contains { $0.id == "find:scroll-mode" }, "“scrol” doesn't find Scroll mode")
            try check(search("sensitivity").first?.id == "find:tracking-speed", "the synonym “sensitivity” doesn't find Tracking speed")
            try check(search("pause").first?.command == "toggle", "“pause” doesn't put Pause first")
            try check(search("speed 12").first?.id == "cmd:pointer-speed-set", "“speed 12” doesn't offer to set it")
            try check(search("top right").contains { $0.id == "button:3" }, "“top right” doesn't find the button")
            let badge = Milestone.all[0]
            try check(search(badge.title).contains { $0.id == "badge:" + badge.id }, "the badge “\(badge.title)” isn't found")
            try check(search("raycast").first?.findable == Findable.externalControl.id, "“raycast” doesn't find its switch")
            // Sharing a setup and importing from KensingtonWorks: their rows and their actions.
            try check(FindableAudit.anchors.isSuperset(of: [Findable.shareSetup.id, Findable.kensingtonWorks.id]), "the Share and KensingtonWorks rows aren't findable")
            let share = search("share").map(\.id)
            try check(share.contains("find:" + Findable.shareSetup.id), "“share” doesn't find Share a setup")
            for kind in ShareKind.choosable {
                try check(search(PageShareMenu.menuTitle(kind)).prefix(3).contains { $0.id == "app:share-\(kind.rawValue)" }, "“\(PageShareMenu.menuTitle(kind))” isn't found")
            }
            try check(search("qr").contains { $0.id == "app:share-everything" }, "“qr” doesn't find Share")
            let kw = search("kensingtonworks").map(\.id)
            try check(kw.contains("find:" + Findable.kensingtonWorks.id) && kw.contains("app:kensingtonworks"), "“kensingtonworks” finds \(kw)")
            // Nothing typed: suggestions, then what was picked lately, newest first.
            let empty = PaletteResults.search("", in: items, recent: [])
            try check(empty.sections.count == 1 && !empty.flat.isEmpty, "nothing typed shows no suggestions")
            PaletteRecents.used("find:fly-glide")
            PaletteRecents.used("cmd:precision")
            let recent = PaletteResults.search("", in: items, recent: PaletteRecents.ids).flat.map(\.id)
            try check(recent.prefix(2) == ["cmd:precision", "find:fly-glide"], "recent picks show as \(recent)")
            UserDefaults.standard.removeObject(forKey: PaletteRecents.key)
            // ⌘K and ⌘F are in the View menu.
            let menuItems = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
            for key in ["k", "f"] {
                try check(menuItems.contains { $0.keyEquivalent == key && $0.action == #selector(AppDelegate.openSearch(_:)) }, "no ⌘\(key.uppercased()) for search")
            }
            CommandPalette.shared.prepare(model)
            // (A longer settle: its field takes focus a turn after it appears, and a short one sometimes caught nothing.)
            try draw(CommandPaletteView(model: model), "the search palette", size: RenderUI.windowSize, settle: 0.3)
            return "\(rows.count) rows on \(GlideTab.allCases.count + 2) pages and 6 Settings tabs, all findable; \(ids.count) settings, "
                + "\(items.count) entries, every command; typos, synonyms and “dark” checked"
        }

        step("weekly recap") {
            // When: once a week, only after real use, never twice, never with recaps off.
            try check(RecapCenter.isDue(enabled: true, seenWeek: "2026-10-26", lastWeek: "2026-11-02", hadRealUse: true), "a recap after a real week isn't due")
            try check(!RecapCenter.isDue(enabled: false, seenWeek: nil, lastWeek: "2026-11-02", hadRealUse: true), "due with recaps off")
            try check(!RecapCenter.isDue(enabled: true, seenWeek: "2026-11-02", lastWeek: "2026-11-02", hadRealUse: true), "due twice for one week")
            try check(!RecapCenter.isDue(enabled: true, seenWeek: nil, lastWeek: "2026-11-02", hadRealUse: false), "due after a week of hardly any use")
            // Weeks start on Monday, whatever the region says.
            let cal = Calendar(identifier: .gregorian)
            let thursday = try unwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 15)), "no date")
            let start = WeeklyRecap.weekStart(containing: thursday)
            try check(Calendar.current.component(.weekday, from: start) == 2 && Calendar.current.component(.day, from: start) == 9,
                      "the week of Thu 12 Nov starts \(start)")
            // Made from each day's totals and the badges' dates.
            func day(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: start)! }
            let days: [String: Tally] = [
                DelightCenter.key(for: day(-3)): Tally(clicks: 1_000, ballMeters: 20, scrollMeters: 30),
                DelightCenter.key(for: day(0)): Tally(clicks: 1_500, ballMeters: 25, scrollMeters: 40),
                DelightCenter.key(for: day(2)): Tally(clicks: 4_000, ballMeters: 60, scrollMeters: 120),
                DelightCenter.key(for: day(6)): Tally(clicks: 50, ballMeters: 1, scrollMeters: 2),
                DelightCenter.key(for: day(7)): Tally(clicks: 9_999),
            ]
            let earned = ["clicks-1k": day(1), "ball-10": day(-1), "scroll-10": day(7)]
            let r = WeeklyRecap.make(start: start, tally: { days[DelightCenter.key(for: $0)] ?? Tally() }, earned: earned)
            try check(r.total.clicks == 5_550 && r.before.clicks == 1_000, "the week adds up to \(r.total.clicks) clicks, the week before \(r.before.clicks)")
            try check(r.busiestDay.map { Calendar.current.isDate($0.date, inSameDayAs: day(2)) } == true, "the busiest day isn't Wednesday")
            try check(r.newBadges == ["clicks-1k"], "the week's badges are \(r.newBadges)")
            try check(r.hadRealUse && r.activeDays == 2, "two real days counted as \(r.activeDays)")
            if case .up = r.change(.clicks) {} else { throw Failure("more clicks than the week before isn't “up”") }
            let quiet = WeeklyRecap.make(start: start, tally: { Calendar.current.isDate($0, inSameDayAs: day(-3)) ? Tally(clicks: 9_000, ballMeters: 90, scrollMeters: 90)
                                                                 : Calendar.current.isDate($0, inSameDayAs: day(1)) ? Tally(clicks: 300, ballMeters: 2, scrollMeters: 2) : Tally() },
                                         earned: [:])
            try check(quiet.change(.clicks) == .down && !quiet.hadRealUse, "a quieter week reads as \(quiet.change(.clicks)), real use \(quiet.hadRealUse)")
            // This Mac's own history: none on a fresh install, so never a recap there.
            let due = RecapCenter.shared.due(model.delight)
            if returning {
                try check(due != nil, "a returning user with a month of use has no recap due")
            } else {
                try check(due == nil, "a fresh install has a recap due")
            }
            // The card, and its share picture end to end.
            let recap = RecapCenter.shared.recap(for: .lastWeek, model.delight) ?? r
            try draw(RecapCard(recap: recap, model: model), "the recap card", size: RenderUI.windowSize)
            let image = try unwrap(ShareImage.render(.recap(recap), delight: model.delight), "the recap's picture didn't draw")
            try check(image.pixelsWide == 1200 && image.pixelsHigh == 750 && !Offscreen.isBlank(image), "the recap's picture is wrong")
            let items = try unwrap(ShareItems(card: .recap(recap), image: image, delight: model.delight), "the recap has no share items")
            try check(!items.text.isEmpty && items.text.count <= 250, "the recap's post is \(items.text.count) characters")
            try? FileManager.default.removeItem(at: items.file)
            return "Mondays, real use only, once a week; sums, busiest day, badges; \(returning ? "due after a month of use" : "none on a fresh install"); card and picture drawn"
        }

        step("try before you change") {
            let preview = TryPreview.shared
            var value = 5.0
            var enabled = true, connected = true
            preview.conditions = { (enabled, connected) }
            defer { preview.conditions = { (AppModel.shared.config.enabled, AppModel.shared.status.deviceConnected) } }
            func start(_ id: String = "test") {
                preview.begin(id: id, was: "5", what: "", countdown: false) { value = 5 }
                value = 9
            }
            // Ten seconds after letting go, it goes back; not a moment before; never mid-drag.
            start()
            preview.check(now: Date().addingTimeInterval(TryPreview.seconds * 5))
            try check(value == 9 && preview.isActive, "it went back mid-drag")
            preview.startCountdown(id: "test", what: "9")
            preview.check(now: Date().addingTimeInterval(TryPreview.seconds - 1))
            try check(value == 9 && preview.isActive, "it went back early")
            preview.check(now: Date().addingTimeInterval(TryPreview.seconds + 0.5))
            try check(value == 5 && !preview.isActive && preview.lastEnding == .timedOut, "time's up didn't put it back")
            // Keep keeps; Go Back (Esc) puts it back.
            start(); preview.startCountdown(id: "test", what: "9"); preview.keep()
            try check(value == 9 && !preview.isActive && preview.lastEnding == .kept, "Keep didn't keep")
            start(); preview.cancel()
            try check(value == 5 && preview.lastEnding == .cancelled, "Esc didn't put it back")
            // Pause, unplug and quit put it back.
            start(); enabled = false; preview.check()
            try check(value == 5 && preview.lastEnding == .paused, "pausing didn't put it back")
            enabled = true
            start(); connected = false; preview.check()
            try check(value == 5 && preview.lastEnding == .unplugged, "unplugging didn't put it back")
            connected = true
            start(); preview.revert(.quit)
            try check(value == 5 && preview.lastEnding == .quit, "quitting didn't put it back")
            // Only one at a time: trying another puts the first back.
            start("a")
            var other = 1.0
            preview.begin(id: "b", was: "1", what: "", countdown: true) { other = 1 }
            other = 2
            try check(value == 5 && preview.isTrying("b"), "a second preview left the first one in place")
            preview.cancel()
            try check(other == 1, "the second preview didn't go back")
            // Return and Enter keep, Esc goes back, nothing else answers.
            try check(TryPreview.key(36) == .keep && TryPreview.key(76) == .keep && TryPreview.key(53) == .cancel && TryPreview.key(49) == nil,
                      "the countdown's keys are wrong")
            // The real thing: the tracking speed on trial, then Glideball paused.
            preview.conditions = { (AppModel.shared.config.enabled, AppModel.shared.status.deviceConnected) }
            let saved = model.config.trackingSpeed
            preview.begin(id: "slider:Tracking speed", was: saved.twoDigits, what: "", countdown: true) { model.config.trackingSpeed = saved }
            model.config.trackingSpeed = saved + 10
            try draw(PointerView(model: model).frame(width: Theme.Space.contentMaxWidth), "the Pointer page with a speed on trial")
            model.config.enabled = false
            preview.check()
            try check(model.config.trackingSpeed == saved && !preview.isActive && preview.lastEnding == .paused,
                      "pausing left the tried speed (\(model.config.trackingSpeed), saved \(saved))")
            model.config.enabled = true
            return "goes back after 10 s (never mid-drag), Keep keeps, Esc, pause, unplug and quit put it back, one at a time"
        }

        step("menu bar panel") {
            try check(MenuBarPanelController.shared.opens == .menu, "the menu-bar icon should open its menu unless the panel is picked")
            try check(!MenuBarPanelController.shared.isOpen && !model.panelOpen, "the panel is open")
            try draw(MenuBarPanelView(model: model), "the menu-bar panel")
            return "the menu by default; the panel drawn, nothing open"
        }

        step("connection state follows the engine") {
            // Levi, beta 13: unplugged with the window open, it kept saying Connected. Every
            // place that shows the connection reads `model.status`, and must be told (by
            // Observation) the moment the engine publishes a change, both ways, without the
            // window closing.
            let saved = (model.status, model.hasAccessibility, model.hasInputMonitoring, model.config.enabled)
            defer {
                model.status = saved.0; model.hasAccessibility = saved.1; model.hasInputMonitoring = saved.2
                model.config.enabled = saved.3
            }
            model.hasAccessibility = true; model.hasInputMonitoring = true; model.config.enabled = true
            var on = DemoData.connected
            on.connection = .usb
            var off = on
            off.deviceConnected = false; off.deviceName = nil; off.connection = nil
            for (from, to) in [(on, off), (off, on), (on, off)] {
                model.status = from
                final class Flag: @unchecked Sendable { var on = false }
                let told = Flag()
                withObservationTracking {
                    _ = SidebarStatus(model).text
                    _ = TrackballLook.of(model)
                    _ = MenuBarIcon.state(of: model)
                    _ = model.shownConnection
                } onChange: { told.on = true }
                model.status = to
                try check(told.on, "the views weren't told the connection changed (\(from.deviceConnected) → \(to.deviceConnected))")
                let c = to.deviceConnected
                let text = SidebarStatus(model).text
                try check(text == (c ? String(localized: "Connected", comment: "Status pill") : String(localized: "Not connected", comment: "Status pill")),
                          "the sidebar says \(text)")
                try check((TrackballLook.of(model) == .connected) == c, "the sidebar trackball is \(TrackballLook.of(model))")
                try check((MenuBarIcon.state(of: model) == .notConnected) == !c, "the menu-bar icon is \(MenuBarIcon.state(of: model))")
                try check((model.shownConnection != nil) == c, "Overview's connection line")
                try check(ExternalControlCenter.snapshot().trackballConnected == c, "status.json")
                try draw(RootView(model: model), "the window, \(c ? "connected" : "unplugged")")
            }
            return "sidebar, trackball, menu-bar icon, Overview line and status.json follow an unplug and a replug at once"
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
            // A shared setup the person opens: shown straight away when nothing's up,
            // queued behind the launch animation, the tour, a sheet or another card.
            let incomingShare = try unwrap(SharedSetup.make(.scrolling, from: model.config, look: nil), "couldn't make a share")
            func openIncoming() {
                model.lastIncomingClosed = -.infinity
                model.receiveShare(incomingShare, from: .link)
            }
            func closeIncoming() {
                model.pendingIncoming = nil
                model.queuedIncoming = nil
                model.lastIncomingClosed = -.infinity
            }
            var queuedOverLaunch = false
            if launch.show != nil {
                try check(model.presentNextPrompt(ignoringWindow: true) == nil, "a prompt showed over the launch animation")
                openIncoming()
                try check(model.pendingIncoming == nil && model.queuedIncoming != nil, "a link's preview showed over the launch animation")
                queuedOverLaunch = true
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
                // A link opened while the icon question is up waits its turn.
                if !queuedOverLaunch { openIncoming() }
                try check(model.pendingIncoming == nil && model.queuedIncoming != nil, "a link's preview showed on top of the icon question")
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
                // The waiting preview comes next, before the recap (the person asked for it).
                try check(RecapCenter.shared.due(model.delight) != nil, "no recap due to come after the preview")
                let previewTurn = model.presentNextPrompt(ignoringWindow: true)
                try check(previewTurn == .importPreview && model.pendingIncoming != nil && model.queuedIncoming == nil,
                          "after the icon question came \(String(describing: previewTurn)), not the waiting preview")
                try check(model.presentNextPrompt(ignoringWindow: true) == nil, "something showed on top of the preview")
                closeIncoming()
                shown.append("the link's preview")
                // Last week's recap (a month of real use), on its own…
                let third = model.presentNextPrompt(ignoringWindow: true)
                try check(third == .weeklyRecap && RecapCenter.shared.showing != nil, "after the icon question came \(String(describing: third)), not the recap")
                try check(model.presentNextPrompt(ignoringWindow: true) == nil, "something showed on top of the recap")
                RecapCenter.shared.close()
                try check(RecapCenter.shared.due(model.delight) == nil, "the recap is still due after it showed")
                shown.append("the weekly recap")
                // …then the small favor.
                let fourth = model.presentNextPrompt(ignoringWindow: true)
                try check(fourth == .smallFavor && model.showingSmallFavor, "after the recap came \(String(describing: fourth))")
                try check(model.presentNextPrompt(ignoringWindow: true) == nil, "two prompts at once")
                shown.append("the small favor")
            } else {
                // A fresh install: the Orb, no icon question, the tour first and nothing on top of it.
                try check(icons.style == .orb && !icons.promptDue, "a fresh install should get the Orb and no icon question")
                if queuedOverLaunch {
                    // The preview that waited for the launch animation comes first.
                    let p = model.presentNextPrompt(ignoringWindow: true)
                    try check(p == .importPreview && model.pendingIncoming != nil, "the preview that waited for the launch came \(String(describing: p))")
                    closeIncoming()
                    shown.append("the link's preview")
                }
                // With nothing up, a link's preview shows straight away.
                openIncoming()
                try check(model.pendingIncoming != nil && model.queuedIncoming == nil, "a link's preview didn't show with nothing in the way")
                try check(model.presentNextPrompt(ignoringWindow: true) == nil, "a prompt showed over a link's preview")
                closeIncoming()
                model.showWelcomeTour()
                try check(model.presentNextPrompt(ignoringWindow: true) == nil, "a prompt showed over the Welcome Tour")
                openIncoming()
                try check(model.pendingIncoming == nil && model.queuedIncoming != nil, "a link's preview showed over the Welcome Tour")
                shown.append("the tour")
                model.closeWelcomeTour()
                let waited = model.presentNextPrompt(ignoringWindow: true)
                try check(waited == .importPreview && model.pendingIncoming != nil, "after the tour came \(String(describing: waited)), not the waiting preview")
                closeIncoming()
                shown.append("the link's preview")
                try check(RecapCenter.shared.due(model.delight) == nil, "a fresh install has a recap due")
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
            closeIncoming()
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

        step("privacy preview") {
            // Settings › Privacy's "What this sends" lists exactly the keys of what's really sent:
            // each key once, every one labelled (an unlabelled key would show raw), none made up.
            let id = RandomID.make() ?? "GB-TEST"
            let crash = CrashReports.Report.example(installID: id)
            let stats = ShareData.shared.stats(model, installID: id)
            let payloads: [(String, [String: Any], [SendPreview.Field], [SendPreview.Label])] = [
                ("crash report", SendPreview.json(crash), SendPreview.fields(of: crash, labels: SendPreview.crashLabels), SendPreview.crashLabels),
                ("stats", SendPreview.json(stats), SendPreview.fields(of: stats, labels: SendPreview.statsLabels), SendPreview.statsLabels),
            ]
            for (name, json, fields, labels) in payloads {
                let listed = fields.flatMap(\.keys)
                let labelled = labels.flatMap(\.keys)
                try check(!json.isEmpty, "the \(name) didn't encode")
                try check(listed.count == Set(listed).count, "the \(name) preview lists a key twice: \(listed)")
                try check(Set(listed) == Set(json.keys), "the \(name) preview lists \(listed.sorted()), but it sends \(json.keys.sorted())")
                try check(Set(labelled) == Set(json.keys),
                          "the \(name)'s labels cover \(labelled.sorted()), but it sends \(json.keys.sorted()) (a key without a label shows raw)")
            }
            let nothing = SendPreview.make(.nothing, model: model, installID: id)
            try check(nothing.crash.isEmpty && nothing.stats.isEmpty, "Nothing previews something being sent")
            let crashes = SendPreview.make(.crashes, model: model, installID: id)
            try check(!crashes.crash.isEmpty && crashes.stats.isEmpty, "Crash reports only previews stats")
            return "crash report \(payloads[0].1.count) keys, stats \(payloads[1].1.count) keys, all labelled"
        }

        step("the sharing name stays private") {
            // The name typed for sharing (Settings › General › Sharing) goes on pictures and links
            // only when switched on, and never into stats, crash reports, settings, backups or sync.
            let d = UserDefaults.standard
            let name = "Quokka Zyxwvut"
            defer {
                d.removeObject(forKey: SharingName.nameKey)
                d.removeObject(forKey: SharingName.picturesKey)
                d.removeObject(forKey: SharingName.linksKey)
                SharingNameStore.shared.reload()
            }
            try check(!SharingName.onPictures() && !SharingName.inLinks(), "the name switches are on without a name")
            SharingName.setName("  \u{202E}\(name)\u{0007}  ")
            try check(SharingName.name() == name, "the name wasn't cleaned: \(SharingName.name().debugDescription)")
            try check(SharingName.onPictures() && SharingName.inLinks(), "the first name didn't turn both switches on")
            SharingName.setName(String(repeating: "x", count: 200))
            try check(SharingName.name().count == SharingName.maxLength, "the name isn't cut to \(SharingName.maxLength)")
            SharingName.setName(name)

            func contains(_ data: Data?) -> Bool { data.map { String(decoding: $0, as: UTF8.self).contains(name) } ?? false }
            let stats = try JSONEncoder().encode(ShareData.shared.stats(model, installID: "00000000-0000-0000-0000-000000000000"))
            try check(!contains(stats), "the name is in the opt-in stats")
            let ips = Sandbox.folder.appendingPathComponent("Glide-name-test.ips")
            let header = #"{"bug_type":"309","app_version":"2.10","build_version":"1","os_version":"macOS 26.1 (25B1)"}"#
            let body = #"{"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"termination":{"indicator":"for \#(name)"},"#
                + #""asi":{"x":["Fatal error: \#(name) said hi"]},"usedImages":[{"name":"GlideSandbox"}],"faultingThread":0,"#
                + #""threads":[{"frames":[{"imageIndex":0,"imageOffset":12,"symbol":"\#(name)()"}]}]}"#
            try Data((header + "\n" + body).utf8).write(to: ips)
            let report = try unwrap(CrashReports.read(ips, date: Date(), installID: "x"), "the made-up crash report wasn't read")
            try check(!contains(try JSONEncoder().encode(report)), "the name is in a crash report")
            try check(!contains(try JSONEncoder().encode(model.config)), "the name is in the settings (and so in sync and backups)")
            // Settings › Privacy's "What this sends" shows the real payloads, so the name mustn't be there either.
            for choice in ShareChoice.allCases {
                let preview = SendPreview.make(choice, model: model, installID: "00000000-0000-0000-0000-000000000000")
                for field in preview.crash + preview.stats {
                    try check(!field.label.contains(name) && !field.value.contains(name),
                              "the name is in Privacy's “What this sends” (\(choice.rawValue), \(field.label))")
                }
            }
            try check(!contains(try JSONEncoder().encode(CrashReports.Report.example(installID: "x"))),
                      "the name is in the crash report Privacy previews")

            let share = try unwrap(model.share(parts: [.pointer]), "no share")
            try check(share.from == name && contains(try share.fileData()), "the name isn't in a shared file with the switch on")
            SharingName.setInLinks(false)
            let quiet = try unwrap(model.share(parts: [.pointer]), "no share")
            try check(quiet.from == nil && !contains(try quiet.fileData()), "the name went into a share with the switch off")
            try check(ShareCardView(card: .overview, delight: model.delight).name == name, "pictures don't get the name")
            SharingName.setOnPictures(false)
            try check(ShareCardView(card: .overview, delight: model.delight).name == nil, "pictures get the name with the switch off")
            return "cleaned and capped; on pictures and links only when switched on; never in stats, crash reports, settings or the Privacy preview"
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
                                      chrome: Offscreen.Chrome = .plain, allowBlank: Bool = false, settle: Double = 0.02) throws {
        // Wait for the real condition, not a fixed delay: a view whose first layout hasn't
        // landed yet (a sheet with a scroll view, say) draws blank for a moment. Drawn again
        // with a longer settle each time, until it shows something or about 2 s have gone.
        // (2.10 beta 13: "the preview of a link drew nothing" now and then on a fresh install.)
        var wait = settle
        var drawn: NSBitmapImageRep?
        for _ in 0..<6 {
            let rep = Offscreen.render(view, size: size ?? (chrome == .plain ? nil : RenderUI.windowSize), chrome: chrome,
                                       appearance: nil, scale: 1, settle: wait)
            drawn = rep
            if let rep, allowBlank || !Offscreen.isBlank(rep) { return }
            wait = min(max(wait * 4, 0.05), 0.8)
        }
        _ = try unwrap(drawn, "\(what) didn't draw")
        try check(allowBlank, "\(what) drew nothing")
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
