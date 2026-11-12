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
        let _ = PerfProbe.count("Group")
        content
            .background { SurfaceShape(radius: radius, pixel: 1 / max(scale, 1)) }
            .modifier(Spotlight(radius: radius))
            .pixelAligned()
    }
}

/// A raised surface, lit from the top left (where the trackball is): a fill a
/// shade brighter at the top, a 1 px edge brightest toward the light, an inner
/// highlight along the top, and two soft layered shadows.
///
/// Drawn once into a single bitmap (with room around it for the shadows) and
/// then only moved: scrolling a page full of these used to redo two blurred
/// shadows, three gradients and two strokes per surface on every frame.
struct SurfaceShape: View {
    var radius: CGFloat = Theme.Radius.group
    var pixel: CGFloat = 0.5
    /// A little more lift (floating cards).
    var raised = false

    var body: some View {
        // Room for the shadows past the surface: the bigger one's radius plus its offset.
        let room: CGFloat = raised ? 44 : 24
        surface
            .padding(room)
            .drawingGroup()
            .padding(-room)
    }

    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return shape
            .fill(LinearGradient(colors: [Theme.surfaceTop, Theme.surfaceBottom], startPoint: .top, endPoint: .bottom))
            .shadow(color: Theme.surfaceShadow, radius: raised ? 3 : 1.5, x: 0, y: raised ? 2 : 1)
            .shadow(color: Theme.surfaceShadow.opacity(0.7), radius: raised ? 26 : 14, x: raised ? 4 : 2, y: raised ? 14 : 7)
            .overlay {
                // The edge: brighter where it faces the light (top left), quieter opposite.
                shape.strokeBorder(LinearGradient(colors: [Theme.surfaceHighlight, Theme.groupBorder, Theme.groupBorder],
                                                  startPoint: .topLeading, endPoint: UnitPoint(x: 0.7, y: 1)),
                                   lineWidth: pixel * 2 > 1 ? pixel * 2 : 1)
                    .opacity(0.9)
            }
            .overlay {
                // The inner highlight just under the top edge.
                shape.inset(by: 1)
                    .stroke(LinearGradient(stops: [.init(color: Theme.surfaceHighlight.opacity(0.55), location: 0),
                                                   .init(color: .clear, location: 0.08)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
    }
}

/// A soft light that follows the pointer along a surface's edge (and a whisper
/// across its face) while hovering. Driven by pointer moves only: it stops when
/// the pointer does, and it's off with Reduce Motion or Increase Contrast.
///
/// Scrolling moves the page under a still pointer, which reads as hovering
/// too. Those updates are ignored (the pointer itself didn't move), and the
/// light goes out until the pointer moves again, so a scroll never redraws it.
struct Spotlight: ViewModifier {
    var radius: CGFloat = Theme.Radius.group
    @State private var point: CGPoint?
    /// Where the pointer was on screen at the last update (not drawn, so changing it redraws nothing).
    @State private var last = PointerMemory()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    final class PointerMemory {
        var screen: CGPoint?
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if let point, !reduceMotion, contrast != .increased {
                    GeometryReader { geo in
                        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                        let c = UnitPoint(x: point.x / max(geo.size.width, 1), y: point.y / max(geo.size.height, 1))
                        ZStack {
                            shape.fill(RadialGradient(colors: [Theme.spotlight.opacity(0.06), .clear],
                                                      center: c, startRadius: 0, endRadius: 280))
                            shape.strokeBorder(RadialGradient(colors: [Theme.spotlight, Theme.spotlight.opacity(0)],
                                                              center: c, startRadius: 0, endRadius: 160), lineWidth: 1)
                        }
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p):
                    let screen = NSEvent.mouseLocation
                    defer { last.screen = screen }
                    if let was = last.screen, abs(was.x - screen.x) < 0.01, abs(was.y - screen.y) < 0.01 {
                        // The page moved, not the pointer: a scroll.
                        if point != nil { point = nil }
                        return
                    }
                    point = p
                case .ended:
                    last.screen = nil
                    withAnimation(.easeOut(duration: 0.25)) { point = nil }
                }
            }
    }
}

/// Nudges a view (by less than a pixel) so its top-left corner sits on the pixel grid. Text above
/// a group has fractional heights, so on a 1x screen a group can start half a pixel in; its edge
/// and its hairlines would then straddle two pixels and draw faint. At 2x this does nothing much.
///
/// It measures against the page (`PixelGrid.page`, set on the scrolling page's
/// content, which itself sits on whole pixels), not the window: in the window's
/// coordinates every group moved on every frame of a scroll, and this ran for
/// each of them each time. Outside a page (a sheet, Settings) the name isn't
/// there and SwiftUI measures in the window, as before.
private struct PixelAligned: ViewModifier {
    @Environment(\.displayScale) private var scale
    @State private var nudge = CGSize.zero

    func body(content: Content) -> some View {
        content
            .offset(nudge)
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .named(PixelGrid.page)).origin } action: { origin in
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

enum PixelGrid {
    /// The coordinate space of a scrolling page's content.
    static let page = "GlidePage"
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
    /// The symbol bounces when this changes (a switch turned on).
    var bounce: Bool? = nil
    @ViewBuilder var control: Control
    @Environment(\.rowPadding) private var padded

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.symbolGap) {
            if let symbol {
                RowSymbol(symbol: symbol, tint: tint, bounce: bounce)
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
        self.init(title: title, hint: hint, symbol: symbol, tint: tint, bounce: nil) { EmptyView() }
    }
}

/// A row's leading symbol: 15 pt on a fixed column so labels line up. A symbol too
/// wide for the column (the tortoise) steps down a size rather than hang out of it.
struct RowSymbol: View {
    let symbol: String
    var tint: Color? = nil
    var bounce: Bool? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Image(systemName: symbol).font(.system(size: 15)).fixedSize()
            Image(systemName: symbol).font(.system(size: 13)).fixedSize()
            Image(systemName: symbol).font(.system(size: 11)).fixedSize()
        }
        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        .symbolEffect(.bounce, value: bounce ?? false)
        .animation(Theme.Motion.fade, value: bounce)
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
        // Turning it on lights the row's symbol and gives it a small bounce, with a soft tick up (or down).
        SettingRow(title: title, hint: subtitle, symbol: symbol, tint: isOn ? (tint ?? Theme.ball) : tint, bounce: isOn) {
            Toggle(title, isOn: Binding(get: { isOn }, set: { new in
                isOn = new
                Sounds.shared.detent(pitch: new ? 1.25 : 0.85, volume: 0.4)
            }))
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
                    .foregroundStyle(dragging ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                    .contentTransition(.numericText(value: value))
                    .animation(.snappy(duration: 0.18), value: value)
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

    private var slider: some View {
        InstrumentSlider(value: snapping, range: range, step: step, tint: tint, defaultValue: defaultValue,
                         label: Text(title), valueText: format(value), defaultText: defaultValue.map(format),
                         dragging: $dragging)
    }
}

/// A slider made like an instrument: a track of ticks like the scroll ring's,
/// filled in the part's color up to a thumb that glows while you drag it, and
/// a small mark at the default. While dragging, each detent ticks softly (when
/// Sounds is on), a little higher the further along it is. VoiceOver and the
/// arrow keys see a plain system slider.
struct InstrumentSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var tint: Color = Theme.ball
    var defaultValue: Double? = nil
    let label: Text
    let valueText: String
    var defaultText: String? = nil
    @Binding var dragging: Bool
    @State private var hovering = false
    @State private var lastDetent: Int?
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// Renders: draw every slider as if it were being dragged.
    nonisolated(unsafe) static var sandboxDragging = false

    private static let thumb: CGFloat = 16
    private var span: Double { max(range.upperBound - range.lowerBound, 1e-9) }
    private var fraction: Double { min(max((value - range.lowerBound) / span, 0), 1) }

    var body: some View {
        let active = (dragging || Self.sandboxDragging) && enabled
        GeometryReader { geo in
            let inset = Self.thumb / 2
            let w = max(geo.size.width - inset * 2, 1)
            let x = inset + CGFloat(fraction) * w
            let mid = geo.size.height / 2
            ZStack(alignment: .topLeading) {
                SliderTicks(fraction: fraction, tint: tint, lit: active, dark: scheme == .dark)
                    .frame(width: w, height: 12)
                    .position(x: inset + w / 2, y: mid)
                // The fill.
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.55), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(x - inset, 0), height: 3)
                    .shadow(color: tint.opacity(active ? 0.8 : 0.35), radius: active ? 5 : 2)
                    .position(x: inset + max(x - inset, 0) / 2, y: mid)
                // The default, a small mark under the track.
                if let defaultValue {
                    let f = (min(max(defaultValue, range.lowerBound), range.upperBound) - range.lowerBound) / span
                    Capsule()
                        .fill(.tertiary)
                        .frame(width: 1.5, height: 4)
                        .position(x: inset + CGFloat(f) * w, y: mid + 10)
                        .help("Default: \(defaultText ?? "")")
                }
                // The thumb's glow while dragging.
                Circle()
                    .fill(RadialGradient(colors: [tint.opacity(0.55), tint.opacity(0)], center: .center, startRadius: 2, endRadius: 18))
                    .frame(width: 36, height: 36)
                    .position(x: x, y: mid)
                    .opacity(active ? 1 : 0)
                // The thumb: a small lit bead.
                Circle()
                    .fill(LinearGradient(colors: [.white, Color(white: 0.86)], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(focused ? tint : Color.black.opacity(0.12), lineWidth: focused ? 2 : 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .scaleEffect(active ? 1.12 : hovering ? 1.05 : 1)
                    .position(x: x, y: mid)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard enabled else { return }
                    if !dragging { dragging = true }
                    let f = min(max((g.location.x - inset) / w, 0), 1)
                    value = range.lowerBound + Double(f) * span
                }
                .onEnded { _ in dragging = false; lastDetent = nil })
        }
        .frame(height: 24)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: active)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .focusable(enabled)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { nudge(-1); return .handled }
        .onKeyPress(.rightArrow) { nudge(1); return .handled }
        .onChange(of: value) { detentTick() }
        .accessibilityRepresentation {
            Slider(value: $value, in: range) { label }
                .accessibilityValue(valueText)
        }
    }

    private func nudge(_ direction: Double) {
        value = min(max(value + direction * (step ?? span / 50), range.lowerBound), range.upperBound)
    }

    /// A soft tick each time the drag crosses a detent (a step, or a twentieth of the range).
    private func detentTick() {
        guard dragging else { return }
        let index = step.map { Int(((value - range.lowerBound) / $0).rounded()) } ?? Int((fraction * 20).rounded())
        defer { lastDetent = index }
        guard let lastDetent, lastDetent != index else { return }
        Sounds.shared.detent(pitch: 0.8 + 0.55 * fraction)
    }
}

/// A slider's track: the scroll ring's ticks laid out straight, every fifth one
/// longer, lit in the part's color up to the value.
private struct SliderTicks: View {
    let fraction: Double
    let tint: Color
    let lit: Bool
    let dark: Bool

    var body: some View {
        Canvas { ctx, size in
            let n = 40
            let ink: Color = dark ? .white : .black
            var off = Path(), on = Path()
            for i in 0...n {
                let f = Double(i) / Double(n)
                let x = (size.width * CGFloat(f)).rounded() + 0.5
                let long = i % 5 == 0
                let h: CGFloat = long ? 10 : 5
                var p = Path()
                p.move(to: CGPoint(x: x, y: (size.height - h) / 2))
                p.addLine(to: CGPoint(x: x, y: (size.height + h) / 2))
                if f <= fraction + 1e-6 { on.addPath(p) } else { off.addPath(p) }
            }
            ctx.stroke(off, with: .color(ink.opacity(dark ? 0.16 : 0.2)), lineWidth: 1)
            ctx.stroke(on, with: .color(tint.opacity(lit ? 0.75 : 0.42)), lineWidth: 1)
        }
        .allowsHitTesting(false)
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
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .background {
                    let fill = configuration.isPressed ? Theme.pressedFill : (hovering && enabled ? Theme.hoverFill : .clear)
                    switch shape {
                    case .circle: Circle().fill(fill)
                    case .rounded: RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
                    }
                }
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(configuration.isPressed ? .easeOut(duration: 0.08) : .spring(response: 0.3, dampingFraction: 0.6),
                           value: configuration.isPressed)
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
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
            let lift = hovering && !configuration.isPressed && !reduceMotion
            configuration.label
                .padding(.horizontal, ListRowButtonStyle.innerPadding)
                .padding(.vertical, 6)
                .frame(minHeight: Theme.Space.rowMinHeight - 2 * ListRowButtonStyle.outerInset)
                .background {
                    shape.fill(configuration.isPressed ? Theme.pressedFill
                               : selected ? Theme.ball.opacity(0.14)
                               : hovering ? Theme.hoverFill : .clear)
                        .shadow(color: selected ? Theme.ball.opacity(0.35) : (lift ? Theme.surfaceShadow : .clear),
                                radius: selected ? 8 : 4, y: lift ? 2 : 0)
                }
                .overlay {
                    if selected {
                        shape.strokeBorder(LinearGradient(colors: [Theme.ball.opacity(0.85), Theme.ball.opacity(0.35)],
                                                          startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    }
                }
                .contentShape(shape)
                .offset(y: lift ? -1 : 0)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
                .padding(ListRowButtonStyle.outerInset)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(configuration.isPressed ? .easeOut(duration: 0.08) : .spring(response: 0.3, dampingFraction: 0.6),
                           value: configuration.isPressed)
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

/// The stage on its own, without the live light (sheets, the tour, whole-page pictures).
struct GlideBackground: View {
    /// Where the light comes from, relative to the stage (nil: the sidebar trackball's place).
    var anchor: UnitPoint? = nil
    var strength = 1.0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        StaticAtmosphere(dark: scheme == .dark, contrast: contrast == .increased, anchor: anchor, strength: strength)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

// MARK: - A row of choices

/// A row of equal choices (a mode, a preset) as cards. Each card can carry a
/// tiny looping demo of what it does (a list moving the way a scroll mode moves
/// it, a dot crossing at a pointer speed) that plays while the card is hovered
/// or keyboard-focused, and holds still otherwise. The chosen card is lit in
/// the part's color (outline, weight and a check, not color alone).
///
/// Picking one is a small moment: the card gives under the click and springs
/// back, the glow glides over from the old card, the outline draws itself
/// round the new one, its demo plays once in its own character, and a soft
/// tick sounds. Reduce Motion: a plain fade.
struct ChoiceStrip<Value: Hashable>: View {
    struct Choice: Identifiable {
        let value: Value
        let title: LocalizedStringKey
        let symbol: String
        var demo: ChoiceDemo? = nil
        var id: Value { value }
    }

    let choices: [Choice]
    /// Whether a choice is the current one (a preset is matched by what it sets, not only by having been picked).
    let isSelected: (Value) -> Bool
    let tint: Color
    let select: (Value) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glow
    /// The card just picked by hand (its demo plays once), and a count so picking again replays it.
    @State private var picked: Value?
    @State private var pickCount = 0

    var body: some View {
        HStack(spacing: 8) {
            ForEach(choices) { c in
                ChoiceCard(title: c.title, symbol: c.symbol, demo: c.demo, selected: isSelected(c.value), tint: tint,
                           glow: glow, picked: picked == c.value ? pickCount : 0) {
                    let was = isSelected(c.value)
                    withAnimation(reduceMotion ? Theme.Motion.fade : .spring(response: 0.42, dampingFraction: 0.8)) {
                        select(c.value)
                    }
                    if !was {
                        picked = c.value
                        pickCount += 1
                        Sounds.shared.detent(pitch: 1.1, volume: 0.45)
                    }
                }
            }
        }
    }
}

/// Renders: draw the choice card with this symbol as if hovered, mid-demo.
enum ChoiceCardSandbox {
    nonisolated(unsafe) static var hovered: String?
}

/// What a choice card's little demo shows.
enum ChoiceDemo: Equatable {
    /// A list scrolling the way this mode scrolls it.
    case scroll(ScrollMode)
    /// A Follow preset: how far a spin carries the list (0…1) and whether it coasts.
    case follow(reach: Double, coast: Bool)
    /// A dot crossing a line at a pointer speed (in the tracking slider's units).
    case pointer(Double)
}

private struct ChoiceCard: View {
    let title: LocalizedStringKey
    let symbol: String
    let demo: ChoiceDemo?
    let selected: Bool
    let tint: Color
    let glow: Namespace.ID
    /// Changes each time this card is picked by hand (0: it wasn't).
    let picked: Int
    let action: () -> Void
    @State private var hovering = false
    @State private var outline = 1.0
    @State private var give = 1.0
    @State private var playingOnce = false
    @State private var onceWork: DispatchWorkItem?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let playing = (hovering || focused || playingOnce || ChoiceCardSandbox.hovered == symbol) && !reduceMotion
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                    Text(title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(tint)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                if let demo {
                    DemoView(demo: demo, tint: selected || playing ? tint : Color.secondary, playing: playing,
                             frozenAt: ChoiceCardSandbox.hovered == symbol ? 0.55 : nil)
                        .frame(height: 30)
                        .frame(maxWidth: .infinity)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, demo == nil ? 8 : 10)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                SurfaceShape(radius: 10)
                    .opacity(selected ? 0 : 1)
                if selected {
                    // The glow glides over from the card that had it…
                    let fill = shape.fill(LinearGradient(colors: [tint.opacity(0.20), tint.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                        .shadow(color: tint.opacity(0.35), radius: 8, y: 2)
                    if reduceMotion {
                        fill
                    } else {
                        fill.matchedGeometryEffect(id: "glow", in: glow)
                    }
                    // …and the outline draws itself round the new one.
                    shape.inset(by: 0.75)
                        .trim(from: 0, to: outline)
                        .stroke(LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .scaleEffect(give)
        .focused($focused)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .offset(y: hovering && !selected && !reduceMotion ? -1 : 0)
        .animation(Theme.Motion.spring, value: selected)
        .onChange(of: picked) { _, n in if n > 0 { pickedMoment() } }
        .onDisappear { onceWork?.cancel() }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The card gives a little and springs back, the outline draws round it, and
    /// its demo plays once (about a loop and a half), in its own character.
    private func pickedMoment() {
        guard !reduceMotion else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { outline = 0; give = 0.95 }
        withAnimation(.easeOut(duration: 0.5).delay(0.04)) { outline = 1 }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.5)) { give = 1 }
        guard demo != nil else { return }
        playingOnce = true
        onceWork?.cancel()
        let work = DispatchWorkItem { playingOnce = false }
        onceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9, execute: work)
    }
}

/// A card's demo, drawn on its own timeline only while it plays.
private struct DemoView: View {
    let demo: ChoiceDemo
    let tint: Color
    let playing: Bool
    var frozenAt: Double? = nil
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing || frozenAt != nil)) { tl in
            let t = frozenAt ?? (playing ? tl.date.timeIntervalSince(start) : 0.55)
            Canvas { ctx, size in Self.draw(demo, t: t, tint: tint, in: &ctx, size: size) }
        }
        .onChange(of: playing) { _, now in if now { start = Date() } }
        .accessibilityHidden(true)
    }

    private static func draw(_ demo: ChoiceDemo, t: Double, tint: Color, in ctx: inout GraphicsContext, size: CGSize) {
        switch demo {
        case .pointer(let speed):
            // A dot crossing a line, faster for a faster preset, with a short trail.
            let y = size.height / 2
            var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(line, with: .color(tint.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            let period = 2.6 / max(speed / 3, 0.3)
            let f = (t.truncatingRemainder(dividingBy: period)) / period
            let x = size.width * CGFloat(f)
            let trail = min(size.width * 0.35, CGFloat(speed) * 6)
            ctx.fill(Path(roundedRect: CGRect(x: x - trail, y: y - 1.5, width: trail, height: 3), cornerRadius: 1.5),
                     with: .linearGradient(Gradient(colors: [tint.opacity(0), tint.opacity(0.6)]),
                                           startPoint: CGPoint(x: x - trail, y: y), endPoint: CGPoint(x: x, y: y)))
            ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(tint))
        case .scroll, .follow:
            // A little list, moved the way the mode moves a page.
            let rowH: CGFloat = 9
            let offset = CGFloat(Self.scrollOffset(demo, t: t)) * rowH
            ctx.clip(to: Path(CGRect(origin: .zero, size: size)))
            let first = Int(floor(offset / rowH)) - 1
            for i in first...(first + Int(size.height / rowH) + 2) {
                let y = CGFloat(i) * rowH - offset
                let w = size.width * (0.35 + 0.45 * CGFloat(abs((i * 37) % 10)) / 10)
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: y + 2.5, width: w, height: 4), cornerRadius: 2),
                         with: .color(tint.opacity(i % 3 == 0 ? 0.55 : 0.3)))
            }
            // Fade the list out at the top and bottom edges.
            ctx.blendMode = .destinationOut
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 6)),
                     with: .linearGradient(Gradient(colors: [.black, .clear]), startPoint: .zero, endPoint: CGPoint(x: 0, y: 6)))
            ctx.fill(Path(CGRect(x: 0, y: size.height - 6, width: size.width, height: 6)),
                     with: .linearGradient(Gradient(colors: [.clear, .black]), startPoint: CGPoint(x: 0, y: size.height - 6),
                                           endPoint: CGPoint(x: 0, y: size.height)))
        }
    }

    /// Rows travelled after `t` seconds of the demo's loop.
    static func scrollOffset(_ demo: ChoiceDemo, t: Double) -> Double {
        switch demo {
        case .scroll(.native):
            // Plain steps: one row at a time.
            return floor(t / 0.32)
        case .scroll(.flywheel):
            // A spin every 1.6 s, then friction slows the page: it coasts.
            let period = 1.6
            let n = floor(t / period), u = t - n * period
            return n * 6 + 6 * (1 - exp(-u / 0.32))
        case .scroll(.follow):
            // The page follows the ring exactly and stops when it stops.
            let period = 1.2
            let n = floor(t / period), u = min((t - n * period) / 0.55, 1)
            return n * 3 + 3 * (u < 1 ? u : 1)
        case .follow(let reach, let coast):
            let period = 1.5
            let n = floor(t / period), u = t - n * period
            let push = 2 + 4 * reach
            let follow = push * min(u / 0.45, 1)
            let glide = coast && u > 0.45 ? push * 0.8 * (1 - exp(-(u - 0.45) / 0.25)) : 0
            return n * push * (coast ? 1.8 : 1) + follow + glide
        case .pointer:
            return 0
        }
    }
}

/// For cards and chips: compresses a little while pressed and springs back.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration)
    }

    private struct PressBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.45)
                .animation(configuration.isPressed ? .easeOut(duration: 0.08) : .spring(response: 0.3, dampingFraction: 0.55),
                           value: configuration.isPressed)
                .focusEffectDisabled(false)
        }
    }
}

// MARK: - Pointer speed presets

/// Precise / macOS / Fast / Turbo: used on the Pointer tab and in the Welcome Tour.
/// The chosen one is whichever matches the speed right now.
struct PointerPresetRow: View {
    @Binding var speed: Double

    private static let presets: [ChoiceStrip<Double>.Choice] = [
        .init(value: 1.5, title: LocalizedStringKey("Precise"), symbol: "scope", demo: .pointer(1.5)),
        .init(value: 3, title: LocalizedStringKey("macOS"), symbol: "applelogo", demo: .pointer(3)),
        .init(value: 5, title: LocalizedStringKey("Fast"), symbol: "hare", demo: .pointer(5)),
        .init(value: 7.5, title: LocalizedStringKey("Turbo"), symbol: "bolt", demo: .pointer(7.5)),
    ]

    var body: some View {
        ChoiceStrip(choices: Self.presets, isSelected: { abs(speed - $0) < 0.01 }, tint: Theme.ball) { speed = $0 }
    }
}
