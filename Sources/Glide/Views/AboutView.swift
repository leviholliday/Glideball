import AppKit
import SwiftUI

/// Everything about the app in one place: the version, updates, feedback, the tour and the
/// links. Opened from the (i) button in the window header and from Glideball › About.
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
        ZStack {
            GlideBackground()
            VStack(spacing: 0) {
                hero
                ScrollView {
                    VStack(spacing: 14) {
                        GlassCard {
                            UpdatesRow(updates: model.updates)
                            Divider().opacity(0.4)
                            actionRow("paperplane", "Send feedback", "Ideas, bugs and questions go straight to the developer.") {
                                open { model.showingFeedback = true }
                            }
                            Divider().opacity(0.4)
                            actionRow("sparkles", "Welcome tour", "A quick walk through what Glideball can do.") {
                                open { model.showWelcomeTour() }
                            }
                        }
                        GlassCard(title: "Links", symbol: "link") {
                            emailRow
                            Divider().opacity(0.4)
                            linkRow("globe", "Website", Self.website)
                            Divider().opacity(0.4)
                            linkRow("doc.text", "What’s new in each version", Self.releases)
                            Divider().opacity(0.4)
                            linkRow("exclamationmark.bubble", "Report a problem on GitHub", Self.issues)
                            Divider().opacity(0.4)
                            linkRow("chevron.left.forwardslash.chevron.right", "Source code (free and open)", Self.source)
                            Divider().opacity(0.4)
                            linkRow("person.crop.circle", "Gravatar profile", Self.gravatar)
                            Divider().opacity(0.4)
                            linkRow("heart", "Support Glideball", Self.support)
                        }
                        GlassCard(title: "Support info", symbol: "info.circle") {
                            Text(supportInfo)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                Text("Handy to include when you report something.")
                                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(supportInfo, forType: .string)
                                    copied = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                                } label: {
                                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                }
                                .buttonStyle(.glass)
                                .contentTransition(.symbolEffect(.replace))
                            }
                        }
                        Text("Made for Kensington trackballs. Glideball is an independent project and isn’t affiliated with Kensington.")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 18)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(width: 520, height: 640)
    }

    // MARK: Pieces

    private var hero: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                    .shadow(color: .purple.opacity(0.5), radius: 16)
                Text(verbatim: "Glideball")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Version \(FeedbackDraft.appInfo["version"] ?? "?") (\(FeedbackDraft.appInfo["build"] ?? "?"))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 26)
            .padding(.bottom, 16)
            Button("Done") { dismiss() }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
                .padding(16)
        }
    }

    private func actionRow(_ symbol: String, _ title: LocalizedStringKey, _ subtitle: LocalizedStringKey,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .medium))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func linkRow(_ symbol: String, _ title: LocalizedStringKey, _ url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 22)
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Email  glideball@proton.me ↗" — opens a new message with the support info already in it.
    private var emailRow: some View {
        Button {
            var c = URLComponents()
            c.scheme = "mailto"
            c.path = Self.contactEmail
            c.queryItems = [URLQueryItem(name: "subject", value: "Glideball"),
                            URLQueryItem(name: "body", value: "\n\n—\n" + supportInfo)]
            if let url = c.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "envelope").font(.system(size: 14, weight: .medium)).frame(width: 22)
                Text("Email").font(.system(size: 14, weight: .medium))
                Spacer()
                Text(verbatim: Self.contactEmail).font(.system(size: 13)).foregroundStyle(.secondary)
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
