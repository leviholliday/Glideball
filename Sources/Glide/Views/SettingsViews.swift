import AppKit
import SwiftUI

// The panes of the Settings window (see SettingsWindow.swift). Each is a
// grouped form at a fixed width; the window takes its height from the form.

/// One Settings tab: a grouped form, as tall as its content.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 600)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Settings › General: how Glideball starts and shows itself, its language and
/// animation, which trackballs it works with, and its sounds.
struct GeneralSettingsPane: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsForm {
            Section {
                ToggleRow(title: "Open at login", subtitle: "Starts quietly in the background so your trackball is always tuned.",
                          symbol: "power", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                ToggleRow(title: "Menu bar icon",
                          subtitle: "Quick access to pause, precision and updates. Glideball keeps running either way — reopen it from the Dock.",
                          symbol: "menubar.rectangle", isOn: $model.menuBarIcon)
                ToggleRow(title: "Show in Dock and app switcher",
                          subtitle: "Turn off to run purely in the background. Open Glideball again from its menu-bar icon (which then stays on).",
                          symbol: "dock.rectangle", isOn: $model.showInDock)
            }
            Section {
                LanguageRow()
                PerformanceRow(model: model)
            }
            Section {
                ToggleRow(title: "Other Kensington trackballs",
                          subtitle: "Let Glideball work with Kensington trackballs besides the Expert Mouse. I haven't tuned it on them yet, so you may hit bugs.",
                          symbol: "computermouse", isOn: $model.otherTrackballs)
            }
            Section {
                ToggleRow(title: "Celebrations",
                          subtitle: "A toast and a little confetti when you reach a milestone or set a personal best. Badges are kept either way.",
                          symbol: "party.popper", isOn: Bindable(model.delight).celebrationsOn)
                ToggleRow(title: "Celebration sounds", subtitle: "A soft chime to go with them.",
                          symbol: "speaker.wave.2", isOn: Bindable(model.delight).soundsOn)
                    .disabled(!model.delight.celebrationsOn)
                LaunchStyleRow()
                ToggleRow(title: "Launch sound",
                          subtitle: "A soft chime the first time Glideball opens after an update. Never when your Mac is muted.",
                          symbol: "music.note", isOn: Bindable(LaunchExperience.shared).soundsOn)
                    .disabled(LaunchExperience.shared.style == .none)
            }
        }
    }
}

/// Settings › Updates: the version, Check for Updates, and early updates.
struct UpdatesSettingsPane: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsForm {
            Section {
                UpdatesRow(updates: model.updates)
                ToggleRow(title: "Early updates",
                          subtitle: "Get new versions before they go out to everyone. They've had less testing, so you may hit bugs.",
                          symbol: "flask", isOn: $model.earlyUpdates)
            }
        }
    }
}

/// Settings › Privacy: opt-in crash reports and stats (see `ShareData`).
struct PrivacySettingsPane: View {
    var body: some View {
        SettingsForm {
            Section {
                ShareDataRow()
            }
        }
    }
}

/// How much the window animates: Smoothest, Efficient (the default) or Minimal.
struct PerformanceRow: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Performance").font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Picker("Performance", selection: $model.performance) {
                ForEach(PerformanceMode.allCases) { mode in
                    Text(verbatim: mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var detail: LocalizedStringKey {
        switch model.performance {
        case .smooth: "The window animates at full rate. Uses the most CPU while it's open."
        case .efficient: "Easy on your CPU: the window animates less when it isn't in front, and holds still when nothing moves."
        case .minimal: "The window updates only a few times a second and its background holds still. Scrolling and buttons are never affected."
        }
    }
}

/// What plays when Glideball opens: the animation, a quick fade, or nothing.
struct LaunchStyleRow: View {
    @Bindable private var launch = LaunchExperience.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("When Glideball opens").font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Picker("When Glideball opens", selection: $launch.style) {
                ForEach(LaunchExperience.Style.allCases) { style in
                    Text(verbatim: style.title).tag(style)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var detail: LocalizedStringKey {
        switch launch.style {
        case .animation: "A short animation over the window. You can click or press Esc to skip it."
        case .fade: "The Glideball mark shows for a moment, then the window fades in."
        case .none: "The window opens with no animation at all."
        }
    }
}

/// Glide's own language, separate from the Mac's. Takes effect on relaunch.
struct LanguageRow: View {
    @State private var choice = AppLanguage.chosen

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Language").font(.system(size: 14, weight: .medium))
                Text("Glideball can speak a different language from the rest of your Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if choice != AppLanguage.atLaunch {
                Button("Relaunch to Apply", action: AppLanguage.relaunch)
                    .buttonStyle(.glassProminent)
                    .tint(.cyan)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            Picker("Language", selection: $choice) {
                Text("System Default").tag(AppLanguage?.none)
                Divider()
                ForEach(AppLanguage.allCases) { language in
                    Text(verbatim: language.nativeName).tag(AppLanguage?.some(language))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .animation(.smooth(duration: 0.25), value: choice)
        .onChange(of: choice) { _, new in AppLanguage.chosen = new }
    }
}

/// "Glideball 2.6 — up to date" with a Check for Updates button.
struct UpdatesRow: View {
    let updates: UpdateChecker

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Updates").font(.system(size: 14, weight: .medium))
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            if let update = updates.available {
                Button("Install \(GlideVersion(update.version)?.display ?? update.version)") { updates.install() }
                    .buttonStyle(.glassProminent)
                    .tint(.cyan)
            } else {
                Button {
                    // The Software Update window shows the result clearly (and checks).
                    if let app = NSApp.delegate as? AppDelegate { app.showUpdatePanel() } else { updates.checkNow() }
                } label: {
                    if updates.manualCheck == .checking {
                        ProgressView().controlSize(.small).frame(width: 110)
                    } else {
                        Text("Check for Updates")
                    }
                }
                .buttonStyle(.glass)
                .disabled(updates.manualCheck == .checking)
            }
        }
        .animation(.smooth, value: updates.manualCheck)
    }

    private var status: String {
        let current = "Glideball \(GlideVersion(updates.currentVersion)?.display ?? updates.currentVersion)"
        if let update = updates.available {
            let new = GlideVersion(update.version)?.display ?? update.version
            return String(localized: "\(current) · \(new) is ready to install", comment: "Glideball 2.6 · 2.7 is ready to install")
        }
        switch updates.manualCheck {
        case .upToDate: return String(localized: "\(current) · You’re up to date ✓", comment: "%@ is “Glideball 2.6”")
        case .failed: return String(localized: "\(current) · Couldn’t reach GitHub — try again later", comment: "%@ is “Glideball 2.6”")
        case .checking: return String(localized: "\(current) · Checking…", comment: "%@ is “Glideball 2.6”")
        case .idle: return String(localized: "\(current) · Checks automatically once a day", comment: "%@ is “Glideball 2.6”")
        }
    }
}
