import AppKit
import Carbon.HIToolbox
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var launchedAtLogin = false
    private var statusItem: NSStatusItem?
    private var precisionItem: NSMenuItem?
    private var isExplicitlyQuitting = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Launched by "Open at Login"? Then start quietly with no window.
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            launchedAtLogin = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppRename.moveIfNeeded() { exit(0) }   // relaunches as Glideball.app before touching anything
        AppRename.finishLoginItem()
        let firstLaunch = WelcomeTour.shouldShowAtLaunch()   // before AppModel loads settings
        _ = AppLanguage.atLaunch   // the language on screen, before anyone can change it
        buildMenu()
        setUpStatusItem()
        _ = AppModel.shared   // starts the engine
        watchModes()
        startHotKeys()
        let showsWindow = firstLaunch || !launchedAtLogin || !AppModel.shared.permissionsOK
        // The launch animation; the first-launch intro opens the tour itself when it ends.
        let introPlays = LaunchExperience.shared.prepare(firstLaunch: firstLaunch, showsWindow: showsWindow)
        if firstLaunch && !introPlays { AppModel.shared.showWelcomeTour() }
        if showsWindow { showWindow() }
    }

    // Closing the window keeps Glide running so the trackball stays tuned.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Some window-management utilities ask an app to quit once it has no
    /// windows. Glide is an input utility, so keep it alive until its own menu
    /// explicitly requests a quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isExplicitlyQuitting || Self.systemIsEndingSession() { return .terminateNow }
        return .terminateCancel
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

    @objc private func showWelcomeTour(_ sender: Any?) {
        showWindow()
        AppModel.shared.showWelcomeTour()
    }

    @objc private func openWebsite(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://glideball.netlify.app")!)
    }

    @objc private func exportSettings() { showWindow(); AppModel.shared.exportSettings() }
    @objc private func importSettings() { showWindow(); AppModel.shared.importSettings() }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.engine.releaseHeldKeys()
        AppModel.shared.engine.releaseAll()
        AppModel.shared.saveTotals()
    }

    func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = false   // dragging a slider must never move the window
            w.minSize = NSSize(width: 960, height: 620)
            let hosting = NSHostingView(rootView: RootView(model: AppModel.shared))
            hosting.sizingOptions = []   // the window decides its size, not the content
            w.contentView = hosting
            w.setContentSize(NSSize(width: 1040, height: 700))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("GlideMain")
            if !w.setFrameUsingName("GlideMain") { w.center() }
            window = w
        }
        AppModel.shared.startSampling()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        AppModel.shared.stopSampling()
        // Closing the window ends the tour (and gives the buttons their mappings back).
        if AppModel.shared.showingWelcomeTour { AppModel.shared.closeWelcomeTour() }
    }

    func windowDidMiniaturize(_ notification: Notification) { AppModel.shared.stopSampling() }
    func windowDidDeminiaturize(_ notification: Notification) { AppModel.shared.startSampling() }

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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "cursorarrow.click", accessibilityDescription: "Glideball")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Show Glideball"), action: #selector(showGlide), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Pause / Resume Glideball"), action: #selector(toggleGlide), keyEquivalent: "")
        // Scroll with ball and Drag lock act at the pointer, which is up here
        // in the menu bar after choosing an item — so only Precision is offered.
        precisionItem = menu.addItem(withTitle: String(localized: "Precision"), action: #selector(togglePrecision), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Send Feedback…"), action: #selector(sendFeedback), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Glideball"), action: #selector(quitGlide), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
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
        showWindow()
        AppModel.shared.updates.checkNow()
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
        appMenu.addItem(withTitle: String(localized: "About Glideball"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: String(localized: "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "").target = self
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

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: String(localized: "Window", comment: "Menu bar title"))
        windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: String(localized: "Help", comment: "Menu bar title"))
        helpMenu.addItem(withTitle: String(localized: "Show Welcome Tour…"), action: #selector(showWelcomeTour), keyEquivalent: "").target = self
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
