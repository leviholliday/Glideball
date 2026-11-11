import SwiftUI

// The window's building blocks, from the design guide: a page header, sections
// (a title, a caption, one quiet group of rows), rows with a hint that talks
// about now, and a few small pieces (status dot, mode chip, inline stat).
// Hierarchy comes from type and spacing, not boxes: there's never a group in a group.

// MARK: - Page header

/// A page's title (26 semibold), one line about it, and a page-level action on the right if there is one.
struct PageHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.Font.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.bottom, 4)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Sections and groups

/// A section: a title (13 semibold, sentence case), an optional caption, then
/// one group of rows. 24 pt between sections comes from the page's stack.
struct SectionBlock<Content: View, Accessory: View>: View {
    let title: LocalizedStringKey?
    var caption: LocalizedStringKey? = nil
    /// Where the hairlines between rows start (past a leading symbol, say).
    var dividerInset: CGFloat = Theme.Space.rowHorizontal
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.titleToGroup) {
            if title != nil || caption != nil {
                SectionTitle(title: title, caption: caption) { accessory }
            }
            RowGroup(dividerInset: dividerInset) { content }
        }
    }
}

extension SectionBlock where Accessory == EmptyView {
    init(title: LocalizedStringKey?, caption: LocalizedStringKey? = nil,
         dividerInset: CGFloat = Theme.Space.rowHorizontal, @ViewBuilder content: () -> Content) {
        self.init(title: title, caption: caption, dividerInset: dividerInset, accessory: { EmptyView() }, content: content)
    }
}

/// A section whose body isn't a group of rows (a row of choices, a chart): the
/// title and caption, then the content straight on the page.
struct PlainSection<Content: View>: View {
    let title: LocalizedStringKey
    var caption: LocalizedStringKey? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.titleToGroup) {
            SectionTitle(title: title, caption: caption)
            content
        }
    }
}

/// A section's title and caption on their own (for a section whose body isn't a group: a chart, say).
struct SectionTitle<Accessory: View>: View {
    let title: LocalizedStringKey?
    var caption: LocalizedStringKey? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(Theme.Font.sectionTitle)
                        .accessibilityAddTraits(.isHeader)
                }
                if let caption {
                    Text(caption)
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
    }
}

extension SectionTitle where Accessory == EmptyView {
    init(title: LocalizedStringKey?, caption: LocalizedStringKey? = nil) {
        self.init(title: title, caption: caption) { EmptyView() }
    }
}

/// One quiet rounded group: 12 pt corners, a whisper of fill, a one-pixel edge,
/// and an inset hairline between each pair of rows.
struct RowGroup<Content: View>: View {
    var dividerInset: CGFloat = Theme.Space.rowHorizontal
    @ViewBuilder var content: Content
    @Environment(\.displayScale) private var scale

    var body: some View {
        PixelColumn(scale: scale) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Hairline().padding(.leading, dividerInset) }
                    row
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupBackground()
    }
}

/// A column that puts every child on a whole device pixel: each one's height is
/// rounded up to the pixel grid, so a hairline between two rows is always
/// exactly one pixel, never straddling two (which draws it faint or not at all).
struct PixelColumn: Layout {
    /// Device pixels per point.
    var scale: CGFloat

    private func snapped(_ h: CGFloat) -> CGFloat {
        let s = max(scale, 1)
        return (h * s - 0.001).rounded(.up) / s
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width
        var w: CGFloat = 0, h: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(ProposedViewSize(width: width, height: nil))
            w = max(w, size.width)
            h += snapped(size.height)
        }
        return CGSize(width: width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for s in subviews {
            let h = snapped(s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height)
            s.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: h))
            y += h
        }
    }
}

/// A line in the separator color exactly one device pixel thick, at any scale.
struct Hairline: View {
    var vertical = false
    @Environment(\.displayScale) private var scale

    var body: some View {
        let t = 1 / max(scale, 1)
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: vertical ? t : nil, height: vertical ? nil : t)
    }
}

extension View {
    /// The group surface on its own (for a block that lays out its own insides).
    func groupBackground(radius: CGFloat = Theme.Radius.group) -> some View {
        modifier(GroupBackground(radius: radius))
    }
}

extension View {
    /// An edge drawn `pixels` device pixels thick (one by default), whatever the screen's density.
    func pixelBorder<S: InsettableShape, F: ShapeStyle>(_ shape: S, _ style: F, pixels: CGFloat = 1) -> some View {
        modifier(PixelBorder(shape: shape, style: style, pixels: pixels))
    }
}

private struct PixelBorder<S: InsettableShape, F: ShapeStyle>: ViewModifier {
    let shape: S
    let style: F
    let pixels: CGFloat
    @Environment(\.displayScale) private var scale

