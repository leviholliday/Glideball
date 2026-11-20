import AppKit
import SwiftUI

/// `--render-ui` screens for "Allow AI apps" (Views/AIAppsViews.swift, AIAppsCenter.swift):
/// the switch with its countdown in Settings › General, the countdown in the sidebar and
/// the menu-bar panel, Connect an AI app…, and an AI app's proposal in the usual preview.
/// Nothing is listening: the sandbox never makes the socket file.
extension RenderUI {
    static func aiAppsScreens(_ model: AppModel) -> [Screen] {
        var list: [Screen] = []
        let center = AIAppsCenter.shared
        /// On, with 14:32 left.
        func on() {
            var now = 1_000.0
            AIAppsCenter.clock = { now }
            center.turnOn()
            now += 28
            center.tick()
        }
        func off() {
            center.turnOff()
            AIAppsCenter.clock = AIAppsClock.now
            model.toast = nil
            baseline(model)
        }
        func add(_ name: String, _ title: String, prepare: @escaping () -> Void = {}, draw: @escaping (Bool, CGFloat) -> NSBitmapImageRep?) {
            list.append(Screen(name: name, group: "Allow AI apps", title: title, prepare: prepare, draw: draw, cleanup: off))
        }

        add("ai-apps-settings", "Settings › General with Allow AI apps on: the countdown beside the switch", prepare: on) { dark, scale in
            settings(.general, dark: dark, scale: scale)
        }
        add("ai-apps-sidebar", "The main window while it's on: the countdown and Stop above the on/off switch", prepare: on) { dark, scale in
            mainWindow(model, tab: .buttons, dark: dark, scale: scale)
        }
        add("ai-apps-menubar-panel", "The menu-bar panel while it's on", prepare: on) { dark, scale in
            card(PopoverMock { MenuBarPanelView(model: model) }, width: MenuBarPanelView.width + 80, dark: dark, scale: scale)
        }
        add("ai-apps-connect", "Connect an AI app…: what to copy into Claude Code, Claude's desktop app or another app") { dark, scale in
            sheet(ConnectAIAppSheet(), dark: dark, scale: scale)
        }
        // A proposal as the person sees it: who sent it (the name it gave, unchecked), every
        // change, ⌘Q flagged red and left out unless ticked, what was left out of the code.
        let proposal = """
        {"format": "glideball-ai-setup", "version": 1, "trackingSpeed": 7,
         "buttons": {"0": "rightClick", "2": "keys:cmd+q", "3": "keys:cmd+w"},
         "combos": [{"buttons": [1, 2], "action": "open:Notes"}]}
        """
        add("ai-apps-review", "An AI app's proposal in the preview: its name as it gave it, ⌘Q flagged, button 0 left out") { dark, scale in
            guard case .code(let r) = model.aiReading(proposal) else { return nil }
            var incoming = IncomingSetup(source: .aiApp("Claude"), content: .shared(r.share), leftOut: r.notes)
            incoming.proposal = String(repeating: "0", count: 32)
            return sheet(IncomingSetupSheet(model: model, incoming: incoming), dark: dark, scale: scale)
        }
        add("ai-apps-review-no-name", "The same from an AI app that gave no name") { dark, scale in
            guard case .code(let r) = model.aiReading(proposal) else { return nil }
            return sheet(IncomingSetupSheet(model: model, incoming: IncomingSetup(source: .aiApp(""), content: .shared(r.share), leftOut: r.notes)),
                         dark: dark, scale: scale)
        }
        return list
    }
}
