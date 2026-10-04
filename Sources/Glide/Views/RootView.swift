import SwiftUI

enum GlideTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case pointer = "Pointer"
    case scroll = "Scrolling"
    case buttons = "Buttons"
    case apps = "Apps"
    case backup = "Sync"

    var id: String { rawValue }
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    /// The tab's name on screen (the raw value is what's saved).
    var title: String {
        switch self {
        case .overview: String(localized: "Overview", comment: "Tab name")
        case .pointer: String(localized: "Pointer", comment: "Tab name")
        case .scroll: String(localized: "Scrolling", comment: "Tab name")
        case .buttons: String(localized: "Buttons", comment: "Tab name")
        case .apps: String(localized: "Apps", comment: "Tab name")
        case .backup: String(localized: "Sync", comment: "Tab name: export, import and iCloud sync")
        }
    }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which way the page slides: +1 to a tab further right, -1 to the left.
    @State private var direction: CGFloat = 1
    @State private var seenTabs: Set<GlideTab> = []
    @State private var stagger = CardStagger()
    /// Bumped to give a newly chosen tab's icon a little bounce.
    @State private var bounces: [GlideTab: Int] = [:]
    private let launch = LaunchExperience.shared

    var body: some View {
        ZStack {
            GlideBackground()
            VStack(spacing: 18) {
                header
                if !model.permissionsOK { PermissionsCard(model: model) }
                ScrollView {
                    // Pages overlap while one slides out and the next in.
                    ZStack(alignment: .top) {
                        // Drawn once the launch animation starts handing
                        // over, so the first page's cards rise in as it does.
                        if launch.contentReady {
                            page(tab)
                                .padding(.bottom, 24)
                                .id(tab)
                                .transition(pageTransition)
                        }
                    }
                    .environment(\.cardStagger, stagger)
                }
                .scrollIndicators(.never)
            }
            .padding(.horizontal, 26)
            .padding(.top, 36)
        }
        .overlay {
            // Confetti for milestones and records — skipped with Reduce Motion.
            if let burst = model.delight.burst, !reduceMotion {
                ConfettiBurst(burst: burst)
                    .id(burst.id)
                    .transition(.opacity)
            }
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
        // The launch animation, over everything until it hands over.
        .overlay { LaunchOverlay() }
        .animation(.smooth(duration: 0.35), value: model.showingWelcomeTour)
        .animation(.smooth, value: model.permissionsOK)
        .animation(.smooth(duration: 0.2), value: model.modes)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: model.delight.showSaved)
        .animation(.smooth(duration: 0.3), value: model.delight.checklistVisible)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.toast)
        .sheet(isPresented: $model.showingFeedback) {
            FeedbackView(model: model)
        }
        .onChange(of: model.requestedTab) { _, requested in
            guard let requested else { return }
            select(requested)
            model.requestedTab = nil
        }
        .onAppear { seenTabs.insert(tab) }
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
                Text(verbatim: "Glideball").font(.system(size: 22, weight: .bold, design: .rounded))
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
                    .help("A Precision button is slowing the cursor — press it again (or pause Glideball) to stop")
            }
            if model.modes.dragLocked {
                ModePill(text: "Drag lock", symbol: "hand.draw.fill", tint: .orange)
                    .help("The left button is held by Drag lock — click, or press the Drag lock button again, to let go")
            }
            if model.modes.ballScrolling {
                ModePill(text: "Ball scroll", symbol: "arrow.up.and.down.and.arrow.left.and.right", tint: .purple)
            }
            if model.delight.showSaved {
                SavedPill()
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            StatusPill(text: .verbatim(statusText), color: statusColor)
            Toggle("", isOn: $model.config.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(model.config.globalShortcuts.pause.map { String(localized: "Pause or resume Glideball — also \($0.display) from anywhere") }
                      ?? String(localized: "Pause or resume Glideball"))
        }
    }

    private var tabBar: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(GlideTab.allCases) { t in
                    Button {
                        select(t)
                    } label: {
                        // Icon over a short label keeps six tabs narrow enough
                        // for the header at the window's 960 pt minimum.
                        VStack(spacing: 2) {
                            Image(systemName: t.symbol)
                                .font(.system(size: 15, weight: .medium))
                                .frame(height: 18)
                                .symbolEffect(.bounce.up.byLayer, options: .speed(1.6), value: bounces[t, default: 0])
                            Text(t.title)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(minWidth: 44)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .foregroundStyle(tab == t ? .primary : .secondary)
                        .background {
                            if tab == t {
                                // The glass bead springs from tab to tab.
                                Capsule()
                                    .fill(.white.opacity(0.18))
                                    .overlay {
                                        Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.04)],
                                                                              startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
                                    }
                                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
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

    @ViewBuilder private func page(_ tab: GlideTab) -> some View {
        switch tab {
        case .overview: OverviewView(model: model)
        case .pointer: PointerView(model: model)
        case .scroll: ScrollSettingsView(model: model)
        case .buttons: ButtonsView(model: model)
        case .apps: AppsView(model: model)
        case .backup: BackupView(model: model)
        }
    }

    // MARK: Page transitions

    /// Switches tab: the page slides the way the tab bar reads (left or
    /// right), and the first visit to a tab staggers its cards in.
    private func select(_ new: GlideTab) {
        guard new != tab else { return }
        // The outgoing page takes its slide direction from its last render,
        // so set the direction first and switch on the next turn of the run loop.
        direction = new.order > tab.order ? 1 : -1
        if !reduceMotion { bounces[new, default: 0] += 1 }
        if !seenTabs.contains(new) {
            seenTabs.insert(new)
            stagger.armed = true
        }
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.32, dampingFraction: 0.86)) {
                tab = new
            }
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .offset(x: 44 * direction).combined(with: .opacity).combined(with: .scale(scale: 0.985, anchor: .top)),
            removal: .offset(x: -44 * direction).combined(with: .opacity).combined(with: .scale(scale: 0.985, anchor: .top))
        )
    }

    private var statusText: String {
        if !model.permissionsOK { return String(localized: "Needs permission", comment: "Status pill") }
        if !model.config.enabled { return String(localized: "Paused", comment: "Status pill") }
        if !model.status.deviceConnected && model.status.unsupportedDeviceName != nil {
            return String(localized: "Beta only", comment: "Status pill: a Kensington device that needs the Beta program")
        }
        guard model.status.deviceConnected else { return String(localized: "Not connected", comment: "Status pill") }
        return model.status.deviceIsBeta ? String(localized: "Connected · Beta", comment: "Status pill")
                                         : String(localized: "Connected", comment: "Status pill")
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
              ? String(localized: "Previewing \(profile.name)’s setup while you edit it. Other apps use your main setup.")
              : String(localized: "\(profile.name) is in front, so Glideball is using its setup. Click to edit it."))
    }
}

struct PermissionsCard: View {
    let model: AppModel

    var body: some View {
        GlassCard(title: "Two quick permissions", symbol: "lock.shield", tint: .orange.opacity(0.25)) {
            Text("Glideball needs these to read your trackball and adjust its buttons and scrolling. Until both are on, your trackball works normally and Glideball stays out of the way.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                permissionButton(granted: model.hasAccessibility, on: "Accessibility — on", off: "Allow Accessibility…") {
                    model.requestAccessibility()
                }
                permissionButton(granted: model.hasInputMonitoring, on: "Input Monitoring — on", off: "Allow Input Monitoring…") {
                    model.requestInputMonitoring()
                }
            }
        }
    }

    private func permissionButton(granted: Bool, on: LocalizedStringKey, off: LocalizedStringKey,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(granted ? on : off,
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
                Label(updates.installState == .idle ? update.displayVersion : String(localized: "Retry", comment: "Update button after a failed install"),
                      systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.glassProminent)
            .tint(updates.installState == .idle ? .cyan : .orange)
            .fixedSize()
            .help("Glideball \(update.displayVersion) is available — install it or see what's new")
        }
    }
}
