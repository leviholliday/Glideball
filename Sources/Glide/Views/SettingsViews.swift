import AppKit
import SwiftUI

// The tabs of the Settings window (SettingsWindow.swift): General, Look & Sound,
// Updates and Privacy here, Shortcuts in ShortcutsSettings.swift. They're made of
// the main window's pieces (sections, one quiet group of rows each), and every
// row has a hint under it that says what its current value does, and changes
// with it.

// MARK: - Pieces

/// One Settings tab: sections down a fixed-width column.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            content
        }
        .padding(.horizontal, 26)
        .padding(.top, 20)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

enum SettingsLayout {
    /// Where a group's hairlines start when its rows have symbols.
    static let symbolInset = Theme.Space.rowHorizontal + Theme.Space.symbolColumn + Theme.Space.symbolGap
}

/// A Settings row: symbol, label, a hint about now (it cross-fades as it
/// changes), an optional "Learn more" link, and the control trailing. The same
/// metrics as `SettingRow`. Put `.findable(...)` on it so search can find it
/// (and point it out: `SettingsSpotlight`).
struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    var hint: String? = nil
    var symbol: String? = nil
    var link: URL? = nil
    @ViewBuilder var control: Control
    @Environment(\.findableID) private var findableID
    private let spot = SettingsSpotlight.shared

    var body: some View {
        let _ = FindableAudit.note(title, findableID)
        let lit = findableID != nil && spot.row == findableID
        HStack(alignment: .center, spacing: Theme.Space.symbolGap) {
            if let symbol {
                RowSymbol(symbol: symbol, tint: lit ? Theme.ball : nil)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint {
                    Text(verbatim: hint)
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(hint)
                        .transition(.opacity)
                }
                if let link {
                    Link(destination: link) {
                        Text("Learn more").font(Theme.Font.hint)
                    }
                    .tint(Theme.ball)
                    .help(Text(verbatim: link.absoluteString))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.vertical, Theme.Space.rowVertical)
        .frame(minHeight: Theme.Space.rowMinHeight)
        .animation(Theme.Motion.fade, value: hint)
        .animation(.easeInOut(duration: 0.4), value: lit)
        .accessibilityElement(children: .contain)
    }
}

/// A Settings row whose control is a switch.
struct SettingsToggle: View {
    let title: LocalizedStringKey
    let hint: String
    let symbol: String
    @Binding var isOn: Bool
    var link: URL? = nil

    var body: some View {
        SettingsRow(title: title, hint: hint, symbol: symbol, link: link) {
            Toggle(isOn: $isOn) { Text(title) }
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

/// A menu picker sized to its choice, for the trailing side of a row.
private struct RowPicker<Value: Hashable, Options: View>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    @ViewBuilder var options: Options

    var body: some View {
        Picker(selection: $selection) { options } label: { Text(title) }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
    }
}

// MARK: - General

/// Settings › General: opening and quitting, where Glideball shows, which
/// trackballs it works with, its language, and what else may control it.
struct GeneralSettingsPane: View {
    @Bindable var model: AppModel
    @Bindable private var launch = LaunchExperience.shared
    @Bindable private var panel = MenuBarPanelController.shared

    var body: some View {
        SettingsPage {
            SectionBlock(title: "Opening and quitting", dividerInset: SettingsLayout.symbolInset) {
                SettingsToggle(title: "Open at login", hint: loginHint, symbol: "power",
                               isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .findable(.openAtLogin)
                SettingsRow(title: "When Glideball opens", hint: launchHint, symbol: "play.circle") {
                    RowPicker(title: "When Glideball opens", selection: $launch.style) {
                        ForEach(LaunchExperience.Style.allCases) { style in
                            Text(verbatim: style.title).tag(style)
                        }
                    }
                }
                .findable(.launchStyle)
                SettingsToggle(title: "Ask before quitting", hint: quitHint, symbol: "xmark.circle", isOn: $model.confirmQuit)
                    .findable(.askBeforeQuitting)
            }
            SectionBlock(title: "Where Glideball shows", dividerInset: SettingsLayout.symbolInset) {
                SettingsToggle(title: "Menu bar icon", hint: menuBarHint, symbol: "menubar.rectangle", isOn: $model.menuBarIcon)
                    .findable(.menuBarIcon)
                SettingsRow(title: "Menu bar icon style", hint: menuBarStyleHint, symbol: "paintpalette") {
                    HStack(spacing: 10) {
                        MenuBarIconPreview(style: model.menuBarIconStyle)
                        RowPicker(title: "Menu bar icon style", selection: $model.menuBarIconStyle) {
                            ForEach(MenuBarIcon.Style.allCases) { style in
                                Text(verbatim: style.title).tag(style)
                            }
                        }
                    }
                }
                .disabled(!model.menuBarIcon)
                .findable(.menuBarIconStyle)
                SettingsRow(title: "Menu bar icon opens", hint: menuBarOpensHint, symbol: "rectangle.topthird.inset.filled") {
                    RowPicker(title: "Menu bar icon opens", selection: $panel.opens) {
                        ForEach(MenuBarClick.allCases) { c in
                            Text(verbatim: c.title).tag(c)
                        }
                    }
                }
                .disabled(!model.menuBarIcon)
                .findable(.menuBarOpens)
                SettingsToggle(title: "Show in Dock and app switcher", hint: dockHint, symbol: "dock.rectangle", isOn: $model.showInDock)
                    .findable(.showInDock)
                LanguageRow()
                    .findable(.language)
            }
            SectionBlock(title: "Trackballs and other apps", dividerInset: SettingsLayout.symbolInset) {
                SettingsToggle(title: "Other Kensington trackballs", hint: otherTrackballsHint, symbol: "computermouse",
                               isOn: $model.otherTrackballs)
                    .findable(.otherTrackballs)
                SettingsToggle(title: "Low battery alerts", hint: lowBatteryHint, symbol: "battery.25percent",
                               isOn: $model.lowBatteryAlerts)
                    .findable(.lowBattery)
                SettingsToggle(title: "Allow Raycast and scripts", hint: externalHint, symbol: "link",
                               isOn: $model.allowExternalControl, link: SiteLinks.help)
                    .findable(.externalControl)
            }
            SharingNameSection()   // SharingNameSettings.swift
        }
    }

    private var menuBarStyleHint: String {
        guard model.menuBarIcon else {
            return String(localized: "Turn on the menu bar icon to choose how it looks.", comment: "Settings › General hint")
        }
        switch model.menuBarIconStyle {
        case .mono: return String(localized: "One color that matches the menu bar, like Apple’s own icons.", comment: "Settings › General hint: menu bar icon style Mono")
        case .color: return String(localized: "The ball shows in your ball color, which you pick in Look.", comment: "Settings › General hint: menu bar icon style Color")
        }
    }

    private var menuBarOpensHint: String {
        guard model.menuBarIcon else {
            return String(localized: "Turn on the menu bar icon to choose what it opens.", comment: "Settings › General hint")
        }
        switch panel.opens {
        case .menu: return String(localized: "A click shows the menu: Pause, Precision and Settings.", comment: "Settings › General hint: the menu bar icon opens its menu")
        case .panel: return String(localized: "A click shows a small panel with your trackball, the main switches and today’s numbers. Right-click for the menu.", comment: "Settings › General hint: the menu bar icon opens a panel")
        }
    }

    private var loginHint: String {
        model.launchAtLogin
            ? String(localized: "Glideball starts quietly when you log in, so your trackball is ready straight away.")
            : String(localized: "You’ll open Glideball yourself after logging in. Until then, your trackball works like plain macOS.")
    }

    private var launchHint: String {
        switch launch.style {
        case .animation: String(localized: "A short animation over the window, a different one each time. Click or press Esc to skip it.")
        case .fade: String(localized: "The Glideball mark shows for a moment, then the window fades in.")
        case .none: String(localized: "The window opens straight away, with no animation.")
        }
    }

    private var quitHint: String {
        model.confirmQuit
            ? String(localized: "Quitting asks first, since your trackball goes back to plain macOS until Glideball opens again.")
            : String(localized: "⌘Q quits straight away. Your trackball goes back to plain macOS until Glideball opens again.")
    }

    private var menuBarHint: String {
        model.menuBarIcon
            ? String(localized: "Pause, Precision and Settings are one click away in the menu bar.")
            : String(localized: "No icon in the menu bar. Open Glideball from the Dock to change things.")
    }

    private var dockHint: String {
        model.showInDock
            ? String(localized: "Glideball shows in the Dock and in ⌘-Tab like any other app.")
            : String(localized: "Glideball runs in the background. Open it from its menu-bar icon, which stays on while this is off.")
    }

    private var otherTrackballsHint: String {
        model.otherTrackballs
            ? String(localized: "Glideball also works with Kensington’s other trackballs. I haven’t tuned it on them yet, so you may hit bugs.")
            : String(localized: "Just the Expert Mouse for now. Turn this on to try Glideball with Kensington’s other trackballs.")
    }

    private var lowBatteryHint: String {
        model.lowBatteryAlerts
            ? String(localized: "You’ll get a notification at 15% and again at 5%. It only works with wireless trackballs that report their battery, and I haven’t been able to test it on one yet.")
            : String(localized: "A notification when a wireless trackball’s battery runs low. It only works with models that report their battery, and I haven’t been able to test it on one yet.")
    }

    private var externalHint: String {
        model.allowExternalControl
            ? String(localized: "Raycast and scripts can pause Glideball, switch modes and change the pointer speed with glideball:// links.")
            : String(localized: "Lets Raycast and scripts pause Glideball, switch modes and change the pointer speed. It stays off unless you turn it on.")
    }
}

// What search finds in General (each row above carries its own).
extension Findable {
    static let openAtLogin = Findable(
        id: "open-at-login", title: String(localized: "Open at login"),
        detail: String(localized: "Start Glideball when you log in, so your trackball is ready.", comment: "Search palette: Open at login"),
        keywords: String(localized: "startup, launch, login items, boot, start automatically", comment: "Search words for Open at login (comma-separated; words people might type)"),
        symbol: "power", place: .settings(.general))
    static let launchStyle = Findable(
        id: "launch-style", title: String(localized: "When Glideball opens"),
        detail: String(localized: "The short animation, a quick fade, or nothing at all.", comment: "Search palette: When Glideball opens"),
        keywords: String(localized: "animation, intro, splash, startup, skip", comment: "Search words for When Glideball opens (comma-separated)"),
        symbol: "play.circle", place: .settings(.general))
    static let askBeforeQuitting = Findable(
        id: "ask-before-quitting", title: String(localized: "Ask before quitting"),
        detail: String(localized: "⌘Q asks first, so you don’t quit by accident.", comment: "Search palette: Ask before quitting"),
        keywords: String(localized: "quit, confirm, command q, close", comment: "Search words for Ask before quitting (comma-separated)"),
        symbol: "xmark.circle", place: .settings(.general))
    static let menuBarIcon = Findable(
        id: "menu-bar-icon", title: String(localized: "Menu bar icon"),
        detail: String(localized: "Show or hide Glideball’s icon in the menu bar.", comment: "Search palette: Menu bar icon"),
        keywords: String(localized: "status bar, status item, top bar, tray", comment: "Search words for Menu bar icon (comma-separated)"),
        symbol: "menubar.rectangle", place: .settings(.general))
    static let menuBarIconStyle = Findable(
        id: "menu-bar-icon-style", title: String(localized: "Menu bar icon style"),
        detail: String(localized: "A one-color icon like Apple’s, or the ball in your ball color.", comment: "Search palette: Menu bar icon style"),
        keywords: String(localized: "status bar, icon, color, colour, mono, template, tray", comment: "Search words for Menu bar icon style (comma-separated)"),
        symbol: "paintpalette", place: .settings(.general))
    static let menuBarOpens = Findable(
        id: "menu-bar-opens", title: String(localized: "Menu bar icon opens"),
        detail: String(localized: "A menu, or a small panel with the trackball and quick controls.", comment: "Search palette: Menu bar icon opens"),
        keywords: String(localized: "panel, popover, menu bar, quick controls, status bar", comment: "Search words for Menu bar icon opens (comma-separated)"),
        symbol: "rectangle.topthird.inset.filled", place: .settings(.general))
    static let showInDock = Findable(
        id: "show-in-dock", title: String(localized: "Show in Dock and app switcher"),
        detail: String(localized: "Hide Glideball from the Dock and ⌘-Tab to keep it in the background.", comment: "Search palette: Show in Dock"),
        keywords: String(localized: "dock, hide, background, command tab, app switcher", comment: "Search words for Show in Dock (comma-separated)"),
        symbol: "dock.rectangle", place: .settings(.general))
    static let language = Findable(
        id: "language", title: String(localized: "Language"),
        detail: String(localized: "Use Glideball in another language than your Mac.", comment: "Search palette: Language"),
        keywords: String(localized: "translation, english, german, spanish, french, locale", comment: "Search words for Language (comma-separated)"),
        symbol: "globe", place: .settings(.general))
    static let otherTrackballs = Findable(
        id: "other-trackballs", title: String(localized: "Other Kensington trackballs"),
        detail: String(localized: "Try Glideball with Kensington trackballs besides the Expert Mouse.", comment: "Search palette: Other Kensington trackballs"),
        keywords: String(localized: "slimblade, orbit, trackball, beta, device, support", comment: "Search words for Other Kensington trackballs (comma-separated)"),
        symbol: "computermouse", place: .settings(.general))
    static let lowBattery = Findable(
        id: "low-battery", title: String(localized: "Low battery alerts"),
        detail: String(localized: "A notification when a wireless trackball runs low.", comment: "Search palette: Low battery alerts"),
        keywords: String(localized: "battery, wireless, bluetooth, notification, charge", comment: "Search words for Low battery alerts (comma-separated)"),
        symbol: "battery.25percent", place: .settings(.general))
    static let externalControl = Findable(
        id: "external-control", title: String(localized: "Allow Raycast and scripts"),
        detail: String(localized: "Let Raycast and glideball:// links pause Glideball and change modes.", comment: "Search palette: Allow Raycast and scripts"),
        keywords: String(localized: "raycast, alfred, stream deck, url, automation, shortcuts, script", comment: "Search words for Allow Raycast and scripts (comma-separated)"),
        symbol: "link", place: .settings(.general))
}

extension GeneralSettingsPane {
    static let findables: [Findable] = [.openAtLogin, .launchStyle, .askBeforeQuitting, .menuBarIcon, .menuBarIconStyle, .menuBarOpens,
                                        .showInDock, .language, .otherTrackballs, .lowBattery, .externalControl,
                                        .sharingName, .sharingNamePictures, .sharingNameLinks]
}

/// The menu-bar icon as it looks now, on a little piece of menu bar.
struct MenuBarIconPreview: View {
    let style: MenuBarIcon.Style
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let image = MenuBarIcon.image(.on, style: style, theme: BallThemeStore.shared.theme)
        Image(nsImage: image)
            .renderingMode(style == .mono ? .template : .original)
            .foregroundStyle(.primary)
            .frame(width: 30, height: 22)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.07)))
            .accessibilityHidden(true)
    }
}

