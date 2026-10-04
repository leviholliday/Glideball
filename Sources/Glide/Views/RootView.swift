import SwiftUI

enum GlideTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case pointer = "Pointer"
    case scroll = "Scrolling"
    case buttons = "Buttons"
    case backup = "Sync"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "sparkles"
        case .pointer: "cursorarrow.motionlines"
        case .scroll: "arrow.up.and.down.circle"
        case .buttons: "button.programmable"
        case .backup: "arrow.triangle.2.circlepath.icloud"
        }
    }
}

struct RootView: View {
    @Bindable var model: AppModel
    @State private var tab: GlideTab = GlideTab(rawValue: UserDefaults.standard.string(forKey: "GlideInitialTab") ?? "") ?? .overview
    @Namespace private var tabNS

    var body: some View {
        ZStack {
            GlideBackground()
            VStack(spacing: 18) {
                header
                if !model.permissionsOK { PermissionsCard(model: model) }
                ScrollView {
                    Group {
                        switch tab {
                        case .overview: OverviewView(model: model)
                        case .pointer: PointerView(model: model)
                        case .scroll: ScrollSettingsView(model: model)
                        case .buttons: ButtonsView(model: model)
                        case .backup: BackupView(model: model)
                        }
                    }
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
                .scrollIndicators(.never)
            }
            .padding(.horizontal, 26)
            .padding(.top, 36)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast, model: model)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.smooth(duration: 0.3), value: tab)
        .animation(.smooth, value: model.permissionsOK)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.toast)
        .onChange(of: model.requestedTab) { _, requested in
            guard let requested else { return }
            tab = requested
            model.requestedTab = nil
        }
        // Drop a settings file anywhere on the window to preview it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.pathExtension == GlideSettingsFile.fileExtension else { return false }
            model.previewImport(url)
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("Glide").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Kensington Expert Mouse").font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            tabBar
            Spacer()
            if let update = model.updates.available {
                UpdateButton(updates: model.updates, update: update)
            }
            StatusPill(text: statusText, color: statusColor)
            Toggle("", isOn: $model.config.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Pause or resume Glide — also ⌃⌥⌘G from anywhere")
        }
    }

    private var tabBar: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(GlideTab.allCases) { t in
                    Button {
                        tab = t
                    } label: {
                        Label(t.rawValue, systemImage: t.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .foregroundStyle(tab == t ? .primary : .secondary)
                            .background {
                                if tab == t {
                                    Capsule()
                                        .fill(.white.opacity(0.18))
                                        .matchedGeometryEffect(id: "sel", in: tabNS)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .glassEffect(.regular, in: .capsule)
        }
    }

    private var statusText: String {
        if !model.permissionsOK { return "Needs permission" }
        if !model.config.enabled { return "Paused" }
        return model.status.deviceConnected ? "Connected" : "Not connected"
    }

    private var statusColor: Color {
        if !model.permissionsOK { return .orange }
        if !model.config.enabled { return .gray }
        return model.status.deviceConnected ? .green : .red
    }
}

struct PermissionsCard: View {
    let model: AppModel

    var body: some View {
        GlassCard(title: "Two quick permissions", symbol: "lock.shield", tint: .orange.opacity(0.25)) {
            Text("Glide needs these to read your trackball and adjust its buttons and scrolling. Until both are on, your trackball works normally and Glide stays out of the way.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                permissionButton("Accessibility", granted: model.hasAccessibility) { model.requestAccessibility() }
                permissionButton("Input Monitoring", granted: model.hasInputMonitoring) { model.requestInputMonitoring() }
            }
        }
    }

    private func permissionButton(_ name: String, granted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(granted ? "\(name) — on" : "Allow \(name)…",
                  systemImage: granted ? "checkmark.circle.fill" : "hand.raised")
                .padding(.horizontal, 6)
        }
        .buttonStyle(.glassProminent)
        .tint(granted ? .green : .orange)
        .disabled(granted)
    }
}

/// "Update 2.1" in the header: install in place, or read what's new.
struct UpdateButton: View {
    let updates: UpdateChecker
    let update: UpdateChecker.Update

    var body: some View {
        switch updates.installState {
        case .downloading(let progress):
            Label("Downloading \(Int(progress * 100))%", systemImage: "arrow.down.circle")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassEffect(.regular.tint(.cyan.opacity(0.3)), in: .capsule)
        case .installing:
            Label("Restarting…", systemImage: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassEffect(.regular.tint(.cyan.opacity(0.3)), in: .capsule)
        case .idle, .failed:
            Menu {
                Button("Install \(update.version) & Relaunch") { updates.install() }
                Button("What’s New in \(update.version)…") { NSWorkspace.shared.open(update.page) }
                if case .failed(let message) = updates.installState {
                    Divider()
                    Text("Last try failed: \(message)")
                }
            } label: {
                Label(updates.installState == .idle ? update.version : "Retry",
                      systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.glassProminent)
            .tint(updates.installState == .idle ? .cyan : .orange)
            .fixedSize()
            .help("Glide \(update.version) is available — install it or see what's new")
        }
    }
}
