import AppKit
import SwiftUI

/// Buttons, read as a map: the trackball large at the top with each pad
/// labelled by what it does (click a pad or its label, or press the real
/// button, to change it), ready-made presets under it, then the list of
/// buttons and the combos. Every "what does this do" opens the same picker.
struct ButtonsView: View {
    @Bindable var model: AppModel
    /// The pad whose picker is open (from the map, its label, or a real press).
    @State private var openPad: Int?
    /// A preset being looked at before it's applied.
    @State private var preview: ButtonPreset?

    /// Renders: draw the map previewing this preset.
    nonisolated(unsafe) static var sandboxPreview: String?

    private let buttons: [(index: Int, name: String, normally: String)] = (0..<4).map {
        ($0, AppModel.buttonName($0), AppModel.buttonDefault($0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            ButtonMap(model: model, openPad: $openPad, preview: preview)

            if model.assignStep != .idle {
                AssignPanel(model: model)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            PresetStrip(model: model, preview: $preview)

            SectionBlock(title: "Your buttons", caption: "Press a button on your trackball: its row lights up.",
                         dividerInset: ButtonRow.dividerInset) {
                ForEach(buttons, id: \.index) { b in
                    ButtonRow(index: b.index, name: b.name, normally: b.normally,
                              isPressed: model.pressed.contains(b.index), model: model,
                              action: Binding(
                                get: { model.config.buttons[b.index] ?? .system },
                                set: { model.config.buttons[b.index] = $0 }))
                }
            }

            CombosCard(model: model)
        }
        .animation(Theme.Motion.spring, value: model.assignStep)
        .onAppear {
            if let id = Self.sandboxPreview { preview = ButtonPreset.all.first { $0.id == id } }
        }
        // While you're on this page with Glideball in front, a real button answers with a soft
        // click down and a lower one up (Sounds on), and a quick press of one of the three free
        // buttons opens its picker. Not the primary button: that's the one you click this
        // window with, and it would tick (and open things) at every click.
        .onChange(of: model.pressed) { old, new in
            guard model.windowIsKey else { return }
            let down = new.subtracting(old).subtracting([0]), up = old.subtracting(new).subtracting([0])
            if !down.isEmpty { Sounds.shared.detent(pitch: 1.05, volume: 0.45, kind: .buttons) }
            else if !up.isEmpty { Sounds.shared.detent(pitch: 0.8, volume: 0.3, kind: .buttons) }
            // One button let go, alone: open its picker (a combo opens nothing).
            if old.count == 1, new.isEmpty, let b = old.first, b != 0, openPad == nil,
               model.assignStep == .idle, preview == nil {
                openPad = b
            }
        }
    }
}

// MARK: - The map

/// The trackball, large, with a label beside each pad saying what it does.
/// The left pads' labels sit on the left, the right pads' on the right, each
/// joined to its pad by a short line. Clicking a pad or a label opens its
/// picker. While a preset is previewed, the labels show the preset's actions
/// (the ones that would change ringed in amber).
struct ButtonMap: View {
    let model: AppModel
    @Binding var openPad: Int?
    let preview: ButtonPreset?
    @Environment(ShellState.self) private var shell: ShellState?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let side: CGFloat = 214
        VStack(alignment: .leading, spacing: Theme.Space.titleToGroup) {
            SectionTitle(title: nil, caption: preview == nil
                         ? "Click a button here, or press it on your trackball, to choose what it does."
                         : "Previewing a preset. Nothing changes until you apply it.") {
                if model.assignStep == .idle {
                    Button {
                        model.beginAssign()
                    } label: {
                        Label("Quick Assign", systemImage: "hand.point.up.left")
                    }
                    .controlSize(.small)
                    .help("Press a trackball button (or two or three together), then the keyboard shortcut it should send")
                }
            }
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .trailing, spacing: side * 0.36) {
                    callout(2, edge: .leading)
                    callout(0, edge: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [Theme.orbBlue.opacity(scheme == .dark ? 0.30 : 0.16),
                                                      Theme.orbViolet.opacity(scheme == .dark ? 0.12 : 0.06), .clear],
                                             center: .center, startRadius: side * 0.1, endRadius: side * 0.75))
                        .frame(width: side * 1.5, height: side * 1.5)
                        .allowsHitTesting(false)
                    TrackballView(feed: model.live, pressed: model.pressed, look: TrackballLook.of(model))
                        .frame(width: side, height: side)
                    PadTargets(side: side, openPad: $openPad, highlighted: preview.map(changedPads) ?? [],
                               gesturePads: Set((1..<4).filter { (preview?.action(for: $0) ?? current($0)).isGesture }),
                               heldPads: model.modes.gestureHeld ? Set(model.modes.gestureButtons) : [])
                    GestureHeldOverlay(model: model)
                        .frame(width: side, height: side)
                }
                .frame(width: side + 24, height: side)
                .onScrollVisibilityChange(threshold: 0.35) { visible in shell?.heroOnScreen = visible }
                .onDisappear { shell?.heroOnScreen = false }
                VStack(alignment: .leading, spacing: side * 0.36) {
                    callout(3, edge: .trailing)
                    callout(1, edge: .trailing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
        }
    }

    private func current(_ b: Int) -> ButtonAction { model.config.buttons[b] ?? .system }

    private func changedPads(_ p: ButtonPreset) -> Set<Int> {
        Set((1..<4).filter { p.changes($0, from: current($0)) })
    }

    @ViewBuilder
    private func callout(_ b: Int, edge: HorizontalEdge) -> some View {
        let shown = preview?.action(for: b) ?? current(b)
        let changing = preview.map { changedPads($0).contains(b) } ?? false
        PadCallout(button: b, action: shown, edge: edge, lit: model.pressed.contains(b), previewing: preview != nil,
                   changing: changing,
                   isOpen: Binding(get: { openPad == b }, set: { openPad = $0 ? b : nil })) { new in
            model.config.buttons[b] = new
        }
    }
}

/// One pad's label on the map: which pad it is, and what it does now, as a
/// button that opens the picker. The bottom-left one is locked to left click.
private struct PadCallout: View {
    let button: Int
    let action: ButtonAction
    let edge: HorizontalEdge
    let lit: Bool
    let previewing: Bool
    let changing: Bool
    @Binding var isOpen: Bool
    let onPick: (ButtonAction) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            if edge == .trailing { connector }
            Button {
                if button != 0 && !previewing { isOpen = true }
            } label: {
                VStack(alignment: edge == .leading ? .trailing : .leading, spacing: 3) {
                    Text(verbatim: AppModel.buttonName(button))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if button == 0 {
                            Image(systemName: "lock.fill").font(.system(size: 9.5)).foregroundStyle(.secondary)
                        }
                        ActionLabel(action: action.isNormal(for: button) ? ButtonAction.normal(for: button) : action, chevron: false)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
                    shape.fill(lit ? Theme.buttons.opacity(0.22) : hovering && button != 0 && !previewing ? Theme.hoverFill : Theme.groupFill)
                        .pixelBorder(shape, changing ? Theme.buttons : lit ? Theme.buttons.opacity(0.8) : Theme.groupBorder)
                        .shadow(color: lit || changing ? Theme.buttons.opacity(0.45) : .clear, radius: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())

            .onHover { hovering = $0 }
            .help(button == 0 ? String(localized: "Your primary click stays a left click, so Glideball can never lock you out.")
                              : String(localized: "Choose what this button does"))
            .accessibilityLabel(Text(verbatim: "\(AppModel.buttonName(button)): \(action.title)"))
            .popover(isPresented: $isOpen, arrowEdge: edge == .leading ? .leading : .trailing) {
                ActionPickerPanel(current: action, button: button) { onPick($0) }
            }
            if edge == .leading { connector }
        }
        .animation(lit ? Theme.Motion.pressIn : Theme.Motion.pressOut, value: lit)
        .animation(Theme.Motion.spring, value: changing)
    }

