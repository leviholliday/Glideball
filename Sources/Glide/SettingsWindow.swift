import AppKit
import SwiftUI

/// The tabs of Glideball › Settings… (⌘,). The raw value is what's saved.
enum SettingsPane: String, CaseIterable {
    case general, updates, privacy, shortcuts

    var title: String {
        switch self {
        case .general: String(localized: "General", comment: "Settings tab")
        case .updates: String(localized: "Updates", comment: "Settings tab")
        case .privacy: String(localized: "Privacy", comment: "Settings tab")
        case .shortcuts: String(localized: "Shortcuts", comment: "Settings tab: keyboard shortcuts")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .updates: "arrow.down.circle"
        case .privacy: "hand.raised"
        case .shortcuts: "command"
        }
    }
}

/// The Settings window: toolbar tabs at the top, like any Mac app's settings,
/// and a window that grows or shrinks to fit each tab. One instance, kept
/// while Glideball runs; it works with the main window closed and with no Dock icon.
final class SettingsWindowController: NSWindowController {
    private static let lastPaneKey = "GlideSettingsPane"
    private let tabs = SettingsTabController()

    init() {
        let model = AppModel.shared
        for pane in SettingsPane.allCases {
            let controller = NSHostingController(rootView: Self.view(for: pane, model: model))
            // Only report a size: the tab controller resizes the window itself (animated).
            controller.sizingOptions = [.preferredContentSize]
            controller.title = pane.title
            let item = NSTabViewItem(viewController: controller)
            item.identifier = pane.rawValue
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        tabs.tabStyle = .toolbar
        let saved = UserDefaults.standard.string(forKey: Self.lastPaneKey).flatMap(SettingsPane.init(rawValue:)) ?? .general
        tabs.selectedTabViewItemIndex = SettingsPane.allCases.firstIndex(of: saved) ?? 0

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        tabs.onSelect = { pane in UserDefaults.standard.set(pane.rawValue, forKey: Self.lastPaneKey) }
        tabs.fitWindow(animated: false)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Brings Settings forward (on `pane`, or wherever it was left), activating
    /// Glideball so the window comes to the front even without a Dock icon.
    func show(_ pane: SettingsPane? = nil) {
        if let pane, let index = SettingsPane.allCases.firstIndex(of: pane) {
            tabs.selectedTabViewItemIndex = index
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    @MainActor @ViewBuilder
    private static func view(for pane: SettingsPane, model: AppModel) -> some View {
        switch pane {
        case .general: GeneralSettingsPane(model: model)
        case .updates: UpdatesSettingsPane(model: model)
        case .privacy: PrivacySettingsPane()
        case .shortcuts: ShortcutsSettingsPane(model: model)
        }
    }
}

/// Toolbar tabs that resize the window to the chosen tab's content, keeping its top edge still.
private final class SettingsTabController: NSTabViewController {
    var onSelect: ((SettingsPane) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String, let pane = SettingsPane(rawValue: id) { onSelect?(pane) }
        fitWindow(animated: view.window?.isVisible == true)
    }

    /// A tab's content changed height (a row appeared or went away): follow it.
    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        guard viewController === tabView.selectedTabViewItem?.viewController else { return }
        fitWindow(animated: view.window?.isVisible == true)
    }

    func fitWindow(animated: Bool) {
        guard let window = view.window, let content = window.contentView,
              let child = tabView.selectedTabViewItem?.viewController else { return }
        let size = child.view.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        var frame = window.frame
        let dh = size.height - content.frame.height
        let dw = size.width - content.frame.width
        guard abs(dh) > 0.5 || abs(dw) > 0.5 else { return }
        frame.size.height += dh
        frame.size.width += dw
        frame.origin.y -= dh   // the top edge stays where it is
        window.setFrame(frame, display: true, animate: animated)
    }
}
