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

/// Settings › Privacy: the same choice as the card, any time, the install ID,
/// what's sent, and Delete My Data with its result right where you clicked.
struct ShareDataSettings: View {
    @Bindable private var share = ShareData.shared
    @State private var confirmingDelete = false
    @State private var copied = false
    /// How the last Delete My Data went (the main window, where toasts appear, may be closed).
    @State private var deleted: Bool? = ShareDataSettings.sandboxDeleted
    /// `--render-ui`: start as if a delete just finished (or failed).
    static var sandboxDeleted: Bool?

    var body: some View {
        SectionBlock(title: "Crash reports and stats",
                     caption: "Off unless you pick something. Never your name, what you type or which apps you use.",
                     dividerInset: SettingsLayout.symbolInset) {
            SettingsRow(title: "Send", hint: choiceHint, symbol: "heart.text.square") {
                Picker(selection: $share.choice) {
                    ForEach(ShareChoice.allCases) { choice in
                        Text(verbatim: choice.title).tag(choice)
                    }
                } label: { Text("Send") }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            if let id = share.installID {
                HStack(alignment: .center, spacing: Theme.Space.symbolGap) {
                    RowSymbol(symbol: "number")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Your install ID").font(Theme.Font.body)
                        Text(verbatim: id)
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text("If I ever need it for support, I’ll ask you for it. I can’t tell whose it is otherwise.")
                            .font(Theme.Font.hint)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                .padding(.horizontal, Theme.Space.rowHorizontal)
                .padding(.vertical, Theme.Space.rowVertical)
            }
            ActionRow(title: "What’s sent", hint: "The privacy page lists everything Glideball can send, with an example.",
                      symbol: "doc.text.magnifyingglass", external: true) {
                NSWorkspace.shared.open(ShareData.explainer)
            }
        }
        if share.installID != nil || deleted != nil {
            SectionBlock(title: "What’s been sent", dividerInset: SettingsLayout.symbolInset) {
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
            .onChange(of: share.choice) { _, now in
                if now != .nothing { deleted = nil }   // sharing again: the old result no longer applies
            }
            .alert("Delete what this Mac has sent?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes the crash reports and stats this Mac has sent to the Glideball server, and turns sharing off. It can't be undone.")
            }
        }
    }

    private var choiceHint: String {
        switch share.choice {
        case .nothing: String(localized: "Glideball doesn’t send anything.")
        case .crashes: String(localized: "If Glideball crashes, it sends where in its code it happened and your versions. Nothing else.")
        case .crashesAndStats: String(localized: "Crash reports, plus once a day your trackball and a few settings, like the scroll mode.")
        }
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
        case nil: return String(localized: "Deletes the crash reports and stats this Mac has sent, and turns sharing off.")
        }
    }

    private func delete() {
        deleted = nil
        share.deleteMyData { ok in deleted = ok }
    }
}
