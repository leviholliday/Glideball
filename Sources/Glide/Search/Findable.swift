import SwiftUI

// What the search palette (⌘K, ⌘F) can find and jump to, described right next
// to the row it's about: each page declares a `Findable` for each of its rows
// (or a whole section) and puts `.findable(...)` on that row. The palette's
// index is just every page's list (`Findable.all`), so it can't drift from the
// pages, and the self-test draws every page and fails if a row on it isn't
// inside a `.findable` (or a `Findable` names a row no page draws).

/// One setting (a row, or a whole section) the palette can find.
struct Findable: Identifiable, Sendable, Equatable {
    /// Also the row's spotlight and scroll target (`SettingsSpotlight`).
    let id: String
    /// What the row is called on screen (the same localized key, so it's already translated).
    let title: String
    /// One line about what it does, shown under the title in the palette.
    let detail: String
    /// Other words people might type for it (comma-separated, localized): "speed" for Tracking speed.
    var keywords: String = ""
    let symbol: String
    let place: Place
    /// The part it's about, for the icon's color.
    var part: Metric? = nil
    /// Only on screen in these scroll modes (Flywheel's sliders, say); empty: always.
    var modes: [ScrollMode] = []
    /// Ranks it a little higher when several match equally ("speed": Tracking speed first).
    var boost: Int = 0
    /// Not always on its page (the setup checklist goes once it's done): search leaves it out
    /// while it isn't there (`present`), and the self-test doesn't expect it on every drawing.
    var sometimes = false

    enum Place: Equatable, Sendable {
        case tab(GlideTab)
        case settings(SettingsPane)

        /// "Pointer", "Settings › Look"
        var name: String {
            switch self {
            case .tab(let tab): tab.title
            case .settings(let pane): String(localized: "Settings › \(pane.title)", comment: "Where a setting is, in the search palette; %@ is a Settings tab")
            }
        }
    }

    static func == (a: Findable, b: Findable) -> Bool { a.id == b.id }

    /// Every page's list, in sidebar order, then Settings' tabs in toolbar order.
    static var all: [Findable] {
        OverviewView.findables + PointerView.findables + ScrollSettingsView.findables + ButtonsView.findables
            + AppsView.findables + Findable.syncFindables
            + GeneralSettingsPane.findables + TrackballSettingsPane.findables + SharingSettingsPane.findables + LookSettingsPane.findables + SoundSettingsPane.findables
            + UpdatesSettingsPane.findables + PrivacySettingsPane.findables + ShortcutsSettingsPane.findables
    }

    static func named(_ id: String) -> Findable? { all.first { $0.id == id } }

    // The Sync page (BackupView) as a whole: its rows are covered by this one entry.
    static let syncPage = Findable(id: "sync-page", title: GlideTab.backup.title,
                                   detail: String(localized: "Sync your settings between Macs, export them, and see your backups.", comment: "Search palette: the Sync page"),
                                   keywords: String(localized: "sync, icloud, backup, backups, export, import, restore, other mac", comment: "Search words for the Sync page (comma-separated; words people might type)"),
                                   symbol: GlideTab.backup.symbol, place: .tab(.backup))
    static let exportSettings = Findable(id: "sync-export", title: String(localized: "Export Settings…"),
                                         detail: String(localized: "Save your setup as a file to keep or send to another Mac.", comment: "Search palette: Export Settings"),
                                         keywords: String(localized: "save, file, share setup, copy", comment: "Search words for Export Settings (comma-separated)"),
                                         symbol: "square.and.arrow.up", place: .tab(.backup))
    static let importSettings = Findable(id: "sync-import", title: String(localized: "Import Settings…"),
                                         detail: String(localized: "Open a settings file and see what it changes before you use it.", comment: "Search palette: Import Settings"),
                                         keywords: String(localized: "open, load, file, restore", comment: "Search words for Import Settings (comma-separated)"),
                                         symbol: "square.and.arrow.down", place: .tab(.backup))
    static let shareSetup = Findable(id: "sync-share", title: String(localized: "Share a setup with someone"),
                                     detail: String(localized: "Everything or just one part, as a link, a file or a picture. They see a preview before anything changes."),
                                     keywords: String(localized: "share, send, link, qr code, picture, friend", comment: "Search words for sharing a setup (comma-separated)"),
                                     symbol: "person.2", place: .tab(.backup))
    /// Only there when KensingtonWorks' settings are on this Mac.
    static let kensingtonWorks = Findable(id: "sync-kensingtonworks", title: String(localized: "Found your KensingtonWorks settings"),
                                          detail: String(localized: "See how your buttons and scrolling map to Glideball before anything changes."),
                                          keywords: String(localized: "kensingtonworks, trackballworks, import, switch, move over", comment: "Search words for importing KensingtonWorks' settings (comma-separated)"),
                                          symbol: "arrow.down.left.arrow.up.right", place: .tab(.backup), sometimes: true)
    /// (Export and Import are the palette's actions; their words are here, beside the page's.)
    static let syncFindables: [Findable] = [syncPage, shareSetup, kensingtonWorks]
}

