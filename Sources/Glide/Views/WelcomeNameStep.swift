import SwiftUI

/// The Welcome Tour's optional name step: what Glideball may put on the things you
/// share, and where. Skippable (the tour's button says Skip until there's a name);
/// the same settings are in Settings › General › Sharing. The name stays on this
/// Mac (SharingName.swift).
struct WelcomeNameStep: View {
    @Bindable private var store = SharingNameStore.shared
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 5) {
                Text("What should Glideball call you?")
                    .font(Theme.Font.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                Text("Only used on things you share, like a picture of your setup or a badge. It’s optional, and it stays on this Mac.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RowGroup(dividerInset: Theme.Space.rowHorizontal + Theme.Space.symbolColumn + Theme.Space.symbolGap) {
                SettingRow(title: "Your name", symbol: "person.crop.circle") {
                    TextField(text: $store.text, prompt: Text("Optional", comment: "Placeholder in the name field")) {
                        Text("Your name")
                    }
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 220)
                    .focused($fieldFocused)
                }
                SettingRow(title: "On shared pictures and badges",
                           hint: store.hasName ? "“\(SharingName.name())’s Glideball setup”" : "Type a name first.",
                           symbol: "photo") {
                    Toggle("On shared pictures and badges", isOn: Binding(get: { store.onPictures }, set: { store.setOnPictures($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                .disabled(!store.hasName)
                SettingRow(title: "On shared links and files",
                           hint: store.hasName ? "Whoever opens one sees “From \(SharingName.name())”." : "Type a name first.",
                           symbol: "link") {
                    Toggle("On shared links and files", isOn: Binding(get: { store.inLinks }, set: { store.setInLinks($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                .disabled(!store.hasName)
            }
            Label("It isn’t synced, backed up, or sent with stats or crash reports. Change it any time in Settings › General.",
                  systemImage: "lock")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 580)
        .frame(maxWidth: .infinity)
    }
}
