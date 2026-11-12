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
                  intro: String(localized: "Here’s what changed since 2.9.1. Most of it is how Glideball looks and sounds; your settings are all still here.",
                                comment: "What's New 2.10: the line under the title"),
                  items: [
                    Item(id: "look",
                         title: String(localized: "A new look", comment: "What's New 2.10 item title"),
                         text: String(localized: "There’s a sidebar now, with your trackball at the top. Roll the ball, turn the ring or press a button and it moves with you. Glideball has a new icon too.",
                                      comment: "What's New 2.10 item"),
                         art: .trackball),
                    Item(id: "settings",
                         title: String(localized: "Settings get their own window", comment: "What's New 2.10 item title"),
                         text: String(localized: "Glideball › Settings (⌘,) has everything that used to sit at the bottom of Overview, plus a new set of soft sounds you can turn off with one switch.",
                                      comment: "What's New 2.10 item"),
                         art: .symbol("gearshape", nil), showMe: .settings(.sound, spotlight: "sounds")),
                    Item(id: "speed",
                         title: String(localized: "Pausing puts your speed back", comment: "What's New 2.10 item title"),
                         text: String(localized: "When you pause or quit Glideball, your trackball goes back to exactly the tracking speed in System Settings, so it always feels the same.",
                                      comment: "What's New 2.10 item"),
                         art: .symbol("cursorarrow.motionlines", .ball)),
                    Item(id: "raycast",
                         title: String(localized: "Raycast and scripts", comment: "What's New 2.10 item title"),
                         text: String(localized: "Turn on Allow Raycast and scripts and you can pause Glideball, switch Precision or change the scroll mode from Raycast or a glideball:// link.",
                                      comment: "What's New 2.10 item; “Allow Raycast and scripts” is a switch in Settings › General"),
                         art: .symbol("command", nil), showMe: .settings(.general, spotlight: "external-control")),
                    Item(id: "privacy",
                         title: String(localized: "Crash reports, only if you want", comment: "What's New 2.10 item title"),
                         text: String(localized: "You can let Glideball send me crash reports, and a few anonymous settings stats if you like. It’s off unless you pick it.",
                                      comment: "What's New 2.10 item"),
                         art: .symbol("heart.text.square", nil), showMe: .settings(.privacy)),
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
        case smallFavor
    }

    /// The next thing due, if any: What's New after an update, then "Glideball
    /// has a new look" until it's answered, then the "A small favor" card while
    /// it's unanswered. A fresh install never gets the first two (it starts on
    /// the Orb and this version's What's New already seen).
    var nextPrompt: Prompt? {
        if WhatsNew.isPending { return .whatsNew }
        if AppIconChoice.shared.promptDue { return .iconChoice }
        if ShareData.shared.shouldAsk { return .smallFavor }
        return nil
    }

    /// Something is already over the window (or a sheet is up): nothing else may show.
    var promptShowing: Bool {
        showingWelcomeTour || showingWhatsNew || showingIconChoice || showingSmallFavor
            || showingFeedback || showingAbout || showingShortcuts || pendingImport != nil
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
        case .smallFavor: showingSmallFavor = true
        }
        return next
    }

    /// Help › What's New, or its turn after an update.
    func showWhatsNew() {
        WhatsNew.markSeen()
        // Asked for by hand: a card already up steps aside and comes back another time.
        showingSmallFavor = false
        showingIconChoice = false
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
