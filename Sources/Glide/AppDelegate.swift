import AppKit
import Carbon.HIToolbox
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) var window: NSWindow?
    private var launchedAtLogin = false
    /// Launched to open a glideball:// URL: start quietly, like at login.
    private var launchedForURL = false
    private var statusItem: NSStatusItem?
    private var precisionItem: NSMenuItem?
    private var isExplicitlyQuitting = false
    private var terminateSignal: DispatchSourceSignal?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // `--self-test` keeps the activation policy main.swift gave it (.prohibited): no Dock icon, never in front.
        guard !Sandbox.isActive else { return }
        // Hidden from the Dock (and ⌘-Tab) if the user chose that; it's reopened from the menu-bar icon.
        if !AppModel.showInDockSaved { NSApp.setActivationPolicy(.accessory) }
        // Launched by "Open at Login"? Then start quietly with no window.
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            launchedAtLogin = true
        }
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventClass == AEEventClass(kInternetEventClass), event.eventID == AEEventID(kAEGetURL),
           event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue?.lowercased()
               .hasPrefix(ExternalControl.scheme + ":") == true {
            launchedForURL = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !Sandbox.isActive {   // `--self-test` never moves the app or touches login items
            if AppRename.moveIfNeeded() { exit(0) }   // relaunches as Glideball.app before touching anything
            AppRename.finishLoginItem()
        }
        let firstLaunch = WelcomeTour.shouldShowAtLaunch()   // before AppModel loads settings
        // The trackball picture's layers (about 70 ms of shading, once), off the main thread
        // so they're ready by the time the window shows.
        DispatchQueue.global(qos: .userInitiated).async { _ = OrbArt.layers }
        _ = AppLanguage.atLaunch   // the language on screen, before anyone can change it
        _ = Sounds.shared.enabled   // settles "Sounds" (the launch reads it) before anything plays
        AppIconChoice.shared.setUp(firstLaunch: firstLaunch)   // the Dock icon: the Orb, or the classic one
        buildMenu()
        installKeyMonitor()
        handleTerminateSignal()
        setUpStatusItem()
        _ = AppModel.shared   // starts the engine
        watchModes()
        startHotKeys()
        ExternalControlCenter.shared.start()   // status.json, if "Allow Raycast and scripts" is on
        let quietLaunch = launchedAtLogin || launchedForURL
        let showsWindow = firstLaunch || !quietLaunch || !AppModel.shared.permissionsOK
        // The launch animation; the first-launch intro opens the tour itself when it ends.
        let introPlays = LaunchExperience.shared.prepare(firstLaunch: firstLaunch, showsWindow: showsWindow)
        if firstLaunch && !introPlays { AppModel.shared.showWelcomeTour() }
        if showsWindow { showWindow() }
        if Sandbox.mode == .selfTest { return SelfTest.launched(self) }   // checks the rest, then exits
        ShareData.shared.start()   // opt-in crash reports and stats; does nothing unless chosen
    }

    // Closing the window keeps Glide running so the trackball stays tuned.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Some window-management utilities ask an app to quit once it has no
    /// windows. Glide is an input utility, so keep it alive unless the quit
    /// really comes from the user: its own menu, macOS, or the command line.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isExplicitlyQuitting || Self.systemIsEndingSession() || Self.quitIsFromUser() { return .terminateNow }
        return .terminateCancel
    }

    /// Quits sent by macOS itself (the Dock, System Settings' "Quit & Reopen",
    /// Activity Monitor, loginwindow) or by a command-line tool with no bundle
    /// ID (osascript, Homebrew) are the user asking. Another app's quit isn't.
    private static func quitIsFromUser() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication,
              let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value, pid > 0 else { return false }
        guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return true }
        return id.hasPrefix("com.apple.")
    }

    /// `killall Glideball`, Homebrew's signal and logout's last resort send
    /// SIGTERM: quit properly, so held keys and modes are released and totals saved.
    private func handleTerminateSignal() {
        signal(SIGTERM, SIG_IGN)   // the source below handles it instead
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            // On the main run loop, not inside a main-queue block: quitting from
            // there can deadlock against anything else waiting on the main queue.
            RunLoop.main.perform(inModes: [.common]) { self?.quitNow() }
            CFRunLoopWakeUp(CFRunLoopGetMain())
            // If the main thread is stuck, still die like a plain SIGTERM would.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                signal(SIGTERM, SIG_DFL)
                raise(SIGTERM)
            }
        }
        source.resume()
        terminateSignal = source
    }

    /// Logging out, restarting and shutting down send a quit with a reason;
    /// Glide must never be the app that holds those up.
    private static func systemIsEndingSession() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication,
              let reason = event.attributeDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog,
                kAERestart, kAEShutDown, kAEShowRestartDialog].map { OSType($0) }.contains(reason)
    }

    /// Quits for real — the Quit menu items and the updater's relaunch.
    func quitNow() {
        isExplicitlyQuitting = true
        NSApp.terminate(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    /// glideball:// URLs go to ExternalControlCenter (Raycast, scripts).
    /// Double-clicking a .glide-settings file: open the window and preview it.
    func application(_ application: NSApplication, open urls: [URL]) {
        let isLink = { (url: URL) in url.scheme?.lowercased() == ExternalControl.scheme }
        urls.filter(isLink).forEach { ExternalControlCenter.shared.handle($0) }
        guard let url = urls.first(where: { !isLink($0) }) else { return }
        showWindow()
        AppModel.shared.previewImport(url)
    }

    @objc private func sendFeedback(_ sender: Any?) {
        Commands.run("feedback", on: AppCommandTarget.shared)
    }

    @objc private func showAbout(_ sender: Any?) {
        showWindow()
        AppModel.shared.showingAbout = true
    }

    @objc private func showWelcomeTour(_ sender: Any?) {
        showWindow()
        AppModel.shared.showWelcomeTour()
    }

    @objc private func openWebsite(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://glideball.netlify.app")!)
    }

    @objc private func openHelp(_ sender: Any?) { NSWorkspace.shared.open(SiteLinks.help) }
    @objc private func openTroubleshooting(_ sender: Any?) { NSWorkspace.shared.open(SiteLinks.troubleshooting) }

    /// Help › What's New: this version's What's New, over the window.
    @objc private func openWhatsNew(_ sender: Any?) {
        showWindow()
        AppModel.shared.showWhatsNew()
    }

    /// Help › Play the Intro: the first-launch intro again, with its music.
    @objc private func playIntro(_ sender: Any?) {
        showWindow()
        LaunchExperience.shared.replayIntro()
    }

    /// View › ⇧1…⇧6 (⌘1…⌘6): the main window's tabs, in the order they sit in the window.
    @objc private func selectTab(_ sender: NSMenuItem) {
        guard GlideTab.allCases.indices.contains(sender.tag) else { return }
        showWindow()
        MainActor.assumeIsolated { AppModel.shared.requestTab(GlideTab.allCases[sender.tag]) }
    }

    /// ⇧ + a digit is a character while something's being typed, never a page.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(selectTab), item.keyEquivalentModifierMask == .shift,
           NSApp.currentEvent?.type == .keyDown, MainActor.assumeIsolated({ AppShortcuts.isTyping }) {
            return false
        }
        return true
    }

    @objc private func exportSettings() { showWindow(); AppModel.shared.exportSettings() }
    @objc private func importSettings() { showWindow(); AppModel.shared.importSettings() }

    /// View › Search… (⌘K, ⌘F): the search palette over the main window.
    @objc func openSearch(_ sender: Any?) { MainActor.assumeIsolated { CommandPalette.shared.toggle() } }

    func applicationWillTerminate(_ notification: Notification) {
        // A value on trial goes back first, so it's never what's left saved.
        MainActor.assumeIsolated { TryPreview.shared.revert(.quit) }
        ExternalControlCenter.shared.stop()   // status.json goes with the app
        AppModel.shared.engine.releaseHeldKeys()
        AppModel.shared.engine.releaseAll()
        AppModel.shared.engine.handBackPointer()   // after releaseAll, which re-applies Glide's speed
        AppModel.shared.saveTotals()
    }

    func showWindow() {
        makeWindow()
        guard !Sandbox.isActive else { return }   // `--self-test` builds the window but never shows it
        let opening = window?.isVisible != true
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        reportWindowState()
        // Opening the window with no launch animation playing (a reopened
        // window, a launch at login opened later): What's New or the small
        // favor can come straight away; otherwise the animation offers it when it ends.
        if opening && LaunchExperience.shared.show == nil { AppModel.shared.showNextPrompt() }
        if opening { AppModel.shared.engine.reconcileDevices() }   // "Connected" is checked against the devices there now
    }

    /// The main window and its contents, made once.
    private func makeWindow() {
        if window == nil {
            let w = MainWindow(contentRect: NSRect(origin: .zero, size: Self.mainWindowSize),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
            Self.styleMainWindow(w)
            w.isMovableByWindowBackground = false   // dragging a slider must never move the window
            w.contentMinSize = Self.mainWindowMinSize
            let hosting = NSHostingView(rootView: RootView(model: AppModel.shared, primary: true))
            hosting.sizingOptions = []   // the window decides its size, not the content
            w.contentView = hosting
            w.setContentSize(Self.mainWindowSize)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("GlideMain")
            if w.setFrameUsingName("GlideMain") {
                Self.keepSensible(w)
            } else {
                w.center()
            }
            window = w
        }
    }

    /// Transparent title bar with the traffic lights over the sidebar, and no custom header.
    /// The empty toolbar is what lets the sidebar's glass run the window's full height,
    /// under the traffic lights, as in Finder or Notes. (Shared with --render-ui.)
    static func styleMainWindow(_ w: NSWindow) {
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Glideball"
        let toolbar = NSToolbar(identifier: "GlideMain")
        toolbar.allowsUserCustomization = false
        w.toolbar = toolbar
        w.toolbarStyle = .unified
    }

    static let mainWindowSize = NSSize(width: 980, height: 680)
    static let mainWindowMinSize = NSSize(width: 860, height: 580)

    /// A saved frame from an older layout (or another display arrangement) is
    /// kept where it can be: never below the minimum, never bigger than the
    /// screen it's on, and pulled fully onto that screen.
    private static func keepSensible(_ w: NSWindow) {
        guard let visible = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = w.frame
        let minFrame = w.frameRect(forContentRect: NSRect(origin: .zero, size: mainWindowMinSize)).size
        frame.size.width = min(max(frame.width, minFrame.width), visible.width)
        frame.size.height = min(max(frame.height, minFrame.height), visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if frame != w.frame { w.setFrame(frame, display: false) }
    }

    /// Tells the model what the window's doing, so it animates only while someone can see it.
    private func reportWindowState(closing: Bool = false) {
        guard let w = window else { return }
        let visible = !closing && w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
        AppModel.shared.windowStateChanged(visible: visible, key: visible && w.isKeyWindow)
    }

    func windowDidBecomeKey(_ notification: Notification) { reportWindowState() }
    func windowDidResignKey(_ notification: Notification) { reportWindowState() }
    func windowDidChangeOcclusionState(_ notification: Notification) { reportWindowState() }

    func windowWillClose(_ notification: Notification) {
        reportWindowState(closing: true)
        // Closing the window ends the tour (and gives the buttons their mappings back).
        if AppModel.shared.showingWelcomeTour { AppModel.shared.closeWelcomeTour() }
    }

    func windowDidMiniaturize(_ notification: Notification) { reportWindowState() }
    func windowDidDeminiaturize(_ notification: Notification) { reportWindowState() }

    // Full screen: the empty toolbar that lets the sidebar's glass run under the
    // traffic lights in a window turns into a plain grey bar across the top in full
    // screen. So it goes while the window is full screen, and comes back on the way out.
    func windowWillEnterFullScreen(_ notification: Notification) { Self.setFullScreen(true, window) }
    func windowWillExitFullScreen(_ notification: Notification) { Self.setFullScreen(false, window) }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { Self.setFullScreen(false, window) }

    /// Shared with --render-ui's `fullscreen` picture.
    static func setFullScreen(_ on: Bool, _ w: NSWindow?) {
        w?.toolbar?.isVisible = !on
        AppModel.shared.fullScreen = on
    }

    /// Shows or hides the menu-bar icon to match the "Menu bar icon" setting.
    func updateStatusItemVisibility() {
        if AppModel.showMenuBarIcon {
            if statusItem == nil {
                setUpStatusItem()
                showModes(AppModel.shared.modes)
            }
        } else if let item = statusItem {
            MainActor.assumeIsolated { MenuBarPanelController.shared.close() }
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            precisionItem = nil
        }
    }

    private func setUpStatusItem() {
        guard AppModel.showMenuBarIcon else { return }
        let menu = makeStatusMenu()
        // `--self-test` builds the menu but puts nothing in the menu bar.
        guard !Sandbox.isActive else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "cursorarrow.click", accessibilityDescription: "Glideball")
        item.button?.image?.isTemplate = true
        item.menu = menu
        statusItem = item
        // "Menu bar icon opens: Panel" takes the clicks instead (a right-click still shows this menu).
        MainActor.assumeIsolated { MenuBarPanelController.shared.attach(item, menu: menu) }
    }

    /// The menu-bar icon's menu.
    private(set) var statusMenu: NSMenu?

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Show Glideball"), action: #selector(showGlide), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Pause / Resume Glideball"), action: #selector(toggleGlide), keyEquivalent: "")
        // Scroll with ball and Drag lock act at the pointer, which is up here
        // in the menu bar after choosing an item — so only Precision is offered.
        precisionItem = menu.addItem(withTitle: String(localized: "Precision"), action: #selector(togglePrecision), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: String(localized: "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Send Feedback…"), action: #selector(sendFeedback), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Glideball"), action: #selector(quitGlide), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusMenu = menu
        return menu
    }

    /// The menu-bar icon shows Precision and Drag lock, even with the window closed.
    private func watchModes() {
        let engine = AppModel.shared.engine
        let modelHandler = engine.onModes   // keeps AppModel.modes updating too
        engine.onModes = { [weak self] modes in
            modelHandler?(modes)
            self?.showModes(modes)
        }
    }

    private func showModes(_ modes: Engine.Modes) {
        let symbol = modes.dragLocked ? "hand.draw.fill" : modes.precision ? "scope" : "cursorarrow.click"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Glideball")
        statusItem?.button?.image?.isTemplate = true
        precisionItem?.state = modes.precision ? .on : .off
    }

    @objc private func showGlide(_ sender: Any?) {
        showWindow()
    }

    @objc private func toggleGlide(_ sender: Any?) {
        Commands.run("toggle", on: AppCommandTarget.shared)
    }

    @objc private func togglePrecision(_ sender: Any?) {
        toggleMode(.precision)
    }

    /// Glideball's own Quit (the menu, ⌘Q, the menu-bar icon): asks first, unless that's turned off.
    @objc func quitGlide(_ sender: Any?) { MainActor.assumeIsolated { QuitConfirm.ask() } }

    /// Help › Keyboard Shortcuts (⌘/), and ? in the window.
    @objc func showShortcuts(_ sender: Any?) {
        showWindow()
        AppModel.shared.showingShortcuts = true
    }

    private var keyMonitor: Any?

    /// ⌘Q goes to the quit question here as well as through the menu (a menu's key
    /// equivalent can be missed the first time after launch), and ? in the main
    /// window opens the shortcuts sheet when nothing is being typed.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            // (Not while Settings › Shortcuts is recording a new shortcut: then ⌘Q is the keys being recorded.)
            if mods == .command, e.charactersIgnoringModifiers?.lowercased() == "q", !GlobalHotKeys.shared.suspended {
                MainActor.assumeIsolated { QuitConfirm.ask() }
                return nil
            }
            if e.characters == "?", mods.subtracting(.shift).isEmpty, let self, self.wantsShortcutKey {
                self.showShortcuts(nil)
                return nil
            }
            return e
        }
    }

    /// ? means the shortcuts only in the main window with nothing being typed, no sheet,
    /// no launch animation, tour or card over it.
    private var wantsShortcutKey: Bool {
        guard let w = window, NSApp.keyWindow === w, w.attachedSheet == nil else { return false }
        if w.firstResponder is NSText { return false }
        let m = AppModel.shared
        return LaunchExperience.shared.show == nil && !m.showingWelcomeTour && !m.showingWhatsNew
            && !m.showingIconChoice && !m.showingSmallFavor && !m.showingShortcuts
            && !CommandPalette.shared.isOpen && RecapCenter.shared.showing == nil
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        Commands.run("check-for-updates", on: AppCommandTarget.shared)
    }

    private var settingsWindow: SettingsWindowController?

    @objc private func openSettings(_ sender: Any?) { Commands.run("settings", on: AppCommandTarget.shared) }

    /// Glideball › Settings… (⌘,): one window, brought forward if it's already
    /// open. Works with the main window closed and with no Dock icon.
    func showSettings(_ pane: SettingsPane? = nil, spotlight: String? = nil) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.show(pane, spotlight: spotlight)
    }

    private var updateWindow: NSWindow?

    /// The Software Update window: checks GitHub (unless `check` is false) and shows,
    /// big and clear, what it found — up to date, an update to install, or couldn't check.
    func showUpdatePanel(check: Bool = true) {
        let updates = AppModel.shared.updates
        let busy: Bool = {
            switch updates.installState {
            case .downloading, .installing: return true
            case .idle, .failed: return false
            }
        }()
        if check && !busy { updates.checkNow() }
        if updateWindow == nil {
            let controller = NSHostingController(rootView: UpdatePanelView(updates: updates) { [weak self] in
                self?.updateWindow?.close()
            })
            controller.sizingOptions = [.preferredContentSize]   // the window follows its content's height
            let w = NSWindow(contentViewController: controller)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = String(localized: "Software Update")
            w.isReleasedWhenClosed = false
            w.isMovableByWindowBackground = true
            w.center()
            updateWindow = w
        }
        updateWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Glide's global shortcuts. Pause (⌃⌥⌘G unless changed) is the escape
    /// hatch that works even if a mapping makes the mouse unusable; the others
    /// switch Precision, Scroll with ball, and Drag lock. No permissions needed.
    private func startHotKeys() {
        GlobalHotKeys.shared.start(AppModel.shared.config.globalShortcuts) { [weak self] action in
            switch action {
            case .pause:
                Commands.run("toggle", on: AppCommandTarget.shared) { running in
                    Sounds.shared.play(running == true ? .resume : .pause)
                }
            case .precision: self?.toggleMode(.precision)
            case .ballScroll: self?.toggleMode(.ballScroll)
            case .dragLock: self?.toggleMode(.dragLock)
            }
        }
        // Scroll with ball and gestures freeze the cursor, held keys and drags hold on:
        // never carry that across sleep or a locked screen.
        let end: (Notification) -> Void = { _ in AppModel.shared.engine.releaseForSleep() }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main, using: end)
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"),
                                                            object: nil, queue: .main, using: end)
    }

    /// A high or low tick says which way it went; a beep means nothing changed
    /// (Glide is paused, or the trackball isn't there to scroll with).
    private func toggleMode(_ mode: GlideMode) {
        Commands.run(mode.rawValue, .toggle, on: AppCommandTarget.shared) { on in
            guard let on else { return NSSound.beep() }
            Sounds.shared.play(on ? .modeOn : .modeOff)
        }
    }

    private func buildMenu() { MainActor.assumeIsolated { buildMenuOnMain() } }

    @MainActor private func buildMenuOnMain() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About Glideball"), action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: String(localized: "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        // Key equivalents come from AppShortcuts, which the shortcuts sheet lists too.
        AppShortcuts.addItem("settings", title: String(localized: "Settings…"), action: #selector(openSettings), to: appMenu, target: self)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide Glideball"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        AppShortcuts.addItem("quit", title: String(localized: "Quit Glideball"), action: #selector(quitGlide), to: appMenu, target: self)
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: String(localized: "File", comment: "Menu bar title"))
        AppShortcuts.addItem("export", title: String(localized: "Export Settings…"), action: #selector(exportSettings), to: fileMenu, target: self)
        AppShortcuts.addItem("import", title: String(localized: "Import Settings…"), action: #selector(importSettings), to: fileMenu, target: self)
        fileMenu.addItem(.separator())
        AppShortcuts.addItem("close", title: String(localized: "Close Window"), action: #selector(NSWindow.performClose(_:)), to: fileMenu, target: nil)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // Text fields get ⌘Z, ⌘X, ⌘C, ⌘V and ⌘A from these items: no target,
        // so each goes to whatever is focused (and greys out when nothing can).
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: "Edit", comment: "Menu bar title"))
        editMenu.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: String(localized: "View", comment: "Menu bar title"))
        // Each page shows ⇧1…⇧6 (the main window handles those itself, and only when
        // nothing's being typed); holding ⌘ with the menu open shows ⌘1…⌘6, which work any time.
        for (index, tab) in GlideTab.allCases.enumerated() {
            for (mask, alternate) in [(NSEvent.ModifierFlags.shift, false), (.command, true)] {
                let item = viewMenu.addItem(withTitle: tab.title, action: #selector(selectTab), keyEquivalent: String(index + 1))
                item.keyEquivalentModifierMask = mask
                item.isAlternate = alternate
                item.target = self
                item.tag = index
            }
        }
        viewMenu.addItem(.separator())
        AppShortcuts.addItem("search", title: String(localized: "Search…", comment: "View menu: opens the search palette"),
                             action: #selector(openSearch), to: viewMenu, target: self)
        AppShortcuts.addItem("find", title: String(localized: "Find a Setting…", comment: "View menu: opens the search palette"),
                             action: #selector(openSearch), to: viewMenu, target: self)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: String(localized: "Window", comment: "Menu bar title"))
        windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: String(localized: "Help", comment: "Menu bar title"))
        helpMenu.addItem(withTitle: String(localized: "About & Help…"), action: #selector(showAbout), keyEquivalent: "").target = self
        helpMenu.addItem(withTitle: String(localized: "Show Welcome Tour…"), action: #selector(showWelcomeTour), keyEquivalent: "").target = self
        helpMenu.addItem(withTitle: String(localized: "Play the Intro"), action: #selector(playIntro), keyEquivalent: "").target = self
        AppShortcuts.addItem("shortcuts-menu", title: String(localized: "Keyboard Shortcuts"), action: #selector(showShortcuts), to: helpMenu, target: self)
        helpMenu.addItem(.separator())
        helpMenu.addItem(withTitle: String(localized: "Glideball Help"), action: #selector(openHelp), keyEquivalent: "").target = self
        helpMenu.addItem(withTitle: String(localized: "Troubleshooting"), action: #selector(openTroubleshooting), keyEquivalent: "").target = self
        helpMenu.addItem(withTitle: String(localized: "What’s New"), action: #selector(openWhatsNew), keyEquivalent: "").target = self
        helpMenu.addItem(.separator())
        helpMenu.addItem(withTitle: String(localized: "Send Feedback…"), action: #selector(sendFeedback), keyEquivalent: "").target = self
        helpMenu.addItem(withTitle: String(localized: "Glideball Website"), action: #selector(openWebsite), keyEquivalent: "").target = self
        helpItem.submenu = helpMenu
        main.addItem(helpItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }
}

/// The main window. A key press nothing inside it wanted ends up here: ⇧1…⇧6
/// switch pages. A search field or a shortcut being recorded takes the key
/// first, so ⇧1 there still types "!" (or is recorded).
final class MainWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        if let tab = AppShortcuts.page(keyCode: event.keyCode, modifiers: event.modifierFlags), !AppShortcuts.isTyping {
            AppModel.shared.requestTab(tab)
            return
        }
        super.keyDown(with: event)
    }
}
