import AppKit
import Observation
import SwiftUI

/// The search palette (⌘K or ⌘F): a glass panel over the main window. Type to
/// find any setting, action, button, badge or help page; ↑↓ to move, Return to
/// run or jump, Esc to close. With nothing typed it shows what you picked
/// lately. Opening it builds the index (`SearchIndex`); closed, it costs nothing.
@Observable
final class CommandPalette {
    static let shared = CommandPalette()
    private(set) var isOpen = false
    /// The index as it was when the palette opened.
    private(set) var items: [PaletteItem] = []

    /// ⌘K, ⌘F, the View menu: shows the main window with the palette over it.
    func open() {
        guard LaunchExperience.shared.show == nil else { return }
        (NSApp.delegate as? AppDelegate)?.showWindow()
        let model = AppModel.shared
        // A card asked for by search is the one that shows.
        model.showingShortcuts = false
        items = SearchIndex.items(model)
        if !isOpen {
            withAnimation(Theme.Motion.fade) { isOpen = true }
        }
    }

    func toggle() { isOpen ? close() : open() }

    func close() {
        guard isOpen else { return }
        withAnimation(Theme.Motion.fade) { isOpen = false }
    }

    /// Runs an item and remembers it for next time.
    @MainActor func run(_ item: PaletteItem) {
        PaletteRecents.used(item.id)
        item.run()
    }

    /// Renders and the self-test: the index without opening anything.
    func prepare(_ model: AppModel) {
        items = SearchIndex.items(model)
    }
}

/// Where the palette's results go.
enum PaletteRouter {
    static func close() { CommandPalette.shared.close() }

    /// Shows a setting: its page or Settings tab, scrolled to its row, which glows for a moment.
    /// One that's only in another scroll mode points out the mode picker instead, and says so.
    static func go(_ f: Findable, after: (() -> Void)? = nil) {
        close()
        let model = AppModel.shared
        var spot = f.id
        if !f.modes.isEmpty, case .tab(.scroll) = f.place, !f.modes.contains(model.config.scrollMode) {
            spot = Findable.scrollMode.id
            let modes = ListFormatter.localizedString(byJoining: f.modes.map(\.title))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                model.show(.init(symbol: "arrow.up.and.down.circle",
                                 text: String(localized: "\(f.title) is part of \(modes) scrolling. Pick it above to see it.",
                                              comment: "Toast after searching for a scroll setting from another mode; the first %@ is the setting, the second a mode like Flywheel")))
            }
        }
        switch f.place {
        case .tab(let tab):
            show(tab, spotlight: spot, then: after)
        case .settings(let pane):
            (NSApp.delegate as? AppDelegate)?.showSettings(pane, spotlight: spot)
        }
    }

    /// The main window on `tab`, then the row pointed out once the page has faded in.
    static func show(_ tab: GlideTab, spotlight: String, then: (() -> Void)? = nil) {
        let model = AppModel.shared
        (NSApp.delegate as? AppDelegate)?.showWindow()
        let already = TabPage.showing == [tab]
        model.requestTab(tab)
        DispatchQueue.main.asyncAfter(deadline: .now() + (already ? 0.12 : 0.38)) {
            SettingsSpotlight.shared.show(spotlight)
            then?()
        }
    }

    static func openAppSetup(_ id: String) {
        close()
        AppModel.shared.selectedProfileID = id
        show(.apps, spotlight: Findable.appSetupID(id))
    }

    static func openButton(_ index: Int) {
        close()
        show(.buttons, spotlight: Findable.buttonID(index)) {
            if index != 0 { PageRequests.shared.ask { $0.buttonPicker = index } }
        }
    }

    static func openButtonPreset(_ id: String) {
        close()
        show(.buttons, spotlight: Findable.buttonPresets.id) {
            PageRequests.shared.ask { $0.presetPreview = id }
        }
    }

    static func openBadge(_ id: String) {
        close()
        show(.overview, spotlight: Findable.badges.id) {
            PageRequests.shared.ask { $0.openBadge = id }
        }
    }

    /// Ten seconds at a pointer speed, with the countdown under the presets.
    static func tryPointerPreset(_ speed: Double) {
        close()
        let model = AppModel.shared
        show(.pointer, spotlight: Findable.pointerPresets.id) {
            let old = model.config.trackingSpeed
            TryPreview.shared.begin(id: PointerPresetRow.tryID, was: old.twoDigits, what: PointerPresetRow.name(speed),
                                    countdown: true) { model.config.trackingSpeed = old }
            withAnimation(Theme.Motion.spring) { model.config.trackingSpeed = speed }
        }
    }
}

// MARK: - The palette

struct CommandPaletteView: View {
    let model: AppModel
    @State private var query = CommandPaletteView.sandboxQuery ?? ""
    @State private var selected: String?
    @State private var hovered: String?
    /// Moved with the keyboard: keep the selected row in view.
    @State private var keyed = 0
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let palette = CommandPalette.shared

    /// Renders: a search already typed, and the row picked with the arrow keys.
    nonisolated(unsafe) static var sandboxQuery: String?
    nonisolated(unsafe) static var sandboxSelectedIndex: Int?

    static let width: CGFloat = 620