/// How much the window animates: Smoothest, Efficient (the default) or Minimal.
struct PerformanceRow: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsRow(title: "Performance", hint: hint, symbol: "gauge.with.dots.needle.33percent") {
            RowPicker(title: "Performance", selection: $model.performance) {
                ForEach(PerformanceMode.allCases) { mode in
                    Text(verbatim: mode.title).tag(mode)
                }
            }
        }
    }

    private var hint: String {
        switch model.performance {
        case .smooth: String(localized: "The window animates at full rate. Uses the most CPU while it's open.")
        case .efficient: String(localized: "Easy on your CPU: the window animates less when it isn't in front, and holds still when nothing moves.")
        case .minimal: String(localized: "The window updates only a few times a second and its background holds still. Scrolling and buttons are never affected.")
        }
    }
}

/// Glideball's own language, separate from the Mac's. Takes effect on relaunch.
struct LanguageRow: View {
    @State private var choice = AppLanguage.chosen

    var body: some View {
        SettingsRow(title: "Language", hint: hint, symbol: "globe") {
            HStack(spacing: 8) {
                if choice != AppLanguage.atLaunch {
                    Button("Relaunch to Apply", action: AppLanguage.relaunch)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.ball)
                        .controlSize(.small)
                        .transition(.opacity)
                }
                RowPicker(title: "Language", selection: $choice) {
                    Text("Same as your Mac").tag(AppLanguage?.none)
                    Divider()
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.nativeName).tag(AppLanguage?.some(language))
                    }
                }
            }
        }
        .animation(Theme.Motion.fade, value: choice)
        .onChange(of: choice) { _, new in AppLanguage.chosen = new }
    }

    private var hint: String {
        if choice != AppLanguage.atLaunch {
            return String(localized: "Glideball switches the next time it opens.")
        }
        guard let choice else {
            return String(localized: "Glideball follows your Mac’s language. Pick one here to use a different one just for Glideball.")
        }
        return String(localized: "Glideball uses \(choice.nativeName), whatever language your Mac is in.", comment: "%@ is a language’s own name, like Deutsch")
    }
}