    /// The short line from the label to its pad, ending in a dot at the pad.
    private var connector: some View {
        HStack(spacing: 0) {
            if edge == .trailing { dot }
            Rectangle()
                .fill(lit || changing ? Theme.buttons.opacity(0.8) : Theme.hairline)
                .frame(width: 22, height: 1)
            if edge == .leading { dot }
        }
        .accessibilityHidden(true)
    }

    private var dot: some View {
        Circle().fill(lit || changing ? Theme.buttons : Theme.hairline).frame(width: 5, height: 5)
    }
}

/// Clickable corners over the trackball: hovering one rings its pad, and
/// clicking it opens that pad's picker (not the locked primary).
private struct PadTargets: View {
    let side: CGFloat
    @Binding var openPad: Int?
    /// Pads to ring in amber (a preset would change them).
    let highlighted: Set<Int>
    /// Pads that are gestures (a small four-way mark), and the one held right now.
    var gesturePads: Set<Int> = []
    var heldPads: Set<Int> = []
    @State private var hovered: Int?

    var body: some View {
        // macOS numbers them 0 bottom left, 1 bottom right, 2 top left, 3 top right.
        let rows: [[Int]] = [[2, 3], [0, 1]]
        VStack(spacing: 0) {
            ForEach(0..<2, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(rows[r], id: \.self) { b in
                        let lit = hovered == b || highlighted.contains(b) || openPad == b
                        RoundedRectangle(cornerRadius: side * 0.12, style: .continuous)
                            .strokeBorder(Theme.buttons.opacity(lit ? 0.85 : 0), lineWidth: 1.5)
                            .shadow(color: Theme.buttons.opacity(lit ? 0.5 : 0), radius: 6)
                            .padding(side * 0.03)
                            .overlay(alignment: b == 2 ? .topLeading : b == 3 ? .topTrailing : b == 0 ? .bottomLeading : .bottomTrailing) {
                                if gesturePads.contains(b) {
                                    GesturePadMark(size: side * 0.09, lit: heldPads.contains(b))
                                        .padding(side * 0.075)
                                }
                            }
                            .contentShape(Rectangle())
                            .onHover { h in
                                if b != 0 { hovered = h ? b : (hovered == b ? nil : hovered) }
                            }
                            .onTapGesture { if b != 0 { openPad = b } }
                            .help(b == 0 ? String(localized: "Your primary click stays a left click, so Glideball can never lock you out.")
                                         : String(localized: "Choose what this button does"))
                    }
                }
            }
        }
        .frame(width: side, height: side)
        // Only the pads, not the ball and ring in the middle.
        .mask {
            Rectangle().overlay(Circle().frame(width: side * 0.84, height: side * 0.84).blendMode(.destinationOut))
                .compositingGroup()
        }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .accessibilityHidden(true)
    }
}

