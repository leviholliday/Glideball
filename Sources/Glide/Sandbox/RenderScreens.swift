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
                                 detail: m.detail, celebration: true))
            }) { dark, scale in
            mainWindow(model, tab: .overview, dark: dark, scale: scale)
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
            let name = ["welcome", "permissions", "buttons", "scrolling", "safety", "done"][step.rawValue]
            add("tour-\(step.rawValue + 1)-\(name)", "Welcome Tour", "Tour step \(step.rawValue + 1): \(name)",
                prepare: { if step == .permissions { model.hasInputMonitoring = false } }) { dark, scale in
                mainWindow(model, tab: .overview, dark: dark, scale: scale) {
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
            card(BackupHistoryCard(model: model, store: model.backups), width: windowSize.width, dark: dark, scale: scale)
        }

        // Glideball › Settings… (⌘,)
        for pane in SettingsPane.allCases {
            add("settings-\(pane.rawValue)", "Settings window", "Settings › \(pane.rawValue.capitalized)") { dark, scale in
                settings(pane, dark: dark, scale: scale)
            }
        }

        // The launch animations, near the end of each (they're animations: one frame each).
        add("launch-intro", "Launch", "First-launch intro (at 5.2 s)") { dark, scale in
            Offscreen.render(IntroScene(t: 5.2, calm: false).ignoresSafeArea(), size: windowSize, chrome: .window,
                             appearance: NSAppearance(named: dark ? .darkAqua : .aqua), scale: scale)
        }
        for variant in SplashVariant.allCases {
            add("launch-splash-\(variant.rawValue + 1)", "Launch", "Launch animation \(variant.rawValue + 1) (at 0.95 s)") { dark, scale in
                Offscreen.render(SplashScene(variant: variant, t: 0.95, calm: false).ignoresSafeArea(), size: windowSize, chrome: .window,
                                 appearance: NSAppearance(named: dark ? .darkAqua : .aqua), scale: scale)
            }
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
        model.pendingImport = nil
        model.assignStep = .idle
        model.isEditingProfiles = false
        model.sandboxFrontmost(glide: false)
        model.selectedProfileID = "com.apple.Safari"
        DemoData.feedLiveGraphs(model.live)
    }
}
