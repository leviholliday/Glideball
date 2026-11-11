import AppKit
import SwiftUI

/// "A small favor": asks once whether Glideball may send crash reports, or
/// crash reports and settings stats (see `ShareData`). Nothing is picked
/// unless the person picks it. Shown over the window by
/// `AppModel.offerSmallFavor()`: after the Welcome Tour on a new Mac, or
/// once after updating on a Mac that already used Glideball.
struct SmallFavorCard: View {
    @Bindable var model: AppModel
    @State private var pick: ShareChoice = .nothing

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.28)).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 46, height: 46)
                    Text("A small favor")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                }
                Text("Hi, I'm Levi. I make Glideball on my own, and when it crashes on someone's Mac, I usually never hear about it. If you're okay with it, Glideball can send me a little anonymous information, so I can fix crashes and see which settings people actually use. It's off unless you pick something here.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 8) {
                    option(.nothing, symbol: "hand.raised",
                           detail: "Glideball doesn't send anything, and that's fine.")
                    option(.crashes, symbol: "ladybug",
                           detail: "If Glideball crashes, it sends me where in its code it happened and which versions of Glideball and macOS you have.")
                    option(.crashesAndStats, symbol: "chart.bar",
                           detail: "Also, once a day: which trackball you have and a few of your settings, like the scroll mode and roughly how fast the pointer is. Never what you type, which apps you use, or your name.")
                }

                Text("It isn't tied to your name, your email or your Mac. You can change this, or delete what was sent, any time in Overview › General.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Thanks either way,")
                        Text(verbatim: "Levi").font(.system(size: 14, weight: .semibold, design: .serif)).italic()
                    }
                    .font(.system(size: 13))
                    Spacer()
                    Button("What’s Sent") { NSWorkspace.shared.open(ShareData.explainer) }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .help("Opens the privacy page on the Glideball website")
                    Button {
                        ShareData.shared.choice = pick
                        ShareData.shared.asked = true
                        model.showingSmallFavor = false
                    } label: {
                        Text("Done").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 10)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.cyan)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(28)
            .frame(width: 580)
            .glassEffect(.regular, in: .rect(cornerRadius: 30))
        }
        .contentShape(Rectangle())   // nothing underneath can be clicked
    }

    private func option(_ choice: ShareChoice, symbol: String, detail: LocalizedStringKey) -> some View {
        let on = pick == choice
        return Button {
            withAnimation(.smooth(duration: 0.2)) { pick = choice }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(on ? Color.cyan : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Label(choice.title, systemImage: symbol)
                        .font(.system(size: 14, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(on ? Color.cyan.opacity(0.14) : Color.primary.opacity(0.04))
                    .strokeBorder(on ? Color.cyan.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Overview › General: the same choice as the card, any time, and "Delete my data".
struct ShareDataRow: View {
    let model: AppModel
    @Bindable private var share = ShareData.shared
    @State private var confirmingDelete = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "heart.text.square")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Crash reports and stats").font(.system(size: 14, weight: .medium))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Picker("Crash reports and stats", selection: $share.choice) {
                    ForEach(ShareChoice.allCases) { choice in
                        Text(verbatim: choice.title).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            if let id = share.installID {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Your install ID").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Text(verbatim: id)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Text("If I ever need this for support, I'll ask you for it. I can't see it otherwise.")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(id, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .contentTransition(.symbolEffect(.replace))
                }
                .padding(.leading, 32)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("What’s Sent") { NSWorkspace.shared.open(ShareData.explainer) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Opens the privacy page on the Glideball website")
                if share.installID != nil {
                    Button {
                        confirmingDelete = true
                    } label: {
                        if share.deleting {
                            ProgressView().controlSize(.mini).frame(width: 90)
                        } else {
                            Text("Delete My Data…")
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(share.deleting)
                    .help("Deletes the crash reports and stats this Mac has sent, and turns sharing off")
                }
            }
        }
        .alert("Delete what this Mac has sent?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the crash reports and stats this Mac has sent to the Glideball server, and turns sharing off. It can't be undone.")
        }
    }

    private var detail: LocalizedStringKey {
        switch share.choice {
        case .nothing: "Off. Glideball doesn't send anything."
        case .crashes: "Sends a crash report if Glideball crashes. Nothing else."
        case .crashesAndStats: "Sends crash reports, plus anonymous settings stats once a day."
        }
    }

    private func delete() {
        share.deleteMyData { ok in
            if ok {
                model.show(.init(symbol: "checkmark.circle.fill", text: String(localized: "Deleted. Glideball won’t send anything now.")))
            } else {
                model.show(.init(symbol: "exclamationmark.triangle.fill",
                                 text: String(localized: "Couldn’t delete it right now. Check your connection and try again."),
                                 isError: true))
            }
        }
    }
}
