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
    /// One line under the page's title.
    var summary: String {
        switch self {
        case .overview: String(localized: "How your trackball’s doing today, and everything it’s done so far.", comment: "Overview page description")
        case .pointer: String(localized: "How fast the cursor moves when you roll the ball.", comment: "Pointer page description")
        case .scroll: String(localized: "How the page moves when you turn the scroll ring.", comment: "Scrolling page description")
        case .buttons: String(localized: "What each button does, and combos you press together.", comment: "Buttons page description")
        case .apps: String(localized: "Different settings for the apps you choose.", comment: "Apps page description")
        case .backup: String(localized: "Keep your settings the same on all your Macs, and back them up.", comment: "Sync page description")
        }
    }
    var symbol: String {
        switch self {
        case .overview: "circle.circle"
        case .pointer: "cursorarrow.motionlines"
        case .scroll: "arrow.up.and.down.circle"
        case .buttons: "circle.grid.2x2"
        case .apps: "macwindow"
        case .backup: "arrow.triangle.2.circlepath"
        }
    }
}

/// The main window: a real macOS sidebar (Liquid Glass, with the traffic
/// lights over it) holding the live trackball and the navigation, and the
/// content on the plain window background.
struct RootView: View {
    @Bindable var model: AppModel
    /// The real main window's (not a picture --render-ui or the self-test draws).
    var primary = false
    @State private var tab: GlideTab = GlideTab(rawValue: UserDefaults.standard.string(forKey: "GlideInitialTab") ?? "") ?? .overview
    /// A new one for every page change, so the page fading in is always a new view (see `select`).
    @State private var pageID = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shell = ShellState()
    private let launch = LaunchExperience.shared

    var body: some View {
        let _ = PerfProbe.count("RootView")
        NavigationSplitView(columnVisibility: .constant(.all)) {
            // `tab` is the one source of truth; the rows select on the press itself.
            Sidebar(model: model, tab: tab, select: select)
                .navigationSplitViewColumnWidth(Theme.Space.sidebarWidth)
        } detail: {
            content
        }
        .navigationSplitViewStyle(.balanced)
        // The lit stage under everything: the sidebar's glass picks up its light too.
        .background { Atmosphere(model: model, tab: tab).ignoresSafeArea() }
        .environment(shell)
        .overlay {
            // Confetti for milestones and records — skipped with Reduce Motion.
            if let burst = model.delight.burst, !reduceMotion {
                ConfettiBurst(burst: burst)
                    .id(burst.id)
                    .transition(.opacity)
            }
        }
        .overlay {
            if model.showingWelcomeTour {
                WelcomeTourView(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }
        }
        .overlay {
            if model.showingSmallFavor {
                SmallFavorCard(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }
        }
        .overlay {
            if model.showingWhatsNew {
                WhatsNewView(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }
        }
        .overlay {
            if model.showingIconChoice {
                IconChoicePrompt(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }
        }
        // The launch animation, over everything until it hands over.
        .overlay { LaunchOverlay() }
        .animation(.smooth(duration: 0.35), value: model.showingWelcomeTour)
        .animation(.smooth(duration: 0.35), value: model.showingSmallFavor)
        .animation(.smooth(duration: 0.3), value: model.showingWhatsNew)
        .animation(.smooth(duration: 0.35), value: model.showingIconChoice)
        .sheet(isPresented: $model.showingFeedback) {
            FeedbackView(model: model)
        }
        .sheet(isPresented: $model.showingAbout) {
            AboutView(model: model)
        }
        .sheet(isPresented: $model.showingShortcuts) {
            ShortcutsSheet(model: model)
        }
        // Pages asked for come straight here (`AppModel.requestTab`). Only the main
        // window's RootView takes them; the pictures --render-ui makes don't.
        .onAppear {
            guard primary else { return }
            model.showTab = { select($0) }
            if let wanted = model.requestedTab { model.requestedTab = nil; select(wanted) }
        }
        .onDisappear { if primary { model.showTab = nil } }
        // One asked for while this wasn't there yet (the window built after a glideball:// link).
        .onChange(of: model.requestedTab) { _, _ in
            guard primary, let wanted = model.requestedTab else { return }
            model.requestedTab = nil
            select(wanted)
        }
        // Drop a settings file anywhere on the window to preview it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.pathExtension == GlideSettingsFile.fileExtension else { return false }
            model.previewImport(url)
            return true
        }
    }

    // MARK: Content

    private var content: some View {
        ZStack(alignment: .top) {
            // Drawn once the launch animation starts handing over.
            if launch.contentReady {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.section) {
                        StatusBanners(model: model)
                        TabPage(tab: tab, model: model)
                    }
                    .frame(maxWidth: Theme.Space.contentMaxWidth, alignment: .leading)
                    .padding(.horizontal, Theme.Space.contentSide)
                    // Full screen has no toolbar above the page: the same room, made here.
                    .padding(.top, Theme.Space.contentTop + (model.fullScreen ? Theme.Space.fullScreenTop : 0))
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Groups line themselves up on pixels relative to the page, which
                    // scrolling doesn't change (the window's coordinates would, every frame).
                    .coordinateSpace(.named(PixelGrid.page))
                }
                .onScrollPhaseChange { _, phase in model.pageScrolling = phase != .idle }
                .scrollIndicators(.automatic)
                .id(pageID)
                .transition(pageTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if model.delight.showSaved {
                SavedPill()
                    .padding(.top, 14)
                    .padding(.trailing, 18)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast, model: model)
                    .environment(\.celebrationPart, toast.part)
                    .padding(.bottom, 20)
                    .padding(.horizontal, 24)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(Theme.Motion.fade, value: model.delight.showSaved)
        .animation(Theme.Motion.spring, value: model.toast)
        .animation(Theme.Motion.spring, value: model.permissionsOK)
        .animation(Theme.Motion.spring, value: model.config.enabled)
    }

    /// Cross-fade with a 6 pt rise; just the fade with Reduce Motion.
    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: Theme.Motion.tabRise)), removal: .opacity)
    }

