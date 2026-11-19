import AppKit
import SwiftUI

/// What's New: a short, hand-written list of what changed in a version (the
/// view is `WhatsNewView`). It shows once per version, on the first time the
/// window opens after an update, never on a fresh install (that gets the
/// Welcome Tour), and never on top of anything else: it waits its turn in
/// `AppModel.showNextPrompt()`. Help › What's New brings it back any time.
///
/// Versions are matched on major.minor, so every 2.10 beta and 2.10 itself
/// share one entry, seen once.
enum WhatsNew {
    static let seenKey = "GlideWhatsNewSeen"

    struct Entry {
        /// "2.10".
        let version: String
        /// The version people know it by, shown in the title.
        let title: String
        /// One or two plain sentences above the list.
        let intro: String
        /// At most five.
        let items: [Item]
    }

    struct Item: Identifiable {
        let id: String
        let title: String
        let text: String
        let art: Art
        var showMe: Destination? = nil
    }

    /// The small picture beside an item.
    enum Art {
        /// The trackball itself.
        case trackball
        /// An SF Symbol, in the color of the part it's about (or none).
        case symbol(String, Part?)
    }

    enum Part { case ball, ring, buttons }

    /// Where "Show Me" goes.
    enum Destination: Equatable {
        case tab(GlideTab)
        /// A Settings tab, with a row pointed out (`SettingsSpotlight`) if named.
        case settings(SettingsPane, spotlight: String? = nil)
    }

    // MARK: The table

    /// Newest first. Written by hand for each version that has something worth saying.
    static var entries: [Entry] {
        [
            Entry(version: "2.10", title: "2.10",
                  intro: String(localized: "Here’s what changed since 2.9.1. Your settings are all still here.",
                                comment: "What's New 2.10: the line under the title"),
                  items: [
                    Item(id: "gestures",
                         title: String(localized: "Gestures", comment: "Button action: hold the button and roll the ball one way or another; it can show a ring of actions around the pointer"),
                         text: String(localized: "Hold a button set to Gestures and roll the ball, and each way does something. It can show a ring of actions around the pointer, and the scroll ring can turn the volume while you hold it.",
                                      comment: "What's New 2.10 item; “Gestures” and “More” are the names used on the Buttons page"),
                         art: .symbol(ButtonAction.gesturesSymbol, .buttons), showMe: .tab(.buttons)),
                    Item(id: "switcher",
                         title: String(localized: "The Switcher", comment: "What's New 2.10 item title: the Switcher button action (⌘-Tab for the trackball)"),
                         text: String(localized: "It’s ⌘-Tab for your trackball. Hold a button set to Switcher, roll the ball or turn the ring to pick one of your open apps, and let go to switch to it.",
                                      comment: "What's New 2.10 item; “Switcher” is the button action's name on the Buttons page"),
                         art: .symbol(AppSwitcher.symbol, .buttons), showMe: .tab(.buttons)),
                    Item(id: "look",
                         title: String(localized: "A new look", comment: "What's New 2.10 item title"),
                         text: String(localized: "There’s a sidebar with your trackball at the top, moving with your hand. Settings have their own window (⌘,), and there’s a new icon and a set of soft sounds.",
                                      comment: "What's New 2.10 item"),
                         art: .trackball),
                    Item(id: "search",
                         title: String(localized: "Search for anything", comment: "What's New 2.10 item title: the search palette"),
                         text: String(localized: "Press ⌘K, or click Search in the sidebar, to find any setting or do things like pause Glideball or try a pointer speed.",
                                      comment: "What's New 2.10 item; “Search” is the button at the top of the sidebar"),
                         art: .symbol("magnifyingglass", nil)),
                    Item(id: "share",
                         title: String(localized: "Share your setup", comment: "What's New 2.10 item title"),
                         text: String(localized: "Send your setup, or just part of it, as a link, a file or a picture, and whoever opens it sees what would change first. The Sync page can bring over your KensingtonWorks settings too.",
                                      comment: "What's New 2.10 item; the Sync page is a tab in the sidebar"),
                         art: .symbol("person.2", nil), showMe: .tab(.backup)),
                  ]),
        ]
    }

    // MARK: When

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// "2.10-beta.7" and "2.10.1" are both "2.10".
    static func majorMinor(_ version: String) -> String {
        let core = version.split(separator: "-").first.map(String.init) ?? version
        return core.split(separator: ".").prefix(2).joined(separator: ".")
    }

    static func entry(for version: String) -> Entry? {
        let key = majorMinor(version)
        return entries.first { $0.version == key }
    }

    /// Whether `version`'s What's New is still to be seen, given the last one seen.
    static func isDue(seen: String?, version: String) -> Bool {
        guard let entry = entry(for: version) else { return false }
        return seen != entry.version
    }

    /// Waiting for the window: this version has one, and it hasn't been seen.
    static var isPending: Bool {
        isDue(seen: UserDefaults.standard.string(forKey: seenKey), version: currentVersion)
    }

