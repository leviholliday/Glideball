import SwiftUI

enum GlideTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case pointer = "Pointer"
    case scroll = "Scrolling"
    case buttons = "Buttons"
    case apps = "Apps"
    case backup = "Sync"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "sparkles"
        case .pointer: "cursorarrow.motionlines"
        case .scroll: "arrow.up.and.down.circle"
        case .buttons: "button.programmable"
        case .apps: "square.grid.2x2"
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
                        case .apps: AppsView(model: model)
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
        .overlay {
            if model.showingWelcomeTour {
                WelcomeTourView(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }
        }
        .animation(.smooth(duration: 0.3), value: tab)
        .animation(.smooth(duration: 0.35), value: model.showingWelcomeTour)
        .animation(.smooth, value: model.permissionsOK)
        .animation(.smooth(duration: 0.2), value: model.modes)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.toast)
        .sheet(isPresented: $model.showingFeedback) {
            FeedbackView(model: model)
        }
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
                if let profile = model.activeProfile {
                    ActiveProfileBadge(model: model, profile: profile)
                } else {
                    HStack(spacing: 6) {
                        Text(model.status.deviceName ?? "Kensington Expert Mouse")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(1)
                        if model.status.deviceConnected && model.status.deviceIsBeta { BetaBadge() }
                    }
                }
            }
            Spacer()
            tabBar
            Spacer()
            if let update = model.updates.available {
                UpdateButton(updates: model.updates, update: update)
            }
            if model.modes.precision {
                ModePill(text: "Precision", symbol: "scope", tint: .cyan)
                    .help("A Precision button is slowing the cursor — press it again (or pause Glide) to stop")
            }
            if model.modes.dragLocked {
                ModePill(text: "Drag lock", symbol: "hand.draw.fill", tint: .orange)
                    .help("The left button is held by Drag lock — click, or press the Drag lock button again, to let go")
            }
            if model.modes.ballScrolling {
                ModePill(text: "Ball scroll", symbol: "arrow.up.and.down.and.arrow.left.and.right", tint: .purple)
            }
            StatusPill(text: statusText, color: statusColor)
            Toggle("", isOn: $model.config.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(model.config.globalShortcuts.pause.map { "Pause or resume Glide — also \($0.display) from anywhere" }
                      ?? "Pause or resume Glide")
        }
    }

    private var tabBar: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(GlideTab.allCases) { t in
                    Button {
                        tab = t
                    } label: {
                        // Icon over a short label keeps six tabs narrow enough
                        // for the header at the window's 960 pt minimum.
                        VStack(spacing: 2) {
                            Image(systemName: t.symbol)
                                .font(.system(size: 15, weight: .medium))
                                .frame(height: 18)
                            Text(t.rawValue)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .frame(minWidth: 44)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
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
        if !model.status.deviceConnected && model.status.unsupportedDeviceName != nil { return "Beta only" }
        guard model.status.deviceConnected else { return "Not connected" }
        return model.status.deviceIsBeta ? "Connected · Beta" : "Connected"
    }

    private var statusColor: Color {
        if !model.permissionsOK { return .orange }
        if !model.config.enabled { return .gray }
        if !model.status.deviceConnected && model.status.unsupportedDeviceName != nil { return .purple }
        return model.status.deviceConnected ? .green : .red
    }
}

/// "Using Safari setup" under the app name while an app setup is in effect.
private struct ActiveProfileBadge: View {
    let model: AppModel
    let profile: AppProfile

    var body: some View {
        Button {
            model.selectedProfileID = profile.id
            model.requestedTab = .apps
        } label: {
            HStack(spacing: 5) {
                AppIcon(bundleID: profile.bundleID, size: 14)
                Text("Using \(profile.name) setup")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help(model.glideIsFrontmost
              ? "Previewing \(profile.name)’s setup while you edit it. Other apps use your main setup."
              : "\(profile.name) is in front, so Glide is using its setup. Click to edit it.")
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
                Button("Install \(update.displayVersion) & Relaunch") { updates.install() }
                Button("What’s New in \(update.displayVersion)…") { NSWorkspace.shared.open(update.page) }
                if update.isPrerelease {
                    Divider()
                    Text("A Beta program build — it may have bugs")
                }
                if case .failed(let message) = updates.installState {
                    Divider()
                    Text("Last try failed: \(message)")
                }
            } label: {
                Label(updates.installState == .idle ? update.displayVersion : "Retry",
                      systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.glassProminent)
            .tint(updates.installState == .idle ? .cyan : .orange)
            .fixedSize()
            .help("Glide \(update.displayVersion) is available — install it or see what's new")
        }
    }
}