    var body: some View {
        let results = PaletteResults.search(query, in: palette.items, recent: PaletteRecents.ids)
        let flat = results.flat
        let current = selected.flatMap { id in flat.first { $0.id == id } } ?? flat.first
        ZStack(alignment: .top) {
            Theme.scrim.opacity(0.7)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { palette.close() }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                field(flat: flat, current: current)
                Hairline()
                if results.isEmpty {
                    nothingFound
                } else {
                    list(results, current: current)
                }
                Hairline()
                footer(current)
            }
            .frame(width: Self.width)
            .background { LitCardBackground(radius: 18) }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.top, 70)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
        .onAppear {
            if let i = Self.sandboxSelectedIndex, flat.indices.contains(i) { selected = flat[i].id }
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onChange(of: query) { _, _ in selected = nil }
        .accessibilityAddTraits(.isModal)
    }

    // MARK: The field

    private func field(flat: [PaletteItem], current: PaletteItem?) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.ball)
                .accessibilityHidden(true)
            TextField(String(localized: "Search settings, actions, buttons and help", comment: "Search palette's placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($fieldFocused)
                .onSubmit { if let current { palette.run(current) } }
                .onKeyPress(.downArrow) { move(1, in: flat, from: current); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: flat, from: current); return .handled }
                .onKeyPress(.escape) {
                    if query.isEmpty { palette.close() } else { query = "" }
                    return .handled
                }
                .onKeyPress(keys: [.return], phases: .down) { press in
                    // ⌥↩ tries a pointer speed for 10 s instead of setting it (the item reads ⌥ itself).
                    guard press.modifiers.contains(.option), let current else { return .ignored }
                    palette.run(current)
                    return .handled
                }
                .accessibilityLabel(Text("Search Glideball", comment: "VoiceOver: the search palette's field"))
            if !query.isEmpty {
                Button {
                    query = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
                .transition(.opacity)
            }
            KeyCap(label: "esc")
                .opacity(0.8)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .animation(Theme.Motion.fade, value: query.isEmpty)
    }

    private func move(_ by: Int, in flat: [PaletteItem], from current: PaletteItem?) {
        guard !flat.isEmpty else { return }
        let i = current.flatMap { c in flat.firstIndex { $0.id == c.id } } ?? 0
        let next = min(max(i + by, 0), flat.count - 1)
        selected = flat[next].id
        keyed &+= 1
    }

    // MARK: Results

    private func list(_ results: PaletteResults, current: PaletteItem?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(results.sections) { section in
                        Text(verbatim: query.isEmpty && PaletteRecents.ids.isEmpty
                             ? String(localized: "Suggestions", comment: "Search palette group, before anything has been searched for")
                             : section.group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, section.group == results.sections.first?.group ? 4 : 10)
                            .padding(.bottom, 3)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.items) { item in
                            row(item, selected: item.id == current?.id)
                                .id(item.id)
                        }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.automatic)
            .frame(height: min(CGFloat(results.flat.count) * 50 + CGFloat(results.sections.count) * 26 + 16, 392))
            .onChange(of: keyed) { _, _ in
                if let id = current?.id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
            }
        }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        let tint = item.part?.color ?? Theme.ball
        return Button {
            palette.run(item)
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(item.part == nil ? AnyShapeStyle(Theme.hoverFill) : AnyShapeStyle(tint.opacity(selected ? 0.24 : 0.15)))
                    Image(systemName: item.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(item.part == nil ? AnyShapeStyle(selected ? AnyShapeStyle(Theme.ball) : AnyShapeStyle(.secondary))
                                                          : AnyShapeStyle(tint))
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: item.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if !item.detail.isEmpty {
                        Text(verbatim: item.detail)
                            .font(Theme.Font.hint)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let trailing = item.trailing {
                    HStack(spacing: 4) {
                        if item.isOn {
                            Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold))
                        }
                        Text(verbatim: trailing)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(item.isOn ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .fixedSize()
                }
                if selected {
                    Image(systemName: "return")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.hoverFill))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                if selected {
                    shape.fill(LinearGradient(colors: [Theme.ball.opacity(0.20), Theme.ball.opacity(0.11)], startPoint: .top, endPoint: .bottom))
                        .overlay(shape.strokeBorder(Theme.ball.opacity(0.35), lineWidth: 1))
                } else if hovered == item.id {
                    shape.fill(Theme.hoverFill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in hovered = h ? item.id : (hovered == item.id ? nil : hovered) }
        .accessibilityLabel(Text(verbatim: item.title))
        .accessibilityHint(Text(verbatim: item.detail))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var nothingFound: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing for “\(query)”", comment: "Search palette: no results; %@ is what was typed")
                .font(Theme.Font.emphasis)
            Text("Try a setting’s name, like speed, scroll or color, or something to do, like pause.", comment: "Search palette: no results")
                .font(Theme.Font.hint)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 30)
    }

    private func footer(_ current: PaletteItem?) -> some View {
        HStack(spacing: 14) {
            hint(["↑", "↓"], String(localized: "Move", comment: "Search palette footer: the arrow keys"))
            hint(["↩"], current?.findable != nil || current?.group == .buttons || current?.group == .badges
                 ? String(localized: "Go there", comment: "Search palette footer: Return jumps to a setting")
                 : String(localized: "Run", comment: "Search palette footer: Return runs an action"))
            if current?.id == "cmd:pointer-speed-set" {
                hint(["⌥", "↩"], String(localized: "Try for 10 s", comment: "Search palette footer"))
            }
            Spacer(minLength: 8)
            hint(["esc"], String(localized: "Close", comment: "Search palette footer: Esc closes it"))
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
    }

    private func hint(_ keys: [String], _ text: String) -> some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { KeyCap(label: $0) }
            }
            Text(verbatim: text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