    func body(content: Content) -> some View {
        content.overlay(shape.strokeBorder(style, lineWidth: pixels / max(scale, 1)))
    }
}

private struct GroupBackground: ViewModifier {
    let radius: CGFloat
    @Environment(\.displayScale) private var scale

    func body(content: Content) -> some View {
        content
            .background {
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                shape.fill(Theme.groupFill)
                    .overlay(shape.strokeBorder(Theme.groupBorder, lineWidth: 1 / max(scale, 1)))
            }
            .pixelAligned()
    }
}

/// Nudges a view (by less than a pixel) so its top-left corner sits on the pixel grid. Text above
/// a group has fractional heights, so on a 1x screen a group can start half a pixel in; its edge
/// and its hairlines would then straddle two pixels and draw faint. At 2x this does nothing much.
private struct PixelAligned: ViewModifier {
    @Environment(\.displayScale) private var scale
    @State private var nudge = CGSize.zero

    func body(content: Content) -> some View {
        content
            .offset(nudge)
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin in
                let s = max(scale, 1)
                // `origin` already includes the current nudge.
                let x = origin.x - nudge.width, y = origin.y - nudge.height
                let next = CGSize(width: (x * s).rounded() / s - x, height: (y * s).rounded() / s - y)
                if abs(next.width - nudge.width) > 0.01 || abs(next.height - nudge.height) > 0.01 { nudge = next }
            }
    }
}

extension View {
    func pixelAligned() -> some View { modifier(PixelAligned()) }
}

// MARK: - Rows

private struct RowPaddingKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// Rows pad themselves inside a group; inside an old-style card (which pads its own content) they don't.
    var rowPadding: Bool {
        get { self[RowPaddingKey.self] }
        set { self[RowPaddingKey.self] = newValue }
    }
}

/// A row: optional leading symbol (15 pt, secondary or the part's color),
/// a 13 pt label with an 11 pt hint under it, and the control trailing.
struct SettingRow<Control: View>: View {
    let title: LocalizedStringKey
    var hint: LocalizedStringKey? = nil
    var symbol: String? = nil
    /// The part this row is about (its symbol takes the part's color).
    var tint: Color? = nil
    @ViewBuilder var control: Control
    @Environment(\.rowPadding) private var padded

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.symbolGap) {
            if let symbol {
                RowSymbol(symbol: symbol, tint: tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Font.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint {
                    Text(hint)
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, padded ? Theme.Space.rowHorizontal : 0)
        .padding(.vertical, padded ? Theme.Space.rowVertical : 0)
        .frame(minHeight: padded ? Theme.Space.rowMinHeight : nil)
        .accessibilityElement(children: .contain)
    }
}

extension SettingRow where Control == EmptyView {
    init(title: LocalizedStringKey, hint: LocalizedStringKey? = nil, symbol: String? = nil, tint: Color? = nil) {
        self.init(title: title, hint: hint, symbol: symbol, tint: tint) { EmptyView() }
    }
}

/// A row's leading symbol: 15 pt on a fixed column so labels line up. A symbol too
/// wide for the column (the tortoise) steps down a size rather than hang out of it.
struct RowSymbol: View {
    let symbol: String
    var tint: Color? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Image(systemName: symbol).font(.system(size: 15)).fixedSize()
            Image(systemName: symbol).font(.system(size: 13)).fixedSize()
            Image(systemName: symbol).font(.system(size: 11)).fixedSize()
        }
        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        .frame(width: Theme.Space.symbolColumn)
        .accessibilityHidden(true)
    }
}

