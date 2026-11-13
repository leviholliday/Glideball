import AppKit
import SwiftUI

/// "A small favor": asks once whether Glideball may send crash reports, or
/// crash reports and settings stats (see `ShareData`). Nothing is picked
/// unless the person picks it. Shown over the window by
/// `AppModel.showNextPrompt()`: after the Welcome Tour on a new Mac, or after
/// an update on a Mac that already used Glideball (behind What's New and
/// "Glideball has a new look", each on its own opening of the window).
struct SmallFavorCard: View {
    @Bindable var model: AppModel
    @State private var pick: ShareChoice = .nothing

    var body: some View {
        OverlayCard(width: 560) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(nsImage: AppIconChoice.shared.image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                    Text("A small favor")
                        .font(.system(size: 20, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                }
                Text("Hi, I'm Levi. I make Glideball on my own, and when it crashes on someone's Mac, I usually never hear about it. If you're okay with it, Glideball can send me a little anonymous information, so I can fix crashes and see which settings people actually use. It's off unless you pick something here.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                RowGroup(dividerInset: 44) {
                    option(.nothing,
                           detail: "Glideball doesn't send anything, and that's fine.")
                    option(.crashes,
                           detail: "If Glideball crashes, it sends me where in its code it happened and which versions of Glideball and macOS you have.")
                    option(.crashesAndStats,
                           detail: "Also, once a day: which trackball you have and a few of your settings, like the scroll mode and roughly how fast the pointer is. Never what you type, which apps you use, or your name.")
                }

                Text("It isn't tied to your name, your email or your Mac. You can change this, or delete what was sent, any time in Glideball › Settings › Privacy.")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Thanks either way,")
                            .font(Theme.Font.body)
                            .foregroundStyle(.secondary)
                        Text(verbatim: "Levi").font(.system(size: 15, weight: .semibold, design: .serif)).italic()
                    }
                    Spacer()
                    Button("What’s Sent") { NSWorkspace.shared.open(ShareData.explainer) }
                        .help("Opens the privacy page on the Glideball website")
                    Button("Done") {
                        ShareData.shared.choice = pick
                        ShareData.shared.asked = true
                        model.showingSmallFavor = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ball)
                    .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }
        }
    }

    private func option(_ choice: ShareChoice, detail: LocalizedStringKey) -> some View {
        let on = pick == choice
        return Button {
            withAnimation(Theme.Motion.fade) { pick = choice }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(on ? AnyShapeStyle(Theme.ball) : AnyShapeStyle(.tertiary))
                    .frame(width: 20)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: choice.title)
                        .font(Theme.Font.body.weight(.medium))
                    Text(detail)
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.rowHorizontal)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowHoverStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Settings › Privacy: the same choice as the card, as three cards (the hero),
/// a live "What this sends" with this Mac's real values, the install ID, what's
/// been sent and Delete My Data with its result right where you clicked, then
/// the full privacy page and the other privacy-related setting, in General.
struct ShareDataSettings: View {
    @Bindable private var share = ShareData.shared
    @State private var confirmingDelete = false
    @State private var copied = false
    /// How the last Delete My Data went (the main window, where toasts appear, may be closed).
    @State private var deleted: Bool? = ShareDataSettings.sandboxDeleted
    /// `--render-ui`: start as if a delete just finished (or failed).
    static var sandboxDeleted: Bool?

    private static let choices: [ChoiceStrip<ShareChoice>.Choice] = [
        .init(value: .nothing, title: LocalizedStringKey("Nothing"), symbol: "lock",
              detail: LocalizedStringKey("Glideball doesn’t send anything.")),
        .init(value: .crashes, title: LocalizedStringKey("Crash reports only"), symbol: "ladybug",
              detail: LocalizedStringKey("Where it crashed, and your versions.")),
        .init(value: .crashesAndStats, title: LocalizedStringKey("Crash reports and settings stats"), symbol: "chart.bar",
              detail: LocalizedStringKey("Crash reports, plus your trackball and a few settings once a day.")),
    ]