    /// At launch: a fresh install starts with this version already "seen" (it
    /// gets the Welcome Tour instead), so the first What's New it ever sees is
    /// the next version's.
    static func noteLaunch(firstLaunch: Bool, version: String) {
        if firstLaunch { markSeen(version) }
    }

    static func markSeen(_ version: String = currentVersion) {
        UserDefaults.standard.set(majorMinor(version), forKey: seenKey)
    }
}

// MARK: - One thing at a time over the window

extension AppModel {
    /// What can show over the window by itself, in the order it's offered.
    enum Prompt: Equatable {
        case whatsNew
        /// "Glideball has a new look" (`IconChoicePrompt`), after an update from the classic icon.
        case iconChoice
        /// A shared setup or KensingtonWorks' settings the person opened while
        /// something else was up (`queuedIncoming`). Never by itself.
        case importPreview
        /// Last week's recap (`RecapCenter`), once a week after a week of real use.
        case weeklyRecap
        case smallFavor
    }

    /// The next thing due, if any: What's New after an update, then "Glideball
    /// has a new look" until it's answered, then a preview the person opened
    /// (a link, a file, KensingtonWorks) that had to wait, then last week's
    /// recap if it's due, then the "A small favor" card while it's unanswered.
    /// A fresh install
    /// never gets the first two (it starts on the Orb and this version's What's
    /// New already seen), nor a recap (there's no week before to look back on).
    var nextPrompt: Prompt? {
        if WhatsNew.isPending { return .whatsNew }
        if AppIconChoice.shared.promptDue { return .iconChoice }
        if queuedIncoming != nil { return .importPreview }
        if RecapCenter.shared.due(delight) != nil { return .weeklyRecap }
        if ShareData.shared.shouldAsk { return .smallFavor }
        return nil
    }

    /// Something is already over the window (or a sheet is up): nothing else may show.
    var promptShowing: Bool {
        showingWelcomeTour || showingWhatsNew || showingIconChoice || showingSmallFavor
            || showingFeedback || showingAbout || showingShortcuts || pendingImport != nil
            || pendingIncoming != nil || shareRequest != nil || pasteBox != nil
            || RecapCenter.shared.showing != nil || CommandPalette.shared.isOpen
    }

    /// Shows the next thing due, once the window is open and nothing else is
    /// over it: never on top of the launch animation, the Welcome Tour, a
    /// sheet or another card. One per opening of the window: if something's
    /// in the way it waits for the next time the window opens, and closing
    /// one doesn't bring the next straight after it. (The Welcome Tour is the
    /// exception: closing it offers the small favor.)
    func showNextPrompt(after delay: Double = 0.8) {
        guard nextPrompt != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.presentNextPrompt()
        }
    }

    /// The decision itself (`showNextPrompt` waits a moment first). Returns
    /// what it showed. `ignoringWindow` is for the self-test, whose window is
    /// never on screen.
    @discardableResult
    func presentNextPrompt(ignoringWindow: Bool = false) -> Prompt? {
        guard !promptShowing, LaunchExperience.shared.show == nil, ignoringWindow || windowVisible,
              let next = nextPrompt else { return nil }
        switch next {
        case .whatsNew: showWhatsNew()
        case .iconChoice: showingIconChoice = true
        case .importPreview:
            pendingIncoming = queuedIncoming
            queuedIncoming = nil
        case .weeklyRecap:
            guard let recap = RecapCenter.shared.due(delight) else { return nil }
            RecapCenter.shared.show(recap, byItself: true)
        case .smallFavor: showingSmallFavor = true
        }
        return next
    }

    /// A preview the person opened can't show yet: the launch animation, the
    /// tour, a sheet or another card is up. It waits in `queuedIncoming`.
    var incomingMustWait: Bool {
        promptShowing || (LaunchExperience.shared.show != nil && !incomingIgnoresLaunch)
    }

    /// Whatever was in the way has gone: a preview that's waiting takes its turn
    /// (after What's New and the icon question, if those are due). Unlike the
    /// other cards it doesn't wait for the window to open again, as the person
    /// asked for it.
    func incomingMayShow() {
        guard queuedIncoming != nil, !incomingMustWait else { return }
        showNextPrompt(after: 0.4)
    }

    /// Help › What's New, or its turn after an update.
    func showWhatsNew() {
        WhatsNew.markSeen()
        // Asked for by hand: a card already up steps aside and comes back another time.
        showingSmallFavor = false
        showingIconChoice = false
        RecapCenter.shared.close()
        showingWhatsNew = true
    }

    func closeWhatsNew(then destination: WhatsNew.Destination? = nil) {
        showingWhatsNew = false
        switch destination {
        case .tab(let tab)?: requestTab(tab)
        case .settings(let pane, let spotlight)?: (NSApp.delegate as? AppDelegate)?.showSettings(pane, spotlight: spotlight)
        case nil: break
        }
    }
}