// MARK: - Look

/// Settings › Look: the ball's color, how strongly the window's light answers
/// the trackball and how much it animates, the app icon, and celebrations.
struct LookSettingsPane: View {
    @Bindable var model: AppModel
    private let icons = AppIconChoice.shared

    var body: some View {
        SettingsPage {
            PlainSection(title: "Ball color",
                         caption: "Colors the trackball everywhere in Glideball, and the light it throws. Ball blue, ring pink and buttons amber stay the same in charts and badges, so they always mean the same thing.") {
                BallColorPicker()
            }
            .findable(.ballColor)
            SectionBlock(title: "Light and motion", dividerInset: SettingsLayout.symbolInset) {
                TuningSlider(title: "Light", symbol: "sun.max", value: $model.lightIntensity, range: 0...1, step: 0.05,
                             format: { lightLabel($0) }, lowLabel: "Off", highLabel: "Full",
                             hint: .verbatim(lightHint), tint: Theme.ball, defaultValue: 0.6)
                    .findable(.light)
                PerformanceRow(model: model)
                    .findable(.performance)
            }
            SectionBlock(title: "Icon and celebrations", dividerInset: SettingsLayout.symbolInset) {
                SettingsRow(title: "App icon", hint: iconHint, symbol: "app.badge") {
                    AppIconPicker()
                }
                .findable(.appIcon)
                SettingsToggle(title: "Celebrations", hint: celebrationsHint, symbol: "party.popper",
                               isOn: Bindable(model.delight).celebrationsOn)
                    .findable(.celebrations)
                SettingsToggle(title: "Weekly recap", hint: recapHint, symbol: "calendar",
                               isOn: Bindable(RecapCenter.shared).enabled)
                    .findable(.weeklyRecap)
            }
        }
    }

