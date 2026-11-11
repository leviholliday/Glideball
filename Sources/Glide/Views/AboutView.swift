import AppKit
import SwiftUI

/// Everything about the app in one place: the version, updates, feedback, the tour and the
/// links. Opened from the (?) button in the sidebar and from Glideball › About.
struct AboutView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private static let website = URL(string: "https://glideball.netlify.app")!
    private static let releases = SiteLinks.changelog
    private static let issues = URL(string: "https://github.com/leviholliday/glideball/issues")!
    private static let source = URL(string: "https://github.com/leviholliday/glideball")!
    static let contactEmail = "glideball@proton.me"
    private static let support = URL(string: "https://venmo.com/code?user_id=3866596929963831322&created=1793653243")!
    private static let gravatar = URL(string: "https://gravatar.com/optimistic1bba948d22")!

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    hero
                    SectionBlock(title: nil, dividerInset: SettingsLayout.symbolInset) {
                        UpdatesRow(updates: model.updates)
                        ActionRow(title: "Send feedback", hint: "Ideas, bugs and questions come straight to me.", symbol: "paperplane") {
                            open { model.showingFeedback = true }
                        }
                        ActionRow(title: "Welcome tour", hint: "A quick walk through what Glideball can do.", symbol: "figure.walk") {
                            open { model.showWelcomeTour() }
                        }
                    }
                    SectionBlock(title: "Links", dividerInset: SettingsLayout.symbolInset) {
                        emailRow
                        link("questionmark.circle", "Glideball Help", SiteLinks.help)
                        link("globe", "Website", Self.website)
                        link("doc.text", "What’s new in each version", Self.releases)
                        link("exclamationmark.bubble", "Report a problem on GitHub", Self.issues)
                        link("chevron.left.forwardslash.chevron.right", "Source code (free and open)", Self.source)
                        link("person.crop.circle", "Gravatar profile", Self.gravatar)
                        link("heart", "Support Glideball", Self.support)
                    }
                    SectionBlock(title: "Support info", caption: "Handy to include when you report something.") {
                        HStack(alignment: .top, spacing: 12) {
                            Text(verbatim: supportInfo)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(supportInfo, forType: .string)
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                            } label: {
                                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .buttonStyle(ChipButtonStyle())
                            .help("Copy the support info")
                        }
                        .padding(.horizontal, Theme.Space.rowHorizontal)
                        .padding(.vertical, 12)
                    }
                    Text("Made for Kensington trackballs. Glideball is an independent project and isn’t affiliated with Kensington.")
                        .font(Theme.Font.hint)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 22)
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: 520, height: 640)
        .background(GlideBackground(anchor: UnitPoint(x: 0.5, y: -0.05), strength: 0.8))
        .overlay(alignment: .topTrailing) {
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .padding(14)
        }
    }

    // MARK: Pieces

    private var hero: some View {
        VStack(spacing: 4) {
            Image(nsImage: AppIconChoice.shared.image)
                .resizable()
                .interpolation(.high)
                .frame(width: 76, height: 76)
                .padding(.bottom, 6)
                .accessibilityHidden(true)
            Text(verbatim: "Glideball")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .accessibilityAddTraits(.isHeader)
            Text("Version \(FeedbackDraft.appInfo["version"] ?? "?") (\(FeedbackDraft.appInfo["build"] ?? "?"))")
                .font(Theme.Font.hint)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
    }

    private func link(_ symbol: String, _ title: LocalizedStringKey, _ url: URL) -> some View {
        ActionRow(title: title, symbol: symbol, external: true) { NSWorkspace.shared.open(url) }
            .help(Text(verbatim: url.host() ?? url.absoluteString))
    }

    /// "Email  glideball@proton.me ↗" — opens a new message with the support info already in it.
    private var emailRow: some View {
        ActionRow(title: "Email", symbol: "envelope", external: true, action: {
            var c = URLComponents()
            c.scheme = "mailto"
            c.path = Self.contactEmail
            c.queryItems = [URLQueryItem(name: "subject", value: "Glideball"),
                            URLQueryItem(name: "body", value: "\n\n—\n" + supportInfo)]
            if let url = c.url { NSWorkspace.shared.open(url) }
        }) {
            Text(verbatim: Self.contactEmail).font(Theme.Font.body).foregroundStyle(.secondary)
        }
        .help("Opens a new email with your version info already filled in")
    }

    /// Closes this sheet, then does `next` once it's gone (a sheet can't open another at the same time).
    private func open(_ next: @escaping () -> Void) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: next)
    }

    /// Version, system and trackball, as plain text for a bug report.
    private var supportInfo: String {
        let app = FeedbackDraft.appInfo, sys = FeedbackDraft.systemInfo
        var lines = [
            "Glideball \(app["version"] ?? "?") (\(app["build"] ?? "?"))",
            "macOS \(sys["macOS"] ?? "?") · \(sys["model"] ?? "Mac") · \(sys["arch"] ?? "?")",
            "Trackball: " + (model.status.deviceConnected ? (model.status.deviceName ?? "connected") : "not connected"),
            "Scrolling: \(model.config.scrollMode.rawValue)",
        ]
        if model.otherTrackballs { lines.append("Other Kensington trackballs: on") }
        if model.earlyUpdates { lines.append("Early updates: on") }
        return lines.joined(separator: "\n")
    }
}
