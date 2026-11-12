import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Apps: setups Glideball switches to while a particular app is in front. One
/// list of them (each with what it changes from the main setup, the one in use
/// marked), and below it the editor for the one that's selected.
struct AppsView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var profiles: [AppProfile] { model.config.appProfiles }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            if profiles.isEmpty {
                emptyState
            } else {
                setupList
                if let id = model.selectedProfileID, profiles.contains(where: { $0.id == id }) {
                    ProfileEditor(model: model, profileID: id)
                        .id(id)
                }
            }
        }
        .onAppear {
            model.isEditingProfiles = true
            ensureSelection()
        }
        .onDisappear { model.isEditingProfiles = false }
        .onChange(of: profiles.map(\.id)) { _, _ in ensureSelection() }
    }

    /// Keeps a setup selected (and so previewed) whenever there is one.
    private func ensureSelection() {
        if !profiles.contains(where: { $0.id == model.selectedProfileID }) {
            model.selectedProfileID = profiles.first?.id
        }
    }

    private var setupList: some View {
        let main = model.config
        let activeID = model.activeProfile?.id
        return SectionBlock(title: "App setups",
                            caption: "When one of these apps is in front, Glideball switches to its setup. Anything left on “Main setup” follows your main settings.",
                            dividerInset: AppSetupRow.dividerInset,
                            accessory: { AddAppMenu(model: model) }) {
            ForEach(profiles) { p in
                AppSetupRow(profile: p, summary: p.summary(comparedTo: main),
                            selected: p.id == model.selectedProfileID, active: p.id == activeID) {
                    withAnimation(Theme.Motion.respecting(reduceMotion, Theme.Motion.spring)) { model.selectedProfileID = p.id }
                }
            }
        }
    }

    private var emptyState: some View {
        SectionBlock(title: "App setups") {
            VStack(spacing: 14) {
                Image(systemName: "macwindow")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(spacing: 4) {
                    Text("Give an app its own setup")
                        .font(Theme.Font.emphasis)
                    Text("Glideball switches to it whenever that app is in front, and back when you leave.")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 560)
                AddAppMenu(model: model, prominent: true)
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - The list

/// One app setup in the list: its icon, name, what it changes, and whether
/// it's the one in effect now. The selected one is the one open below.
private struct AppSetupRow: View {
    let profile: AppProfile
    let summary: String
    let selected: Bool
    let active: Bool
    let select: () -> Void

    private static let iconSize: CGFloat = 28
    /// Where the hairlines start: past the row's inset, padding, icon and gap.
    static let dividerInset = ListRowButtonStyle.dividerInset(leading: iconSize + Theme.Space.symbolGap)

    var body: some View {
        Button(action: select) {
            HStack(spacing: Theme.Space.symbolGap) {
                AppIcon(bundleID: profile.bundleID, size: Self.iconSize)
                    // The setup in effect right now glows softly behind its icon.
                    .background {
                        if active {
                            Circle()
                                .fill(RadialGradient(colors: [Theme.ok.opacity(0.45), Theme.ok.opacity(0)], center: .center,
                                                     startRadius: 2, endRadius: Self.iconSize * 0.95))
                                .frame(width: Self.iconSize * 2, height: Self.iconSize * 2)
                                .allowsHitTesting(false)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(summary)
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if active {
                    HStack(spacing: 5) {
                        StatusDot(color: Theme.ok, size: 7)
                            .shadow(color: Theme.ok, radius: 3)
                        Text("Active now")
                            .font(Theme.Font.hint.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .fixedSize()
                    .help("This setup is in effect right now.")
                }
            }
        }
        .buttonStyle(ListRowButtonStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Add an app

private struct AddAppMenu: View {
    let model: AppModel
    /// The one button of an empty page (otherwise a small one beside the list's title).
    var prominent = false

    private struct Candidate {
        let bundleID: String
        let name: String
        let icon: NSImage
    }

    /// Open apps with a Dock icon that don't have a setup yet.
    private var candidates: [Candidate] {
        let me = ProcessInfo.processInfo.processIdentifier
        let taken = Set(model.config.appProfiles.map(\.bundleID))
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app -> Candidate? in
            guard app.activationPolicy == .regular, app.processIdentifier != me,
                  let id = app.bundleIdentifier, !taken.contains(id), seen.insert(id).inserted else { return nil }
            let icon = (app.icon?.copy() as? NSImage) ?? NSImage()
            icon.size = NSSize(width: 32, height: 32)
            return Candidate(bundleID: id, name: app.localizedName ?? id, icon: icon)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @State private var open = false

    var body: some View {
        let button = Button {
            open = true
        } label: {
            Label("Add App…", systemImage: "plus")
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SearchPickerPanel(placeholder: String(localized: "Search open apps", comment: "Add App picker search field"),
                              sections: sections,
                              emptyText: { q in String(localized: "No open app called “\(q)”. Choose it from Applications instead.",
                                                       comment: "Add App picker: nothing found; %@ is what was typed") },
                              width: 340, height: 400)
        }
        if prominent {
            button.controlSize(.large)
        } else {
            button.controlSize(.small)
        }
    }

    private func sections(_ query: String) -> [PickerSection] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let apps = candidates.filter { q.isEmpty || $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        var out: [PickerSection] = []
        if !apps.isEmpty {
            out.append(PickerSection(id: "open", title: String(localized: "Open apps"), entries: apps.map { app in
                PickerEntry(id: app.bundleID, title: app.name, icon: .image(app.icon)) {
                    open = false
                    withAnimation(Theme.Motion.spring) { model.addProfile(bundleID: app.bundleID, name: app.name) }
                }
            }))
        }
        out.append(PickerSection(id: "more", entries: [
            PickerEntry(id: "choose", title: String(localized: "Choose from Applications…"),
                        detail: String(localized: "Any app, open or not.", comment: "Add App picker"),
                        icon: .symbol("folder"), opensMore: true) {
                open = false
                DispatchQueue.main.async { chooseApp() }
            },
        ]))
        return out
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Add an App")
        panel.message = String(localized: "Choose the app that should get its own trackball setup.")
        panel.prompt = String(localized: "Add", comment: "Open panel button: add the chosen app")
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let id = Bundle(url: url)?.bundleIdentifier else {
            model.show(.init(symbol: "exclamationmark.triangle.fill", text: String(localized: "Glideball couldn’t identify that app."), isError: true))
            return
        }
        if id == Bundle.main.bundleIdentifier {
            model.show(.init(symbol: "info.circle.fill", text: String(localized: "Glideball itself always uses your main setup.")))
            return
        }
        withAnimation(Theme.Motion.spring) { model.addProfile(bundleID: id, name: url.deletingPathExtension().lastPathComponent) }
    }
}

// MARK: - Editing one app's setup

private struct ProfileEditor: View {
    @Bindable var model: AppModel
    let profileID: String
    @State private var confirmingDelete = false

    private static let buttonRows: [(index: Int, normally: String)] = (0..<4).map { ($0, AppModel.buttonDefault($0)) }

    private var profile: Binding<AppProfile> {
        Binding(
            get: { model.config.appProfiles.first { $0.id == profileID } ?? AppProfile(bundleID: profileID, name: "") },
            set: { new in
                if let i = model.config.appProfiles.firstIndex(where: { $0.id == profileID }) {
                    model.config.appProfiles[i] = new
                }
            })
    }

    /// Switches an area between the main setup (nil) and a custom copy of it.
    private func customizing<T>(_ path: WritableKeyPath<AppProfile, T?>, from main: @escaping () -> T) -> Binding<Bool> {
        Binding(get: { profile.wrappedValue[keyPath: path] != nil },
                set: { on in withAnimation(Theme.Motion.spring) { profile.wrappedValue[keyPath: path] = on ? main() : nil } })
    }

    var body: some View {
        let p = profile.wrappedValue
        let main = model.config
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            header(p)

            OverrideSection(title: "Pointer",
                            mainSummary: String(localized: "speed \(main.trackingSpeed.formatted())", comment: "Pointer speed, after “Following your main setup ·”"),
                            isCustom: customizing(\.trackingSpeed) { model.config.trackingSpeed }) {
                RowGroup {
                    TuningSlider(title: "Tracking speed", symbol: "gauge.with.dots.needle.67percent",
                                 value: Binding(get: { profile.wrappedValue.trackingSpeed ?? model.config.trackingSpeed },
                                                set: { profile.wrappedValue.trackingSpeed = $0 }),
                                 range: 0.5...80, step: 0.5,
                                 format: { $0.twoDigits },
                                 lowLabel: "Slow", highLabel: "Ludicrous")
                }
            }

            OverrideSection(title: "Scrolling",
                            mainSummary: main.scrollMode.title,
                            isCustom: customizing(\.scroll) { model.config.scrollSettings }) {
                let scroll = scrollConfig
                VStack(alignment: .leading, spacing: Theme.Space.section) {
                    ModePicker(mode: scroll.scrollMode)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollControls(config: scroll)
                }
            }

            AssignPanel(model: model, profileID: profileID)

            OverrideSection(title: "Buttons",
                            mainSummary: Self.remapped(main.buttons),
                            isCustom: customizing(\.buttons) { model.config.buttons }) {
                RowGroup(dividerInset: ButtonRow.dividerInset) {
                    ForEach(Self.buttonRows, id: \.index) { b in
                        ButtonRow(index: b.index, name: AppModel.buttonName(b.index), normally: b.normally,
                                  isPressed: model.pressed.contains(b.index),
                                  action: buttonBinding(b.index))
                    }
                }
            }

            OverrideSection(title: "Combos",
                            mainSummary: main.chords.isEmpty ? String(localized: "none", comment: "No combos, after “Following your main setup ·”")
                                                             : String(localized: "\(main.chords.count) combos"),
                            isCustom: customizing(\.chords) { model.config.chords }) {
                CombosCard(chords: Binding(get: { profile.wrappedValue.chords ?? model.config.chords },
                                           set: { profile.wrappedValue.chords = $0 }), title: nil)
            }
        }
        .confirmationDialog("Delete the \(p.name) setup?", isPresented: $confirmingDelete) {
            Button("Delete Setup", role: .destructive) {
                withAnimation(Theme.Motion.spring) { model.deleteProfile(profileID) }
            }
        } message: {
            let changes = p.changes(comparedTo: main)
            if changes.isEmpty {
                Text("\(p.name) will follow your main setup again.")
            } else {
                Text("This deletes what you changed for \(p.name): \(changes.joined(separator: ", ")). It will follow your main setup again.")
            }
        }
    }

    /// Whose setup this is, and the way to delete it.
    private func header(_ p: AppProfile) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Hairline()
            HStack(spacing: 12) {
                AppIcon(bundleID: p.bundleID, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name)
                        .font(Theme.Font.emphasis)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Text("Used whenever \(p.name) is in front. While you edit it here, it’s live so you can try it.")
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    model.requestShare(.appSetup, appSetup: p.bundleID)
                } label: {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)
                .help("Share this app’s setup as a link, a file or a picture")
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .controlSize(.small)
                .help("Delete this app’s setup")
            }
        }
    }

    /// The main setup with this app's scrolling laid over it; writes go to the app only.
    private var scrollConfig: Binding<GlideConfig> {
        Binding(
            get: {
                var c = model.config
                if let s = profile.wrappedValue.scroll { c.scrollSettings = s }
                return c
            },
            set: { profile.wrappedValue.scroll = $0.scrollSettings })
    }

    private func buttonBinding(_ index: Int) -> Binding<ButtonAction> {
        Binding(
            get: { (profile.wrappedValue.buttons ?? model.config.buttons)[index] ?? .system },
            set: { action in
                var map = profile.wrappedValue.buttons ?? model.config.buttons
                map[index] = action
                profile.wrappedValue.buttons = map
            })
    }

    private static func remapped(_ buttons: [Int: ButtonAction]) -> String {
        let n = buttons.filter { $0.key != 0 && $0.value != .system }.count
        return n == 0 ? String(localized: "default buttons", comment: "After “Following your main setup ·”")
                      : String(localized: "\(n) remapped", comment: "Number of buttons that do something other than normal")
    }
}

/// One area of an app setup: its title, whether it follows the main setup or
/// is customized (a "Main setup / Customize" switch), and, when customized,
/// that area's usual controls below.
private struct OverrideSection<Content: View>: View {
    let title: LocalizedStringKey
    let mainSummary: String
    @Binding var isCustom: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.titleToGroup) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Font.sectionTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text(isCustom ? "Custom for this app · starts as a copy of your main setup"
                                  : "Following your main setup · \(mainSummary)")
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Picker(title, selection: $isCustom) {
                    Text("Main setup").tag(false)
                    Text("Customize").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }

            if isCustom {
                content
                    .transition(.opacity)
            }
        }
    }
}

/// An app's Finder icon, or a placeholder when it isn't installed on this Mac
/// (setups sync between Macs).
struct AppIcon: View {
    let bundleID: String
    var size: CGFloat = 32

    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let image = Self.icon(for: bundleID) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: size * 0.75))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }

    @MainActor private static func icon(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = image
        return image
    }
}
