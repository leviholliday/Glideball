import AppKit
import Foundation

/// Everything a button or combo can do, the way the action picker shows it:
/// in groups, each with an icon, its name, one line about what it does, and
/// a few extra words search also matches. The names and icons come from
/// `ButtonAction.presets` (Config.swift), so menus elsewhere say the same.
enum ActionCatalog {
    enum Category: String, CaseIterable, Identifiable {
        case clicks, navigation, windows, editing, modes, media, tools, nothing
        var id: String { rawValue }

        var title: String {
            switch self {
            case .clicks: String(localized: "Clicks", comment: "Action picker group")
            case .navigation: String(localized: "Back, forward and tabs", comment: "Action picker group")
            case .windows: String(localized: "Spaces, Mission Control and windows", comment: "Action picker group")
            case .editing: String(localized: "Editing", comment: "Action picker group")
            case .modes: String(localized: "Pointer and scrolling modes", comment: "Action picker group")
            case .media: String(localized: "Media", comment: "Action picker group: music and video controls")
            case .tools: String(localized: "Apps and tools", comment: "Action picker group")
            case .nothing: String(localized: "Turn it off", comment: "Action picker group: make a button do nothing")
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let action: ButtonAction
        let category: Category
        let title: String
        let symbol: String
        /// One line about what it does.
        let detail: String
        /// More words search matches (English and the translation both work, since
        /// they're joined with the title and detail).
        let keywords: String
        var id: String { "\(action)" }

        /// The keys it sends, for the keycaps on the right ("⌃→"), if it's a shortcut.
        var keys: String? {
            switch action {
            case .shortcut(let s), .holdShortcut(let s): s.display
            default: nil
            }
        }

        func matches(_ query: String) -> Bool { score(query) > 0 }

        /// How well it matches a search (0: not at all). A word at the start of the
        /// name counts most, then anywhere in the name, then the extra words, then
        /// the line about it. Every typed word has to match somewhere.
        func score(_ query: String) -> Double {
            let words = query.split(separator: " ").map(String.init)
            guard !words.isEmpty else { return 1 }
            let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            var total = 0.0
            for w in words {
                let titleWords = title.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "(" })
                if titleWords.contains(where: { $0.range(of: w, options: opts.union(.anchored)) != nil }) { total += 4 }
                else if title.range(of: w, options: opts) != nil { total += 3 }
                else if keywords.range(of: w, options: opts) != nil || (keys ?? "").range(of: w, options: opts) != nil { total += 2 }
                else if detail.range(of: w, options: opts) != nil { total += 1 }
                else { return 0 }
            }
            return total
        }
    }

    private static func item(_ action: ButtonAction, _ category: Category, _ detail: String, _ keywords: String = "") -> Item {
        Item(action: action, category: category, title: action.title, symbol: action.symbol, detail: detail, keywords: keywords)
    }

