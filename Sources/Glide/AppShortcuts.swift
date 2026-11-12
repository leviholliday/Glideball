import AppKit

/// Every keyboard shortcut in Glideball's window, in one list. The menus take
/// their key equivalents from here (`AppDelegate.buildMenu`) and the shortcuts
/// sheet (? or ⌘/) lists it, so a shortcut added here shows up in both. (The
/// system-wide ones are `GlobalShortcuts`, recorded in Settings › Shortcuts.)
struct AppShortcut: Identifiable {
    let id: String
    let title: String
    var detail: String? = nil
    /// The keycaps the sheet shows.
    let keys: [String]
    /// The menu item's key equivalent, when it's one (nil: the window handles the keys itself).
    var menuKey: String? = nil
    var menuModifiers: NSEvent.ModifierFlags = .command
}

@MainActor
enum AppShortcuts {
    /// The six pages: ⇧1–⇧6 when nothing is being typed (so "!" still types in a
    /// search field), and ⌘1–⌘6 any time.
    static let pageKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22]   // the digit row's 1–6, whatever the layout

    /// The page for a key press, if it's ⇧ and one of the digit row's 1–6.
    static func page(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> GlideTab? {
        guard modifiers.intersection([.command, .option, .control, .shift]) == .shift,
              let i = pageKeyCodes.firstIndex(of: keyCode), GlideTab.allCases.indices.contains(i) else { return nil }
        return GlideTab.allCases[i]
    }

    static var all: [AppShortcut] {
        let pages = GlideTab.allCases.count
        return [
            AppShortcut(id: "pages", title: String(localized: "Switch pages"),
                        detail: String(localized: "\(ListFormatter.localizedString(byJoining: GlideTab.allCases.map(\.title))). ⌘1–⌘\(GlideTab.allCases.count) work too, even while you’re typing.",
                                       comment: "Shortcuts sheet: the pages in order, then a second way to switch; %lld is the number of pages"),
                        keys: ["⇧", "1–\(pages)"]),
            AppShortcut(id: "search", title: String(localized: "Search settings and actions"),
                        detail: String(localized: "⌘F does the same."), keys: ["⌘", "K"], menuKey: "k"),
            AppShortcut(id: "find", title: String(localized: "Search settings and actions"), keys: ["⌘", "F"], menuKey: "f"),
            AppShortcut(id: "settings", title: String(localized: "Settings"), keys: ["⌘", ","], menuKey: ","),
            AppShortcut(id: "export", title: String(localized: "Export Settings…"), keys: ["⌘", "E"], menuKey: "e"),
            AppShortcut(id: "import", title: String(localized: "Import Settings…"), keys: ["⌘", "O"], menuKey: "o"),
            AppShortcut(id: "shortcuts", title: String(localized: "Keyboard shortcuts (this list)"),
                        detail: String(localized: "Or ⌘/ from the Help menu."), keys: ["?"]),
            AppShortcut(id: "shortcuts-menu", title: String(localized: "Keyboard shortcuts (this list)"), keys: ["⌘", "/"], menuKey: "/"),
            AppShortcut(id: "close", title: String(localized: "Close the window (Glideball keeps running)"), keys: ["⌘", "W"], menuKey: "w"),
            AppShortcut(id: "quit", title: String(localized: "Quit Glideball"),
                        detail: AppModel.shared.confirmQuit ? String(localized: "Asks first: Return or ⌘Q again quits.") : nil,
                        keys: ["⌘", "Q"], menuKey: "q"),
        ]
    }

    /// What the sheet lists (one line per thing you can do).
    static var listed: [AppShortcut] { all.filter { $0.id != "shortcuts-menu" && $0.id != "find" } }

    static func entry(_ id: String) -> AppShortcut {
        guard let e = all.first(where: { $0.id == id }) else { preconditionFailure("no shortcut \(id)") }
        return e
    }

    /// A menu item with the key equivalent the list gives `id`.
    @discardableResult
    static func addItem(_ id: String, title: String, action: Selector, to menu: NSMenu, target: AnyObject?) -> NSMenuItem {
        let e = entry(id)
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: e.menuKey ?? "")
        item.keyEquivalentModifierMask = e.menuModifiers
        item.target = target
        return item
    }

    /// Something is being typed in the key window (⇧ + a digit is a character then, not a page).
    static var isTyping: Bool {
        NSApp.keyWindow?.firstResponder is NSText || GlobalHotKeys.shared.suspended
    }
}
