import AppKit
import SwiftUI

/// The "Software Update" window: what a Check for Updates the user asked for found,
/// big and clear — checking, up to date, an update (with its notes and Install),
/// or couldn't check. Opened by every Check for Updates button and menu item.
struct UpdatePanelView: View {
    let updates: UpdateChecker
    let close: () -> Void

    var body: some View {
        ZStack {
            GlideBackground()
            VStack(spacing: 0) {
                content
                    .padding(.horizontal, 30)
                    .padding(.top, 34)
                    .padding(.bottom, 24)
            }
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.smooth(duration: 0.3), value: phase)
    }

    // MARK: State

    private enum Phase: Equatable {
        case checking, upToDate, available, failed, downloading, installing, installFailed
    }

    private var phase: Phase {
        switch updates.installState {
        case .downloading: return .downloading
        case .installing: return .installing
        case .failed: if updates.available != nil { return .installFailed }
        case .idle: break
        }
        if updates.manualCheck == .checking { return .checking }
        if updates.available != nil { return .available }
        if updates.manualCheck == .failed { return .failed }
        return .upToDate
    }

    private var current: String {
        GlideVersion(updates.currentVersion)?.display ?? updates.currentVersion
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .checking:
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).frame(height: 56)
                title("Checking for updates…")
                subtitle(String(localized: "Asking GitHub for the newest version of Glideball."))
            }
            .frame(maxWidth: .infinity)
            .transition(.opacity)

        case .upToDate:
            VStack(spacing: 14) {
                badge("checkmark.seal.fill", color: .green)
                title("You’re up to date!")
                subtitle(EarlyUpdates.isEnabled
                         ? String(localized: "Glideball \(current) is the newest version, including beta releases.")
                         : String(localized: "Glideball \(current) is the newest version."))
                if let checked = updates.lastChecked {
                    Text("Checked \(checked.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                buttons {
                    Button("OK", action: close)
                        .buttonStyle(.glassProminent).tint(.cyan)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(maxWidth: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))

        case .available, .installFailed:
            if let update = updates.available {
                availableView(update)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

        case .failed:
            VStack(spacing: 14) {
                badge("exclamationmark.triangle.fill", color: .orange)
                title("Couldn’t check for updates")
                subtitle(String(localized: "Glideball couldn’t reach GitHub. Check your internet connection and try again."))
                buttons {
                    Button("OK", action: close).buttonStyle(.glass)
                    Button("Try Again") { updates.checkNow() }
                        .buttonStyle(.glassProminent).tint(.cyan)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(maxWidth: .infinity)
            .transition(.opacity)

        case .downloading, .installing:
            VStack(spacing: 14) {
                badge("arrow.down.circle.fill", color: .cyan)
                if case .downloading(let progress) = updates.installState {
                    title("Downloading Glideball \(updates.available?.displayVersion ?? "")…")
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.cyan)
                        .frame(maxWidth: 300)
                    Text(verbatim: "\(Int(progress * 100))%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(.secondary)
                } else {
                    title("Installing…")
                    subtitle(String(localized: "Glideball will reopen in a moment."))
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .transition(.opacity)
        }
    }

    private func availableView(_ update: UpdateChecker.Update) -> some View {
        VStack(spacing: 14) {
            badge("arrow.down.circle.fill", color: .cyan)
            title("Glideball \(update.displayVersion) is available")
            subtitle(String(localized: "You have \(current). Your settings and permissions carry over."))
            if update.isPrerelease {
                Label("An early update. It may have bugs.", systemImage: "flask")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
            }
            if !update.notes.isEmpty {
                ScrollView {
                    Text(Self.notes(update.notes))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxHeight: 150)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
            }
            if case .failed(let message) = updates.installState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons {
                Button("Release Notes") { NSWorkspace.shared.open(update.page) }
                    .buttonStyle(.glass)
                Spacer(minLength: 0)
                Button("Later", action: close).buttonStyle(.glass)
                Button(updates.installState == .idle ? String(localized: "Install & Relaunch")
                                                     : String(localized: "Try Again")) { updates.install() }
                    .buttonStyle(.glassProminent).tint(.cyan)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Pieces

    private func badge(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 44, weight: .medium))
            .foregroundStyle(color)
            .shadow(color: color.opacity(0.5), radius: 14)
            .frame(height: 56)
            .symbolEffect(.bounce, value: phase)
    }

    private func title(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func subtitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func buttons<B: View>(@ViewBuilder _ content: () -> B) -> some View {
        HStack(spacing: 10) { content() }
            .controlSize(.large)
            .padding(.top, 6)
    }

    /// Release notes are Markdown on GitHub; keep links, bold and line breaks.
    private static func notes(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}
