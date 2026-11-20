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

        step("pasting a shared link") {
            // The paste box, ⌘V and Import Setup from Clipboard go the way a glideball://import link
            // goes: the same preview, nothing until Apply, a checkpoint and Undo. The clipboard here
            // is the test's own text, never the real one.
            let before = model.config
            var theirs = before
            theirs.trackingSpeed = before.trackingSpeed == 12 ? 13 : 12
            theirs.buttons[2] = .shortcut(.copy)
            let share = try unwrap(SharedSetup.make([.pointer, .buttons], from: theirs, look: nil, sounds: nil), "couldn't make a share")
            let web = try unwrap(share.link(), "no link").absoluteString
            let message = "Here’s my setup: \(web). Enjoy!"
            guard case .share(let read, .web) = ImportPaste.read(message) else { throw Failure("a link in a message wasn't read") }
            try check((try? read.fileData()) == (try? share.fileData()), "the pasted link read as a different setup")
            let wrong = web.replacingOccurrences(of: "glideball.netlify.app/", with: "glideball.netlify.app.evil.com/")
            try check(ImportPaste.read(wrong).refusal == .notGlideball, "a look-alike host was accepted")

            defer {
                AppModel.readClipboard = { nil }
                model.pasteBox = nil
                model.pendingIncoming = nil
                model.queuedIncoming = nil
                model.incomingIgnoresLaunch = false
                model.lastIncomingClosed = -.infinity
            }
            model.incomingIgnoresLaunch = true
            model.lastIncomingClosed = ProcessInfo.processInfo.systemUptime   // a preview just closed: a link from a page would be dropped
            model.openPasteBox()
            try check(model.pasteBox != nil && model.promptShowing, "Paste a Link… didn't open the box, or something else could show over it")
            try draw(PasteLinkSheet(model: model, request: PasteBoxRequest(text: message)), "the paste box with a link")
            model.reviewPasted(read)
            try check(model.pasteBox == nil, "Review Changes… left the box open")
            if model.pendingIncoming == nil {
                // It waited while the box closed; it takes its turn like any preview that waited.
                try check(model.queuedIncoming != nil, "the pasted link was dropped")
                if WhatsNew.isPending || AppIconChoice.shared.promptDue || model.showingWelcomeTour {
                    model.pendingIncoming = model.queuedIncoming
                    model.queuedIncoming = nil
                } else {
                    try check(model.presentNextPrompt(ignoringWindow: true) == .importPreview, "the pasted link's preview didn't take its turn")
                }
            }
            let pending = try unwrap(model.pendingIncoming, "a pasted link didn't open a preview")
            try check(pending.source == .link && (try? pending.share?.fileData()) == (try? share.fileData()), "the preview isn't the pasted link's")
            try check(model.config == before, "pasting changed settings before Apply")
            model.applyIncoming()
            try check(model.config.trackingSpeed == theirs.trackingSpeed && model.config.buttons[0] == before.buttons[0], "Apply didn't apply the pasted link")
            // (The checkpoint isn't a new file when the newest backup already holds these settings.)
            var saved = before
            saved.enabled = true
            try check(model.backups.backups.first.flatMap(model.backups.load) == saved && model.toast?.action == .undoImport,
                      "no checkpoint of the settings before, or no Undo, after a pasted link")
            model.undoImport()
            try check(model.config == before, "Undo didn't put a pasted link back")

            // Import Setup from Clipboard, and ⌘V on the window.
            model.lastIncomingClosed = -.infinity
            AppModel.readClipboard = { "  \(web)\n" }
            model.importFromClipboard(quiet: true)
            try check(model.pendingIncoming != nil && model.pasteBox == nil, "⌘V with a link on the clipboard didn't open its preview")
            model.cancelIncoming()
            try check(model.config == before, "Cancel after ⌘V changed something")
            AppModel.readClipboard = { wrong }
            model.importFromClipboard(quiet: true)
            try check(model.pendingIncoming == nil && model.pasteBox?.text == wrong, "a look-alike link on the clipboard didn't go to the box to say why")
            model.pasteBox = nil
            AppModel.readClipboard = { "glideball://pause" }
            model.importFromClipboard(quiet: false)
            try check(model.config.enabled == before.enabled && model.pendingIncoming == nil && model.pasteBox != nil, "a pasted command link did something")
            model.pasteBox = nil
            let toastBefore = model.toast?.id
            AppModel.readClipboard = { "just some text I copied" }
            model.importFromClipboard(quiet: true)
            try check(model.pasteBox == nil && model.pendingIncoming == nil && model.toast?.id == toastBefore, "⌘V with ordinary text on the clipboard did something")
            model.importFromClipboard(quiet: false)
            try check(model.pasteBox == nil && model.toast?.id != toastBefore, "Import Setup from Clipboard with no link said nothing")

            // ⌘V reaches the main window when nothing in it takes text (Edit › Paste has no target).
            let window = try unwrap(delegate.window as? MainWindow, "the main window isn't a MainWindow")
            // From the window's content (the SwiftUI hosting view, first responder when a control in
            // the window has the focus ring), not just from the window itself.
            var responder: NSResponder? = window.contentView
            var taker: NSResponder?
            while let r = responder {
                if r.responds(to: #selector(NSText.paste(_:))) { taker = r; break }
                responder = r.nextResponder
            }
            try check(taker === window, "⌘V on the window goes to \(taker.map { String(describing: type(of: $0)) } ?? "nothing"), not the window")
            let item = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            try check(window.validateMenuItem(item), "Edit › Paste is off on the main window")
            return "a link in a message read and previewed (cooldown or not), Apply, checkpoint, Undo; the clipboard: a link, a look-alike, a command link, plain text; ⌘V reaches the window"
        }

        step("set up with AI") {
            // Copy prompt → a chatbot's code pasted into the box → the preview inside the sheet →
            // Apply (a "before AI setup" checkpoint) → Undo, through the real model. Nothing is
            // copied for real (the sandbox never touches the clipboard) and nothing is sent.
            // Settings no backup holds yet, so Apply's checkpoint is a new one.
            let original = model.config
            model.config.ballScrollSpeed = original.ballScrollSpeed == 1.75 ? 1.5 : 1.75
            let before = model.config
            let flow = model.aiSetup
            let sharingName = SharingName.name()
            SharingName.setName("Robin Quill")
            defer {
                SharingName.setName(sharingName)
                model.config = original
                flow.reset()
                model.showingAISetup = false
                model.pendingIncoming = nil
                model.queuedIncoming = nil
                model.pasteBox = nil
                model.incomingIgnoresLaunch = false
                model.lastIncomingClosed = -.infinity
                AppModel.readClipboard = { nil }
            }
            flow.reset()
            let prompt = model.aiPrompt()
            try check(prompt.contains("<my_setup>") && prompt.contains(SetupCode.formatMarker) && prompt.contains("<what_glideball_can_change>"),
                      "the prompt lacks the setup or the reference")
            try check(AIReference.roughTokens(prompt) < AIReference.comfortableTokens, "the prompt is about \(AIReference.roughTokens(prompt)) tokens")
            try check(!prompt.contains("Robin"), "the prompt has the sharing name in it")
            flow.leaveAppNamesOut = true
            // (The reference's own examples name Safari and Figma; your setup is what's checked.)
            let quiet = model.aiSetupCode()
            try check(!model.config.appProfiles.contains { quiet.contains($0.name) || quiet.contains($0.bundleID) } && !quiet.contains("\"apps\""),
                      "Leave app names out left an app setup in the prompt")
            flow.leaveAppNamesOut = false

            model.showAISetup()
            try check(model.showingAISetup && model.promptShowing && flow.step == 1, "Set up with AI didn't open at step 1, or something else could show over it")
            try draw(SetupWithAISheet(model: model), "Set up with AI, step 1")
            try check(model.copyAIPrompt() && flow.copied && flow.step == 2, "Copy Prompt didn't move on to step 2")

            // Your own setup pasted back changes nothing and leaves nothing out.
            flow.text = "```json\n" + model.aiSetupCode() + "\n```"
            let own = model.aiReading(flow.text)
            guard case .code(let ownCode) = own else { throw Failure("your own setup didn't read back as a code: \(own)") }
            try check(ownCode.notes.isEmpty && model.readingMatches(own), "your own setup, pasted back, would change something or left something out: \(ownCode.notes.map(\.path))")

            // A chatbot's code with a mistake in it.
            let code = """
            Here you go! This makes the top left button close tabs and adds a combo for Notes.
            ```json
            {"format": "glideball-ai-setup", "version": 1, "trackingSpeed": \(before.trackingSpeed == 9 ? 10 : 9),
             "buttons": {"0": "rightClick", "2": "keys:cmd+w", "1": "macro:paste twice"},
             "combos": [{"buttons": [1, 2], "action": "open:Notes"}]}
            ```
            """
            flow.text = code
            guard case .code(let r) = model.aiReading(code) else { throw Failure("a chatbot's code wasn't read") }
            try check(r.notes.count == 2 && r.notes.contains { $0.why == .primaryButton }, "the code's mistakes weren't left out: \(r.notes.map(\.path))")
            try draw(SetupWithAISheet(model: model), "Set up with AI, a code pasted")
            model.reviewAICode()
            let incoming = try unwrap(flow.reviewing, "Review Changes… didn't show the preview")
            try check(incoming.source == .aiCode && incoming.from == nil && incoming.leftOut.count == 2, "the preview isn't labelled as a chatbot's, or lost what was left out")
            try check(model.config == before, "reviewing changed something")
            try draw(SetupWithAISheet(model: model), "Set up with AI's preview")
            model.cancelAIReview()
            try check(flow.reviewing == nil && flow.text == code && model.config == before, "Cancel didn't go back to the box as it was")
            model.reviewAICode()
            model.applyAIReview(parts: nil)
            try check(flow.applied && flow.appliedLeftOut.count == 2, "Apply didn't move on to Applied")
            try check(model.config.trackingSpeed != before.trackingSpeed && model.config.buttons[2] == .shortcut(.closeTab)
                      && model.config.buttons[0] == before.buttons[0] && model.config.buttons[1] == before.buttons[1]
                      && model.config.enabled == before.enabled, "Apply didn't apply the code, or changed what it couldn't")
            try check(model.config.chords.contains { $0.buttons == [1, 2] && $0.action == .openApp(bundleID: "com.apple.Notes") }, "the combo for Notes wasn't added")
            // A checkpoint is skipped when the newest backup already holds these settings
            // (an earlier step's), so what counts is that the newest backup can put them back.
            var safe = before; safe.enabled = true
            let newest = try unwrap(model.backups.backups.first, "no backup before the AI setup")
            try check((newest.kind == .beforeAI || model.backups.load(newest) == safe) && model.toast?.action == .undoImport,
                      "no \"before AI setup\" checkpoint (or an equal newest backup), or no Undo")
            try draw(SetupWithAISheet(model: model), "Set up with AI, applied")
            model.undoAISetup()
            try check(model.config == before && !flow.applied, "Undo in the sheet didn't put everything back")

            // Closing the sheet and opening it again finds the box as it was.
            model.showingAISetup = false
            model.showAISetup()
            try check(flow.text == code, "closing the sheet lost what was in the box")
            model.showingAISetup = false

            // A code on the clipboard: ⌘V opens Set up with AI with it in the box.
            AppModel.readClipboard = { code }
            model.importFromClipboard(quiet: true)
            try check(model.showingAISetup && flow.text == code && model.pendingIncoming == nil && model.config == before, "⌘V with a setup code didn't open Set up with AI with it")
            model.showingAISetup = false

            // Paste a Link… takes a code too: the usual preview, labelled as a chatbot's.
            model.incomingIgnoresLaunch = true
            model.reviewPastedCode(r)
            if model.pendingIncoming == nil, let waiting = model.queuedIncoming {
                model.pendingIncoming = waiting
                model.queuedIncoming = nil
            }
            let pending = try unwrap(model.pendingIncoming, "a code in Paste a Link… didn't open a preview")
            try check(pending.source == .aiCode && pending.leftOut.count == 2, "a code in Paste a Link… isn't labelled as a chatbot's")
            try draw(IncomingSetupSheet(model: model, incoming: pending), "a chatbot's code in the usual preview")
            model.cancelIncoming()
            try check(model.config == before, "a code in Paste a Link… changed something before Apply")

            // Shortcuts that delete, quit or log out: flagged, left out unless ticked, and a way
            // back without the trackball's buttons (Undo Last Import, ⌘Z in the window).
            let risky = """
            {"format": "glideball-ai-setup", "version": 1, "buttons": {"2": "keys:cmd+q", "3": "forward"},
             "apps": [{"app": "Figma", "buttons": {"3": {"gesture": {"up": "keys:cmd+c", "right": {"more": {"upRight": "keys:cmd+opt+shift+delete"}}}}}}]}
            """
            flow.text = risky
            model.reviewAICode()
            let riskyIncoming = try unwrap(flow.reviewing, "a code with ⌘Q didn't open the preview")
            let flags = model.changes(for: riskyIncoming).flatMap(\.risks).filter { $0.tier == .destructive }
            try check(flags.count == 2 && flags.contains { $0.id.hasSuffix("#right.more.upRight") }, "the red flags aren't where they sit: \(flags.map(\.id))")
            try draw(SetupWithAISheet(model: model), "the preview with red flags")
            model.applyAIReview(parts: nil)
            try check(model.config.buttons[3] == .forward && model.config.buttons[2] == before.buttons[2], "an unticked ⌘Q was applied, or the rest wasn't")
            if case .gesture(let g)? = model.config.profile(for: "com.figma.Desktop")?.buttons?[3] {
                try check(g.up?.action == .shortcut(.copy) && g.right == nil, "an unticked Empty Trash in a More was applied")
            } else { throw Failure("the app setup's gesture wasn't applied around the flag") }
            try check(model.canUndoImport, "Undo Last Import isn't there after an import")
            let window = try unwrap(delegate.window as? MainWindow, "the main window isn't a MainWindow")
            let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
            try check(window.validateMenuItem(undoItem), "⌘Z doesn't undo the import on the main window")
            let fileUndo = NSMenuItem(title: "Undo Last Import", action: #selector(AppDelegate.undoLastImport(_:)), keyEquivalent: "")
            try check(delegate.validateMenuItem(fileUndo), "Undo Last Import is off in the menus after an import")
            let statusMenu = try unwrap(delegate.statusMenu, "no menu-bar icon menu")
            func statusUndoShown() -> Bool {
                delegate.menuNeedsUpdate(statusMenu)
                return statusMenu.items.contains { $0.action == #selector(AppDelegate.undoLastImport(_:)) && !$0.isHidden }
            }
            try check(statusUndoShown(), "Undo Last Import isn't in the menu-bar icon's menu after an import")
            window.undo(nil)
            try check(model.config == before && !model.canUndoImport && !window.validateMenuItem(undoItem) && !delegate.validateMenuItem(fileUndo)
                      && !statusUndoShown(), "⌘Z on the window didn't undo the import, or Undo stayed on")
            flow.text = risky
            model.reviewAICode()
            let ticked = try unwrap(flow.reviewing, "the code didn't open the preview again")
            model.applyAIReview(parts: nil, confirmed: Set(model.changes(for: ticked).flatMap(\.risks).map(\.id)))
            try check(model.config.buttons[2] == .shortcut(KeyShortcut(keyCode: 12, modifiers: CGEventFlags.maskCommand.rawValue)), "a ticked ⌘Q wasn't applied")
            model.config.trackingSpeed += 1   // a change of your own after the import
            delegate.undoLastImport(nil)
            try check(model.config == before && model.backups.backups.first?.kind == .beforeRestore,
                      "Undo Last Import didn't put things back, or didn't save what you'd changed since")
            flow.reset()
            return "prompt built (\(AIReference.roughTokens(prompt)) tokens), app names left out on request; copy, paste, review inside the sheet, Cancel, Apply (before AI setup checkpoint), Undo; your own setup matches; ⌘V and Paste a Link… take a code"
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
            try draw(TrackballSettingsPane(model: model).frame(width: width), "Settings › Trackball")
            try draw(SharingSettingsPane().frame(width: width), "Settings › Sharing")
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

        step("hold to try on") {
            // Holding a preset card puts the preset on the engine only, for 20 s with the card
            // let go, and every way a try can end takes it off again; only Keep writes it (as
            // Apply does). The person's own settings (the model's, and what's saved) are never
            // the tried-on ones, so a crash mid-try has nothing to undo.
            let t = model.tryOn
            let good = TryOn.Conditions(enabled: true, connected: true, active: true, windowKey: true, leftDown: true,
                                        trackballPrimaryDown: true, trackballButtonsDown: true, busy: false)
            var c = good
            let realConditions = t.conditions
            let saved = (model.status, model.config.enabled)
            t.conditions = { c }
            defer {
                t.end(.quit)
                t.conditions = realConditions
                model.status = saved.0
                model.config.enabled = saved.1
            }
            model.config.enabled = true
            model.status = DemoData.connected
            model.pushToEngine()
            t.watchTheApp()   // the app's own notices (the real app starts this at launch)
            let mine = model.config
            let own = model.engineConfig
            // Two presets that aren't what the buttons already do (a returning user has Spaces).
            let different = ButtonPreset.all.filter { $0.buttons[2] != nil && $0.buttons[2] != own.buttons[2] }
            let preset = try unwrap(different.first, "no preset differs from the setup")
            let other = try unwrap(different.dropFirst().first, "no second preset differs from the setup")
            let id = PresetStrip.tryID(preset)
            var t0 = Date()
            var kept = 0

            @MainActor func untouched(_ when: String) throws {
                try check(model.config == mine, "\(when): the model's settings changed")
                try check(GlideConfig.load() == mine, "\(when): what's saved isn't the person's own setup")
            }
            @MainActor func wearing(_ p: ButtonPreset, _ when: String) throws {
                let e = model.engineConfig
                try check(e.buttons[2] == p.buttons[2] && e.buttons[3] == p.buttons[3]
                            && e.chords.map(\.buttons) == p.chords.map(\.buttons) && e.chords.map(\.action) == p.chords.map(\.action),
                          "\(when): the engine isn't wearing \(p.id)")
                try check(e.buttons[0] == own.buttons[0], "\(when): the primary button's entry changed")
                try untouched(when)
            }
            @MainActor func press(_ when: String) throws {
                c = good
                t0 = Date()
                try check(t.press(id: id, name: preset.title, now: t0, change: { $0 = $0.tryingOn(preset) }, keep: { kept += 1 }),
                          "\(when): the press was refused")
            }
            /// Charged and tried on, then the card let go: the try goes on, hands free.
            @MainActor func tryOn(_ when: String) throws {
                try press(when)
                t.tick(now: t0.addingTimeInterval(TryOn.engageDelay / 2))
                try check(!t.isTrying && t.pressing == id && model.engineConfig == own, "\(when): tried on before the hold was long enough")
                t.tick(now: t0.addingTimeInterval(TryOn.engageDelay))
                try check(t.isTrying(id) && t.pressing == nil, "\(when): holding didn't try it on")
                try wearing(preset, when)
                try check(t.release(id: id), "\(when): letting go of a tried-on card counted as a click")
                c.leftDown = false; c.trackballPrimaryDown = false; c.trackballButtonsDown = false
                t.tick(now: t0.addingTimeInterval(TryOn.engageDelay + 1)); t.tick(now: t0.addingTimeInterval(TryOn.engageDelay + 1.1))
                try check(t.isTrying(id), "\(when): letting go of the card ended the try")
                try wearing(preset, "\(when), let go")
            }
            @MainActor func back(_ why: TryOn.Ending, _ when: String) throws {
                try check(!t.isTrying && t.pressing == nil, "\(when): still trying")
                try check(t.lastEnding == why, "\(when): ended as \(String(describing: t.lastEnding)), expected \(why)")
                try check(!t.hudUp && !TryOnHUD.isShowing, "\(when): the floating panel stayed up")
                if why != .kept {
                    try check(model.engineConfig == own, "\(when): the engine didn't get the person's own setup back")
                    try untouched(when)
                }
            }

            // A click is still a click: let go before the hold takes, nothing is ever tried.
            try press("a click")
            t.tick(now: t0.addingTimeInterval(0.15))
            try check(!t.release(id: id) && !t.isTrying && model.engineConfig == own, "a quick click tried the preset on")
            // Dragged off the card before it took: nothing tried, however long it's held.
            try press("dragged off")
            t.cancelPress()
            t.tick(now: t0.addingTimeInterval(TryOn.engageDelay + 1))
            try check(!t.isTrying && !t.release(id: id), "a press dragged off the card was tried on")
            // The mouse-up never arrives while it charges (macOS says the button is up, two looks
            // in a row), or the trackball's own report says its primary came up: called off.
            try press("lost mouse-up")
            c.leftDown = false
            t.tick(now: t0.addingTimeInterval(0.1))
            try check(t.pressing == id, "one odd answer about the button called the press off")
            t.tick(now: t0.addingTimeInterval(0.2)); t.tick(now: t0.addingTimeInterval(TryOn.engageDelay))
            try check(t.pressing == nil && !t.isTrying, "a press whose mouse-up was lost was still tried on")
            try press("trackball's button up")
            c.trackballPrimaryDown = false
            t.tick(now: t0.addingTimeInterval(0.1)); t.tick(now: t0.addingTimeInterval(0.2)); t.tick(now: t0.addingTimeInterval(TryOn.engageDelay))
            try check(t.pressing == nil && !t.isTrying, "the trackball let go while charging, and it was still tried on")
            // (Held with another mouse, the trackball's primary button was never down: that's no reason.)
            c = good; c.trackballPrimaryDown = false; c.trackballButtonsDown = false
            t0 = Date()
            try check(t.press(id: id, name: preset.title, now: t0, change: { $0 = $0.tryingOn(preset) }), "another mouse: the press was refused")
            t.tick(now: t0.addingTimeInterval(0.2)); t.tick(now: t0.addingTimeInterval(TryOn.engageDelay))
            try check(t.isTrying(id), "a card held with another mouse wasn't tried on")
            t.putBack()
            try back(.putBack, "another mouse")

            // 1. Put mine back.
            try tryOn("put back"); t.putBack(); try back(.putBack, "Put mine back")
            // The page drawn mid-try, then taken away (its onDisappear): that's an ending too.
            try tryOn("the page goes")
            try draw(ButtonsView(model: model).frame(width: Theme.Space.contentMaxWidth), "the Buttons page with a preset tried on")
            try back(.pageLeft, "the page went away")
            // 2. The time runs out, and not a moment before.
            try tryOn("time")
            t.tick(now: t0.addingTimeInterval(TryOn.engageDelay + TryOn.trial - 0.5))
            try check(t.isTrying && t.remaining(at: t0.addingTimeInterval(TryOn.engageDelay + TryOn.trial - 0.5)) > 0.4, "ended before its time")
            t.tick(now: t0.addingTimeInterval(TryOn.engageDelay + TryOn.trial + 0.05))
            try back(.timedOut, "time ran out")
            // 3. Keep: written as Apply writes it (Undo puts theirs back), and nothing tried is left over.
            try tryOn("keep")
            t.keep()
            try check(kept == 1, "Keep ran its apply \(kept) times")
            try back(.kept, "Keep")
            try check(t.remaining() == TryOn.trial, "a countdown still runs after Keep")
            // (The real card's Keep is `AppModel.applyPreset`: what's saved is the preset, then Undo is theirs.)
            model.applyPreset(preset)
            try check(GlideConfig.load().buttons == model.config.buttons && model.config.buttons[2] == preset.buttons[2]
                        && model.engineConfig.buttons[2] == preset.buttons[2],
                      "after Keep the engine or what's saved isn't the kept preset")
            model.undoImport()
            try check(model.config == mine && model.engineConfig == own, "Undo after Keep didn't put theirs back")
            // 4. Off to another app to try it there: it goes on, with the floating panel, and the
            //    panel goes when Glideball's window has the keys again.
            try tryOn("another app")
            c.active = false; c.windowKey = false
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
            t.tick(now: t0.addingTimeInterval(3))
            try check(t.isTrying(id) && t.hudUp, "going to another app ended the try or showed no panel")
            try wearing(preset, "another app")
            c.active = true
            t.tick(now: t0.addingTimeInterval(3.1))
            try check(t.hudUp, "Glideball in front without its window's keys: no panel")
            c.windowKey = true
            t.tick(now: t0.addingTimeInterval(3.2))
            try check(t.isTrying(id) && !t.hudUp, "back in the window: the panel stayed up")
            // The window losing the keys (the model's own path) and Glideball hidden: the same.
            model.windowStateChanged(visible: true, key: false)
            NotificationCenter.default.post(name: NSApplication.didHideNotification, object: nil)
            try check(t.isTrying(id), "the window losing the keys, or hiding, ended the try")
            model.windowStateChanged(visible: true, key: true)
            // The floating panel as it's made (never put on screen here): it can't take the keys
            // or bring Glideball forward, it's on every Space and over full screen, it stays when
            // Glideball hides, and it's no bigger than the pill.
            let hud = TryOnHUD.make(t)
            try check(hud.styleMask.contains(.nonactivatingPanel) && !hud.canBecomeKey && !hud.canBecomeMain,
                      "the floating panel could take the keys or bring Glideball forward")
            try check(hud.collectionBehavior.contains(.canJoinAllSpaces) && hud.collectionBehavior.contains(.fullScreenAuxiliary)
                        && !hud.hidesOnDeactivate && !hud.canHide && hud.level == .statusBar,
                      "the floating panel doesn't stay up over other apps")
            try check(hud.frame.width > 150 && hud.frame.width < 640 && hud.frame.height < 60, "the floating panel is \(hud.frame.size)")
            try check(!hud.isVisible && !TryOnHUD.isShowing, "the floating panel went on screen in the self-test")
            try draw(TryOnPill(tryOn: t, floating: true), "the floating panel")
            try draw(TryOnPill(tryOn: t), "the countdown in the window")
            t.end(.windowClosed)
            try back(.windowClosed, "the window closed")
            // 5. Pause (the model's own switch), and what the engine gets is paused, nothing else.
            try tryOn("pause")
            model.config.enabled = false
            try check(!t.isTrying && t.lastEnding == .paused, "pausing left the preset tried on")
            try check(model.engineConfig.buttons == own.buttons && model.engineConfig.chords == own.chords, "paused with the preset's buttons")
            c.enabled = false
            try check(!t.press(id: id, name: preset.title, change: { $0 = $0.tryingOn(preset) }), "a card can be tried while paused")
            model.config.enabled = true
            try back(.paused, "resumed")
            // 6. Unplugged (the engine's status).
            try tryOn("unplug")
            var off = model.status
            off.deviceConnected = false
            model.status = off
            try check(!t.isTrying && t.lastEnding == .unplugged && model.engineConfig == own, "unplugging left the preset tried on")
            c.connected = false
            try check(!t.press(id: id, name: preset.title, change: { $0 = $0.tryingOn(preset) }), "a card can be tried with no trackball")
            model.status = DemoData.connected
            // 7. The watchdog's own looks: paused, unplugged, Quick Assign or the tour.
            for (change, why): ((inout TryOn.Conditions) -> Void, TryOn.Ending) in [
                ({ $0.enabled = false }, .paused), ({ $0.connected = false }, .unplugged), ({ $0.busy = true }, .busy)] {
                try tryOn("watchdog \(why.rawValue)")
                change(&c)
                t.tick(now: t0.addingTimeInterval(2))
                try back(why, "watchdog \(why.rawValue)")
            }
            // 8. The Mac sleeps, the screens sleep, the user is switched: the real notices. (The
            //    screen locking is a distributed notice, which would reach every app on this Mac,
            //    and quitting's would reach the app's own quit path: both are on the same paths,
            //    and not posted here.)
            let work = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                         NSWorkspace.sessionDidResignActiveNotification] {
                try tryOn(name.rawValue)
                work.post(name: name, object: nil)
                try back(.slept, name.rawValue)
            }
            try tryOn("quit"); t.end(.quit); try back(.quit, "quit")
            // 9. Quick Assign and the tour take the buttons; leaving the page; Esc's key.
            try tryOn("Quick Assign"); model.beginAssign(); try back(.busy, "Quick Assign"); model.cancelAssign()
            try tryOn("tour"); model.mappingsSuspended = true; try check(!t.isTrying && t.lastEnding == .busy, "the tour left it on")
            model.mappingsSuspended = false; model.pushToEngine(); try back(.busy, "the tour")
            try tryOn("page"); t.end(.pageLeft); try back(.pageLeft, "left the page")
            try check(TryPreview.key(53) == .cancel && TryPreview.key(36) == .keep, "Esc and Return aren't Put mine back and Keep")
            // 10. Another card: the first comes off before anything else can go on.
            try tryOn("another card")
            try check(t.press(id: PresetStrip.tryID(other), name: other.title, now: t0, change: { $0 = $0.tryingOn(other) }), "second press refused")
            try check(!t.isTrying && t.lastEnding == .replaced && model.engineConfig == own, "another card pressed: the first stayed on")
            t.cancelPress()
            try back(.replaced, "another card pressed")
            // 11. Their own settings changing underneath (sync, a slider): theirs change, the preset
            //     stays on top, and putting theirs back leaves exactly theirs.
            try tryOn("a change underneath")
            model.config.trackingSpeed = mine.trackingSpeed + 1
            try check(model.engineConfig.trackingSpeed == mine.trackingSpeed + 1 && model.engineConfig.buttons[2] == preset.buttons[2],
                      "a change of their own mid-try didn't reach the engine under the preset")
            try check(GlideConfig.load().buttons == mine.buttons && GlideConfig.load().chords == mine.chords, "the preset was saved with their change")
            t.putBack()
            model.config.trackingSpeed = mine.trackingSpeed
            try back(.putBack, "after a change underneath")

            // The card's mouse catcher: down, dragged off, back on, up; and torn down mid-press.
            let catcher = PressCatcher.CatcherView(frame: NSRect(x: 0, y: 0, width: 100, height: 60))
            var log: [String] = []
            catcher.onDown = { log.append("down") }
            catcher.onInside = { log.append($0 ? "in" : "out") }
            catcher.onUp = { log.append($0 ? "up inside" : "up outside") }
            @MainActor func mouse(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
                try unwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 10), modifierFlags: [], timestamp: 0, windowNumber: 0,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1), "no mouse event")
            }
            catcher.mouseDown(with: try mouse(.leftMouseDown, 10))
            catcher.mouseDragged(with: try mouse(.leftMouseDragged, 300))
            catcher.mouseDragged(with: try mouse(.leftMouseDragged, 20))
            catcher.mouseUp(with: try mouse(.leftMouseUp, 20))
            catcher.mouseUp(with: try mouse(.leftMouseUp, 20))   // a second one does nothing
            catcher.mouseDown(with: try mouse(.leftMouseDown, 10))
            catcher.viewDidMoveToWindow()                        // no window: taken off the page while down
            try check(log == ["down", "out", "in", "up inside", "down", "up outside"], "the card's mouse catcher reported \(log)")
            return "a click stays a click; a hold puts the preset on the engine only, for 20 s with the card let go and in other apps (with the floating panel); Keep writes it as Apply does; Put mine back, 20 s, pause, unplug, sleep, the user switched, quit, the window closing, the page, Quick Assign, the tour and another card take it off; settings and what's saved never change"
        }

        step("the ball's light follows the ball color, readable") {
            // The Gestures ring, its editor and the Switcher's lens are lit in `Theme.light`. Every
            // ball color, and custom ones at the extremes (yellow, near-white, white, very dark,
            // black, a grey), keep it showing on dark and pale glass, its labels and its ink readable.
            let customs: [(String, UInt32)] = [("yellow", 0xFFE070), ("near-white", 0xF4F2EC), ("white", 0xFFFFFF),
                                               ("very dark", 0x101018), ("black", 0x000000), ("grey", 0x808080), ("default", 0x2EC99A)]
            let themes = BallTheme.curated.filter { $0.id != "orb" }.map { ($0.id, $0) }
                + customs.map { ("custom \($0.0)", BallTheme.custom([OrbRGB(hex: 0xFFFFFF), OrbRGB(hex: $0.1), OrbRGB(hex: 0x000000)])) }
            let white = OrbRGB(1, 1, 1), darkGlass = OrbRGB(hex: 0x1E1E22)
            var worst = (label: 99.0, name: "")
            for (name, theme) in themes {
                let v = theme.lightValues
                try check(v.dark.luminance >= BallTheme.darkLightFloor - 0.005, "\(name): its light is too dark to show on dark glass")
                try check(v.light.luminance <= BallTheme.lightLightCeiling + 0.005, "\(name): its light is too pale to show on light glass")
                for fill in [v.dark, v.light] {
                    let c = fill.contrast(BallTheme.label(on: fill))
                    try check(c >= 2.3, "\(name): the lit chip's label reads at \(String(format: "%.2f", c)):1")
                    if c < worst.label { worst = (c, name) }
                }
                let base = theme.palette.mid
                let inkDark = base.luminance(0.30, toward: white), inkLight = base.luminance(0.18, toward: OrbRGB(0, 0, 0))
                try check(inkDark.contrast(darkGlass) >= 4.5 && inkLight.contrast(white) >= 4.5, "\(name): a More's name in its color doesn't read")
            }
            // The Orb is exactly ball blue, as before.
            try check(BallTheme.orb.light == Theme.ball && BallTheme.orb.lightInk == Theme.ball, "the Orb's light isn't ball blue")
            return "\(themes.count) ball colors: the light shows on dark and pale glass, labels at least \(String(format: "%.1f", worst.label)):1 (\(worst.name)), ink at least 4.5:1"
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

        step("press primes everything") {
            // The ring's first frame, measured the way the app measures it (`PressTiming`: from
            // the engine asking to the frame's commit), with the real overlay in its real window.
            // The window is never ordered in here, so this is the main thread's share (building,
            // laying out and committing the first frame), not the window server's or the glass.
            let panel = WheelOverlayPanel.shared
            let timing = PressTiming.shared
            let rings = [ButtonGesture.standard, .media, .tabs, .zoom].map {
                WheelOverlayModel.of($0, level: nil, selected: nil, dot: .zero, ring: nil)
            }
            let at = CGPoint(x: 400, y: 400)
            @MainActor func hold(_ ring: WheelOverlayModel, primed: Bool, rolled: Bool = false) {
                if primed {
                    panel.primeWheel(ring)   // the press
                    Sandbox.spin(0.02)       // (some of) the designed wait
                }
                var shown = ring
                if rolled { shown.dot = CGPoint(x: 0.5, y: -0.25); shown.selected = 0 }   // rolled, and lit one, before it came up
                timing.askedFor(.ring, pressedAt: PressTiming.now())
                panel.showWheel(shown, at: at)
                Sandbox.spin(0.03)           // this turn's commit closes the measurement
                panel.hideWheel()
                Sandbox.spin(0.14)           // the drain, and the window going
            }
            @MainActor func measure(primed: Bool) throws -> PressTiming.Stat {
                timing.reset()
                for i in 0..<6 { hold(rings[i % rings.count], primed: primed, rolled: i % 3 == 2) }
                return try unwrap(PerfProbe.press().ringFirstFrame, "the ring's first frame wasn't measured")
            }
            let cold = try measure(primed: false)
            let warm = try measure(primed: true)
            try check(cold.count == 6 && warm.count == 6, "measured \(cold.count) and \(warm.count) rings, not 6 and 6")
            let frame = PerfProbe.frame
            if let late = timing.slipped(frame: frame) { throw Failure("with the press priming it: \(late)") }
            try check(PerfProbe.press().releaseToAction == nil, "something posted an action in the sandbox")
            timing.reset()

            // What priming is allowed to do: lay the ring out, and nothing anyone could see.
            let state = panel.state
            try check(state.model == nil && !state.shown && !state.primed, "a ring was left behind")
            let before = state.appearCount
            panel.primeWheel(rings[0])
            try check(state.primed && !state.shown && state.appearCount == before + 1, "the press didn't lay the ring out")
            panel.primeWheel(rings[0])
            try check(state.appearCount == before + 1, "the same ring was laid out twice")
            var rolled = rings[0]
            rolled.dot = CGPoint(x: 0.25, y: 0)
            panel.showWheel(rolled, at: at)
            try check(state.shown && !state.primed && state.appearCount == before + 1 && state.model == rolled,
                      "showing the ring the press laid out built it again")
            panel.primeWheel(rings[1])
            try check(state.model == rolled && !state.primed, "a press changed a ring that was up")
            panel.hideWheel()
            Sandbox.spin(0.14)
            try check(state.model == nil && !state.shown, "the ring didn't go")
            // A different ring from the one laid out (another button's): built afresh, as it always was.
            panel.primeWheel(rings[0])
            panel.showWheel(rings[1], at: at)
            try check(state.appearCount == before + 3 && state.model == rings[1] && !state.primed, "a different ring reused the one laid out")
            panel.hideWheel()
            Sandbox.spin(0.14)
            // No visible change: a ring the press laid out ends up drawn exactly as one built at
            // the show does, once its entrance has played.
            let content = try unwrap(panel.contentForTests, "the ring has no window")
            @MainActor func settled(primed: Bool) throws -> NSBitmapImageRep {
                if primed { panel.primeWheel(rings[3]); Sandbox.spin(0.02) }
                panel.showWheel(rings[3], at: at)
                Offscreen.settleDown(content, seconds: 0.5)
                let rep = try unwrap(Offscreen.image(of: content, scale: 1), "the ring didn't draw")
                panel.hideWheel()
                Sandbox.spin(0.14)
                return rep
            }
            let built = try settled(primed: false), laidOut = try settled(primed: true)
            try check(!Offscreen.isBlank(built), "the ring drew nothing")
            let a = try unwrap(built.bitmapData, "no pixels"), b = try unwrap(laidOut.bitmapData, "no pixels")
            let bytes = built.bytesPerRow * built.pixelsHigh
            try check(bytes == laidOut.bytesPerRow * laidOut.pixelsHigh, "the two rings are different sizes")
            var differing = 0
            for i in 0..<bytes where abs(Int(a[i]) - Int(b[i])) > 24 { differing += 1 }
            try check(differing * 200 < bytes, "a primed ring settles differently from one built at the show (\(differing) of \(bytes) bytes differ)")

            // A press whose ring never comes up leaves nothing on screen and nothing running.
            panel.primeWheel(rings[2])
            try check(state.primed && !state.shown && NSApp.windows.allSatisfy { !$0.isVisible }, "a primed ring is on screen")
            func ms(_ s: Double) -> String { String(format: "%.1f", s * 1000) }
            let same = "settles to the same picture (\(differing) of \(bytes) bytes differ)"
            return "ring's first frame, offscreen: not primed med \(ms(cold.median)) worst \(ms(cold.worst)) ms; "
                + "primed at the press med \(ms(warm.median)) worst \(ms(warm.worst)) ms; one frame is \(ms(frame)) ms; \(same)"
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

        step("the stats say which settings, never names, keys or colors") {
            // App setups, shortcut keys, a custom ball color and display names are all set up to be
            // spotted; none of it may reach the stats, which stay small and ranges-only.
            let before = model.config
            let themeBefore = BallThemeStore.shared.theme.id
            defer {
                model.config = before
                BallThemeStore.shared.choose(themeBefore)
            }
            var c = model.config
            c.appProfiles.append(AppProfile(bundleID: "com.example.quokkasecretapp", name: "Quokka Secret App"))
            let key = KeyShortcut(keyCode: 0, modifiers: CGEventFlags.maskCommand.rawValue, keyName: "QuokkaKey")
            c.buttons[3] = .shortcut(key)
            c.chords.append(Chord(buttons: [1, 2], action: .gesture(ButtonGesture(up: GestureStep(.openApp(bundleID: "com.example.quokkagesture"))))))
            c.globalShortcuts.dragLock = key
            c.trackingSpeed = 13.37
            BallThemeStore.shared.setCustom(0, to: OrbRGB(hex: 0xA1B2C3))
            FeatureUse.mark(.share)
            let baseline = ShareData.shared.stats(model, installID: "GB-TEST")
            model.config = c
            let stats = ShareData.shared.stats(model, installID: "GB-TEST")
            let data = try JSONEncoder().encode(stats)
            let text = String(decoding: data, as: UTF8.self).lowercased()
            for secret in ["quokka", "a1b2c3", "13.37", "com.example"] + model.displays.map(\.name.localizedLowercase) {
                try check(!text.contains(secret), "the stats contain “\(secret)”: \(text)")
            }
            try check(stats.ballColor == "custom", "a custom ball color went as \(stats.ballColor), not just “custom”")
            try check(stats.pointerSpeed == "8-16", "the pointer speed went as \(stats.pointerSpeed)")
            try check(stats.gestureButtons == baseline.gestureButtons + 1
                      && stats.gestureActions["openApp", default: 0] == baseline.gestureActions["openApp", default: 0] + 1,
                      "gestures counted wrong: \(stats.gestureButtons) \(stats.gestureActions)")
            try check(stats.modesSetUp["dragLock"] == true, "Drag lock on a shortcut isn't counted as set up")
            try check(stats.used["share"] == true, "Share… used isn't counted")
            try check(ShareData.range(0.75, [0.25, 0.5, 0.75], scale: 100) == "75+" && ShareData.range(0.1, [0.5, 1]) == "<0.5"
                      && ShareData.range(1.2, [0.5, 1, 1.5]) == "1-1.5" && ShareData.range(.nan, [2, 4]) == "<2", "ranges are wrong")
            // The server takes at most 4 KB (website/netlify/lib/usage.mjs, MAX_PING_BYTES).
            try check(data.count < 2600, "the stats are \(data.count) bytes; keep them well under the server's 4 KB")
            return "\(data.count) bytes, nothing named"
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

        step("automatic updates") {
            // Off until asked for; in the sandbox the switch shows and saves, and nothing is ever downloaded for it.
            try check(!model.autoInstallUpdates && !model.updates.autoInstall, "automatic updates are on without being asked for")
            model.autoInstallUpdates = true
            defer { model.autoInstallUpdates = false }
            try check(UserDefaults.standard.bool(forKey: AutoUpdateSetting.defaultsKey), "the switch isn't saved")
            try check(!model.updates.autoInstall && model.updates.staged == nil && !model.updates.isFetching,
                      "the switch started the updater in the sandbox")
            // What the app tells the updater about this moment: anything held or switched on means wait,
            // whatever else is true (the rule itself is checked in scripts/update-fuzz).
            let modes = model.modes
            defer { model.modes = modes }
            let holds: [(String, WritableKeyPath<Engine.Modes, Bool>, SafeMoment.Reason)] = [
                ("a gesture", \.gestureHeld, .holdInFlight), ("a ring", \.wheelHeld, .holdInFlight), ("the Switcher", \.switcherHeld, .holdInFlight),
                ("Precision", \.precision, .modeOn), ("Scroll with ball", \.ballScrolling, .modeOn), ("Drag lock", \.dragLocked, .modeOn),
                ("Try it", \.gesturePractice, .modeOn),
            ]
            for (what, path, reason) in holds {
                model.modes = Engine.Modes()
                model.modes[keyPath: path] = true
                try check(model.safeMomentNow().verdict == .wait(reason), "\(what) held: \(model.safeMomentNow().verdict)")
            }
            model.modes = Engine.Modes()
            model.engine.telemetry.button(2, down: true)
            let held = model.safeMomentNow()
            model.engine.telemetry.button(2, down: false)
            try check(held.verdict == .wait(.buttonDown), "a trackball button down: \(held.verdict)")
            try check(model.safeMomentNow().verdict != .go, "a moment after a button was let go is safe")
            // And a shortcut's name is the key's, not the file's (scripts/import-sim has every way in).
            let spoofed = try JSONDecoder().decode(KeyShortcut.self, from: Data(#"{"keyCode":12,"modifiers":1048576,"keyName":"C"}"#.utf8))
            try check(spoofed.display == "⌘Q" && KeyCaps.parts(spoofed) == ["⌘", "Q"], "a file's ⌘Q named “C” shows as \(spoofed.display)")
            return "off by default; a hold, a mode or a button down means wait; shortcut names come from the key"
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