    /// Any number of times, in any order, mid-transition or not: the last one asked for wins.
    ///
    /// Every change is a new page identity (`pageID`, not the tab): going back to a
    /// page that's still fading out (Overview, Pointer, Overview inside 0.18 s) makes
    /// a fresh page instead of reviving the half-faded copy that's on its way out.
    private func select(_ new: GlideTab) {
        guard new != tab else { return }
        model.pageScrolling = false   // the new page starts still
        withAnimation(reduceMotion ? Theme.Motion.fade : Theme.Motion.tabChange) {
            tab = new
            pageID &+= 1
        }
    }
}

/// A tab's page under its header (title and one line about it).
struct TabPage: View {
    let tab: GlideTab
    let model: AppModel

    /// The self-test: how many copies of each page are in the window right now
    /// (more than one page only while one fades into another).
    nonisolated(unsafe) static var onScreen: [GlideTab: Int] = [:]
    static var showing: [GlideTab] { onScreen.filter { $0.value > 0 }.map(\.key) }

    var body: some View {
        let _ = PerfProbe.count("TabPage")
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            PageHeader(title: .verbatim(tab.title), subtitle: .verbatim(tab.summary))
            switch tab {
            case .overview: OverviewView(model: model)
            case .pointer: PointerView(model: model)
            case .scroll: ScrollSettingsView(model: model)
            case .buttons: ButtonsView(model: model)
            case .apps: AppsView(model: model)
            case .backup: BackupView(model: model)
            }
        }
        .onAppear { Self.onScreen[tab, default: 0] += 1 }
        .onDisappear { Self.onScreen[tab, default: 0] -= 1 }
    }
}

// MARK: - Sidebar

/// The trackball, the six pages and the footer, on the sidebar's glass.
///
/// The pages used to be a `List` (an NSTableView underneath) with a selection
/// binding rebuilt on every redraw, so there were two selections, the table's and
/// ours, and the sidebar is redrawn right as you click (the trackball picture above
/// the rows lights the pad you press; Overview's trackball stepping down redraws it
/// too). A redraw landing inside the table's own mouse tracking could put the old
/// page back, and a click on a window that wasn't in front only brought it forward.
/// These rows are plain views over the one `tab`: a press selects at once, every
/// time, mid-transition or not, and the click that brings the window forward counts.
private struct Sidebar: View {
    @Bindable var model: AppModel
    let tab: GlideTab
    let select: (GlideTab) -> Void
    @Environment(ShellState.self) private var shell: ShellState?