struct ToggleRow: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let symbol: String
    @Binding var isOn: Bool
    var tint: Color? = nil

    var body: some View {
        SettingRow(title: title, hint: subtitle, symbol: symbol, tint: tint) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

/// A slider row: label and value on top, a thin system slider filled in the
/// part's color with a small mark at the default, and a hint about now.
struct TuningSlider: View {
    let title: LocalizedStringKey
    let symbol: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: (Double) -> String
    var lowLabel: LocalizedStringKey? = nil
    var highLabel: LocalizedStringKey? = nil
    /// One line about what the current value does; changes as it does.
    var hint: LocalizedStringKey? = nil
    /// The part the setting is about.
    var tint: Color = Theme.ball
    /// Where it starts out (a mark on the track).
    var defaultValue: Double? = nil
    @Environment(\.rowPadding) private var padded
    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.symbolGap) {
                RowSymbol(symbol: symbol)
                Text(title).font(Theme.Font.body)
                Spacer(minLength: 8)
                Text(format(value))
                    .font(Theme.Font.value)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: value))
                    .accessibilityHidden(true)
            }
            slider
                .padding(.leading, Theme.Space.symbolColumn + Theme.Space.symbolGap)
            if lowLabel != nil || highLabel != nil || hint != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if lowLabel != nil || highLabel != nil {
                        HStack {
                            if let lowLabel { Text(lowLabel) }
                            Spacer()
                            if let highLabel { Text(highLabel) }
                        }
                        .foregroundStyle(.tertiary)
                    }
                    if let hint {
                        Text(hint)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(Theme.Font.hint)
                .padding(.leading, Theme.Space.symbolColumn + Theme.Space.symbolGap)
            }
        }
        .padding(.horizontal, padded ? Theme.Space.rowHorizontal : 0)
        .padding(.vertical, padded ? 12 : 0)
    }

    /// The slider's value, snapped to `step` by hand. (The system's own `step:` draws a dotted tick
    /// under the track; this keeps the snapping and leaves the track bare.)
    private var snapping: Binding<Double> {
        Binding(
            get: { value },
            set: { raw in
                guard let step else { value = raw; return }
                let low = range.lowerBound
                var next = ((raw - low) / step).rounded() * step + low
                // An arrow key or VoiceOver nudge smaller than a step still moves one step.
                if !dragging, abs(next - value) < step * 0.01, abs(raw - value) > 1e-9 {
                    next = value + (raw > value ? step : -step)
                }
                next = min(max(next, low), range.upperBound)
                next = (next * 1e6).rounded() / 1e6
                if next != value { value = next }
            })
    }

    @ViewBuilder private var slider: some View {
        Group {
            Slider(value: snapping, in: range, label: { Text(title) }, onEditingChanged: { dragging = $0 })
        }
        .labelsHidden()
        .controlSize(.small)
        .tint(tint)
        .accessibilityValue(format(value))
        .background(alignment: .bottomLeading) {
            // The default, as a small mark under the track. (Drawn here rather than as a
            // system tick so the slider never snaps to it.)
            if let defaultValue, range.upperBound > range.lowerBound {
                GeometryReader { geo in
                    let knob: CGFloat = 5   // the small knob's half width: where the track's ends really are
                    let f = (min(max(defaultValue, range.lowerBound), range.upperBound) - range.lowerBound)
                        / (range.upperBound - range.lowerBound)
                    Capsule()
                        .fill(.tertiary)
                        .frame(width: 1.5, height: 4)
                        .position(x: knob + CGFloat(f) * (geo.size.width - knob * 2), y: geo.size.height + 3)
                }
                .help("Default: \(format(defaultValue))")
                .accessibilityHidden(true)
            }
        }
    }
}

extension LocalizedStringKey {
    /// Text that's already localized (or never is: names, shortcuts), for a
    /// view that takes a `LocalizedStringKey`. Its key is just "%@", which no
    /// table defines, so it shows as is.
    static func verbatim(_ text: String) -> LocalizedStringKey { "\(text)" }
}

// MARK: - Small pieces

/// A number as typography: a big rounded numeral over a small label with the part's dot.
struct InlineStat: View {
    let value: String
    let label: LocalizedStringKey
    var color: Color? = nil
    var size: CGFloat = 30
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(Theme.Font.numeral(size))
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 6) {
                if let color { StatusDot(color: color, size: 7) }
                Text(label)
                    .font(Theme.Font.hint.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            if let detail {
                Text(detail)
                    .font(Theme.Font.hint)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A plain dot: a status, or the part a number is about. Never glows.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// A mode that's on right now (Precision, Drag lock…): a small quiet chip with the part's symbol color.
struct ModeChip: View {
    let text: LocalizedStringKey
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(tint.opacity(0.14)))
        .pixelBorder(Capsule(), tint.opacity(0.28))
        .fixedSize()
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }
}

/// A status line: a dot and a few words (Connected, Paused…).
struct StatusPill: View {
    let text: LocalizedStringKey
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: color, size: 7)
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.groupFill))
        .pixelBorder(Capsule(), Theme.groupBorder)
    }
}


/// A notice at the top of the content: what's going on, in a sentence, and the one thing to do about it.
struct NoticeBanner<Actions: View>: View {
    let symbol: String
    /// A status color (yellow for something needed, the part's or secondary for information).
    let tint: Color
    let title: LocalizedStringKey
    var message: LocalizedStringKey? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 22)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.Font.sectionTitle)
                    if let message {
                        Text(message)
                            .font(Theme.Font.hint)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 10) { actions }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
            shape.fill(Theme.groupFill)
                .pixelBorder(shape, tint.opacity(0.6))
        }
        .accessibilityElement(children: .contain)
    }
}

/// An icon-only button: a hover wash, a tooltip and a spoken name, always.
struct IconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    var size: CGFloat = 26
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(HoverButtonStyle(shape: .circle))
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// For clickable things that aren't system controls: a wash on hover, a
/// little more while pressed, and a focus ring when tabbed to.
struct HoverButtonStyle: ButtonStyle {
    enum Shape { case circle, rounded }
    var shape: Shape = .rounded
    var radius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, shape: shape, radius: radius)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        let shape: Shape
        let radius: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .background {
                    let fill = configuration.isPressed ? Theme.pressedFill : (hovering && enabled ? Theme.hoverFill : .clear)
                    switch shape {
                    case .circle: Circle().fill(fill)
                    case .rounded: RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
                    }
                }
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .focusEffectDisabled(false)
        }
    }
}

