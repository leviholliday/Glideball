import AppKit
import Observation
import SwiftUI

/// What a click on the menu-bar icon opens (Settings › General). Per Mac.
enum MenuBarClick: String, CaseIterable, Identifiable {
    /// The classic menu (the default: Levi's own menu bar is crowded, and a menu is quick).
    case menu
    /// A small glass panel: the live trackball, the main switches, today's numbers.
    case panel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .menu: String(localized: "Menu", comment: "Settings › General: the menu bar icon opens its menu")
        case .panel: String(localized: "Panel", comment: "Settings › General: the menu bar icon opens a small panel")
        }
    }
}

/// The menu-bar icon's panel. With "Menu bar icon opens: Panel", a click opens
/// it under the icon; a right-click (or ⌃-click) always shows the classic menu.
/// The panel's view exists only while it's open, so closed it costs nothing.
@Observable
final class MenuBarPanelController: NSObject, NSPopoverDelegate {
    static let shared = MenuBarPanelController()
    static let key = "GlideMenuBarOpens"

    var opens: MenuBarClick = MenuBarClick(rawValue: UserDefaults.standard.string(forKey: MenuBarPanelController.key) ?? "") ?? .menu {
        didSet {
            UserDefaults.standard.set(opens.rawValue, forKey: Self.key)
            configure()
        }
    }

    @ObservationIgnored private weak var item: NSStatusItem?
    @ObservationIgnored private var menu: NSMenu?
    @ObservationIgnored private var popover: NSPopover?

    var isOpen: Bool { popover?.isShown == true }

    /// The status item and its menu, from `AppDelegate.setUpStatusItem`.
    func attach(_ item: NSStatusItem, menu: NSMenu) {
        self.item = item
        self.menu = menu
        configure()
    }

    /// Menu: the item shows its menu itself. Panel: clicks come here.
    private func configure() {
        guard let item, let button = item.button else { return }
        switch opens {
        case .menu:
            close()
            item.menu = menu
            button.target = nil
            button.action = nil
        case .panel:
            item.menu = nil
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if wantsMenu, let menu {
            close()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 5), in: sender)
            return
        }
        isOpen ? close() : open(from: sender)
    }

    private func open(from button: NSStatusBarButton) {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let host = NSHostingController(rootView: MenuBarPanelView(model: .shared) { [weak self] in self?.close() })
        host.sizingOptions = [.preferredContentSize]
        p.contentViewController = host
        p.delegate = self
        popover = p
        AppModel.shared.setPanelOpen(true)
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
    }

    func close() {
        popover?.performClose(nil)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Let go of the view: nothing runs for the panel while it's closed.
            popover?.contentViewController = nil
            popover = nil
            AppModel.shared.setPanelOpen(false)
        }
    }
}

/// The panel itself: the trackball small with its status and the on/off
/// switch, today's three numbers, the scroll mode, the pointer speed,
/// Precision, the app setup in effect, and the way into Glideball.
struct MenuBarPanelView: View {
    @Bindable var model: AppModel
    var close: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    static let width: CGFloat = 320

    var body: some View {
        let status = SidebarStatus(model)
        let look = TrackballLook.of(model)
        VStack(alignment: .leading, spacing: 14) {
            // The trackball, what it is and how it is, and the switch.
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [Theme.orbBlue.opacity(scheme == .dark ? 0.5 : 0.28), Theme.orbViolet.opacity(0.12), .clear],
                                             center: .center, startRadius: 4, endRadius: 46))
                        .frame(width: 96, height: 96)
                        .opacity(look == .connected ? 1 : 0.35)
                    TrackballView(feed: model.live, pressed: model.pressed, look: look,
                                  driftFPS: model.performance.idleDriftFPS(windowIsKey: true, deviceConnected: model.status.deviceConnected))
                        .frame(width: 64, height: 64)
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: status.deviceName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        StatusDot(color: status.color, size: 7)
                        Text(verbatim: status.text)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Toggle("Glideball is on", isOn: $model.config.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(model.config.enabled ? String(localized: "Pause Glideball") : String(localized: "Resume Glideball"))
            }

            // Today, as on Overview.
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(Metric.lifetimeOrder.enumerated()), id: \.element) { i, m in
                    if i > 0 { Hairline(vertical: true).padding(.horizontal, 12) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: today(m))
                            .font(Theme.Font.numeral(19))
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        HStack(spacing: 5) {
                            Circle().fill(m.color).frame(width: 6, height: 6)
                            Text(verbatim: todayLabel(m))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Today", comment: "VoiceOver: today's numbers in the menu bar panel"))

            Hairline()

            VStack(alignment: .leading, spacing: 6) {
                Text("Scroll mode").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Picker("Scroll mode", selection: $model.config.scrollMode) {
                    ForEach(ScrollMode.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            TuningSlider(title: "Tracking speed", symbol: "gauge.with.dots.needle.67percent",
                         value: $model.config.trackingSpeed, range: Commands.pointerSpeedRange, step: Commands.pointerSpeedStep,
                         format: { $0.twoDigits }, tint: Theme.ball, defaultValue: GlideConfig().trackingSpeed, tryable: false)
                .environment(\.rowPadding, false)

            HStack(spacing: Theme.Space.symbolGap) {
                RowSymbol(symbol: "scope", tint: model.modes.precision ? Theme.ball : nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Precision", comment: "Mode that slows the pointer for fine work").font(Theme.Font.body)
                    Text(model.modes.precision ? "The cursor is slowed for fine work." : "Slows the cursor for fine work.")
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Toggle("Precision", isOn: Binding(get: { model.modes.precision }, set: { on in
                    Commands.run("precision", on ? .on : .off, on: AppCommandTarget.shared) { now in
                        guard let now else { return NSSound.beep() }
                        Sounds.shared.play(now ? .modeOn : .modeOff)
                    }
                }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!model.config.enabled || !model.status.deviceConnected)
            }

            if let profile = model.activeProfile {
                HStack(spacing: 7) {
                    AppIcon(bundleID: profile.bundleID, size: 16)
                    Text("Using \(profile.name) setup")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Hairline()

            HStack(spacing: 8) {
                Button {
                    close()
                    (NSApp.delegate as? AppDelegate)?.showWindow()
                } label: {
                    Text("Open Glideball")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ball)
                Button {
                    close()
                    (NSApp.delegate as? AppDelegate)?.showSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings…")
                .accessibilityLabel(Text("Settings…"))
                Button {
                    close()
                    CommandPalette.shared.open()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Search Glideball (⌘K)")
                .accessibilityLabel(Text("Search Glideball", comment: "VoiceOver: the search palette's field"))
            }
            .controlSize(.large)
        }
        .padding(16)
        .frame(width: Self.width)
        .animation(Theme.Motion.spring, value: model.modes.precision)
        .animation(Theme.Motion.spring, value: model.activeProfile?.id)
    }

    private func today(_ m: Metric) -> String {
        switch m {
        case .clicks: model.totals.clicks.formatted()
        case .ball: OverviewView.meters(model.totals.ballCounts / AppModel.countsPerInch * 0.0254)
        case .scroll: OverviewView.meters(model.totals.scrollPoints * Tally.metersPerScrollPoint)
        }
    }

    private func todayLabel(_ m: Metric) -> String {
        switch m {
        case .clicks: String(localized: "clicks", comment: "Share picture: under the number of clicks")
        case .ball: String(localized: "rolled", comment: "Share picture: under the distance the ball rolled")
        case .scroll: String(localized: "scrolled", comment: "Share picture: under the distance scrolled")
        }
    }
}