    var body: some View {
        // Overview's big trackball is on screen: this one steps down to a small status light.
        let compact = (shell?.heroOnScreen ?? false) && (tab == .overview || tab == .buttons)
        VStack(spacing: 0) {
            SidebarHero(model: model, compact: compact, fullScreen: model.fullScreen)
                .padding(.bottom, 6)
            VStack(spacing: 0) {
                ForEach(GlideTab.allCases) { t in
                    SidebarRow(tab: t, selected: t == tab) { select(t) }
                }
            }
            .padding(.horizontal, 10)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pages")
            Spacer(minLength: 0)
            SidebarFooter(model: model)
        }
        .toolbar(removing: .sidebarToggle)
    }
}

/// One page in the sidebar, drawn like the system's sidebar rows. Selects on
/// the press (as Finder's sidebar does), so a trackball that drifts a little
/// while clicking still lands, and it takes the click that brings the window forward.
private struct SidebarRow: View {
    let tab: GlideTab
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.symbol)
                .font(.system(size: 14))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 22)
            Text(verbatim: tab.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background {
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
            if selected {
                shape.fill(Theme.sidebarSelection.opacity(appearsActive ? 1 : 0.7))
            } else if hovering || pressed {
                shape.fill(Theme.hoverFill)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !pressed else { return }
                pressed = true
                action()
            }
            .onEnded { _ in pressed = false })
        .allowsWindowActivationEvents(true)
        .onHover { hovering = $0 }
        .help(String(localized: "\(tab.title) (⇧\(tab.order + 1) or ⌘\(tab.order + 1))", comment: "Sidebar tooltip: a page's name and its two shortcuts"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: tab.title))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { action() }
    }
}