/// A full-width list row that's a button, inset a little inside its group: a
/// wash on hover, a little more while pressed, a ball-blue outline when it's
/// the selected one, and the standard focus ring. (The group's own hairlines
/// should start at `dividerInset(leading:)`.)
struct ListRowButtonStyle: ButtonStyle {
    var selected = false
    static let outerInset: CGFloat = 4
    static let innerPadding: CGFloat = 10

    /// Where a group's hairlines start for a row whose text begins `leading` pt (an icon and its gap) in.
    static func dividerInset(leading: CGFloat) -> CGFloat { outerInset + innerPadding + leading }

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, selected: selected)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
            configuration.label
                .padding(.horizontal, ListRowButtonStyle.innerPadding)
                .padding(.vertical, 6)
                .frame(minHeight: Theme.Space.rowMinHeight - 2 * ListRowButtonStyle.outerInset)
                .background {
                    shape.fill(configuration.isPressed ? Theme.pressedFill
                               : selected ? Theme.ball.opacity(0.12)
                               : hovering ? Theme.hoverFill : .clear)
                }
                .overlay { if selected { shape.strokeBorder(Theme.ball.opacity(0.45), lineWidth: 1) } }
                .contentShape(shape)
                .padding(ListRowButtonStyle.outerInset)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .focusEffectDisabled(false)
        }
    }
}

/// A small neutral label next to a name ("This Mac", "Before import"). Already-localized text.
struct QuietChip: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.hoverFill))
            .pixelBorder(Capsule(), Theme.groupBorder)
            .fixedSize()
    }
}

// MARK: - Compatibility: the old card

/// Pages not yet redesigned still build their blocks out of `GlassCard`. It now
/// draws the new quiet group with a sentence-case title above it, so those
/// pages already look like the rest. The symbol and tint are no longer drawn
/// (titles don't carry icons, and color means a part).
struct GlassCard<Content: View>: View {
    var title: LocalizedStringKey? = nil
    var symbol: String? = nil
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.titleToGroup) {
            if let title {
                Text(title)
                    .font(Theme.Font.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .groupBackground()
            .environment(\.rowPadding, false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Background

/// The plain window background (no gradient, no mesh).
struct GlideBackground: View {
    var body: some View {
        Theme.windowBackground.ignoresSafeArea()
    }
}

// MARK: - A row of choices

/// A quiet row of equal choices (a preset, a mode): the chosen one is filled and
/// outlined in the part's color, the rest are plain until hovered. The chosen
/// one reads as "this one" without relying on color alone (weight and outline
/// change too), in light and dark.
struct ChoiceStrip<Value: Hashable>: View {
    struct Choice: Identifiable {
        let value: Value
        let title: LocalizedStringKey
        let symbol: String
        var id: Value { value }
    }

    let choices: [Choice]
    /// Whether a choice is the current one (a preset is matched by what it sets, not only by having been picked).
    let isSelected: (Value) -> Bool
    let tint: Color
    let select: (Value) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(choices) { c in
                let selected = isSelected(c.value)
                Button {
                    withAnimation(Theme.Motion.respecting(reduceMotion, Theme.Motion.spring)) { select(c.value) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: c.symbol)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                        Text(c.title)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .padding(.horizontal, 6)
                    .background {
                        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                        shape.fill(selected ? tint.opacity(0.13) : Theme.groupFill)
                            .pixelBorder(shape, selected ? tint.opacity(0.7) : Theme.groupBorder, pixels: selected ? 2 : 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverButtonStyle(radius: 8))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

// MARK: - Pointer speed presets

/// Precise / macOS / Fast / Turbo: used on the Pointer tab and in the Welcome Tour.
/// The chosen one is whichever matches the speed right now.
struct PointerPresetRow: View {
    @Binding var speed: Double

    private static let presets: [ChoiceStrip<Double>.Choice] = [
        .init(value: 1.5, title: LocalizedStringKey("Precise"), symbol: "scope"),
        .init(value: 3, title: LocalizedStringKey("macOS"), symbol: "applelogo"),
        .init(value: 5, title: LocalizedStringKey("Fast"), symbol: "hare"),
        .init(value: 7.5, title: LocalizedStringKey("Turbo"), symbol: "bolt"),
    ]

    var body: some View {
        ChoiceStrip(choices: Self.presets, isSelected: { abs(speed - $0) < 0.01 }, tint: Theme.ball) { speed = $0 }
    }
}