    private var recapHint: String {
        RecapCenter.shared.enabled
            ? String(localized: "On the first day you open Glideball each week, a short look back at the week before. Only after a week you really used it.", comment: "Settings › Look hint: weekly recap on")
            : String(localized: "No weekly look back. You can still see last week any time from Overview.", comment: "Settings › Look hint: weekly recap off")
    }

    private func lightLabel(_ v: Double) -> String {
        v < 0.01 ? String(localized: "Off", comment: "Light strength: none") : v.wholePercent
    }

    private var lightHint: String {
        let v = model.lightIntensity
        if v < 0.01 { return String(localized: "The window stays still and dark. The trackball itself still answers your hand.") }
        if v < 0.4 { return String(localized: "A soft glow when you roll, spin or click, easy to ignore.") }
        if v < 0.8 { return String(localized: "The room lights up with your hand: blue when you roll, pink when you spin, amber when you click.") }
        return String(localized: "The full show: the light fills the window as you use the trackball.")
    }

    private var iconHint: String {
        switch icons.style {
        case .orb: String(localized: "The Dock and the app switcher show the Orb, the same as Finder.")
        case .classic: String(localized: "The Dock and the app switcher show the classic icon while Glideball runs. Finder shows the Orb either way.")
        }
    }

    private var celebrationsHint: String {
        model.delight.celebrationsOn
            ? String(localized: "A toast and a little confetti when you reach a milestone or set a personal best.")
            : String(localized: "No toasts or confetti. Your badges and records are still kept on the Overview page.")
    }
}