// MARK: - Presets

/// Ready-made sets, each a card with a tiny map of what it does. Clicking one
/// previews it on the map above; Apply sets every button and combo at once
/// (after a backup, with Undo in the toast).
struct PresetStrip: View {
    let model: AppModel
    @Binding var preview: ButtonPreset?

    var body: some View {
        let current = model.config.matchingPreset
        VStack(alignment: .leading, spacing: Theme.Space.titleToGroup) {
            SectionTitle(title: "Presets", caption: "Sets all your buttons and a few combos at once. You can undo it.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(ButtonPreset.all) { p in
                    PresetCard(preset: p, applied: current?.id == p.id, selected: preview?.id == p.id) {
                        withAnimation(Theme.Motion.spring) { preview = preview?.id == p.id ? nil : p }
                        Sounds.shared.detent(pitch: 1.1, volume: 0.45)
                    }
                }
            }
            if let p = preview {
                PresetConfirm(preset: p, config: model.config, applied: current?.id == p.id,
                              cancel: { withAnimation(Theme.Motion.spring) { preview = nil } },
                              apply: {
                                  withAnimation(Theme.Motion.spring) {
                                      model.applyPreset(p)
                                      preview = nil
                                  }
                              })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct PresetCard: View {
    let preset: ButtonPreset
    let applied: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                MiniPadMap(actions: (0..<4).map(preset.action(for:)), size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: preset.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if applied {
                        Label("In use", systemImage: "checkmark")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.ball)
                    } else {
                        Text(verbatim: summary)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                shape.fill(selected ? Theme.buttons.opacity(0.12) : hovering ? Theme.hoverFill : Theme.groupFill)
                    .pixelBorder(shape, selected ? Theme.buttons : applied ? Theme.ball.opacity(0.6) : Theme.groupBorder)
                    .shadow(color: selected ? Theme.buttons.opacity(0.35) : .clear, radius: 8)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .help(preset.detail)
        .accessibilityLabel(Text(verbatim: preset.title + ". " + preset.detail))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// "Back · Forward": the top buttons, which is what most presets are about.
    private var summary: String {
        let top = [2, 3].map { preset.action(for: $0) }
        if top.allSatisfy({ $0 == .system }) { return String(localized: "Out of the box", comment: "Preset card: the stock preset") }
        if top.contains(where: \.isGesture) { return String(localized: "Hold and roll", comment: "Preset card: a preset whose buttons are gestures") }
        return top.map(\.title).joined(separator: " · ")
    }
}

/// Under the presets while one is previewed: what it does, what it changes,
/// and Apply.
private struct PresetConfirm: View {
    let preset: ButtonPreset
    let config: GlideConfig
    let applied: Bool
    let cancel: () -> Void
    let apply: () -> Void

    var body: some View {
        RowGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: Theme.Space.symbolGap) {
                    RowSymbol(symbol: preset.symbol, tint: Theme.buttons)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: preset.title).font(Theme.Font.emphasis)
                        Text(verbatim: preset.detail)
                            .font(Theme.Font.hint)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !preset.chords.isEmpty {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(preset.chords) { chord in
                            HStack(spacing: 6) {
                                ButtonChips(buttons: chord.buttons)
                                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                                ActionLabel(action: chord.action, chevron: false)
                            }
                            .padding(.leading, 3)
                            .padding(.trailing, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.groupFill))
                            .pixelBorder(Capsule(), Theme.groupBorder)
                        }
                    }
                    .padding(.leading, Theme.Space.symbolColumn + Theme.Space.symbolGap)
                }
                HStack(spacing: 8) {
                    Text(verbatim: changes)
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Cancel", action: cancel).controlSize(.small)
                    Button(applied ? String(localized: "Already in Use") : String(localized: "Apply \(preset.title)", comment: "Button; %@ is a preset name"),
                           action: apply)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.ball)
                        .controlSize(.small)
                        .disabled(applied)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, Theme.Space.rowHorizontal)
            .padding(.vertical, 12)
        }
    }

    private var changes: String {
        let buttons = (1..<4).filter { preset.changes($0, from: config.buttons[$0] ?? .system) }.count
        let combosNow = config.chords.count
        if buttons == 0 && Set(preset.chords.map { "\($0.buttons)\($0.action)" }) == Set(config.chords.map { "\($0.buttons)\($0.action)" }) {
            return String(localized: "Your buttons already match it.")
        }
        let b = buttons == 0 ? String(localized: "Keeps your buttons", comment: "Preset preview, before “replaces your 2 combos with 3”")
            : buttons == 1 ? String(localized: "Changes 1 button", comment: "Preset preview") : String(localized: "Changes \(Int(buttons)) buttons", comment: "Preset preview")
        let c: String?
        if preset.chords.isEmpty {
            c = combosNow == 0 ? nil : String(localized: "removes your \(Int(combosNow)) combos", comment: "Preset preview, after “Changes 2 buttons,”")
        } else if combosNow == 0 {
            c = String(localized: "adds \(preset.chords.count) combos", comment: "Preset preview, after “Changes 2 buttons,”")
        } else {
            c = String(localized: "replaces your \(Int(combosNow)) combos with \(preset.chords.count)", comment: "Preset preview, after “Changes 2 buttons,”")
        }
        return c.map { "\(b), \($0)" } ?? b
    }
}