    var body: some View {
        PlainSection(title: "Crash reports and stats",
                     caption: "Off unless you pick something. Never your name, what you type or which apps you use.") {
            VStack(alignment: .leading, spacing: 12) {
                ChoiceStrip(choices: Self.choices, isSelected: { $0 == share.choice }, tint: Theme.ball) { share.choice = $0 }
                SendPreviewView(choice: share.choice, installID: share.installID)
            }
        }
        .findable(.crashReports)

        SectionBlock(title: "Your install ID", dividerInset: SettingsLayout.symbolInset) {
            installIDRow
        }
        .findable(.installID)

        SectionBlock(title: "Your data", dividerInset: SettingsLayout.symbolInset) {
            SettingsRow(title: "Last sent", hint: lastSentHint, symbol: "clock.arrow.circlepath") {
                EmptyView()
            }
            SettingsRow(title: "Delete my data", hint: deleteHint, symbol: deleteSymbol) {
                if share.deleting {
                    ProgressView().controlSize(.small).padding(.horizontal, 8)
                } else if share.installID != nil && deleted != true {
                    Button("Delete My Data…") { confirmingDelete = true }
                        .controlSize(.small)
                        .help("Deletes the crash reports and stats this Mac has sent, and turns sharing off")
                }
            }
        }
        .findable(.deleteMyData)
        .onChange(of: share.choice) { _, now in
            if now != .nothing { deleted = nil }   // sharing again: the old result no longer applies
        }
        .alert("Delete what this Mac has sent?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the crash reports and stats this Mac has sent to the Glideball server, and turns sharing off. It can't be undone.")
        }

        VStack(alignment: .leading, spacing: 8) {
            Link(destination: ShareData.explainer) {
                Label("The full privacy page", systemImage: "arrow.up.right.square")
                    .font(Theme.Font.hint.weight(.medium))
            }
            .tint(Theme.ball)
            .help("Opens the privacy page on the Glideball website")
            .findable(.whatsSent)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Allow Raycast and scripts, which lets other apps control Glideball, is in General.")
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show") {
                    (NSApp.delegate as? AppDelegate)?.showSettings(.general, spotlight: Findable.externalControl.id)
                }
                .buttonStyle(.link)
                .font(Theme.Font.hint.weight(.medium))
                .tint(Theme.ball)
                .help("Opens General, with the switch pointed out")
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: Install ID

    @ViewBuilder private var installIDRow: some View {
        let on = share.choice != .nothing
        HStack(alignment: .center, spacing: Theme.Space.symbolGap) {
            RowSymbol(symbol: "number")
            VStack(alignment: .leading, spacing: 3) {
                if let id = share.installID {
                    Text(verbatim: id)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(on ? .primary : .secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .accessibilityLabel(Text("Your install ID"))
                    Text(on ? "If I ever need it for support, I’ll ask you for it. I can’t tell whose it is otherwise."
                            : "Not used while sharing is off. Delete my data forgets it.")
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No ID. One is made only if you turn sharing on.")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let id = share.installID {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(id, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(ChipButtonStyle())
                .help("Copy the install ID")
            }
        }
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.vertical, Theme.Space.rowVertical)
        .frame(minHeight: Theme.Space.rowMinHeight)
        .animation(Theme.Motion.fade, value: share.installID)
    }

    // MARK: Your data

    private var lastSentHint: String {
        if let when = share.lastSent {
            let relative = when.formatted(.relative(presentation: .named))
            return String(localized: "This Mac last sent something \(relative).", comment: "Settings › Privacy; %@ is a relative time, like “2 hours ago”")
        }
        if share.installID != nil {
            return String(localized: "Nothing yet. The first stats go out within a day, and crash reports only if Glideball crashes.", comment: "Settings › Privacy: sharing is on, nothing sent yet")
        }
        return String(localized: "Nothing has been sent from this Mac.", comment: "Settings › Privacy")
    }

    private var deleteSymbol: String {
        switch deleted {
        case true?: "checkmark.circle"
        case false?: "exclamationmark.triangle"
        case nil: "trash"
        }
    }

    private var deleteHint: String {
        if share.deleting { return String(localized: "Deleting…") }
        switch deleted {
        case true?: return String(localized: "Deleted. Glideball won’t send anything now.")
        case false?: return String(localized: "Couldn’t delete it right now. Check your connection and try again.")
        case nil:
            return share.installID == nil
                ? String(localized: "There’s nothing to delete, since this Mac hasn’t been set up to send anything.", comment: "Settings › Privacy: Delete my data with no install ID")
                : String(localized: "Deletes the crash reports and stats this Mac has sent, and turns sharing off.")
        }
    }

    private func delete() {
        deleted = nil
        share.deleteMyData { ok in deleted = ok }
    }
}

/// "What this sends": changes with the choice, built from the real payloads (`SendPreview`).
struct SendPreviewView: View {
    let choice: ShareChoice
    let installID: String?