    static var all: [Item] {
        [
            item(.system, .clicks, String(localized: "Whatever this button does without Glideball.", comment: "Action picker: Default"), "normal reset original"),
            item(.leftClick, .clicks, String(localized: "A normal click.", comment: "Action picker: Left click"), "primary select"),
            item(.rightClick, .clicks, String(localized: "Opens the menu for what’s under the pointer.", comment: "Action picker: Right click"), "secondary context menu"),
            item(.middleClick, .clicks, String(localized: "Opens links in a new tab in most browsers.", comment: "Action picker: Middle click"), "wheel"),
            item(.modifiedClick(button: 0, modifiers: CGEventFlags.maskCommand.rawValue), .clicks,
                 String(localized: "Click with ⌘ held: opens links in a background tab.", comment: "Action picker: Command-click"), "cmd"),
            item(.modifiedClick(button: 0, modifiers: CGEventFlags.maskControl.rawValue), .clicks,
                 String(localized: "Click with ⌃ held: the other way to right-click.", comment: "Action picker: Control-click"), "ctrl"),
            item(.modifiedClick(button: 0, modifiers: CGEventFlags.maskShift.rawValue), .clicks,
                 String(localized: "Click with ⇧ held: selects everything in between.", comment: "Action picker: Shift-click"), "range"),
            item(.modifiedClick(button: 0, modifiers: CGEventFlags.maskAlternate.rawValue), .clicks,
                 String(localized: "Click with ⌥ held.", comment: "Action picker: Option-click"), "alt"),
            item(.modifiedClick(button: 1, modifiers: CGEventFlags.maskControl.rawValue), .clicks,
                 String(localized: "Right click with ⌃ held.", comment: "Action picker: Control-right-click"), "ctrl"),

            item(.back, .navigation, String(localized: "Back in browsers, Finder and most apps, like a mouse’s side button.", comment: "Action picker: Back"), "previous page button 4"),
            item(.forward, .navigation, String(localized: "Forward in browsers, Finder and most apps.", comment: "Action picker: Forward"), "next page button 5"),
            item(.shortcut(.browserBack), .navigation, String(localized: "Back with the keyboard shortcut, for apps that ignore the mouse button.", comment: "Action picker: Browser Back"), "previous page"),
            item(.shortcut(.browserForward), .navigation, String(localized: "Forward with the keyboard shortcut.", comment: "Action picker: Browser Forward"), "next page"),
            item(.shortcut(.newTab), .navigation, String(localized: "Opens a new tab.", comment: "Action picker: New Tab"), "browser"),
            item(.shortcut(.closeTab), .navigation, String(localized: "Closes the tab or window in front.", comment: "Action picker: Close Tab"), "browser window"),
            item(.shortcut(.reopenTab), .navigation, String(localized: "Brings back the tab you just closed.", comment: "Action picker: Reopen Closed Tab"), "browser undo"),
            item(.shortcut(.nextTab), .navigation, String(localized: "Moves to the tab on the right.", comment: "Action picker: Next Tab"), "browser switch"),
            item(.shortcut(.previousTab), .navigation, String(localized: "Moves to the tab on the left.", comment: "Action picker: Previous Tab"), "browser switch"),
            item(.shortcut(.reload), .navigation, String(localized: "Reloads the page.", comment: "Action picker: Reload"), "refresh browser"),
            item(.shortcut(.zoomIn), .navigation, String(localized: "Makes the page bigger.", comment: "Action picker: Zoom In"), "larger"),
            item(.shortcut(.zoomOut), .navigation, String(localized: "Makes the page smaller.", comment: "Action picker: Zoom Out"), "smaller"),

            item(.shortcut(.previousSpace), .windows, String(localized: "Slides to the Space on the left.", comment: "Action picker: Previous Space"), "desktop left"),
            item(.shortcut(.nextSpace), .windows, String(localized: "Slides to the Space on the right.", comment: "Action picker: Next Space"), "desktop right"),
            item(.shortcut(.missionControl), .windows, String(localized: "Shows every open window and your Spaces.", comment: "Action picker: Mission Control"), "expose overview"),
            item(.shortcut(.appExpose), .windows, String(localized: "Shows the windows of the app in front.", comment: "Action picker: App Exposé"), "expose windows"),
            item(.shortcut(.lastApp), .windows, String(localized: "Jumps back to the app you were just using.", comment: "Action picker: Last Used App"), "switch command tab"),
            item(.shortcut(.minimize), .windows, String(localized: "Sends the window in front to the Dock.", comment: "Action picker: Minimize Window"), "hide"),
            item(.shortcut(.fullScreen), .windows, String(localized: "Turns full screen on or off for the window in front.", comment: "Action picker: Full Screen"), "maximize"),

            item(.shortcut(.copy), .editing, String(localized: "Copies what’s selected.", comment: "Action picker: Copy")),
            item(.shortcut(.paste), .editing, String(localized: "Pastes what you copied.", comment: "Action picker: Paste")),
            item(.shortcut(.cut), .editing, String(localized: "Cuts what’s selected.", comment: "Action picker: Cut")),
            item(.shortcut(.undo), .editing, String(localized: "Undoes the last change.", comment: "Action picker: Undo")),
            item(.shortcut(.redo), .editing, String(localized: "Does it again after an undo.", comment: "Action picker: Redo")),
            item(.shortcut(.selectAll), .editing, String(localized: "Selects everything.", comment: "Action picker: Select All")),
            item(.shortcut(.save), .editing, String(localized: "Saves the document in front.", comment: "Action picker: Save")),
            item(.shortcut(.find), .editing, String(localized: "Searches the page or document.", comment: "Action picker: Find"), "search"),

            item(.precisionHold, .modes, String(localized: "Slows the pointer while you hold the button, for fine work.", comment: "Action picker: Precision (hold)"), "slow sniper fine"),
            item(.precisionToggle, .modes, String(localized: "Press once to slow the pointer, again to go back.", comment: "Action picker: Precision (toggle)"), "slow sniper fine"),
            item(.ballScrollHold, .modes, String(localized: "Hold it and roll the ball to scroll in any direction.", comment: "Action picker: Scroll with ball (hold)"), "pan drag scroll"),
            item(.dragLock, .modes, String(localized: "Picks up what’s under the pointer; press again or click to drop it.", comment: "Action picker: Drag lock"), "hold drag move"),

            item(.media(.playPause), .media, String(localized: "Plays or pauses music and videos.", comment: "Action picker: Play or Pause"), "music spotify video"),
            item(.media(.next), .media, String(localized: "Skips to the next song.", comment: "Action picker: Next Track"), "music skip"),
            item(.media(.previous), .media, String(localized: "Goes back a song.", comment: "Action picker: Previous Track"), "music"),
            item(.media(.volumeUp), .media, String(localized: "Turns the sound up a step.", comment: "Action picker: Volume Up"), "louder"),
            item(.media(.volumeDown), .media, String(localized: "Turns the sound down a step.", comment: "Action picker: Volume Down"), "quieter"),
            item(.media(.mute), .media, String(localized: "Mutes or unmutes your Mac.", comment: "Action picker: Mute"), "silent sound"),

            item(.shortcut(.spotlight), .tools, String(localized: "Opens Spotlight to search your Mac.", comment: "Action picker: Spotlight"), "search launcher"),
            item(.holdShortcut(.wisprFlow), .tools, String(localized: "Holds ⌃Space while the button is down, for push-to-talk dictation.", comment: "Action picker: Wispr Flow"), "dictation voice speech"),
            item(.shortcut(.screenshot), .tools, String(localized: "Drag to capture part of the screen.", comment: "Action picker: Screenshot"), "capture"),
            item(.shortcut(.screenshotTools), .tools, String(localized: "Opens the screenshot and screen recording tools.", comment: "Action picker: Screenshot and Recording"), "capture video record"),
            item(.shortcut(.emoji), .tools, String(localized: "Opens the emoji picker where you’re typing.", comment: "Action picker: Emoji & Symbols"), "characters"),
            item(.shortcut(.lockScreen), .tools, String(localized: "Locks your Mac straight away.", comment: "Action picker: Lock Screen"), "sleep security"),

            item(.disabled, .nothing, String(localized: "The button does nothing at all.", comment: "Action picker: Do nothing"), "disable off none"),
        ]
    }

