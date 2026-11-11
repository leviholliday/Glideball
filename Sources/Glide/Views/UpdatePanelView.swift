import AppKit
import SwiftUI

/// The "Software Update" window: what a Check for Updates the user asked for found,
/// big and clear — checking, up to date, an update (with its notes and Install),
/// or couldn't check. Opened by every Check for Updates button and menu item.
struct UpdatePanelView: View {
    let updates: UpdateChecker
    let close: () -> Void

    var body: some View {
        content
            .padding(.horizontal, 30)
            .padding(.top, 34)
            .padding(.bottom, 24)
            .frame(width: 440)
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.windowBackground)
            .animation(Theme.Motion.spring, value: phase)
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
                badge("checkmark.seal.fill", color: Theme.ok)
                title("You’re up to date!")
                subtitle(EarlyUpdates.isEnabled
                         ? String(localized: "Glideball \(current) is the newest version, including beta releases.")
                         : String(localized: "Glideball \(current) is the newest version."))
                if let checked = updates.lastChecked {
                    Text("Checked \(checked.formatted(.relative(presentation: .named)))")
                        .font(Theme.Font.hint).foregroundStyle(.tertiary)
                }
                buttons {
                    Button("OK", action: close)
                        .buttonStyle(.borderedProminent).tint(Theme.ball)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(maxWidth: .infinity)
            .transition(.opacity)

        case .available, .installFailed:
            if let update = updates.available {
                availableView(update)
                    .transition(.opacity)
            }

        case .failed:
            VStack(spacing: 14) {
                badge("exclamationmark.triangle.fill", color: Theme.warn)
                title("Couldn’t check for updates")
                subtitle(String(localized: "Glideball couldn’t reach GitHub. Check your internet connection and try again."))
                buttons {
                    Button("OK", action: close)
                        .keyboardShortcut(.cancelAction)
                    Button("Try Again") { updates.checkNow() }
                        .buttonStyle(.borderedProminent).tint(Theme.ball)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(maxWidth: .infinity)
            .transition(.opacity)

        case .downloading, .installing:
            VStack(spacing: 14) {
                badge("arrow.down.circle.fill", color: Theme.ball)
                if case .downloading(let progress) = updates.installState {
                    title("Downloading Glideball \(updates.available?.displayVersion ?? "")…")
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Theme.ball)
                        .frame(maxWidth: 300)
                    Text(verbatim: "\(Int(progress * 100))%")
                        .font(Theme.Font.value)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: progress))
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
            badge("arrow.down.circle.fill", color: Theme.ball)
            title("Glideball \(update.displayVersion) is available")
            subtitle(String(localized: "You have \(current). Your settings and permissions carry over."))
            if update.isPrerelease {
                Label("An early update. It may have bugs.", systemImage: "flask")
                    .font(Theme.Font.hint.weight(.medium)).foregroundStyle(.secondary)
            }
            if !update.notes.isEmpty {
                ScrollView {
                    Text(Self.notes(update.notes))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(14)
                }
                .frame(maxHeight: 160)
                .groupBackground()
            }
            if case .failed(let message) = updates.installState {
                Label {
                    Text(verbatim: message).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                }
                .font(Theme.Font.hint)
                .fixedSize(horizontal: false, vertical: true)
            }
            buttons {
                Button("Release Notes") { NSWorkspace.shared.open(update.notesPage) }
                    .help("Opens this version’s notes on the Glideball website")
                Spacer(minLength: 0)
                Button("Later", action: close)
                    .keyboardShortcut(.cancelAction)
                Button(updates.installState == .idle ? String(localized: "Install & Relaunch")
                                                     : String(localized: "Try Again")) { updates.install() }
                    .buttonStyle(.borderedProminent).tint(Theme.ball)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Pieces

    private func badge(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 40, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .frame(height: 52)
            .accessibilityHidden(true)
    }

    private func title(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 20, weight: .semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func subtitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.body)
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
