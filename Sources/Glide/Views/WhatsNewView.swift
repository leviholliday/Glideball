import AppKit
import SwiftUI

/// What's New, over the window: a title, a line about the version, one row
/// per change (a small picture, a title, a sentence or two, and "Show Me"
/// where there's somewhere to go), and the full changelog a click away.
/// Return or esc closes it. Opened by `AppModel.showingWhatsNew`.
struct WhatsNewView: View {
    @Bindable var model: AppModel
    var entry: WhatsNew.Entry? = WhatsNew.entry(for: WhatsNew.currentVersion) ?? WhatsNew.entries.first

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.32)).ignoresSafeArea()
            if let entry {
                GeometryReader { g in
                    card(entry)
                        .frame(maxHeight: max(320, g.size.height - 48))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .contentShape(Rectangle())   // nothing underneath can be clicked
    }

    private func card(_ entry: WhatsNew.Entry) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("What’s new in Glideball \(entry.title)", comment: "What's New title; %@ is a version like 2.10")
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: entry.intro)
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // All of it when it fits; scrolling in a small window.
            ViewThatFits(in: .vertical) {
                items(entry)
                ScrollView { items(entry) }
                    .scrollIndicators(.automatic)
            }

            HStack(spacing: 12) {
                Link(destination: SiteLinks.whatsNew(in: WhatsNew.currentVersion)) {
                    Label("Full changelog", systemImage: "arrow.up.right")
                        .labelStyle(TrailingIconLabel())
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ball)
                .help("Every version, on the Glideball website")
                Spacer()
                Button("Close") { model.closeWhatsNew() }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                Button {
                    model.closeWhatsNew()
                } label: {
                    Text("Continue").padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ball)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 640)
        .background {
            // Solid, so the page underneath never shows through the words.
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            shape.fill(Theme.windowBackground)
                .overlay(shape.strokeBorder(Theme.groupBorder, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        }
    }

    private func items(_ entry: WhatsNew.Entry) -> some View {
        RowGroup(dividerInset: Theme.Space.rowHorizontal + 36 + 12) {
            ForEach(entry.items) { item in row(item) }
        }
    }

    private func row(_ item: WhatsNew.Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            WhatsNewArt(art: item.art)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.title)
                    .font(Theme.Font.sectionTitle)
                Text(verbatim: item.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let destination = item.showMe {
                Button("Show Me") { model.closeWhatsNew(then: destination) }
                    .controlSize(.small)
                    .help(help(for: destination))
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private func help(for destination: WhatsNew.Destination) -> String {
        switch destination {
        case .tab(let tab): String(localized: "Open the \(tab.title) tab", comment: "%@ is a tab name")
        case .settings(let pane, _): String(localized: "Open Settings › \(pane.title)", comment: "%@ is a Settings tab name")
        }
    }
}

/// An item's small picture: the trackball itself, or a symbol in its part's color.
private struct WhatsNewArt: View {
    let art: WhatsNew.Art

    var body: some View {
        Group {
            switch art {
            case .trackball:
                TrackballArt(pose: TrackballPose())
            case .symbol(let name, let part):
                let color = part.map(Self.color)
                Image(systemName: name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                    .frame(width: 36, height: 36)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(color.map { $0.opacity(0.13) } ?? Theme.hoverFill)
                    }
            }
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }

    private static func color(_ part: WhatsNew.Part) -> Color {
        switch part {
        case .ball: Theme.ball
        case .ring: Theme.ring
        case .buttons: Theme.buttons
        }
    }
}

/// Title first, then a small icon after it (for links that leave the app).
private struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.font(.system(size: 9, weight: .semibold))
        }
    }
}