    /// The catalog's entry for an action, or one made up for it (a recorded shortcut, an app).
    static func item(for action: ButtonAction) -> Item {
        if let known = all.first(where: { $0.action == action }) { return known }
        switch action {
        case .shortcut(let s):
            return Item(action: action, category: .tools, title: s.display, symbol: "keyboard",
                        detail: String(localized: "Your own keyboard shortcut.", comment: "Action picker: a recorded shortcut"), keywords: "")
        case .holdShortcut(let s):
            return Item(action: action, category: .tools, title: s.display, symbol: "keyboard",
                        detail: String(localized: "Holds your shortcut while the button is down.", comment: "Action picker: a held shortcut"), keywords: "")
        case .openApp:
            return Item(action: action, category: .tools, title: action.title, symbol: "app",
                        detail: String(localized: "Opens the app, or brings it to the front.", comment: "Action picker: open an app"), keywords: "launch")
        default:
            return Item(action: action, category: .clicks, title: action.title, symbol: action.symbol, detail: "", keywords: "")
        }
    }

    /// A few good first picks for a button, before anything's been chosen recently.
    static func suggestions(forButton button: Int?) -> [ButtonAction] {
        switch button {
        case 1: [.rightClick, .shortcut(.missionControl), .precisionHold]
        case 2: [.middleClick, .shortcut(.previousSpace), .back]
        case 3: [.back, .shortcut(.nextSpace), .ballScrollHold]
        default: [.shortcut(.missionControl), .shortcut(.newTab), .media(.playPause)]
        }
    }

    // MARK: Recently chosen (per Mac)

    static let recentsKey = "GlideRecentActions"

    static var recents: [ButtonAction] {
        guard let data = UserDefaults.standard.data(forKey: recentsKey),
              let list = try? JSONDecoder().decode([ButtonAction].self, from: data) else { return [] }
        return list
    }

    static func remember(_ action: ButtonAction) {
        guard action != .system else { return }
        var list = recents.filter { $0 != action }
        list.insert(action, at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(4))) {
            UserDefaults.standard.set(data, forKey: recentsKey)
        }
    }

    // MARK: Apps

    /// An app's name from its bundle ID (for "Open Safari"), cached.
    nonisolated(unsafe) private static var names: [String: String] = [:]

    static func appName(_ bundleID: String) -> String? {
        if let n = names[bundleID] { return n }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        names[bundleID] = name
        return name
    }

    static func appIcon(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Lets `ButtonAction.title` name apps (Config.swift can't look them up itself).
    static func install() {
        ButtonAction.appName = { appName($0) }
    }
}
