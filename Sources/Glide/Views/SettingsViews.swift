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
/// metrics as `SettingRow`. `spotlight` names it for `SettingsSpotlight`.
struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    var hint: String? = nil
    var symbol: String? = nil
    var link: URL? = nil
    var spotlight: String? = nil
    @ViewBuilder var control: Control
    private let spot = SettingsSpotlight.shared

    var body: some View {
        let lit = spotlight != nil && spot.row == spotlight
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
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.ball.opacity(lit ? 0.12 : 0))
                .padding(3)
        }
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
    var spotlight: String? = nil

    var body: some View {
        SettingsRow(title: title, hint: hint, symbol: symbol, link: link, spotlight: spotlight) {
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

/// Settings › General: how Glideball starts and shows itself, its language and
/// how much it animates, and what else it works with.
struct GeneralSettingsPane: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsPage {
            SectionBlock(title: "Opening Glideball", dividerInset: SettingsLayout.symbolInset) {
                SettingsToggle(title: "Open at login", hint: loginHint, symbol: "power",
                               isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                SettingsToggle(title: "Menu bar icon", hint: menuBarHint, symbol: "menubar.rectangle", isOn: $model.menuBarIcon)
                SettingsToggle(title: "Show in Dock and app switcher", hint: dockHint, symbol: "dock.rectangle", isOn: $model.showInDock)
            }
            SectionBlock(title: "Language and performance", dividerInset: SettingsLayout.symbolInset) {
                LanguageRow()
                PerformanceRow(model: model)
            }
            SectionBlock(title: "Works with", dividerInset: SettingsLayout.symbolInset) {
                SettingsToggle(title: "Other Kensington trackballs", hint: otherTrackballsHint, symbol: "computermouse",
                               isOn: $model.otherTrackballs)
                SettingsToggle(title: "Allow Raycast and scripts", hint: externalHint, symbol: "link",
                               isOn: $model.allowExternalControl, link: SiteLinks.help, spotlight: "external-control")
            }
        }
    }

    private var loginHint: String {
        model.launchAtLogin
            ? String(localized: "Glideball starts quietly when you log in, so your trackball is ready straight away.")
            : String(localized: "You’ll open Glideball yourself after logging in. Until then, your trackball works like plain macOS.")
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

    private var externalHint: String {
        model.allowExternalControl
            ? String(localized: "Raycast, Shortcuts and scripts can pause Glideball, switch modes and change the pointer speed with glideball:// links.")
            : String(localized: "Lets Raycast, Shortcuts and scripts pause Glideball, switch modes and change the pointer speed. It stays off unless you turn it on.")
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

// MARK: - Look & Sound

/// Settings › Look & Sound: the app icon, what plays when Glideball opens,
/// celebrations, and the one Sounds switch with a preview of each sound.
struct LookSettingsPane: View {
    @Bindable var model: AppModel
    @Bindable private var launch = LaunchExperience.shared
    private let icons = AppIconChoice.shared
    @State private var soundsOn = Sounds.shared.enabled

    var body: some View {
        SettingsPage {
            SectionBlock(title: "Look", dividerInset: SettingsLayout.symbolInset) {
                SettingsRow(title: "App icon", hint: iconHint, symbol: "app.badge") {
                    AppIconPicker()
                }
                SettingsRow(title: "When Glideball opens", hint: launchHint, symbol: "play.circle") {
                    RowPicker(title: "When Glideball opens", selection: $launch.style) {
                        ForEach(LaunchExperience.Style.allCases) { style in
                            Text(verbatim: style.title).tag(style)
                        }
                    }
                }
                SettingsToggle(title: "Celebrations", hint: celebrationsHint, symbol: "party.popper",
                               isOn: Bindable(model.delight).celebrationsOn)
            }
            SectionBlock(title: "Sound", dividerInset: SettingsLayout.symbolInset) {
                SettingsToggle(title: "Sounds", hint: soundsHint, symbol: soundsOn ? "speaker.wave.2" : "speaker.slash",
                               isOn: $soundsOn, spotlight: "sounds")
                SoundPreviewRow()
            }
        }
        .onChange(of: soundsOn) { _, on in Sounds.shared.enabled = on }
    }

    private var iconHint: String {
        switch icons.style {
        case .orb: String(localized: "The Dock and the app switcher show the Orb, the same as Finder.")
        case .classic: String(localized: "The Dock and the app switcher show the classic icon while Glideball runs. Finder shows the Orb either way.")
        }
    }

    private var launchHint: String {
        switch launch.style {
        case .animation: String(localized: "A short animation over the window, a different one each time. Click or press Esc to skip it.")
        case .fade: String(localized: "The Glideball mark shows for a moment, then the window fades in.")
        case .none: String(localized: "The window opens straight away, with no animation.")
        }
    }

    private var celebrationsHint: String {
        model.delight.celebrationsOn
            ? String(localized: "A toast and a little confetti when you reach a milestone or set a personal best.")
            : String(localized: "No toasts or confetti. Your badges and records are still kept on the Overview page.")
    }

    private var soundsHint: String {
        soundsOn
            ? String(localized: "Soft tones when you pause, switch a mode, save a change or reach a milestone, and a chime after an update. Never when your Mac is muted.")
            : String(localized: "Glideball stays silent, including the chime after an update.")
    }
}

/// "Hear them": each sound once, even with Sounds off, so you can decide.
private struct SoundPreviewRow: View {
    @State private var playing: Sound?

    private let sounds: [(Sound, LocalizedStringKey)] = [
        (.resume, LocalizedStringKey("Resume")), (.pause, LocalizedStringKey("Pause")),
        (.modeOn, LocalizedStringKey("Mode on")), (.modeOff, LocalizedStringKey("Mode off")),
        (.tick, LocalizedStringKey("Saved")), (.milestone, LocalizedStringKey("Milestone")),
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
                ActionRow(title: "What’s new in this version", hint: .verbatim(whatsNewHint), symbol: "doc.text", external: true) {
                    NSWorkspace.shared.open(SiteLinks.whatsNew(in: model.updates.currentVersion))
                }
            }
            SectionBlock(title: "Getting updates", dividerInset: SettingsLayout.symbolInset) {
                SettingsToggle(title: "Early updates", hint: earlyHint, symbol: "flask", isOn: $model.earlyUpdates)
            }
        }
    }

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
