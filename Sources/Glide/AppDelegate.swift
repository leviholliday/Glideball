import AppKit
import Carbon.HIToolbox
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var launchedAtLogin = false

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
        _ = AppModel.shared   // starts the engine
        registerPanicHotKey()
        if !launchedAtLogin || !AppModel.shared.permissionsOK { showWindow() }
    }

    // Closing the window keeps Glide running so the trackball stays tuned.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.engine.releaseHeldKeys()
        AppModel.shared.saveTotals()
    }

    func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = false   // dragging a slider must never move the window
            w.minSize = NSSize(width: 820, height: 600)
            let hosting = NSHostingView(rootView: RootView(model: AppModel.shared))
            hosting.sizingOptions = []   // the window decides its size, not the content
            w.contentView = hosting
            w.setContentSize(NSSize(width: 960, height: 680))
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
        appMenu.addItem(withTitle: "Quit Glide", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}