extension Findable {
    static let ballColor = Findable(
        id: "ball-color", title: String(localized: "Ball color"),
        detail: String(localized: "Color the trackball and the light it throws.", comment: "Search palette: Ball color"),
        keywords: String(localized: "theme, colour, color, appearance, orb, look, custom", comment: "Search words for Ball color (comma-separated)"),
        symbol: "paintpalette", place: .settings(.look), boost: 4)
    static let light = Findable(
        id: "light", title: String(localized: "Light"),
        detail: String(localized: "How strongly the window lights up when you use the trackball.", comment: "Search palette: Light"),
        keywords: String(localized: "glow, brightness, aurora, effects, calm", comment: "Search words for the Light slider (comma-separated)"),
        symbol: "sun.max", place: .settings(.look))
    static let performance = Findable(
        id: "performance", title: String(localized: "Performance"),
        detail: String(localized: "How much the window animates, and how much CPU it uses.", comment: "Search palette: Performance"),
        keywords: String(localized: "cpu, battery, energy, animation, smooth, minimal, efficient", comment: "Search words for Performance (comma-separated)"),
        symbol: "gauge.with.dots.needle.33percent", place: .settings(.look))
    static let appIcon = Findable(
        id: "app-icon", title: String(localized: "App icon"),
        detail: String(localized: "The Orb or the classic icon in the Dock.", comment: "Search palette: App icon"),
        keywords: String(localized: "icon, dock icon, classic, orb", comment: "Search words for App icon (comma-separated)"),
        symbol: "app.badge", place: .settings(.look))
    static let celebrations = Findable(
        id: "celebrations", title: String(localized: "Celebrations"),
        detail: String(localized: "A toast and a little confetti for milestones and records.", comment: "Search palette: Celebrations"),
        keywords: String(localized: "confetti, toast, milestone, record, notification", comment: "Search words for Celebrations (comma-separated)"),
        symbol: "party.popper", place: .settings(.look))
    static let weeklyRecap = Findable(
        id: "weekly-recap", title: String(localized: "Weekly recap"),
        detail: String(localized: "A short look back at last week, once a week.", comment: "Search palette: Weekly recap"),
        keywords: String(localized: "summary, week, stats, report, last week", comment: "Search words for Weekly recap (comma-separated)"),
        symbol: "calendar", place: .settings(.look))
}

