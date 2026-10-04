import AppKit
import Carbon.HIToolbox
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var launchedAtLogin = false
    private var statusItem: NSStatusItem?
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
        buildMenu()
        setUpStatusItem()
        _ = AppModel.shared   // starts the engine
        registerPanicHotKey()
        if !launchedAtLogin || !AppModel.shared.permissionsOK { showWindow() }
    }

    // Closing the window keeps Glide running so the trackball stays tuned.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Some window-management utilities ask an app to quit once it has no
    /// windows. Glide is an input utility, so keep it alive until its own menu
    /// explicitly requests a quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isExplicitlyQuitting ? .terminateNow : .terminateCancel
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

    @objc private func openWebsite(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://glide-trackball.netlify.app")!)
    }

    @objc private func exportSettings() { showWindow(); AppModel.shared.exportSettings() }
    @objc private func importSettings() { showWindow(); AppModel.shared.importSettings() }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.engine.releaseHeldKeys()
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
    }

    func windowDidMiniaturize(_ notification: Notification) { AppModel.shared.stopSampling() }
    func windowDidDeminiaturize(_ notification: Notification) { AppModel.shared.startSampling() }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "cursorarrow.click", accessibilityDescription: "Glide")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(withTitle: "Show Glide", action: #selector(showGlide), keyEquivalent: "")
        menu.addItem(withTitle: "Pause / Resume Glide", action: #selector(toggleGlide), keyEquivalent: "")
        menu.addItem(withTitle: "Send Feedback…", action: #selector(sendFeedback), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Glide", action: #selector(quitGlide), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func showGlide(_ sender: Any?) {
        showWindow()
    }

    @objc private func toggleGlide(_ sender: Any?) {
        AppModel.shared.config.enabled.toggle()
    }

    @objc private func quitGlide(_ sender: Any?) {
        isExplicitlyQuitting = true
        NSApp.terminate(nil)
    }

    /// ⌃⌥⌘G pauses / resumes Glide from anywhere — an escape hatch that works
    /// even if a mapping makes the mouse unusable. Needs no permissions.
    private func registerPanicHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                let model = AppModel.shared
                model.config.enabled.toggle()
                NSSound(named: model.config.enabled ? "Pop" : "Funk")?.play()
            }
            return noErr
        }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_G), UInt32(controlKey | optionKey | cmdKey),
                            EventHotKeyID(signature: OSType(0x474C4944), id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Glide", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Glide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Glide", action: #selector(quitGlide), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Export Settings…", action: #selector(exportSettings), keyEquivalent: "e").target = self
        fileMenu.addItem(withTitle: "Import Settings…", action: #selector(importSettings), keyEquivalent: "o").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Send Feedback…", action: #selector(sendFeedback), keyEquivalent: "").target = self
        helpMenu.addItem(withTitle: "Glide Website", action: #selector(openWebsite), keyEquivalent: "").target = self
        helpItem.submenu = helpMenu
        main.addItem(helpItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }
}
