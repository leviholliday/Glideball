import AppKit
import Carbon.HIToolbox
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

        // Full screen on a 1440 × 900 display: no toolbar, the sidebar's glass to the top,
        // the page starting at the top with room of its own (the traffic lights only
        // appear with the menu bar when the pointer reaches the top edge).
        add("fullscreen", "Main window", "Overview in full screen (simulated: toolbar hidden, as the app does)") { dark, scale in
            mainWindow(model, tab: .overview, dark: dark, scale: scale, size: NSSize(width: 1440, height: 900), fullScreen: true) { EmptyView() }
        }
        add("fullscreen-pointer", "Main window", "Pointer in full screen (simulated)") { dark, scale in
            mainWindow(model, tab: .pointer, dark: dark, scale: scale, size: NSSize(width: 1440, height: 900), fullScreen: true) { EmptyView() }
        }
        add("overview-hint-gone", "Main window", "Overview, whole page, once the Settings hint has gone (5 days, 2 weeks or its ×)",
            prepare: { SettingsHintMemory.dismiss() },
            cleanup: { UserDefaults.standard.removeObject(forKey: SettingsHintMemory.goneKey) }) { dark, scale in
            fullPage(page(.overview, model), dark: dark, scale: scale)
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
        add("icon-prompt", "States", "“Glideball has a new look” (after an update from the classic icon)",
            prepare: { model.showingIconChoice = true }) { dark, scale in
            mainWindow(model, tab: .overview, dark: dark, scale: scale)
        }

        // Version 2: the light the hand makes, and the moments that can't be seen in a still otherwise.
        add("overview-record", "Light and motion", "Overview the moment today passes your best rolling day (sweep, pop, sparks)",
            prepare: {
                model.delight.celebrationsOn = false   // just the dial's moment, not the toast
                var t = DemoData.today
                t.ballCounts = 72.0 / Tally.metersPerBallCount
                model.engine.telemetry.restore(t)
                model.totals = t
                model.delight.tick(totals: t, peaks: Telemetry.Peaks())
                TodayCluster.sandboxRecordMoment = .ball
            },
            cleanup: {
                TodayCluster.sandboxRecordMoment = nil
                model.engine.telemetry.restore(DemoData.today)
                model.totals = DemoData.today
                model.delight.tick(totals: DemoData.today, peaks: Telemetry.Peaks())
                model.delight.celebrationsOn = true
            }) { dark, scale in
            mainWindow(model, tab: .overview, dark: dark, scale: scale)
        }
        add("atmosphere-rolling", "Light and motion", "Rolling the ball: the room warms blue, the dot rides the response curve",
            prepare: { DemoData.move(model.live, roll: CGVector(dx: 2.4, dy: -1.2)) }) { dark, scale in
            mainWindow(model, tab: .pointer, dark: dark, scale: scale)
        }
        add("atmosphere-ring", "Light and motion", "Spinning the ring: pink runs through the light, the lane lights up",
            prepare: { DemoData.move(model.live, ring: 22) }) { dark, scale in
            mainWindow(model, tab: .scroll, dark: dark, scale: scale)
        }
        add("atmosphere-click", "Light and motion", "A click: amber flashes, the button's row lights",
            prepare: {
                model.pressed = [3]
                model.live.pulseClick()
            }) { dark, scale in
            mainWindow(model, tab: .buttons, dark: dark, scale: scale)
        }
        add("slider-dragging", "Light and motion", "Dragging a slider (every slider drawn mid-drag)",
            prepare: { InstrumentSlider.sandboxDragging = true },
            cleanup: { InstrumentSlider.sandboxDragging = false }) { dark, scale in
            mainWindow(model, tab: .scroll, dark: dark, scale: scale)
        }
        add("mode-card-hover", "Light and motion", "Hovering the Follow mode card: its demo plays",
            prepare: { ChoiceCardSandbox.hovered = "hand.point.up.left" },
            cleanup: { ChoiceCardSandbox.hovered = nil }) { dark, scale in
            mainWindow(model, tab: .scroll, dark: dark, scale: scale)
        }
        add("minimal-performance", "Light and motion", "Minimal performance mode while rolling: the stage stays still",
            prepare: {
                model.performance = .minimal
                DemoData.move(model.live, roll: CGVector(dx: 2.4, dy: -1.2))
            },
            cleanup: { model.performance = .efficient }) { dark, scale in
            mainWindow(model, tab: .pointer, dark: dark, scale: scale)
        }

        // Round 3: the action picker, presets, ball colors, badges and sharing. Popovers are
        // separate windows a render can't draw, so the picker and the badge details are drawn
        // where they'd open, on a glass card like the popover's.
        add("buttons-picker", "Buttons and picker", "The action picker open on the top-right button",
            prepare: { model.config.buttons[3] = .shortcut(.nextSpace) }) { dark, scale in
            mainWindow(model, tab: .buttons, dark: dark, scale: scale) {
                PopoverMock(alignment: .topTrailing, top: 168, side: 36) {
                    ActionPickerPanel(current: .shortcut(.nextSpace), button: 3) { _ in }
                }
            }
        }
        add("buttons-picker-search", "Buttons and picker", "The picker, searching “tab”",
            prepare: { ActionPickerPanel.sandboxQuery = "tab" },
            cleanup: { ActionPickerPanel.sandboxQuery = nil }) { dark, scale in
            card(PopoverMock { ActionPickerPanel(current: .back, button: 3) { _ in } }, width: 470, dark: dark, scale: scale)
        }
        add("buttons-picker-nothing", "Buttons and picker", "The picker, a search that finds nothing",
            prepare: { ActionPickerPanel.sandboxQuery = "teleport" },
            cleanup: { ActionPickerPanel.sandboxQuery = nil }) { dark, scale in
            card(PopoverMock { ActionPickerPanel(current: .back, button: 3) { _ in } }, width: 470, dark: dark, scale: scale)
        }
        add("buttons-picker-record", "Buttons and picker", "The picker recording a shortcut",
            prepare: { ActionPickerPanel.sandboxRecording = true },
            cleanup: { ActionPickerPanel.sandboxRecording = false }) { dark, scale in
            card(PopoverMock { ActionPickerPanel(current: .back, button: 3) { _ in } }, width: 470, dark: dark, scale: scale)
        }
        add("buttons-preset-preview", "Buttons and picker", "Previewing the Browser preset (map, cards and Apply)",
            prepare: { ButtonsView.sandboxPreview = "browser" },
            cleanup: { ButtonsView.sandboxPreview = nil }) { dark, scale in
            fullPage(page(.buttons, model), dark: dark, scale: scale)
        }
        add("buttons-preset-applied", "Buttons and picker", "The Media preset in use",
            prepare: { model.config.apply(ButtonPreset.all.first { $0.id == "media" }!) },
            cleanup: { model.config.buttons = DemoData.config.buttons; model.config.chords = DemoData.config.chords }) { dark, scale in
            mainWindow(model, tab: .buttons, dark: dark, scale: scale)
        }
        add("buttons-new-combo", "Buttons and picker", "Adding a combo: two pads picked",
            prepare: { NewComboRow.sandboxPicked = [1, 2] },
            cleanup: { NewComboRow.sandboxPicked = nil }) { dark, scale in
            fullPage(page(.buttons, model), dark: dark, scale: scale)
        }
        // Gestures, per-display speed, battery and connection.
        func gestureButtons() {
            model.config.buttons[3] = .gesture(.standard)
            model.config.buttons[2] = .gesture(.media)
        }
        func restoreButtons() {
            model.config.buttons = DemoData.config.buttons
            model.config.chords = DemoData.config.chords
        }
        func hold(_ direction: GestureDirection?, fired: GestureDirection?? = nil, tapped: Bool = false) {
            var m = Engine.Modes()
            m.gestureHeld = !tapped
            m.gestureButtons = tapped ? [] : [3]
            m.gestureDirection = direction
            if let fired { m.gestureFlash = Engine.GestureFlash(seq: 1, direction: fired, buttons: [3]) }
            model.modes = m
            if !tapped { model.pressed = [3] }
            GestureFlashClock.sandboxHold = true
        }
        add("buttons-gesture-page", "Gestures", "Top right and top left as gestures: the editor under each row",
            prepare: gestureButtons, cleanup: restoreButtons) { dark, scale in
            fullPage(page(.buttons, model), dark: dark, scale: scale)
        }
        add("buttons-gesture-narrow", "Gestures", "The gesture editor at the smallest window's width (stacked)",
            prepare: gestureButtons, cleanup: restoreButtons) { dark, scale in
            card(page(.buttons, model).frame(width: AppDelegate.mainWindowMinSize.width - Theme.Space.sidebarWidth - Theme.Space.contentSide * 2),
                 width: AppDelegate.mainWindowMinSize.width - Theme.Space.sidebarWidth, dark: dark, scale: scale)
        }
        add("buttons-gesture-held", "Gestures", "Holding top right and rolling right: Next Space just fired (sidebar, map and label)",
            prepare: { gestureButtons(); hold(.right, fired: .some(.right)) },
            cleanup: { restoreButtons(); GestureFlashClock.sandboxHold = false }) { dark, scale in
            mainWindow(model, tab: .buttons, dark: dark, scale: scale)
        }
        add("buttons-gesture-held-page", "Gestures", "Holding top right, rolling up (before it fires): the compass leans up",
            prepare: { gestureButtons(); hold(.up) },
            cleanup: { restoreButtons(); GestureFlashClock.sandboxHold = false }) { dark, scale in
            fullPage(page(.buttons, model), dark: dark, scale: scale)
        }
        add("buttons-gesture-try", "Gestures", "Try it: rolled up, Mission Control would have opened",
            prepare: { gestureButtons(); hold(.up, fired: .some(.up)); GestureEditor.sandboxTrying = true },
            cleanup: { restoreButtons(); GestureFlashClock.sandboxHold = false; GestureEditor.sandboxTrying = false }) { dark, scale in
            fullPage(page(.buttons, model), dark: dark, scale: scale)
        }
        add("buttons-gesture-try-waiting", "Gestures", "Try it, waiting for a hold",
            prepare: { gestureButtons(); GestureEditor.sandboxTrying = true },
            cleanup: { restoreButtons(); GestureEditor.sandboxTrying = false }) { dark, scale in
            fullPage(page(.buttons, model), dark: dark, scale: scale)
        }
        add("buttons-gesture-tap", "Gestures", "A tap (no roll): the tap's picker flashes",
            prepare: { gestureButtons(); hold(nil, fired: .some(nil), tapped: true); GestureEditor.sandboxTrying = true },
            cleanup: { restoreButtons(); GestureFlashClock.sandboxHold = false; GestureEditor.sandboxTrying = false }) { dark, scale in
            fullPage(page(.buttons, model), dark: dark, scale: scale)
        }
        add("buttons-picker-gesture", "Gestures", "The picker for top right: Gesture (hold and roll) at the top") { dark, scale in
            card(PopoverMock { ActionPickerPanel(current: .back, button: 3) { _ in } }, width: 470, dark: dark, scale: scale)
        }
        add("buttons-picker-gesture-direction", "Gestures", "The picker for a gesture's direction (only quick actions)") { dark, scale in
            card(PopoverMock { ActionPickerPanel(current: .shortcut(.nextSpace), purpose: .gestureDirection) { _ in } },
                 width: 470, dark: dark, scale: scale)
        }
        add("buttons-preset-gestures", "Gestures", "Previewing the Gestures preset",
            prepare: { ButtonsView.sandboxPreview = "gestures" },
            cleanup: { ButtonsView.sandboxPreview = nil }) { dark, scale in
            fullPage(page(.buttons, model), dark: dark, scale: scale)
        }

        func displays(_ n: Int, enabled: Bool = true) {
            let all = [DisplayInfo(key: "610-41271-1", name: "Built-in Retina Display", isMain: true,
                                   frame: CGRect(x: 0, y: 0, width: 1512, height: 982)),
                       DisplayInfo(key: "4268-41150-77", name: "Studio Display", isMain: false,
                                   frame: CGRect(x: -380, y: -1440, width: 2560, height: 1440)),
                       DisplayInfo(key: "1552-9984-12", name: "DELL U2723QE", isMain: false,
                                   frame: CGRect(x: 2180, y: -1580, width: 1440, height: 2560))]
            model.displays = Array(all.prefix(n))
            model.config.displaySpeeds.enabled = enabled
            if n > 1 { model.config.displaySpeeds.speeds = ["4268-41150-77": 9] }
            var s = DemoData.connected
            s.pointerDisplay = n > 1 ? "4268-41150-77" : nil
            model.status = s
        }
        func restoreDisplays() {
            model.refreshDisplays()
            model.config.displaySpeeds = DisplaySpeeds()
        }
        for n in 1...3 {
            add("pointer-displays-\(n)", "Per-display speed", "Pointer, speed for each display, \(n) display\(n == 1 ? "" : "s") connected",
                prepare: { displays(n) }, cleanup: restoreDisplays) { dark, scale in
                fullPage(page(.pointer, model), dark: dark, scale: scale)
            }
        }
        add("pointer-displays-off", "Per-display speed", "Pointer, two displays, the switch off",
            prepare: { displays(2, enabled: false) }, cleanup: restoreDisplays) { dark, scale in
            fullPage(page(.pointer, model), dark: dark, scale: scale)
        }

        func device(_ connection: DeviceConnection?, _ battery: Int?) {
            var s = DemoData.connected
            s.deviceName = connection == .usb ? "Kensington Expert Mouse" : "Kensington SlimBlade Pro"
            s.deviceIsBeta = connection != .usb
            s.connection = connection
            s.batteryPercent = battery
            model.status = s
        }
        for (name, connection, battery, what) in [("battery-ok", DeviceConnection.bluetooth, 62, "Bluetooth, 62%"),
                                                  ("battery-low", .bluetooth, 14, "Bluetooth, 14% (amber)"),
                                                  ("battery-empty", .receiver, 4, "Receiver, 4% (red)")] as [(String, DeviceConnection, Int, String)] {
            add(name, "Battery and connection", "Overview and sidebar: \(what)",
                prepare: { device(connection, battery) }) { dark, scale in
                mainWindow(model, tab: .overview, dark: dark, scale: scale)
            }
        }
        add("battery-states", "Battery and connection", "The status line in every state (unknown battery and USB show none)") { dark, scale in
            card(DeviceStatesSheet(), width: 560, dark: dark, scale: scale)
        }
        add("sync-older-mac-toast", "Battery and connection", "Sync: another Mac is on an older Glideball (toast)",
            prepare: {
                model.show(.init(symbol: "arrow.triangle.2.circlepath",
                                 text: String(localized: "Another Mac is on an older Glideball, so gestures weren’t synced to it."),
                                 isError: true))
            }) { dark, scale in
            mainWindow(model, tab: .backup, dark: dark, scale: scale)
        }

        add("apps-add-picker", "Buttons and picker", "Add App… (the same picker, for apps)") { dark, scale in
            card(PopoverMock {
                SearchPickerPanel(placeholder: String(localized: "Search open apps", comment: "Add App picker search field"),
                                  sections: { _ in DemoData.addAppSections() }, emptyText: { _ in "" }, width: 340, height: 400)
            }, width: 410, dark: dark, scale: scale)
        }
        add("ball-colors", "Ball colors", "The trackball in every ball color") { dark, scale in
            card(BallThemeSheet(), width: 1000, dark: dark, scale: scale)
        }
        add("settings-look-custom", "Settings window", "Look with a custom ball color (three wells)",
            prepare: { BallThemeStore.shared.choose("custom") },
            cleanup: { BallThemeStore.shared.choose("orb") }) { dark, scale in
            settings(.look, dark: dark, scale: scale)
        }
        for theme in ["ember", "ocean", "classic"] {
            add("overview-theme-\(theme)", "Ball colors", "Overview with the \(theme) ball color (the whole window recolored)",
                prepare: { BallThemeStore.shared.choose(theme) },
                cleanup: { BallThemeStore.shared.choose("orb") }) { dark, scale in
                mainWindow(model, tab: .overview, dark: dark, scale: scale)
            }
        }
        add("badges", "Badges and sharing", "Badges on Overview: four groups, the next one in each showing progress") { dark, scale in
            card(BadgesSection(delight: model.delight), width: windowSize.width - Theme.Space.sidebarWidth, dark: dark, scale: scale)
        }
        add("badge-detail", "Badges and sharing", "A badge's details: earned, and one still to earn") { dark, scale in
            card(HStack(alignment: .top, spacing: 24) {
                PopoverMock { BadgeDetail(milestone: Milestone.all.first { $0.id == "scroll-828" }!, delight: model.delight) }
                PopoverMock { BadgeDetail(milestone: Milestone.all.first { $0.id == "scroll-3776" }!, delight: model.delight) }
                PopoverMock { BadgeDetail(milestone: Milestone.all.first { $0.id == "setup-scroll-modes" }!, delight: model.delight) }
            }, width: 1060, dark: dark, scale: scale)
        }
        add("share-panel", "Badges and sharing", "Share… from Overview: the picture and what to do with it",
            prepare: { SharePanel.sandboxImage = ShareImage.render(.overview, delight: model.delight) },
            cleanup: { SharePanel.sandboxImage = nil }) { dark, scale in
            card(PopoverMock { SharePanel(card: .overview) }, width: 500, dark: dark, scale: scale)
        }
        add("share-panel-posted", "Badges and sharing", "Share… after X was clicked: the picture copied, X's composer opened in the browser",
            prepare: {
                SharePanel.sandboxImage = ShareImage.render(.overview, delight: model.delight)
                SharePanel.sandboxDone = String(localized: "Picture copied. Paste it into the post.")
            },
            cleanup: { SharePanel.sandboxImage = nil; SharePanel.sandboxDone = nil }) { dark, scale in
            card(PopoverMock { SharePanel(card: .overview) }, width: 500, dark: dark, scale: scale)
        }
        add("share-panel-badge", "Badges and sharing", "A badge's Share… (the panel the badge's details turn into), after Instagram was clicked",
            prepare: {
                let m = Milestone.all.first { $0.id == "scroll-828" }!
                SharePanel.sandboxImage = ShareImage.render(.badge(m, model.delight.ledger.earned[m.id]), delight: model.delight)
                SharePanel.sandboxDone = String(localized: "Saved to Downloads. Instagram only takes uploads from its app or site.")
            },
            cleanup: { SharePanel.sandboxImage = nil; SharePanel.sandboxDone = nil }) { dark, scale in
            card(PopoverMock { BadgeDetail(milestone: Milestone.all.first { $0.id == "scroll-828" }!, delight: model.delight, sharing: true) },
                 width: 500, dark: dark, scale: scale)
        }
        // The pictures as Share… makes them (ImageRenderer, always 2x).
        add("share-card-overview", "Badges and sharing", "The share picture: your numbers (as saved, 2x)") { _, _ in
            ShareImage.render(.overview, delight: model.delight)
        }
        add("share-card-badge", "Badges and sharing", "The share picture: a badge (as saved, 2x)") { _, _ in
            let m = Milestone.all.first { $0.id == "scroll-828" }!
            return ShareImage.render(.badge(m, model.delight.ledger.earned[m.id]), delight: model.delight)
        }
        add("share-card-badge-locked", "Badges and sharing", "The share picture: a badge not earned yet (as saved, 2x)") { _, _ in
            let m = Milestone.all.first { $0.id == "scroll-3776" }!
            return ShareImage.render(.badge(m, nil), delight: model.delight)
        }
        add("share-card-theme", "Badges and sharing", "The share picture in the Sunset ball color",
            prepare: { BallThemeStore.shared.choose("sunset") },
            cleanup: { BallThemeStore.shared.choose("orb") }) { _, _ in
            ShareImage.render(.overview, delight: model.delight)
        }

        // The trackball hero in every state, at the sidebar's size and large (the tour's).
        add("trackball-states", "Trackball", "The trackball in each state") { dark, scale in
            card(TrackballStates(), width: 1000, dark: dark, scale: scale)
        }
        add("trackball-rolling", "Trackball", "The ball turning as it rolls: right, then away from you, a quarter turn in steps, large and small") { dark, scale in
            card(TrackballRolling(), width: 1000, dark: dark, scale: scale)
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
        add("shortcuts-sheet", "Sheets", "Keyboard shortcuts (? in the window, Help › Keyboard Shortcuts)") { dark, scale in
            sheet(ShortcutsSheet(model: model), dark: dark, scale: scale)
        }
        add("quit-card", "Sheets", "⌘Q: “Quit Glideball?” over the window (it floats over the whole screen)") { dark, scale in
            mainWindow(model, tab: .overview, dark: dark, scale: scale) {
                QuitConfirm.preview()
            }
        }
        add("quit-card-close", "Sheets", "The quit card on its own, at its real size") { dark, scale in
            sheet(QuitConfirm.preview().padding(40).background(GlideBackground()), dark: dark, scale: scale)
        }
        add("scrolling-try-active", "States", "Scrolling, “Try it here” taking the ring (after a click): no hint",
            prepare: { ScrollCaptureSandbox.active = true },
            cleanup: { ScrollCaptureSandbox.active = false }) { dark, scale in
            fullPage(page(.scroll, model), dark: dark, scale: scale)
        }
        add("backup-history", "Sheets", "Backup history (Sync tab)") { dark, scale in
            card(BackupHistorySection(model: model, store: model.backups), width: windowSize.width, dark: dark, scale: scale)
        }

        // Glideball › Settings… (⌘,)
        for pane in SettingsPane.allCases {
            add("settings-\(pane.rawValue)", "Settings window", "Settings › \(pane.title)") { dark, scale in
                settings(pane, dark: dark, scale: scale)
            }
        }
        add("settings-general-spotlight", "Settings window", "General, opened from the external-control notice (the switch pointed out)",
            prepare: { SettingsSpotlight.shared.show("external-control") }) { dark, scale in
            settings(.general, dark: dark, scale: scale)
        }
        add("settings-look-classic", "Settings window", "Look & Sound with the classic icon and Sounds off",
            prepare: {
                AppIconChoice.shared.choose(.classic)
                Sounds.shared.enabled = false
            },
            cleanup: {
                AppIconChoice.shared.choose(.orb)
                Sounds.shared.enabled = true
            }) { dark, scale in
            settings(.look, dark: dark, scale: scale)
        }
        add("settings-privacy-deleted", "Settings window", "Privacy, just after Delete My Data",
            prepare: { ShareDataSettings.sandboxDeleted = true },
            cleanup: { ShareDataSettings.sandboxDeleted = nil }) { dark, scale in
            settings(.privacy, dark: dark, scale: scale)
        }
        add("settings-shortcuts-search", "Settings window", "Shortcuts, searching “scroll”",
            prepare: { ShortcutsSettingsPane.sandboxSearch = "scroll" },
            cleanup: { ShortcutsSettingsPane.sandboxSearch = "" }) { dark, scale in
            settings(.shortcuts, dark: dark, scale: scale)
        }
        add("settings-shortcuts-no-match", "Settings window", "Shortcuts, a search that matches nothing",
            prepare: { ShortcutsSettingsPane.sandboxSearch = "zoom" },
            cleanup: { ShortcutsSettingsPane.sandboxSearch = "" }) { dark, scale in
            settings(.shortcuts, dark: dark, scale: scale)
        }
        add("settings-shortcuts-conflict", "Settings window", "Shortcuts: one moved from another, one the window uses (⌘1), one macOS uses (⌃↑)",
            prepare: {
                var g = model.config.globalShortcuts
                g.ballScroll = KeyShortcut.make(kVK_ANSI_P, "P", [.maskControl, .maskAlternate, .maskCommand])
                g.precision = nil
                g.pause = KeyShortcut.make(kVK_ANSI_1, "1", [.maskCommand])
                g.dragLock = .missionControl
                model.config.globalShortcuts = g
                ShortcutsSettingsPane.sandboxNote = .init(text: String(localized: "\("⌃⌥⌘P") was the shortcut for \(GlobalShortcuts.Action.precision.title). That one has no shortcut now.",
                                                                       comment: "First %@ is a shortcut like ⌃⌥⌘P; the second is what it did, like Precision"))
            },
            cleanup: {
                model.config.globalShortcuts = DemoData.config.globalShortcuts
                ShortcutsSettingsPane.sandboxNote = nil
            }) { dark, scale in
            settings(.shortcuts, dark: dark, scale: scale)
        }
        add("external-control-notice", "Settings window", "“Something tried to control Glideball” (the switch is off)") { dark, scale in
            panel(ExternalControlNoticeView(openSettings: {}, close: {}), dark: dark, scale: scale)
        }

        // The launch animations: the intro at three moments, and each short one
        // part-way and at its finished frame (they're animations: one frame each).
        func launch<V: View>(_ view: V, _ dark: Bool, _ scale: CGFloat) -> NSBitmapImageRep? {
            Offscreen.render(view.ignoresSafeArea(), size: windowSize, chrome: .window,
                             appearance: NSAppearance(named: dark ? .darkAqua : .aqua), scale: scale)
        }
        for (t, what) in [(1.4, "rolling in"), (3.0, "ring spinning up"), (3.4, "light drawing in"), (3.75, "held beat"),
                          (3.97, "the hit"), (4.15, "the word landing"), (4.3, "ripple"), (5.6, "finished")] {
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
            add("launch-\(name)-settling", "Launch", "Launch animation “\(name)”: the ball's overshoot (0.4 s)") { dark, scale in
                launch(SplashScene(variant: variant, t: 0.4, calm: false), dark, scale)
            }
            add("launch-\(name)", "Launch", "Launch animation “\(name)”, finished (0.85 s)") { dark, scale in
                launch(SplashScene(variant: variant, t: 0.85, calm: false), dark, scale)
            }
        }
        for (p, what) in [(0.3, "opening"), (0.65, "wide")] {
            add("launch-reveal-\(what)", "Launch", "The hand-off \(Int(p * 100))% through: the light opening out over the window") { dark, scale in
                mainWindow(model, tab: .overview, dark: dark, scale: scale) {
                    SplashScene(variant: .rollIn, t: 0.85, calm: false)
                        .modifier(RevealOut(progress: p, calm: false, from: SplashScene.ballAnchor))
                        .ignoresSafeArea()
                }
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

    /// Frames of the ball rolling right and rolling away (up the screen), a sixteenth of a turn apart.
    struct TrackballRolling: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                ForEach([("Rolling right →", CGVector(dx: 1, dy: 0)), ("Rolling away from you ↑", CGVector(dx: 0, dy: -1))], id: \.0) { title, dir in
                    Text(verbatim: title).font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 10) {
                        ForEach(0..<5) { i in
                            TrackballArt(pose: TrackballPose(orientation: BallSpin.rolled(Double(i) * .pi / 8, direction: dir)))
                                .frame(width: 180, height: 180)
                        }
                    }
                    HStack(spacing: 10) {
                        ForEach(0..<9) { i in
                            TrackballArt(pose: TrackballPose(orientation: BallSpin.rolled(Double(i) * .pi / 8, direction: dir)))
                                .frame(width: 60, height: 60)
                        }
                    }
                }
            }
        }
    }

    /// A popover's content as it looks open: on glass, with the popover's
    /// rounded corners and shadow. Placed in a corner of whatever it's over.
    struct PopoverMock<Content: View>: View {
        var alignment: Alignment = .center
        var top: CGFloat = 0
        var side: CGFloat = 0
        @ViewBuilder var content: Content

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            content
                .background { Color.clear.glassEffect(.regular, in: shape) }
                .clipShape(shape)
                .overlay { shape.strokeBorder(Theme.groupBorder, lineWidth: 1) }
                .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
                .padding(.top, top)
                .padding(alignment == .topTrailing ? .trailing : .leading, side)
                .frame(maxWidth: alignment == .center ? nil : .infinity, maxHeight: alignment == .center ? nil : .infinity,
                       alignment: alignment)
        }
    }

    /// The sidebar's status line for each way a trackball can be connected, and the
    /// battery at each level (wired and unknown show no battery at all).
    struct DeviceStatesSheet: View {
        private let rows: [(String, String, DeviceConnection?, Int?)] = [
            ("Kensington Expert Mouse", "Wired, USB", .usb, nil),
            ("Kensington SlimBlade Pro", "Bluetooth, battery unknown", .bluetooth, nil),
            ("Kensington SlimBlade Pro", "Bluetooth, 100%", .bluetooth, 100),
            ("Kensington SlimBlade Pro", "Bluetooth, 62%", .bluetooth, 62),
            ("Kensington Expert Mouse Wireless", "Receiver, 15% (amber)", .receiver, 15),
            ("Kensington Expert Mouse Wireless", "Receiver, 5% (red)", .receiver, 5),
            ("Kensington Orbit", "Connection unknown, 40%", nil, 40),
        ]

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 18) {
                        Text(verbatim: row.1).font(.system(size: 11)).foregroundStyle(.tertiary).frame(width: 170, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: row.0).font(.system(size: 13, weight: .semibold))
                            HStack(spacing: 5) {
                                StatusDot(color: Theme.ok, size: 7)
                                Text(row.2 == .usb ? "Connected" : "Connected · Beta").font(.system(size: 11)).foregroundStyle(.secondary)
                                let detail = ConnectionDetail(connection: row.2, battery: row.3)
                                if !detail.isEmpty {
                                    Text(verbatim: "·").font(.system(size: 11)).foregroundStyle(.tertiary)
                                    detail
                                }
                            }
                            ConnectionDetail(connection: row.2, battery: row.3, size: 12, symbol: true)
                        }
                    }
                }
            }
        }
    }

    /// Every ball color, as the trackball in it and its little swatch.
    struct BallThemeSheet: View {
        var body: some View {
            let themes = BallTheme.curated + [BallTheme.custom(BallThemeStore.shared.custom)]
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(220), spacing: 18), count: 4), alignment: .leading, spacing: 18) {
                ForEach(themes) { theme in
                    VStack(spacing: 8) {
                        ThemedTrackball(theme: theme)
                            .frame(width: 170, height: 170)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.stage, style: .continuous).fill(Theme.stage))
                        HStack(spacing: 8) {
                            OrbSwatch(palette: theme.palette, size: 22)
                            Text(verbatim: theme.title).font(.system(size: 12, weight: .medium))
                        }
                    }
                }
            }
        }
    }

    /// The trackball drawn in a theme other than the one in use (for the sheet above).
    struct ThemedTrackball: View {
        let theme: BallTheme
        var body: some View {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [theme.glow[1].opacity(0.5), theme.glow[2].opacity(0.18), .clear],
                                         center: .center, startRadius: 10, endRadius: 100))
                TrackballArt(pose: TrackballPose(), theme: theme)
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
        model.showingIconChoice = false
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