extension LookSettingsPane {
    static let findables: [Findable] = [.ballColor, .light, .performance, .appIcon, .celebrations, .weeklyRecap]
}

/// The ball colors as little balls to click, and Custom with three color wells.
struct BallColorPicker: View {
    private let store = BallThemeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                ForEach(BallTheme.curated) { theme in
                    swatch(theme, selected: store.theme.id == theme.id)
                }
                swatch(BallTheme.custom(store.custom), selected: store.theme.id == "custom")
            }
            if store.theme.id == "custom" {
                HStack(spacing: 18) {
                    well(0, String(localized: "Top", comment: "Custom ball color: the top of the ball"))
                    well(1, String(localized: "Middle", comment: "Custom ball color"))
                    well(2, String(localized: "Bottom", comment: "Custom ball color: the bottom of the ball"))
                    Spacer(minLength: 0)
                    Text("Light colors work best at the top, deep ones at the bottom.")
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 220, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .groupBackground()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Theme.Motion.spring, value: store.theme.id)
    }

    private func swatch(_ theme: BallTheme, selected: Bool) -> some View {
        Button {
            store.choose(theme.id)
            Sounds.shared.detent(pitch: 1.1, volume: 0.45)
        } label: {
            VStack(spacing: 6) {
                OrbSwatch(palette: theme.palette, size: 44)
                    .padding(4)
                    .overlay {
                        Circle().strokeBorder(selected ? Theme.ball : .clear, lineWidth: 2)
                    }
                    .shadow(color: selected ? theme.glow[1].opacity(0.55) : .clear, radius: 8)
                Text(verbatim: theme.title)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(radius: 10))
        .help(theme.title)
        .accessibilityLabel(Text(verbatim: theme.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func well(_ i: Int, _ label: String) -> some View {
        HStack(spacing: 6) {
            ColorPicker(selection: Binding(get: { store.custom[i].color },
                                           set: { store.setCustom(i, to: OrbRGB(NSColor($0))) }),
                        supportsOpacity: false) { Text(verbatim: label) }
                .labelsHidden()
            Text(verbatim: label).font(Theme.Font.hint).foregroundStyle(.secondary)
        }
    }
}

/// A little ball in a palette: the orb's layers, small, standing still.
struct OrbSwatch: View {
    let palette: OrbPalette
    var size: CGFloat = 44
    var pixels = 120

    var body: some View {
        let layers = OrbArt.layers(for: palette, pixels: pixels)
        ZStack {
            Image(decorative: layers.liquid, scale: 1)
                .resizable()
                .frame(width: size * OrbArt.liquidSpan, height: size * OrbArt.liquidSpan)
            Image(decorative: layers.glass, scale: 1).resizable()
            Image(decorative: layers.glow, scale: 1).resizable().blendMode(.plusLighter)
            Image(decorative: layers.highlight, scale: 1).resizable()
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1.5)
        .accessibilityHidden(true)
    }
}

// MARK: - Sound

/// Settings › Sound: the one Sounds switch, how loud, which kinds play, and a
/// preview of each.
struct SoundSettingsPane: View {
    @State private var soundsOn = Sounds.shared.enabled
    @State private var volume = Sounds.shared.volume
    @State private var kinds: [SoundKind: Bool] = Dictionary(uniqueKeysWithValues: SoundKind.allCases.map { ($0, Sounds.shared.isOn($0)) })

    var body: some View {
        SettingsPage {
            SectionBlock(title: "Sounds", dividerInset: SettingsLayout.symbolInset) {
                SettingsToggle(title: "Sounds", hint: soundsHint, symbol: soundsOn ? "speaker.wave.2" : "speaker.slash",
                               isOn: $soundsOn)
                    .findable(.sounds)
                TuningSlider(title: "Volume", symbol: "speaker.wave.1", value: $volume, range: 0.1...1, step: 0.05,
                             format: { $0.wholePercent }, lowLabel: "Quiet", highLabel: "Full",
                             hint: "Never louder than your Mac’s own volume.", tint: Theme.ball, defaultValue: 1, tryable: false)
                    .disabled(!soundsOn)
                    .findable(.volume)
            }
            SectionBlock(title: "Play a sound for", dividerInset: SettingsLayout.symbolInset) {
                ForEach(SoundKind.allCases) { kind in
                    SettingsRow(title: .verbatim(kind.title), symbol: kind.symbol) {
                        Toggle(isOn: Binding(get: { kinds[kind] ?? true }, set: { kinds[kind] = $0; Sounds.shared.set(kind, on: $0) })) {
                            Text(verbatim: kind.title)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                    }
                }
            }
            .disabled(!soundsOn)
            .opacity(soundsOn ? 1 : 0.55)
            .findable(.soundKinds)
            SectionBlock(title: "Preview", dividerInset: SettingsLayout.symbolInset) {
                SoundPreviewRow()
                    .findable(.soundPreview)
            }
        }
        .onChange(of: soundsOn) { _, on in Sounds.shared.enabled = on }
        .onChange(of: volume) { _, v in Sounds.shared.volume = v }
    }

    private var soundsHint: String {
        soundsOn
            ? String(localized: "Soft tones when you pause, switch a mode, assign a button or reach a milestone, and a chime after an update. Never when your Mac is muted.")
            : String(localized: "Glideball stays silent, including the chime after an update.")
    }
}

extension Findable {
    static let sounds = Findable(
        id: "sounds", title: String(localized: "Sounds"),
        detail: String(localized: "Soft tones for pausing, modes and milestones, or silence.", comment: "Search palette: Sounds"),
        keywords: String(localized: "audio, mute, silent, quiet, chime, noise, beep", comment: "Search words for Sounds (comma-separated)"),
        symbol: "speaker.wave.2", place: .settings(.sound), boost: 2)
    static let volume = Findable(
        id: "volume", title: String(localized: "Volume"),
        detail: String(localized: "How loud Glideball’s sounds are.", comment: "Search palette: Volume"),
        keywords: String(localized: "loud, quiet, sound level", comment: "Search words for Volume (comma-separated)"),
        symbol: "speaker.wave.1", place: .settings(.sound))
    static let soundKinds = Findable(
        id: "sound-kinds", title: String(localized: "Play a sound for"),
        detail: String(localized: "Choose which things make a sound: pausing, modes, buttons, milestones.", comment: "Search palette: Play a sound for"),
        keywords: String(localized: "click sound, tick, detent, pause sound, mode sound", comment: "Search words for the sound kinds (comma-separated)"),
        symbol: "speaker.badge.exclamationmark", place: .settings(.sound))
    static let soundPreview = Findable(
        id: "sound-preview", title: String(localized: "Hear them"),
        detail: String(localized: "Play each sound once to hear what it’s like.", comment: "Search palette: Hear them (sound preview)"),
        keywords: String(localized: "preview, listen, test sound", comment: "Search words for the sound preview (comma-separated)"),
        symbol: "ear", place: .settings(.sound))
}

extension SoundSettingsPane {
    static let findables: [Findable] = [.sounds, .volume, .soundKinds, .soundPreview]
}

/// "Hear them": each sound once, even with Sounds off, so you can decide.
private struct SoundPreviewRow: View {
    @State private var playing: Sound?

    private let sounds: [(Sound, LocalizedStringKey)] = [
        (.resume, LocalizedStringKey("Resume")), (.pause, LocalizedStringKey("Pause")),
        (.modeOn, LocalizedStringKey("Mode on")), (.modeOff, LocalizedStringKey("Mode off")),
        (.tick, LocalizedStringKey("Assign")), (.milestone, LocalizedStringKey("Milestone")),
        (.milestoneBig, LocalizedStringKey("Big milestone")),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.symbolGap) {
            RowSymbol(symbol: "ear")
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hear them").font(Theme.Font.body)
                    Text("Each one plays once, even with Sounds off.")
                        .font(Theme.Font.hint)
                        .foregroundStyle(.secondary)
                }
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(sounds, id: \.0) { sound, name in
                        Button {
                            Sounds.shared.preview(sound)
                            playing = sound
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if playing == sound { playing = nil } }
                        } label: {
                            Label {
                                Text(name)
                            } icon: {
                                Image(systemName: playing == sound ? "speaker.wave.2.fill" : "play.fill")
                                    .font(.system(size: 8.5))
                                    .frame(width: 11)
                            }
                            .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(ChipButtonStyle())
                        .help("Play this sound")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.vertical, 12)
    }
}

// MARK: - Updates

/// Settings › Updates: the version, when it last looked, Check for Updates,
/// what's new in this version, and early updates.
struct UpdatesSettingsPane: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsPage {
            SectionBlock(title: "Your version", dividerInset: SettingsLayout.symbolInset) {
                UpdatesRow(updates: model.updates)
                    .findable(.checkForUpdates)
                ActionRow(title: "What’s new in this version", hint: .verbatim(whatsNewHint), symbol: "doc.text", external: true) {
                    NSWorkspace.shared.open(SiteLinks.whatsNew(in: model.updates.currentVersion))
                }
                .findable(.releaseNotes)
            }
            SectionBlock(title: "Getting updates", dividerInset: SettingsLayout.symbolInset) {
                SettingsToggle(title: "Early updates", hint: earlyHint, symbol: "flask", isOn: $model.earlyUpdates)
                    .findable(.earlyUpdates)
            }
        }
    }

    static let findables: [Findable] = [.checkForUpdates, .releaseNotes, .earlyUpdates]

    private var whatsNewHint: String {
        String(localized: "The release notes for \(GlideVersion(model.updates.currentVersion)?.display ?? model.updates.currentVersion) on the Glideball website.",
               comment: "%@ is a version, like 2.10 beta 7")
    }

    private var earlyHint: String {
        model.earlyUpdates
            ? String(localized: "You get new versions as soon as they’re out, before everyone else. They’ve had less testing, so you may hit bugs.")
            : String(localized: "You get new versions once they’ve settled. Turn this on to try them early, while I’m still testing.")
    }
}

extension Findable {
    static let checkForUpdates = Findable(
        id: "check-for-updates", title: String(localized: "Your version"),
        detail: String(localized: "Which Glideball you have, and Check for Updates.", comment: "Search palette: Your version"),
        keywords: String(localized: "update, upgrade, version, check for updates, new version", comment: "Search words for Your version (comma-separated)"),
        symbol: "arrow.down.circle", place: .settings(.updates))
    static let releaseNotes = Findable(
        id: "release-notes", title: String(localized: "What’s new in this version"),
        detail: String(localized: "The release notes on the Glideball website.", comment: "Search palette: What's new in this version"),
        keywords: String(localized: "changelog, release notes, changes, news", comment: "Search words for the release notes (comma-separated)"),
        symbol: "doc.text", place: .settings(.updates))
    static let earlyUpdates = Findable(
        id: "early-updates", title: String(localized: "Early updates"),
        detail: String(localized: "Get new versions before everyone else, while they’re still being tested.", comment: "Search palette: Early updates"),
        keywords: String(localized: "beta, prerelease, testing, early access", comment: "Search words for Early updates (comma-separated)"),
        symbol: "flask", place: .settings(.updates))
}

/// "Glideball 2.10 · You’re up to date" with when it last looked, and Check
/// for Updates (or Install, when there's one). Also in About & Help.
struct UpdatesRow: View {
    let updates: UpdateChecker

    var body: some View {
        HStack(spacing: Theme.Space.symbolGap) {
            Image(nsImage: AppIconChoice.shared.image)
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
                .frame(width: Theme.Space.symbolColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Glideball \(GlideVersion(updates.currentVersion)?.display ?? updates.currentVersion)")
                    .font(Theme.Font.body.weight(.medium))
                Text(verbatim: status)
                    .font(Theme.Font.hint)
                    .foregroundStyle(statusIsProblem ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .id(status)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let update = updates.available {
                Button("Install \(update.displayVersion)…") { (NSApp.delegate as? AppDelegate)?.showUpdatePanel(check: false) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ball)
                    .controlSize(.small)
            } else if updates.manualCheck == .checking {
                ProgressView().controlSize(.small).padding(.horizontal, 8)
            } else {
                Button("Check for Updates") {
                    // The Software Update window shows the result clearly (and checks).
                    if let app = NSApp.delegate as? AppDelegate { app.showUpdatePanel() } else { updates.checkNow() }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .padding(.vertical, Theme.Space.rowVertical)
        .frame(minHeight: Theme.Space.rowMinHeight)
        .animation(Theme.Motion.fade, value: status)
    }

    private var statusIsProblem: Bool { updates.manualCheck == .failed && updates.available == nil }

    private var status: String {
        if let update = updates.available {
            return String(localized: "\(update.displayVersion) is ready to install. Your settings and permissions carry over.",
                          comment: "%@ is a version, like 2.11")
        }
        switch updates.manualCheck {
        case .checking:
            return String(localized: "Checking GitHub for a newer version…")
        case .failed:
            return String(localized: "Couldn’t reach GitHub just now. Glideball tries again by itself once a day.")
        case .upToDate, .idle:
            guard let checked = updates.lastChecked else {
                return String(localized: "Glideball checks for updates by itself once a day.")
            }
            let when = checked.formatted(.relative(presentation: .named))
            return String(localized: "You’re up to date. Last checked \(when).", comment: "%@ is a relative time, like “5 minutes ago”")
        }
    }
}

// MARK: - Privacy

/// Settings › Privacy: opt-in crash reports and stats (see `ShareData`), the
/// install ID, what's sent, and Delete My Data with its result right there.
struct PrivacySettingsPane: View {
    var body: some View {
        SettingsPage {
            ShareDataSettings()
        }
    }
}
