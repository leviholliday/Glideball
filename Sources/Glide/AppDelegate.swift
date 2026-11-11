import AppKit
import Carbon.HIToolbox
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) var window: NSWindow?
    private var launchedAtLogin = false
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
        buildMenu()
        handleTerminateSignal()
        setUpStatusItem()
        _ = AppModel.shared   // starts the engine
        watchModes()
        startHotKeys()
        let showsWindow = firstLaunch || !launchedAtLogin || !AppModel.shared.permissionsOK
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

    /// Double-clicking a .glide-settings file: open the window and preview it.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        showWindow()
        AppModel.shared.previewImport(url)
    }

    @objc private func sendFeedback(_ sender: Any?) {
        showWindow()
        AppModel.shared.showingFeedback = true
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

    @objc private func openWhatsNew(_ sender: Any?) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        NSWorkspace.shared.open(SiteLinks.whatsNew(in: version))
    }

    /// Help › Play the Intro: the first-launch intro again, with its music.
    @objc private func playIntro(_ sender: Any?) {
        showWindow()
        LaunchExperience.shared.replayIntro()
    }

    /// View › ⌘1…⌘6: the main window's tabs, in the order they sit in the window.
    @objc private func selectTab(_ sender: NSMenuItem) {
        guard GlideTab.allCases.indices.contains(sender.tag) else { return }
        showWindow()
        AppModel.shared.requestedTab = GlideTab.allCases[sender.tag]
    }

    @objc private func exportSettings() { showWindow(); AppModel.shared.exportSettings() }
    @objc private func importSettings() { showWindow(); AppModel.shared.importSettings() }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.engine.releaseHeldKeys()
        AppModel.shared.engine.releaseAll()
        AppModel.shared.engine.handBackPointer()   // after releaseAll, which re-applies Glide's speed
        AppModel.shared.saveTotals()
    }

    func showWindow() {
        makeWindow()
        guard !Sandbox.isActive else { return }   // `--self-test` builds the window but never shows it
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        reportWindowState()
        // With no launch animation playing (a reopened window, a launch at
        // login opened later), the card can come straight away; otherwise
        // the animation offers it when it ends.
        if LaunchExperience.shared.show == nil { AppModel.shared.offerSmallFavor() }
    }

    /// The main window and its contents, made once.
    private func makeWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.mainWindowSize),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            Self.styleMainWindow(w)
            w.isMovableByWindowBackground = false   // dragging a slider must never move the window
            w.contentMinSize = Self.mainWindowMinSize
            let hosting = NSHostingView(rootView: RootView(model: AppModel.shared))
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

    /// Shows or hides the menu-bar icon to match the "Menu bar icon" setting.
    func updateStatusItemVisibility() {
        if AppModel.showMenuBarIcon {
            if statusItem == nil {
                setUpStatusItem()
                showModes(AppModel.shared.modes)
            }
        } else if let item = statusItem {
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
        AppModel.shared.config.enabled.toggle()
    }

    @objc private func togglePrecision(_ sender: Any?) {
        toggleMode(.precision)
    }

    @objc private func quitGlide(_ sender: Any?) { quitNow() }

    @objc private func checkForUpdates(_ sender: Any?) {
        showUpdatePanel()
    }

    private var settingsWindow: SettingsWindowController?

    @objc private func openSettings(_ sender: Any?) { showSettings() }

    /// Glideball › Settings… (⌘,): one window, brought forward if it's already
    /// open. Works with the main window closed and with no Dock icon.
    func showSettings(_ pane: SettingsPane? = nil) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.show(pane)
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
                let model = AppModel.shared
                model.config.enabled.toggle()
                NSSound(named: model.config.enabled ? "Pop" : "Funk")?.play()
            case .precision: self?.toggleMode(.precision)
            case .ballScroll: self?.toggleMode(.ballScroll)
            case .dragLock: self?.toggleMode(.dragLock)
            }
        }
        // A keyboard Scroll with ball freezes the cursor until switched off:
        // never carry that across sleep or a locked screen.
        let end: (Notification) -> Void = { _ in AppModel.shared.engine.endBallScrollLatch() }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main, using: end)
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"),
                                                            object: nil, queue: .main, using: end)
    }

    /// A quiet sound says which way it went; a beep means nothing changed
    /// (Glide is paused, or the trackball isn't there to scroll with).
    private func toggleMode(_ mode: Engine.ToggleMode) {
        AppModel.shared.engine.toggleMode(mode) { on in
            guard let on else { return NSSound.beep() }
            NSSound(named: on ? "Tink" : "Purr")?.play()
        }
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About Glideball"), action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: String(localized: "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide Glideball"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit Glideball"), action: #selector(quitGlide), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: String(localized: "File", comment: "Menu bar title"))
        fileMenu.addItem(withTitle: String(localized: "Export Settings…"), action: #selector(exportSettings), keyEquivalent: "e").target = self
        fileMenu.addItem(withTitle: String(localized: "Import Settings…"), action: #selector(importSettings), keyEquivalent: "o").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: String(localized: "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
        for (index, tab) in GlideTab.allCases.enumerated() {
            let item = viewMenu.addItem(withTitle: tab.title, action: #selector(selectTab), keyEquivalent: String(index + 1))
            item.target = self
            item.tag = index
        }
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
