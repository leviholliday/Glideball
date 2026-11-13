import SwiftUI

/// Settings › General › Sharing: the name you may put on what you share, and
/// where it goes (SharingName.swift says where it never goes).
struct SharingNameSection: View {
    @Bindable private var store = SharingNameStore.shared

    var body: some View {
        SectionBlock(title: "Sharing", dividerInset: SettingsLayout.symbolInset) {
            SettingsRow(title: "Your name", hint: nameHint, symbol: "person.crop.circle") {
                TextField(text: $store.text, prompt: Text("Optional", comment: "Placeholder in the name field")) {
                    Text("Your name")
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 180)
            }
            .findable(.sharingName)
            SettingsToggle(title: "On shared pictures and badges", hint: picturesHint, symbol: "photo",
                           isOn: Binding(get: { store.onPictures }, set: { store.setOnPictures($0) }))
                .disabled(!store.hasName)
                .findable(.sharingNamePictures)
            SettingsToggle(title: "On shared links and files", hint: linksHint, symbol: "link",
                           isOn: Binding(get: { store.inLinks }, set: { store.setInLinks($0) }))
                .disabled(!store.hasName)
                .findable(.sharingNameLinks)
        }
    }

    private var nameHint: String {
        String(localized: "Only used on things you share. It stays on this Mac: it isn’t synced, backed up or sent with stats or crash reports.",
               comment: "Settings › General › Sharing hint")
    }

    private var picturesHint: String {
        guard store.hasName else { return String(localized: "Type a name first.", comment: "Settings › General › Sharing hint") }
        return store.onPictures
            ? String(localized: "Pictures say “\(SharingName.name())’s Glideball setup”, on badges and the weekly recap too.", comment: "Settings › General › Sharing hint; %@ is the name")
            : String(localized: "Pictures say “My Glideball setup”.", comment: "Settings › General › Sharing hint")
    }

    private var linksHint: String {
        guard store.hasName else { return String(localized: "Type a name first.", comment: "Settings › General › Sharing hint") }
        return store.inLinks
            ? String(localized: "Whoever opens a link or file you share sees “From \(SharingName.name())”.", comment: "Settings › General › Sharing hint; %@ is the name")
            : String(localized: "Links and files you share don’t say who they’re from.", comment: "Settings › General › Sharing hint")
    }
}

// What search finds in General › Sharing.
extension Findable {
    static let sharingName = Findable(
        id: "sharing-name", title: String(localized: "Your name"),
        detail: String(localized: "A name to put on pictures and links you share. Optional.", comment: "Search palette: Your name"),
        keywords: String(localized: "name, sharing, badge, picture, link, from", comment: "Search words for Your name (comma-separated)"),
        symbol: "person.crop.circle", place: .settings(.general))
    static let sharingNamePictures = Findable(
        id: "sharing-name-pictures", title: String(localized: "On shared pictures and badges"),
        detail: String(localized: "Put your name on share pictures, badges and the weekly recap.", comment: "Search palette: name on pictures"),
        keywords: String(localized: "name, picture, badge, recap", comment: "Search words for name on pictures (comma-separated)"),
        symbol: "photo", place: .settings(.general))
    static let sharingNameLinks = Findable(
        id: "sharing-name-links", title: String(localized: "On shared links and files"),
        detail: String(localized: "Say who a shared link or file is from.", comment: "Search palette: name in links"),
        keywords: String(localized: "name, link, file, from", comment: "Search words for name in links (comma-separated)"),
        symbol: "link", place: .settings(.general))
}