    var body: some View {
        let preview = SendPreview.make(choice, model: AppModel.shared, installID: installID)
        VStack(alignment: .leading, spacing: 10) {
            Text("What this sends")
                .font(.system(size: 12, weight: .semibold))
            switch choice {
            case .nothing:
                Label("Nothing leaves this Mac.", systemImage: "lock.fill")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
            case .crashes, .crashesAndStats:
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(choice == .crashes
                         ? "If Glideball crashes, it sends where in its code it happened and your versions. Nothing else."
                         : "If Glideball crashes, it sends where in its code it happened and your versions.")
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Link("See an Example", destination: ShareData.explainer)
                        .font(Theme.Font.hint.weight(.medium))
                        .tint(Theme.ball)
                        .help("Opens an example crash report on the privacy page")
                }
                fields(preview.crash)
                if !preview.stats.isEmpty {
                    Text("And once a day, these stats:")
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    fields(preview.stats.filter { f in !preview.crash.contains { $0.id == f.id } })
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupBackground()
        .animation(Theme.Motion.fade, value: choice)
        .accessibilityElement(children: .contain)
    }

    private func fields(_ list: [SendPreview.Field]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                            GridItem(.flexible(), spacing: 16, alignment: .topLeading)],
                  alignment: .leading, spacing: 6) {
            ForEach(list) { f in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: f.label)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text(verbatim: f.value)
                        .font(f.keys == ["installId"] ? .system(size: 10.5, weight: .medium, design: .monospaced) : Theme.Font.hint.weight(.medium))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

extension Findable {
    static let crashReports = Findable(
        id: "crash-reports", title: String(localized: "Crash reports and stats"),
        detail: String(localized: "Choose whether Glideball sends crash reports, and a few anonymous stats.", comment: "Search palette: Crash reports and stats"),
        keywords: String(localized: "privacy, analytics, telemetry, diagnostics, send, data", comment: "Search words for Crash reports and stats (comma-separated)"),
        symbol: "heart.text.square", place: .settings(.privacy))
    static let installID = Findable(
        id: "install-id", title: String(localized: "Your install ID"),
        detail: String(localized: "The random ID your reports are sent under.", comment: "Search palette: Your install ID"),
        keywords: String(localized: "id, identifier, support", comment: "Search words for Your install ID (comma-separated)"),
        symbol: "number", place: .settings(.privacy), sometimes: true)
    static let whatsSent = Findable(
        id: "whats-sent", title: String(localized: "What’s sent"),
        detail: String(localized: "Everything Glideball can send, with an example, on the privacy page.", comment: "Search palette: What's sent"),
        keywords: String(localized: "privacy policy, data, example", comment: "Search words for What's sent (comma-separated)"),
        symbol: "doc.text.magnifyingglass", place: .settings(.privacy))
    static let deleteMyData = Findable(
        id: "delete-my-data", title: String(localized: "Delete my data"),
        detail: String(localized: "Delete what this Mac has sent, and turn sharing off.", comment: "Search palette: Delete my data"),
        keywords: String(localized: "erase, remove, gdpr, forget", comment: "Search words for Delete my data (comma-separated)"),
        symbol: "trash", place: .settings(.privacy), sometimes: true)
}

extension PrivacySettingsPane {
    static let findables: [Findable] = [.crashReports, .installID, .whatsSent, .deleteMyData]
}
