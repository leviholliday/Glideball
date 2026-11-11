import AppKit
import SwiftUI

/// Every screen `--render-ui` draws, in order. Names are stable: they're the
/// file names (`<name>.<light|dark>.png`) and what `--only` matches.
extension RenderUI {
    static func all(_ model: AppModel) -> [Screen] {
        var list: [Screen] = []
        func add(_ name: String, _ group: String, _ title: String,
                 prepare: @escaping () -> Void = {}, cleanup: @escaping () -> Void = {},
                 draw: @escaping (Bool, CGFloat) -> NSBitmapImageRep?) {
            list.append(Screen(name: name, group: group, title: title, prepare: prepare, draw: draw,
                               cleanup: { cleanup(); baseline(model) }))
        }

        // The main window, one per tab, as it opens (980 × 680).
        let tabs: [(GlideTab, String)] = [(.overview, "overview"), (.pointer, "pointer"), (.scroll, "scrolling"),
                                          (.buttons, "buttons"), (.apps, "apps"), (.backup, "sync")]
        for (tab, name) in tabs {
            add(name, "Main window", "\(tab.rawValue) tab") { dark, scale in
                mainWindow(model, tab: tab, dark: dark, scale: scale)
            }
        }

        // The smallest the window goes (860 × 580): nothing may clip or wrap mid-word.
        for (tab, name) in tabs {
            add("min-size-\(name)", "Smallest window", "\(tab.rawValue) tab at the minimum size") { dark, scale in
                mainWindow(model, tab: tab, dark: dark, scale: scale, size: AppDelegate.mainWindowMinSize)
            }
        }

        // Whole tabs, top to bottom: everything scrolling would reveal.
        for (tab, name) in tabs {
            add("\(name)-page", "Whole tabs (scrolled)", "\(tab.rawValue), whole page") { dark, scale in
                fullPage(page(tab, model), dark: dark, scale: scale)
            }
        }

        // The Scrolling tab in its other two modes (the plain "scrolling" shows Flywheel).
        for (mode, name) in [(ScrollMode.native, "scrolling-native"), (.follow, "scrolling-follow")] {
            add("\(name)-page", "Whole tabs (scrolled)", "Scrolling in \(mode.rawValue) mode, whole page",
                prepare: { model.config.scrollMode = mode },
                cleanup: { model.config.scrollMode = .flywheel }) { dark, scale in
                fullPage(page(.scroll, model), dark: dark, scale: scale)
            }
        }

        // States of the main window.
        add("permissions-needed", "States", "Permissions needed",
            prepare: { model.hasAccessibility = false; model.hasInputMonitoring = false }) { dark, scale in
            mainWindow(model, tab: .overview, dark: dark, scale: scale)
        }
        add("permissions-half", "States", "One permission still needed",
            prepare: { model.hasInputMonitoring = false }) { dark, scale in
            mainWindow(model, tab: .overview, dark: dark, scale: scale)
        }
        add("paused", "States", "Paused",
            prepare: { model.config.enabled = false }) { dark, scale in
            mainWindow(model, tab: .overview, dark: dark, scale: scale)
        }
        add("no-trackball", "States", "No trackball connected",
            prepare: {
                model.status = Engine.Status(tapActive: true, listening: true)
                model.live.reset()
            }) { dark, scale in
            mainWindow(model, tab: .overview, dark: dark, scale: scale)
        }
        add("other-kensington", "States", "A Kensington that needs Other Kensington trackballs",
            prepare: {
                model.status = Engine.Status(tapActive: true, listening: true, unsupportedDeviceName: "SlimBlade Pro")
                model.live.reset()
            }) { dark, scale in
            mainWindow(model, tab: .overview, dark: dark, scale: scale)
        }
        add("modes-on", "States", "Precision and Drag lock on (sidebar chips), top left held",
            prepare: {
                model.modes = Engine.Modes(precision: true, ballScrolling: false, dragLocked: true)
                model.pressed = [2]
            }) { dark, scale in
            mainWindow(model, tab: .buttons, dark: dark, scale: scale)
        }
        add("app-setup-active", "States", "An app setup in effect (sidebar badge)",
            prepare: {
                model.sandboxFrontmost(glide: true)
                model.isEditingProfiles = true
                model.selectedProfileID = "com.apple.Safari"
            }) { dark, scale in
            // Glideball is in front with the Apps tab open, so Safari's setup is previewed.
            mainWindow(model, tab: .apps, dark: dark, scale: scale)
        }
        add("celebration-toast", "States", "A celebration toast",
            prepare: {
                let m = Milestone.all.first { $0.id == "ball-1k" } ?? Milestone.all[0]
                model.show(.init(symbol: m.symbol, text: String(localized: "Milestone: \(m.title)", comment: "%@ is a badge name"),
                                 detail: m.detail, celebration: true, part: m.metric))
            }) { dark, scale in
            mainWindow(model, tab: .overview, dark: dark, scale: scale)
        }
        add("celebration-confetti", "States", "A big milestone: the toast and its confetti, a moment in",
            prepare: {
                let m = Milestone.all.first { $0.id == "ball-1k" } ?? Milestone.all[0]
                model.show(.init(symbol: m.symbol, text: String(localized: "Milestone: \(m.title)", comment: "%@ is a badge name"),
                                 detail: m.detail, celebration: true, part: m.metric))
            }) { dark, scale in
            mainWindow(model, tab: .overview, dark: dark, scale: scale) {
                ConfettiBurst(burst: .init(lead: .ball))
            }
        }
        add("toast-import", "States", "An import toast with Undo",
            prepare: {
                model.show(.init(symbol: "arrow.down.doc.fill", text: String(localized: "Imported “\("Studio Mac setup")”"),
                                 action: .undoImport))
            }) { dark, scale in
            mainWindow(model, tab: .backup, dark: dark, scale: scale)
        }
        add("import-preview", "States", "Importing a settings file (preview)",
            prepare: {
                var incoming = DemoData.config
                incoming.trackingSpeed = 3
                incoming.scrollMode = .native
                incoming.appProfiles.removeLast()
                model.pendingImport = .init(fileName: "Studio Mac setup",
                                            file: GlideSettingsFile(config: incoming, exportedFrom: "Studio Mac"))
            }) { dark, scale in
            mainWindow(model, tab: .backup, dark: dark, scale: scale)
        }
        add("import-preview-page", "States", "Sync page, whole, with an import to review",
            prepare: {
                var incoming = DemoData.config
                incoming.trackingSpeed = 3
                incoming.scrollMode = .native
                incoming.appProfiles.removeLast()
                model.pendingImport = .init(fileName: "Studio Mac setup",
                                            file: GlideSettingsFile(config: incoming, exportedFrom: "Studio Mac"))
            }) { dark, scale in
            fullPage(page(.backup, model), dark: dark, scale: scale)
        }
        add("apps-empty", "States", "Apps tab with no app setups yet",
            prepare: { model.config.appProfiles = [] },
            cleanup: { model.config.appProfiles = DemoData.config.appProfiles }) { dark, scale in
            mainWindow(model, tab: .apps, dark: dark, scale: scale)
        }
        add("quick-assign", "States", "Quick assign, waiting for a shortcut",
            prepare: { model.assignStep = .waitingForAction([2, 3]) }) { dark, scale in
            mainWindow(model, tab: .buttons, dark: dark, scale: scale)
        }
        add("small-favor", "States", "“A small favor” card",
            prepare: { model.showingSmallFavor = true }) { dark, scale in
            mainWindow(model, tab: .overview, dark: dark, scale: scale)
        }

        // The trackball hero in every state, at the sidebar's size and large (the tour's).
        add("trackball-states", "Trackball", "The trackball in each state") { dark, scale in
            card(TrackballStates(), width: 1000, dark: dark, scale: scale)
        }

        // The Welcome Tour, every step, over the window.
        for step in WelcomeTourView.Step.allCases {
            add("tour-\(step.rawValue + 1)-\(step.name)", "Welcome Tour", "Tour step \(step.rawValue + 1): \(step.name)",
                prepare: { if step == .permissions { model.hasInputMonitoring = false } }) { dark, scale in
                mainWindow(model, tab: .overview, dark: dark, scale: scale) {
                    WelcomeTourView(model: model, step: step)
                }
            }
        }
        add("tour-3-buttons-found", "Welcome Tour", "Meet your buttons, two found and the top right held",
            prepare: { model.pressed = [3] }) { dark, scale in
            mainWindow(model, tab: .overview, dark: dark, scale: scale) {
                WelcomeTourView(model: model, step: .buttons, found: [2, 3])
            }
        }

        // What's New after an update (the 2.10 entry), over the window.
        add("whats-new", "What’s New", "What’s New in this version",
            prepare: { model.showingWhatsNew = true }) { dark, scale in
            mainWindow(model, tab: .overview, dark: dark, scale: scale)
        }
        add("min-size-whats-new", "Smallest window", "What’s New at the minimum size",
            prepare: { model.showingWhatsNew = true }) { dark, scale in
            mainWindow(model, tab: .overview, dark: dark, scale: scale, size: AppDelegate.mainWindowMinSize)
        }
        for step in [WelcomeTourView.Step.buttons, .tryIt] {
            add("min-size-tour-\(step.rawValue + 1)", "Smallest window", "Tour step \(step.rawValue + 1) at the minimum size") { dark, scale in
                mainWindow(model, tab: .overview, dark: dark, scale: scale, size: AppDelegate.mainWindowMinSize) {
                    WelcomeTourView(model: model, step: step)
                }
            }
        }

        // Sheets and cards.
        add("about", "Sheets", "About & Help") { dark, scale in
            sheet(AboutView(model: model), dark: dark, scale: scale)
        }
        add("feedback", "Sheets", "Send Feedback",
            prepare: { fillFeedback() }) { dark, scale in
            sheet(FeedbackView(model: model), dark: dark, scale: scale)
        }
        add("feedback-idea", "Sheets", "Send Feedback (an idea, empty)",
            prepare: {
                let d = FeedbackDraft.shared
                d.kind = .idea; d.title = ""; d.details = ""; d.phase = .writing
            }) { dark, scale in
            sheet(FeedbackView(model: model), dark: dark, scale: scale)
        }
        add("feedback-sending", "Sheets", "Send Feedback, sending",
            prepare: { fillFeedback(); FeedbackDraft.shared.phase = .sending(0.6, String(localized: "Sending…")) }) { dark, scale in
            sheet(FeedbackView(model: model), dark: dark, scale: scale)
        }
        add("feedback-sent", "Sheets", "Send Feedback, sent",
            prepare: { fillFeedback() }) { dark, scale in
            // Opening the sheet starts a fresh report (prepareToShow), so the
            // send finishes just after it opens, as it does in the app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { FeedbackDraft.shared.phase = .sent("GB-7Q2K-M4XD") }
            return sheet(FeedbackView(model: model), dark: dark, scale: scale)
        }
        add("backup-history", "Sheets", "Backup history (Sync tab)") { dark, scale in
            card(BackupHistorySection(model: model, store: model.backups), width: windowSize.width, dark: dark, scale: scale)
        }

        // Glideball › Settings… (⌘,)
        for pane in SettingsPane.allCases {
            add("settings-\(pane.rawValue)", "Settings window", "Settings › \(pane.rawValue.capitalized)") { dark, scale in
                settings(pane, dark: dark, scale: scale)
            }
        }

        // The launch animations: the intro at three moments, and each short one
        // part-way and at its finished frame (they're animations: one frame each).
        func launch<V: View>(_ view: V, _ dark: Bool, _ scale: CGFloat) -> NSBitmapImageRep? {
            Offscreen.render(view.ignoresSafeArea(), size: windowSize, chrome: .window,
                             appearance: NSAppearance(named: dark ? .darkAqua : .aqua), scale: scale)
        }
        for (t, what) in [(1.4, "rolling in"), (3.0, "ring spinning up"), (5.6, "finished")] {
            let name = "launch-intro-" + what.replacingOccurrences(of: " ", with: "-")
            add(name, "Launch", "First-launch intro at \(t) s: \(what)") { dark, scale in
                launch(IntroScene(t: t, calm: false), dark, scale)
            }
        }
        for variant in SplashVariant.allCases {
            let name = variant == .ringSpin ? "ring-spin" : "roll-in"
            add("launch-\(name)-start", "Launch", "Launch animation “\(name)” part-way (0.2 s)") { dark, scale in
                launch(SplashScene(variant: variant, t: 0.2, calm: false), dark, scale)
            }
            add("launch-\(name)", "Launch", "Launch animation “\(name)”, finished (0.8 s)") { dark, scale in
                launch(SplashScene(variant: variant, t: 0.8, calm: false), dark, scale)
            }
        }
        add("launch-fade", "Launch", "Quick fade, finished") { dark, scale in
            launch(SplashScene(variant: .ringSpin, t: 0.3, calm: true), dark, scale)
        }

        // Software Update, in each state it can show (in this order: each builds on the last).
        add("update-checking", "Software Update", "Checking",
            prepare: {
                stub(.never)
                model.updates.checkNow()
            }) { dark, scale in
            updatePanel(model, dark: dark, scale: scale)
        }
        add("update-failed", "Software Update", "Couldn’t check",
            prepare: {
                stub(.serverError)
                model.updates.checkNow()
                waitUntil(3) { model.updates.manualCheck == .failed }
            }) { dark, scale in
            updatePanel(model, dark: dark, scale: scale)
        }
        add("update-up-to-date", "Software Update", "Up to date",
            prepare: {
                stub(.releases(newer: false))
                model.updates.checkNow()
                waitUntil(3) { model.updates.manualCheck == .upToDate }
            }) { dark, scale in
            updatePanel(model, dark: dark, scale: scale)
        }
        // (Each of these gets there from wherever the last one left off, so --only works on any of them.)
        func findUpdate() {
            guard model.updates.available == nil else { return }
            stub(.releases(newer: true))
            model.updates.checkNow()
            waitUntil(3) { model.updates.available != nil && model.updates.manualCheck == .idle }
        }
        func download() {
            findUpdate()
            if case .downloading = model.updates.installState { return }
            stub(.download)
            model.updates.install()
            waitUntil(3) {
                if case .downloading(let p) = model.updates.installState { return p > 0.3 }
                return false
            }
        }
        add("update-available", "Software Update", "An update is available", prepare: findUpdate) { dark, scale in
            updatePanel(model, dark: dark, scale: scale)
        }
        add("update-in-header", "Software Update", "Update pill in the sidebar", prepare: findUpdate) { dark, scale in
            mainWindow(model, tab: .overview, dark: dark, scale: scale)
        }
        add("update-downloading", "Software Update", "Downloading", prepare: download) { dark, scale in
            updatePanel(model, dark: dark, scale: scale)
        }
        add("update-install-failed", "Software Update", "The download failed",
            prepare: {
                download()
                SandboxURLProtocol.failStalled()
                waitUntil(3) { if case .failed = model.updates.installState { return true }; return false }
            }) { dark, scale in
            updatePanel(model, dark: dark, scale: scale)
        }
        return list
    }