/// The live trackball on its stage, the device's name and one status line.
private struct SidebarHero: View {
    let model: AppModel
    var compact = false
    var fullScreen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = PerfProbe.count("SidebarHero")
        let status = SidebarStatus(model)
        VStack(spacing: 10) {
            TrackballView(feed: model.live, pressed: model.pressed, look: TrackballLook.of(model),
                          driftFPS: model.windowVisible && !compact
                            ? model.performance.idleDriftFPS(windowIsKey: model.windowIsKey, deviceConnected: model.status.deviceConnected)
                            : 0)
                // Always drawn at full size and scaled, so stepping down and back is one smooth
                // scale (the drawing itself never animates); the space stays the same either way.
                .frame(width: 150, height: 150)
                .overlay { GestureHeldOverlay(model: model) }   // a held gesture: the way you roll, what fired
                .scaleEffect(compact ? 84.0 / 150 : 1)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background {
                    SidebarAura(model: model, look: TrackballLook.of(model))
                        .scaleEffect(compact ? 0.7 : 1)
                        .opacity(compact ? 0.75 : 1)
                }
                .animation(reduceMotion ? Theme.Motion.fade : .spring(response: 0.45, dampingFraction: 0.85), value: compact)

            VStack(spacing: 3) {
                Text(status.deviceName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    StatusDot(color: status.color, size: 7)
                    Text(status.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // How it's connected and its battery, when known (never a guess).
                    let detail = ConnectionDetail(connection: model.shownConnection, battery: model.shownBattery)
                    if !detail.isEmpty {
                        Text(verbatim: "·").font(.system(size: 11)).foregroundStyle(.tertiary)
                        ViewThatFits { detail; ConnectionDetail(connection: nil, battery: model.shownBattery) }
                    }
                }
                .accessibilityElement(children: .combine)
                // "Connected · Beta": a device supported through Other Kensington trackballs.
                .help(model.status.deviceConnected && model.status.deviceIsBeta
                      ? String(localized: "Not fully tested yet. You may hit bugs") : "")
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 12)
        // Up into the empty title bar a little, closer under the traffic lights.
        // (Full screen has no title bar: room of its own instead.)
        .padding(.top, fullScreen ? Theme.Space.fullScreenTop : -10)
    }
}

/// The trackball's light on the sidebar's glass: a soft aurora in the orb's
/// colors around it (dimmer when it's paused or missing), and the hand's live
/// light on top. Static at rest.
private struct SidebarAura: View {
    let model: AppModel
    let look: TrackballLook
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let k = look == .connected ? 1.0 : 0.35
        ZStack {
            Rectangle()
                .fill(EllipticalGradient(colors: [Theme.orbBlue.opacity((dark ? 0.55 : 0.30) * k),
                                              Theme.orbViolet.opacity((dark ? 0.22 : 0.12) * k), .clear], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                .frame(width: 380, height: 360)
            Rectangle()
                .fill(EllipticalGradient(colors: [Theme.orbMagenta.opacity((dark ? 0.16 : 0.08) * k), .clear], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                .frame(width: 240, height: 200)
                .offset(x: 50, y: 70)
            if model.performance != .minimal, look == .connected {
                LightBloom(feed: model.live, pressed: model.pressed, dark: dark, size: 360, strength: 0.9)
            }
        }
        .animation(Theme.Motion.pause, value: look)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// What the sidebar says about the trackball: its name, and one status.
struct SidebarStatus {
    let deviceName: String
    let text: String
    let color: Color

    @MainActor init(_ model: AppModel) {
        let s = model.status
        deviceName = s.deviceConnected ? (s.deviceName ?? "Kensington Expert Mouse")
                                       : (s.unsupportedDeviceName.map { $0.localizedCaseInsensitiveContains("Kensington") ? $0 : "Kensington \($0)" }
                                          ?? s.deviceName ?? "Kensington Expert Mouse")
        if !model.permissionsOK {
            text = String(localized: "Needs permission", comment: "Status pill"); color = Theme.warn
        } else if !model.config.enabled {
            text = String(localized: "Paused", comment: "Status pill"); color = Theme.idle
        } else if !s.deviceConnected && s.unsupportedDeviceName != nil {
            text = String(localized: "Beta only", comment: "Status pill: a Kensington device that needs Other Kensington trackballs turned on")
            color = Theme.warn
        } else if !s.deviceConnected {
            text = String(localized: "Not connected", comment: "Status pill"); color = Theme.bad
        } else {
            text = s.deviceIsBeta ? String(localized: "Connected · Beta", comment: "Status pill")
                                  : String(localized: "Connected", comment: "Status pill")
            color = Theme.ok
        }
    }
}

/// Modes that are on, the app setup in effect, the on/off switch, and the footer.
private struct SidebarFooter: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.modes.precision || model.modes.dragLocked || model.modes.ballScrolling {
                ModeChips(modes: model.modes)
            }
            if let profile = model.activeProfile {
                ActiveProfileBadge(model: model, profile: profile)
            }
            HStack(spacing: 8) {
                Text(model.config.enabled ? "Glideball is on" : "Paused")
                    .font(.system(size: 13, weight: .medium))
                    .contentTransition(.opacity)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Toggle("Glideball is on", isOn: $model.config.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(model.config.globalShortcuts.pause.map { String(localized: "Pause or resume Glideball (also \($0.display) from anywhere)") }
                          ?? String(localized: "Pause or resume Glideball"))
            }
            HStack(spacing: 4) {
                if let update = model.updates.available {
                    UpdateButton(updates: model.updates, update: update)
                }
                Spacer(minLength: 0)
                IconButton(symbol: "gearshape", help: "Settings…") {
                    (NSApp.delegate as? AppDelegate)?.showSettings()
                }
                IconButton(symbol: "questionmark.circle", help: "About & Help") {
                    model.showingAbout = true
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .animation(Theme.Motion.spring, value: model.modes)
    }
}

/// Precision, Drag lock, Ball scroll — whichever are on right now.
private struct ModeChips: View {
    let modes: Engine.Modes

    var body: some View {
        // Two chips fit a line; a third wraps.
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                if modes.precision {
                    ModeChip(text: "Precision", symbol: "scope", tint: Theme.ball)
                        .help("A Precision button is slowing the cursor. Press it again (or pause Glideball) to stop")
                }
                if modes.dragLocked {
                    ModeChip(text: "Drag lock", symbol: "hand.draw.fill", tint: Theme.buttons)
                        .help("The left button is held by Drag lock. Click, or press the Drag lock button again, to let go")
                }
            }
            if modes.ballScrolling {
                ModeChip(text: "Ball scroll", symbol: "arrow.up.and.down.and.arrow.left.and.right", tint: Theme.ball)
            }
        }
    }
}

/// "Using Safari setup" while an app setup is in effect: small and secondary; opens it on Apps.
private struct ActiveProfileBadge: View {
    let model: AppModel
    let profile: AppProfile

    var body: some View {
        Button {
            model.selectedProfileID = profile.id
            model.requestTab(.apps)
        } label: {
            HStack(spacing: 6) {
                AppIcon(bundleID: profile.bundleID, size: 16)
                Text("Using \(profile.name) setup")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(radius: 6))
        .padding(.horizontal, -6)
        .help(model.glideIsFrontmost
              ? String(localized: "Previewing \(profile.name)’s setup while you edit it. Other apps use your main setup.")
              : String(localized: "\(profile.name) is in front, so Glideball is using its setup. Click to edit it."))
    }
}

// MARK: - Status banners

/// What needs saying above every page: permissions, paused, no trackball.
private struct StatusBanners: View {
    let model: AppModel

    var body: some View {
        if !model.permissionsOK {
            PermissionsBanner(model: model)
        } else if !model.config.enabled {
            NoticeBanner(symbol: "pause.circle", tint: .secondary, title: "Glideball is paused",
                         message: "Your trackball works like a plain mouse until you turn Glideball back on.") {
                Button("Resume") { model.config.enabled = true }
                    .controlSize(.small)
            }
        } else if !model.status.deviceConnected, let name = model.status.unsupportedDeviceName {
            // A Kensington device Glideball only supports with "Other Kensington trackballs" on: a gentle nudge, not an error.
            NoticeBanner(symbol: "computermouse", tint: .secondary,
                         title: "Turn on Other Kensington trackballs to try Glideball with your \(name).") {
                Button("Turn On") { model.otherTrackballs = true }
                    .controlSize(.small)
            }
        } else if !model.status.deviceConnected {
            NoticeBanner(symbol: "cable.connector", tint: .secondary, title: "Plug in your Expert Mouse.",
                         message: "Glideball starts working as soon as it’s connected.") {
                EmptyView()
            }
        }
    }
}

struct PermissionsBanner: View {
    let model: AppModel

    var body: some View {
        NoticeBanner(symbol: "lock.shield", tint: Theme.warn, title: "Two quick permissions",
                     message: "Glideball needs these to read your trackball and adjust its buttons and scrolling. Until both are on, your trackball works normally and Glideball stays out of the way.") {
            permissionButton(granted: model.hasAccessibility, on: "Accessibility: on", off: "Allow Accessibility…") {
                model.requestAccessibility()
            }
            permissionButton(granted: model.hasInputMonitoring, on: "Input Monitoring: on", off: "Allow Input Monitoring…") {
                model.requestInputMonitoring()
            }
            Link("Why?", destination: SiteLinks.permissions)
                .font(.system(size: 12))
        }
    }

    @ViewBuilder private func permissionButton(granted: Bool, on: LocalizedStringKey, off: LocalizedStringKey,
                                               action: @escaping () -> Void) -> some View {
        if granted {
            Label(on, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ok)
                .lineLimit(1)
        } else {
            Button(action: action) {
                Text(off).lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }
}

// MARK: - Update

/// "2.11" in the sidebar's footer: install in place, or read what's new.
struct UpdateButton: View {
    let updates: UpdateChecker
    let update: UpdateChecker.Update

    var body: some View {
        switch updates.installState {
        case .downloading(let progress):
            Label("Downloading \(Int(progress * 100))%", systemImage: "arrow.down.circle")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .installing:
            Label("Restarting…", systemImage: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .idle, .failed:
            Menu {
                Button("Install \(update.displayVersion) & Relaunch") { updates.install() }
                Button("Details…") { (NSApp.delegate as? AppDelegate)?.showUpdatePanel(check: false) }
                Button("What’s New in \(update.displayVersion)…") { NSWorkspace.shared.open(update.notesPage) }
                if update.isPrerelease {
                    Divider()
                    Text("An early update. It may have bugs")
                }
                if case .failed(let message) = updates.installState {
                    Divider()
                    Text("Last try failed: \(message)")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(updates.installState == .idle ? update.displayVersion : String(localized: "Retry", comment: "Update button after a failed install"))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(updates.installState == .idle ? Theme.ball : Theme.warn)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill((updates.installState == .idle ? Theme.ball : Theme.warn).opacity(0.14)))
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(HoverButtonStyle(radius: 12))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Glideball \(update.displayVersion) is available. Install it or see what's new")
        }
    }
}
