import AppKit
import SwiftUI

// Pieces the Settings window and the sheets share, built on the stage-1
// components (Components.swift): a card that floats over the window, a
// clickable row for links and actions, a big result moment, keycaps, and a
// layout that wraps.

extension Theme {
    /// A surface that sits above the window (a card over it, a sheet): a step
    /// lighter than the window in dark mode, white in light.
    static let raised = Color(nsColor: NSColor(name: "GlideRaised") { appearance in
        isDark(appearance) ? NSColor(srgbHex: 0x1C1C21) : NSColor(srgbHex: 0xFFFFFF)
    })
    /// The dim behind a card over the window.
    static let scrim = Color(nsColor: NSColor(name: "GlideScrim") { appearance in
        isDark(appearance) ? NSColor(white: 0, alpha: 0.5) : NSColor(white: 0, alpha: 0.22)
    })
}

/// A card over the main window (A small favor, the new icon): the window
/// dims, nothing under it can be clicked, and the card sits in the middle,
/// floating over the lit stage (`LitCardBackground`).
struct OverlayCard<Content: View>: View {
    var width: CGFloat = 520
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Theme.scrim.ignoresSafeArea()
            content
                .padding(28)
                .frame(width: width)
                .background { LitCardBackground(radius: 20) }
        }
        .contentShape(Rectangle())   // nothing underneath can be clicked
    }
}

/// A card that floats over the window (What's New, the new icon, a small
/// favor): Liquid Glass tinted nearly solid (so the words never fight what's
/// underneath), the trackball's aurora glowing in from the top, light catching
/// its top edge, and a deep soft shadow.
struct LitCardBackground: View {
    var radius: CGFloat = 20
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = scheme == .dark
        Color.clear
            .glassEffect(.regular.tint(Theme.raised.opacity(contrast == .increased ? 0.97 : 0.86)), in: shape)
            .overlay {
                // The aurora, in from the top.
                VStack {
                    Rectangle()
                        .fill(EllipticalGradient(colors: [Theme.orbBlue.opacity(dark ? 0.42 : 0.18),
                                                          Theme.orbViolet.opacity(dark ? 0.18 : 0.08), .clear],
                                                 center: UnitPoint(x: 0.3, y: 0), startRadiusFraction: 0, endRadiusFraction: 0.55))
                        .frame(height: 260)
                    Spacer(minLength: 0)
                }
                .clipShape(shape)
                .opacity(contrast == .increased ? 0.4 : 1)
                .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [Theme.surfaceHighlight, Theme.groupBorder, Theme.groupBorder],
                                                  startPoint: .topLeading, endPoint: .bottom), lineWidth: 1)
            }
            .shadow(color: .black.opacity(dark ? 0.45 : 0.16), radius: 34, y: 16)
            .shadow(color: Theme.orbBlue.opacity(dark ? 0.12 : 0.06), radius: 40, y: 0)
    }
}

/// A row that does one thing when clicked: opens a page (↗), or goes
/// somewhere in the app (›). Same metrics as `SettingRow`, with a hover wash.
struct ActionRow<Trailing: View>: View {
    let title: LocalizedStringKey
    var hint: LocalizedStringKey? = nil
    var symbol: String? = nil
    var external = false
    let action: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.symbolGap) {
                if let symbol { RowSymbol(symbol: symbol) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Font.body)
                    if let hint {
                        Text(hint)
                            .font(Theme.Font.hint)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
                Image(systemName: external ? "arrow.up.right" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Theme.Space.rowHorizontal)
            .padding(.vertical, Theme.Space.rowVertical)
            .frame(minHeight: Theme.Space.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowHoverStyle())
        .accessibilityHint(external ? Text("Opens in your browser") : Text(""))
    }
}

extension ActionRow where Trailing == EmptyView {
    init(title: LocalizedStringKey, hint: LocalizedStringKey? = nil, symbol: String? = nil,
         external: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, hint: hint, symbol: symbol, external: external, action: action) { EmptyView() }
    }
}

/// The moment something finished (feedback sent, data deleted): a ring that
/// draws itself around a check, in the status color. No glow.
struct ResultMark: View {
    var color: Color = Theme.ok
    var size: CGFloat = 72
    @State private var t: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.12))
            Circle().trim(from: 0, to: t)
                .stroke(color, style: StrokeStyle(lineWidth: size / 22, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Path { p in
                p.move(to: CGPoint(x: size * 0.31, y: size * 0.51))
                p.addLine(to: CGPoint(x: size * 0.44, y: size * 0.64))
                p.addLine(to: CGPoint(x: size * 0.70, y: size * 0.37))
            }
            .trim(from: 0, to: max(0, (t - 0.45) / 0.55))
            .stroke(color, style: StrokeStyle(lineWidth: size / 17, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .onAppear {
            if reduceMotion || Sandbox.isActive { t = 1 } else { withAnimation(.easeOut(duration: 0.7)) { t = 1 } }
        }
        .accessibilityHidden(true)
    }
}

/// A shortcut as keycaps: ⌃ ⌥ ⌘ G, each in its own small rounded key.
struct KeyCaps: View {
    let shortcut: KeyShortcut

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.parts(shortcut).enumerated()), id: \.offset) { _, part in
                KeyCap(label: part)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: shortcut.display))
    }

    static func parts(_ s: KeyShortcut) -> [String] {
        var out: [String] = []
        if s.flags.contains(.maskControl) { out.append("⌃") }
        if s.flags.contains(.maskAlternate) { out.append("⌥") }
        if s.flags.contains(.maskShift) { out.append("⇧") }
        if s.flags.contains(.maskCommand) { out.append("⌘") }
        out.append(s.keyName)
        return out
    }
}

/// One key.
struct KeyCap: View {
    let label: String

    var body: some View {
        Text(verbatim: label)
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, label.count > 1 ? 5 : 0)
            .background {
                let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
                shape.fill(Theme.raised)
                    .pixelBorder(shape, Theme.groupBorder)
                    .shadow(color: .black.opacity(0.12), radius: 0, y: 0.5)
            }
    }
}

/// Lays its children out in rows, wrapping when the next one doesn't fit
/// (buttons whose names grow in German, say).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + lineSpacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + lineSpacing
                x = bounds.minX
                line = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// A quiet bordered capsule for small secondary actions (sound previews, Copy).
struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration)
    }

    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background {
                    Capsule().fill(configuration.isPressed ? Theme.pressedFill : hovering && enabled ? Theme.hoverFill : Theme.groupFill)
                        .pixelBorder(Capsule(), Theme.groupBorder)
                }
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// A whole row as a button: a wash on hover, a little more while pressed,
/// inset a few points so it sits inside the group's rounded corners.
struct RowHoverStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowHoverBody(configuration: configuration)
    }

    private struct RowHoverBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(configuration.isPressed ? Theme.pressedFill : hovering && enabled ? Theme.hoverFill : .clear)
                        .padding(3)
                }
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