/// A trackball's four pads, tiny, each with the icon of what it does. Pads
/// that do something other than their normal click are amber.
struct MiniPadMap: View {
    /// What buttons 0…3 do.
    let actions: [ButtonAction]
    var size: CGFloat = 46

    var body: some View {
        let order = [2, 3, 0, 1]
        let gap = size * 0.06
        let pad = (size - gap * 3) / 2
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.13), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
                .pixelBorder(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous), Color.white.opacity(0.12))
            VStack(spacing: gap) {
                ForEach(0..<2, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(0..<2, id: \.self) { c in
                            let b = order[r * 2 + c]
                            let a = b < actions.count ? actions[b] : .system
                            let custom = b != 0 && a != .system
                            RoundedRectangle(cornerRadius: pad * 0.3, style: .continuous)
                                .fill(custom ? AnyShapeStyle(LinearGradient(colors: [Color(red: 1, green: 0.8, blue: 0.45), Theme.buttons],
                                                                            startPoint: .top, endPoint: .bottom))
                                             : AnyShapeStyle(Color.white.opacity(0.10)))
                                .overlay {
                                    if custom {
                                        Image(systemName: a.symbol)
                                            .font(.system(size: pad * 0.42, weight: .bold))
                                            .foregroundStyle(Color.black.opacity(0.7))
                                    }
                                }
                                .frame(width: pad, height: pad)
                        }
                    }
                }
            }
            Circle()
                .fill(RadialGradient(colors: [Theme.orbCyan, Theme.orbBlue, Theme.orbViolet], center: UnitPoint(x: 0.35, y: 0.3),
                                     startRadius: 0, endRadius: size * 0.16))
                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: size * 0.025))
                .frame(width: size * 0.3, height: size * 0.3)
        }
        .frame(width: size, height: size)
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }
}