    static func page(_ tab: GlideTab, _ model: AppModel) -> some View {
        TabPage(tab: tab, model: model)
    }

    /// The seven looks from the design guide's table, each on the sidebar's stage, plus two large.
    struct TrackballStates: View {
        private struct Item: Identifiable {
            let id: String
            let look: TrackballLook
            let feed: LiveFeed
            var pressed: Set<Int> = []
        }

        private let items: [Item] = [
            .init(id: "Connected, idle", look: .connected, feed: LiveFeed()),
            .init(id: "Rolling (right and away)", look: .connected, feed: DemoData.movingFeed(roll: CGVector(dx: 2.6, dy: -1.6))),
            .init(id: "Ring turning", look: .connected, feed: DemoData.movingFeed(ring: 18)),
            .init(id: "Button down (top left)", look: .connected, feed: LiveFeed(), pressed: [2]),
            .init(id: "Paused", look: .paused, feed: LiveFeed()),
            .init(id: "Not connected", look: .notConnected, feed: LiveFeed()),
            .init(id: "Needs permission", look: .needsPermission, feed: LiveFeed()),
        ]

        var body: some View {
            VStack(alignment: .leading, spacing: 24) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(196), spacing: 18), count: 4), alignment: .leading, spacing: 18) {
                    ForEach(items) { item in
                        VStack(spacing: 8) {
                            TrackballView(feed: item.feed, pressed: item.pressed, look: item.look)
                                .frame(width: 150, height: 150)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity)
                                .background(RoundedRectangle(cornerRadius: Theme.Radius.stage, style: .continuous).fill(Theme.stage))
                            Text(verbatim: item.id).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(alignment: .bottom, spacing: 24) {
                    TrackballView(feed: LiveFeed(), pressed: [], look: .connected).frame(width: 300, height: 300)
                    TrackballView(feed: DemoData.movingFeed(roll: CGVector(dx: -1.5, dy: 2), ring: -12), pressed: [1], look: .connected)
                        .frame(width: 230, height: 230)
                }
            }
        }
    }

    /// A bug report, part written.
    static func fillFeedback() {
        let d = FeedbackDraft.shared
        d.kind = .bug
        d.title = "Scrolling jumps in Safari after the Mac wakes"
        d.details = "After waking from sleep, the first spin of the ring scrolls about a page too far in Safari. "
            + "It happens maybe one time in three. Turning Glideball off and on fixes it until the next sleep."
        d.priority = .high
        d.phase = .writing
    }

    /// The state every screen starts from (and is put back to).
    static func baseline(_ model: AppModel) {
        model.status = DemoData.connected
        model.hasAccessibility = true
        model.hasInputMonitoring = true
        if !model.config.enabled { model.config.enabled = true }
        model.modes = Engine.Modes()
        model.pressed = []
        model.toast = nil
        model.showingSmallFavor = false
        model.showingAbout = false
        model.showingFeedback = false
        model.showingWelcomeTour = false
        model.showingWhatsNew = false
        model.pendingImport = nil
        model.assignStep = .idle
        model.isEditingProfiles = false
        model.sandboxFrontmost(glide: false)
        model.selectedProfileID = "com.apple.Safari"
        DemoData.feedLiveGraphs(model.live)
    }
}
