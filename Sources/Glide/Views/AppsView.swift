import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Apps tab: setups Glide switches to while a particular app is in front.
struct AppsView: View {
    @Bindable var model: AppModel

    private var profiles: [AppProfile] { model.config.appProfiles }

    var body: some View {
        Group {
            if profiles.isEmpty {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) {
                        listCard
                        Text("When one of these apps is in front, Glide switches to its setup. Anything left on “Main setup” follows your main settings.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 6)
                    }
                    .frame(width: 280)

                    if let id = model.selectedProfileID, profiles.contains(where: { $0.id == id }) {
                        ProfileEditor(model: model, profileID: id)
                            .id(id)
                    }
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

    private var listCard: some View {
        GlassCard(title: "App setups", symbol: "square.grid.2x2") {
            VStack(spacing: 4) {
                ForEach(profiles) { p in
                    let selected = p.id == model.selectedProfileID
                    Button {
                        withAnimation(.smooth(duration: 0.2)) { model.selectedProfileID = p.id }
                    } label: {
                        HStack(spacing: 10) {
                            AppIcon(bundleID: p.bundleID, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Text(p.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background {
                            RoundedRectangle(cornerRadius: 16).fill(.white.opacity(selected ? 0.16 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            AddAppMenu(model: model)
        }
    }

    private var emptyState: some View {
        GlassCard(title: "App setups", symbol: "square.grid.2x2") {
            HStack(alignment: .center, spacing: 18) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(LinearGradient(colors: [.cyan, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Give an app its own setup")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Faster tracking in a design app, different buttons in your browser — Glide switches the moment that app comes to the front, and back again when you leave. Pick only the parts you want to change; everything else follows your main setup.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                AddAppMenu(model: model)
            }
        }
    }
}

// MARK: - Add an app

private struct AddAppMenu: View {
    let model: AppModel

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
            icon.size = NSSize(width: 16, height: 16)
            return Candidate(bundleID: id, name: app.localizedName ?? id, icon: icon)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Menu {
            let apps = candidates
            Section("Open apps") {
                if apps.isEmpty {
                    Text("No other open apps")
                }
                ForEach(apps, id: \.bundleID) { app in
                    Button {
                        withAnimation(.smooth) { model.addProfile(bundleID: app.bundleID, name: app.name) }
                    } label: {
                        Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                    }
                }
            }
            Divider()
            Button("Choose from Applications…", action: chooseApp)
        } label: {
            Label("Add App…", systemImage: "plus")
                .padding(.horizontal, 4)
        }
        .menuStyle(.button)
        .buttonStyle(.glassProminent)
        .fixedSize()
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Add an App"
        panel.message = "Choose the app that should get its own trackball setup."
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let id = Bundle(url: url)?.bundleIdentifier else {
            model.show(.init(symbol: "exclamationmark.triangle.fill", text: "Glide couldn’t identify that app.", isError: true))
            return
        }
        if id == Bundle.main.bundleIdentifier {
            model.show(.init(symbol: "info.circle.fill", text: "Glide itself always uses your main setup."))
            return
        }
        withAnimation(.smooth) { model.addProfile(bundleID: id, name: url.deletingPathExtension().lastPathComponent) }
    }
}

// MARK: - Editing one app's setup

private struct ProfileEditor: View {
    @Bindable var model: AppModel
    let profileID: String
    @State private var confirmingDelete = false

    private static let buttonRows: [(index: Int, normally: String)] = [
        (0, "Left click"), (1, "Right click"), (2, "Middle click"), (3, "Back"),
    ]

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
                set: { on in withAnimation(.smooth(duration: 0.25)) { profile.wrappedValue[keyPath: path] = on ? main() : nil } })
    }

    var body: some View {
        let p = profile.wrappedValue
        let main = model.config
        VStack(spacing: 18) {
            header(p)

            OverrideSection(title: "Pointer", symbol: "cursorarrow.motionlines",
                            mainSummary: String(format: "speed %g", main.trackingSpeed),
                            isCustom: customizing(\.trackingSpeed) { model.config.trackingSpeed }) {
                GlassCard {
                    TuningSlider(title: "Tracking speed", symbol: "gauge.with.dots.needle.67percent",
                                 value: Binding(get: { profile.wrappedValue.trackingSpeed ?? model.config.trackingSpeed },
                                                set: { profile.wrappedValue.trackingSpeed = $0 }),
                                 range: 0.5...80, step: 0.5,
                                 format: { String(format: "%.2g", $0) },
                                 lowLabel: "Slow", highLabel: "Ludicrous")
                }
            }

            OverrideSection(title: "Scrolling", symbol: "arrow.up.and.down.circle",
                            mainSummary: main.scrollMode.title,
                            isCustom: customizing(\.scroll) { model.config.scrollSettings }) {
                let scroll = scrollConfig
                ModePicker(mode: scroll.scrollMode)
                ScrollControls(config: scroll)
            }

            AssignPanel(model: model, profileID: profileID)

            OverrideSection(title: "Buttons", symbol: "button.programmable",
                            mainSummary: Self.remapped(main.buttons),
                            isCustom: customizing(\.buttons) { model.config.buttons }) {
                VStack(spacing: 12) {
                    ForEach(Self.buttonRows, id: \.index) { b in
                        ButtonRow(index: b.index, name: AppModel.buttonName(b.index), normally: b.normally,
                                  isPressed: model.pressed.contains(b.index),
                                  action: buttonBinding(b.index))
                    }
                }
            }

            OverrideSection(title: "Combos", symbol: "square.on.square",
                            mainSummary: main.chords.isEmpty ? "none" : "\(main.chords.count) combo\(main.chords.count == 1 ? "" : "s")",
                            isCustom: customizing(\.chords) { model.config.chords }) {
                CombosCard(chords: Binding(get: { profile.wrappedValue.chords ?? model.config.chords },
                                           set: { profile.wrappedValue.chords = $0 }))
            }
        }
        .confirmationDialog("Delete the \(p.name) setup?", isPresented: $confirmingDelete) {
            Button("Delete Setup", role: .destructive) {
                withAnimation(.smooth) { model.deleteProfile(profileID) }
            }
        } message: {
            Text("\(p.name) will follow your main setup again.")
        }
    }

    private func header(_ p: AppProfile) -> some View {
        HStack(spacing: 14) {
            AppIcon(bundleID: p.bundleID, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.system(size: 20, weight: .bold, design: .rounded)).lineLimit(1)
                Text("Used whenever \(p.name) is in front. While you edit it here, it’s live so you can try it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.glass)
            .help("Delete this app’s setup")
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
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
        return n == 0 ? "default buttons" : "\(n) remapped"
    }
}

/// One area of an app setup: a "Main setup / Customize" switch, then that
/// area's usual controls when customized.
private struct OverrideSection<Content: View>: View {
    let title: String
    let symbol: String
    let mainSummary: String
    @Binding var isCustom: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(isCustom ? "Custom for this app — starts as a copy of your main setup"
                                  : "Following your main setup · \(mainSummary)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Picker(title, selection: $isCustom) {
                    Text("Main setup").tag(false)
                    Text("Customize").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(16)
            .glassEffect(isCustom ? .regular.tint(.cyan.opacity(0.18)) : .regular, in: .rect(cornerRadius: 22))

            if isCustom {
                content
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