// MARK: - The list

/// A button's row: which corner it is, what it does normally, and what it does now.
/// Lights up amber while the real button is down (80 ms in, 250 ms out).
struct ButtonRow: View {
    let index: Int
    let name: String
    let normally: String
    let isPressed: Bool
    /// For a gesture button's editor (what's held right now, Try it).
    var model: AppModel? = nil
    @Binding var action: ButtonAction

    @State private var pulse = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let dividerInset = Theme.Space.rowHorizontal + 26 + Theme.Space.symbolGap

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if case .gesture(let g) = action, index != 0 {
                GestureEditor(model: model, button: index,
                              gesture: Binding(get: { g }, set: { action = .gesture($0) }))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Theme.Motion.spring, value: action.isGesture)
    }

    private var row: some View {
        HStack(spacing: Theme.Space.symbolGap) {
            CornerGlyph(index: index, lit: isPressed)

            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .medium))
                Text(index == 0 ? String(localized: "Your primary click stays a left click, so Glideball can never lock you out.")
                                : String(localized: "Normally: \(normally)"))
                    .font(Theme.Font.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if index == 0 {
                Label("Left click", systemImage: "lock.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(TrailingIconLabelStyle())
                    .help("Your primary click stays a left click, so Glideball can never lock you out.")
                    .accessibilityLabel("Left click · locked")
            } else {
                ActionPickerButton(action: action, button: index) { action = $0 }
            }
        }
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.vertical, Theme.Space.rowVertical)
        .frame(minHeight: Theme.Space.rowMinHeight)
        .background {
            ZStack(alignment: .leading) {
                Theme.buttons.opacity(isPressed ? 0.16 : 0)
                // The edge nearest the trackball lights first…
                LinearGradient(colors: [Theme.buttons.opacity(0.9), Theme.buttons.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 3)
                    .opacity(isPressed ? 1 : 0)
                    .shadow(color: Theme.buttons, radius: 6)
                // …and a pulse of light runs across the row from that side.
                GeometryReader { g in
                    LinearGradient(colors: [Theme.buttons.opacity(0), Theme.buttons.opacity(0.35), Theme.buttons.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 140)
                        .offset(x: -140 + (g.size.width + 140) * pulse)
                        .opacity(pulse < 1 && pulse > 0 ? 1 : 0)
                }
            }
            .allowsHitTesting(false)
        }
        .animation(isPressed ? Theme.Motion.pressIn : Theme.Motion.pressOut, value: isPressed)
        .onChange(of: isPressed) { _, down in
            guard down, !reduceMotion else { return }
            pulse = 0.001
            withAnimation(.easeOut(duration: 0.45)) { pulse = 1 }
        }
    }
}

/// Which corner a button is: a little 2×2 of the trackball's pads with that
/// one filled (amber while the real button is down).
struct CornerGlyph: View {
    let index: Int
    var lit = false

    var body: some View {
        // macOS numbers them 0 bottom left, 1 bottom right, 2 top left, 3 top right.
        let order = [2, 3, 0, 1]
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<2, id: \.self) { col in
                        let b = order[row * 2 + col]
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(b == index ? (lit ? AnyShapeStyle(Theme.buttons) : AnyShapeStyle(.secondary))
                                             : AnyShapeStyle(Theme.hairline))
                            .frame(width: 9, height: 9)
                            .shadow(color: b == index && lit ? Theme.buttons : .clear, radius: 4)
                            .scaleEffect(b == index && lit ? 0.88 : 1)
                    }
                }
            }
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}

/// Text first, then the icon (for "Left click 🔒").
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.title
            configuration.icon.font(.system(size: 10))
        }
    }
}