// MARK: - On a row

private struct FindableIDKey: EnvironmentKey { static let defaultValue: String? = nil }

extension EnvironmentValues {
    /// The `Findable` a row sits inside (the self-test's audit reads it).
    var findableID: String? {
        get { self[FindableIDKey.self] }
        set { self[FindableIDKey.self] = newValue }
    }
}

extension View {
    /// Makes this row (or section) the palette's `Findable`: a scroll target, and it
    /// glows softly for a moment when the palette jumps here.
    func findable(_ f: Findable) -> some View { findable(id: f.id) }

    /// The same for a row whose `Findable` is made on the fly (a button, an app setup).
    func findable(id: String) -> some View { modifier(FindableAnchor(id: id)) }

    /// Rows in here are found through `id`'s entry, which points somewhere else
    /// (an app setup's editor is found through its row in the list; the Sync page
    /// as a whole). No glow and no scroll target of its own.
    func findableScope(_ id: String) -> some View {
        let _ = FindableAudit.anchor(id)
        return environment(\.findableID, id)
    }
}

private struct FindableAnchor: ViewModifier {
    let id: String
    private let spot = SettingsSpotlight.shared

    func body(content: Content) -> some View {
        let _ = FindableAudit.anchor(id)
        let lit = spot.row == id
        content
            .environment(\.findableID, id)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.ball.opacity(lit ? 0.13 : 0))
                    .padding(3)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.ball.opacity(lit ? 0.55 : 0), lineWidth: 1)
                    .shadow(color: Theme.ball.opacity(lit ? 0.5 : 0), radius: 6)
                    .padding(3)
                    .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.4), value: lit)
            .id(id)
    }
}

// MARK: - The audit

/// The self-test's check that every row is findable: while `recording`, each
/// row reports itself as it's drawn, with the `Findable` it sits inside.
enum FindableAudit {
    nonisolated(unsafe) static var recording = false
    nonisolated(unsafe) static var rows: [(title: String, findable: String?)] = []
    /// Every `.findable` drawn while recording.
    nonisolated(unsafe) static var anchors: Set<String> = []

    static func anchor(_ id: String) {
        if recording { anchors.insert(id) }
    }

    static func note(_ title: LocalizedStringKey, _ findable: String?) {
        guard recording else { return }
        rows.append((title.keyText, findable))
    }

    static func note(_ title: String, _ findable: String?) {
        guard recording else { return }
        rows.append((title, findable))
    }
}

extension LocalizedStringKey {
    /// The key's own text ("Tracking speed"), for the audit's messages.
    var keyText: String {
        Mirror(reflecting: self).children.first { $0.label == "key" }?.value as? String ?? "\(self)"
    }
}
