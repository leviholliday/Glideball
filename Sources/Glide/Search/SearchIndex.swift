import AppKit
import Observation
import SwiftUI

// The search palette's index: every setting (`Findable.all`), every command
// in `Commands` (pause, Precision, scroll mode…), the buttons and combos as
// they're set now, app setups, ball colors and presets, badges, and help. It's
// built fresh each time the palette opens (it's small), so it always says
// what's true right now ("Pause Glideball" or "Resume Glideball").

/// One thing the palette can show and do.
struct PaletteItem: Identifiable {
    enum Group: Int, CaseIterable, Comparable {
        case recent, settings, actions, buttons, badges, help

        static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .recent: String(localized: "Recent", comment: "Search palette group")
            case .settings: String(localized: "Settings", comment: "Search palette group")
            case .actions: String(localized: "Actions", comment: "Search palette group")
            case .buttons: String(localized: "Buttons and combos", comment: "Search palette group")
            case .badges: String(localized: "Badges", comment: "Search palette group")
            case .help: String(localized: "Help", comment: "Search palette group")
            }
        }
    }

    let id: String
    var group: Group
    let title: String
    let detail: String
    var keywords: String = ""
    let symbol: String
    /// The part it's about (its icon's color), if any.
    var part: Metric? = nil
    /// Small words on the right: where it is ("Pointer"), or its state ("On").
    var trailing: String? = nil
    /// It's on right now (a mode, the current scroll mode, the ball color in use).
    var isOn = false
    var boost = 0
    /// The `Commands` entry it runs, if it's one (the self-test checks every command has one).
    var command: String? = nil
    /// The `Findable` it jumps to, if it's a setting.
    var findable: String? = nil
    let run: @MainActor () -> Void
}

enum SearchIndex {
    /// Everything, as it is right now.
    static func items(_ model: AppModel = .shared) -> [PaletteItem] {
        settings(model) + actions(model) + buttons(model) + badges(model) + help(model)
    }

    // MARK: Settings

    static func settings(_ model: AppModel) -> [PaletteItem] {
        Findable.all.filter { present($0, model) }.map { f in
            var trailing = f.place.name
            if !f.modes.isEmpty, !f.modes.contains(model.config.scrollMode) {
                trailing += " · " + ListFormatter.localizedString(byJoining: f.modes.map(\.title))
            }
            return PaletteItem(id: "find:" + f.id, group: .settings, title: f.title, detail: f.detail, keywords: f.keywords,
                               symbol: f.symbol, part: f.part, trailing: trailing, boost: f.boost, findable: f.id) {
                PaletteRouter.go(f)
            }
        }
    }

    /// Whether a `sometimes` setting is on its page right now.
    static func present(_ f: Findable, _ model: AppModel) -> Bool {
        guard f.sometimes else { return true }
        switch f.id {
        case Findable.makeItYours.id: return model.delight.checklistVisible
        case Findable.settingsMoved.id: return SettingsHintMemory.isDue()
        case Findable.installID.id, Findable.deleteMyData.id: return ShareData.shared.installID != nil
        case Findable.kensingtonWorks.id: return KensingtonWorksSource.found
        default: return true
        }
    }

    // MARK: Actions (every command, plus colors and presets)

    /// Commands the palette deliberately shows as part of another's entry.
    static let commandAliases: [String: String] = ["pause": "toggle", "resume": "toggle"]

    static func actions(_ model: AppModel) -> [PaletteItem] {
        let target = AppCommandTarget.shared
        var out: [PaletteItem] = []
        for c in Commands.all {
            switch c.id {
            case "pause", "resume", "toggle":
                // One entry that says what it'll do now.
                guard c.id == "toggle" else { continue }
                let paused = target.isPaused
                out.append(PaletteItem(id: "cmd:pause", group: .actions,
                                       title: paused ? String(localized: "Resume Glideball") : String(localized: "Pause Glideball"),
                                       detail: paused ? String(localized: "Turn Glideball back on.", comment: "Search palette: Resume")
                                                      : String(localized: "Your trackball works like a plain mouse until you resume.", comment: "Search palette: Pause"),
                                       keywords: String(localized: "pause, resume, stop, start, disable, enable, off, on, toggle", comment: "Search words for Pause / Resume (comma-separated)"),
                                       symbol: paused ? "play.circle" : "pause.circle", boost: 6, command: "toggle") {
                    PaletteRouter.close()
                    Commands.run("toggle", on: target) { running in Sounds.shared.play(running == true ? .resume : .pause) }
                })
            case "precision", "ball-scroll", "drag-lock":
                guard let mode = GlideMode(rawValue: c.id) else { continue }
                let on = target.isOn(mode)
                out.append(PaletteItem(id: "cmd:" + c.id, group: .actions, title: c.title, detail: modeDetail(mode),
                                       keywords: modeKeywords(mode), symbol: modeSymbol(mode), part: .ball,
                                       trailing: on ? String(localized: "On") : String(localized: "Off"), isOn: on, command: c.id) {
                    PaletteRouter.close()
                    Commands.run(c.id, .toggle, on: target) { on in
                        guard let on else { return NSSound.beep() }
                        Sounds.shared.play(on ? .modeOn : .modeOff)
                    }
                })
            case "scroll-mode":
                for mode in ScrollMode.allCases {
                    let current = target.scrollMode == mode
                    out.append(PaletteItem(id: "cmd:scroll-mode-" + mode.rawValue, group: .actions,
                                           title: String(localized: "Scroll mode: \(mode.title)", comment: "Search palette action; %@ is Native, Flywheel or Follow"),
                                           detail: ModePicker.about(mode),
                                           keywords: String(localized: "scroll mode, scrolling, ring", comment: "Search words for the scroll mode actions (comma-separated)"),
                                           symbol: ModePicker.symbol(mode), part: .scroll,
                                           trailing: current ? String(localized: "In use", comment: "Search palette: this is the current choice") : nil,
                                           isOn: current, command: c.id) {
                        PaletteRouter.close()
                        Commands.run("scroll-mode", .choice(mode.rawValue), on: target)
                        Sounds.shared.detent(pitch: 1.1, volume: 0.45)
                    })
                }
            case "pointer-speed":
                // The number itself is typed into the search ("speed 12"): `numberItems`.
                // Plain, it's the Pointer page's slider, which Settings already lists.
                out.append(PaletteItem(id: "cmd:pointer-speed", group: .actions,
                                       title: String(localized: "Set pointer speed…", comment: "Search palette action"),
                                       detail: String(localized: "Type a number after it, like “speed 12”. Now \(Commands.speedText(target.pointerSpeed)).", comment: "Search palette: Set pointer speed; %@ is the current speed"),
                                       keywords: String(localized: "tracking speed, pointer speed, cursor speed, set speed", comment: "Search words for Set pointer speed (comma-separated)"),
                                       symbol: "gauge.with.dots.needle.67percent", part: .ball, command: c.id) {
                    PaletteRouter.go(.trackingSpeed)
                })
                out += PointerPresetRow.values.map { v in
                    let name = PointerPresetRow.name(v)
                    return PaletteItem(id: "try:pointer-\(v)", group: .actions,
                                       title: String(localized: "Try the \(name) pointer preset", comment: "Search palette action; %@ is a preset like Turbo"),
                                       detail: String(localized: "Ten seconds at that speed, then keep it or let it go back.", comment: "Search palette: try a pointer preset"),
                                       keywords: String(localized: "preset, try, speed, pointer", comment: "Search words for trying a pointer preset (comma-separated)"),
                                       symbol: "timer", part: .ball,
                                       trailing: abs(target.pointerSpeed - v) < 0.01 ? String(localized: "In use", comment: "Search palette: this is the current choice") : nil) {
                        PaletteRouter.tryPointerPreset(v)
                    }
                }
            case "gestures", "per-display-speed":
                let on = c.state(target) == "on"
                let gestures = c.id == "gestures"
                out.append(PaletteItem(id: "cmd:" + c.id, group: .actions, title: c.title,
                                       detail: gestures ? String(localized: "Buttons set to Gesture: hold and roll the ball to do things.", comment: "Search palette: the Gestures switch")
                                                        : String(localized: "Each display uses the speed you gave it.", comment: "Search palette: the per-display speed switch"),
                                       keywords: gestures ? String(localized: "gesture, hold and roll, swipe", comment: "Search words for Gestures (comma-separated)")
                                                          : String(localized: "monitor, display, screen speed", comment: "Search words for per-display speed (comma-separated)"),
                                       symbol: gestures ? "dot.arrowtriangles.up.right.down.left.circle" : "display.2",
                                       part: gestures ? .clicks : .ball,
                                       trailing: on ? String(localized: "On") : String(localized: "Off"), isOn: on, command: c.id) {
                    PaletteRouter.close()
                    Commands.run(c.id, .toggle, on: target)
                    Sounds.shared.play(c.state(target) == "on" ? .modeOn : .modeOff)
                })
            case "app-setup":
                for setup in target.appSetups {
                    let pinned = target.pinnedAppSetup == setup.bundleID
                    out.append(PaletteItem(id: "cmd:app-setup-" + setup.bundleID, group: .actions,
                                           title: String(localized: "Use the \(setup.name) setup now", comment: "Search palette action; %@ is an app's name"),
                                           detail: String(localized: "Whatever app is in front, until you pause or pick automatic again.", comment: "Search palette: use an app setup"),
                                           keywords: String(localized: "app setup, profile, pin", comment: "Search words for using an app setup (comma-separated)"),
                                           symbol: "pin", trailing: pinned ? String(localized: "In use", comment: "Search palette: this is the current choice") : nil,
                                           isOn: pinned, command: c.id) {
                        PaletteRouter.close()
                        Commands.run("app-setup", .name(setup.bundleID), on: target)
                    })
                }
                if target.appSetups.isEmpty {
                    out.append(PaletteItem(id: "cmd:app-setup-none", group: .actions, title: c.title,
                                           detail: String(localized: "There are no app setups yet. Add one on the Apps page.", comment: "Search palette: Use an app setup, with none made yet"),
                                           keywords: String(localized: "app setup, profile, pin", comment: "Search words for using an app setup (comma-separated)"),
                                           symbol: "pin", command: c.id) {
                        PaletteRouter.go(.appSetups)
                    })
                }
                if target.pinnedAppSetup != nil {
                    out.append(PaletteItem(id: "cmd:app-setup-automatic", group: .actions,
                                           title: String(localized: "Follow the app in front", comment: "Search palette action: app setups switch automatically again"),
                                           detail: String(localized: "App setups switch by themselves again.", comment: "Search palette: app setups back to automatic"),
                                           keywords: String(localized: "automatic, unpin, app setup", comment: "Search words for automatic app setups (comma-separated)"),
                                           symbol: "pin.slash", command: c.id) {
                        PaletteRouter.close()
                        Commands.run("app-setup", .name(Commands.automaticSetup), on: target)
                    })
                }
                // Each setup's own page entry, to change it.
                for p in model.config.appProfiles {
                    out.append(PaletteItem(id: "find:app-setup-" + p.id, group: .settings,
                                           title: String(localized: "\(p.name) setup", comment: "Search palette: an app setup; %@ is the app's name"),
                                           detail: p.summary(comparedTo: model.config),
                                           keywords: String(localized: "app setup, profile", comment: "Search words for an app setup (comma-separated)") + ", " + p.bundleID,
                                           symbol: "macwindow", trailing: GlideTab.apps.title, findable: Findable.appSetupID(p.id)) {
                        PaletteRouter.openAppSetup(p.id)
                    })
                }
            case "open":
                for tab in GlideTab.allCases {
                    out.append(PaletteItem(id: "cmd:open-" + tab.rawValue, group: .actions,
                                           title: String(localized: "Go to \(tab.title)", comment: "Search palette action: show a page; %@ is its name"),
                                           detail: tab.summary, keywords: tab.title, symbol: tab.symbol,
                                           trailing: "⌘\(tab.order + 1)", command: c.id) {
                        PaletteRouter.close()
                        AppModel.shared.requestTab(tab)
                    })
                }
            case "settings":
                for pane in SettingsPane.allCases {
                    out.append(PaletteItem(id: "cmd:settings-" + pane.rawValue, group: .actions,
                                           title: String(localized: "Open Settings › \(pane.title)", comment: "Search palette action; %@ is a Settings tab"),
                                           detail: String(localized: "The Settings window, on this tab.", comment: "Search palette: open a Settings tab"),
                                           keywords: String(localized: "preferences, settings, options", comment: "Search words for opening Settings (comma-separated)"),
                                           symbol: pane.symbol, trailing: pane == .general ? "⌘," : nil, command: c.id) {
                        PaletteRouter.close()
                        (NSApp.delegate as? AppDelegate)?.showSettings(pane)
                    })
                }
            case "check-for-updates":
                out.append(PaletteItem(id: "cmd:" + c.id, group: .actions, title: c.title,
                                       detail: String(localized: "See if there’s a newer Glideball.", comment: "Search palette: Check for Updates"),
                                       keywords: String(localized: "update, upgrade, new version", comment: "Search words for Check for Updates (comma-separated)"),
                                       symbol: "arrow.down.circle", command: c.id) {
                    PaletteRouter.close()
                    Commands.run(c.id, on: target)
                })
            case "feedback":
                out.append(PaletteItem(id: "cmd:" + c.id, group: .help, title: c.title,
                                       detail: String(localized: "Tell me about a bug or an idea. It goes straight to me.", comment: "Search palette: Send Feedback"),
                                       keywords: String(localized: "bug, report, idea, contact, problem, support, email", comment: "Search words for Send Feedback (comma-separated)"),
                                       symbol: "envelope", command: c.id) {
                    PaletteRouter.close()
                    Commands.run(c.id, on: target)
                })
            default:
                // A command added later still shows up, run as it is (with its default argument).
                out.append(PaletteItem(id: "cmd:" + c.id, group: .actions, title: c.title, detail: "", symbol: "command", command: c.id) {
                    PaletteRouter.close()
                    Commands.run(c.id, c.parameter?.fallback ?? .none, on: target)
                })
            }
        }

        // Ball colors.
        let store = BallThemeStore.shared
        for theme in BallTheme.curated {
            let current = store.theme.id == theme.id
            out.append(PaletteItem(id: "color:" + theme.id, group: .actions,
                                   title: String(localized: "Ball color: \(theme.title)", comment: "Search palette action; %@ is a ball color's name"),
                                   detail: String(localized: "Colors the trackball and the light it throws.", comment: "Search palette: a ball color"),
                                   keywords: String(localized: "ball color, colour, theme", comment: "Search words for a ball color (comma-separated)"),
                                   symbol: "circle.fill", trailing: current ? String(localized: "In use", comment: "Search palette: this is the current choice") : nil,
                                   isOn: current) {
                PaletteRouter.close()
                store.choose(theme.id)
                Sounds.shared.detent(pitch: 1.1, volume: 0.45)
            })
        }

        // Button presets: they change every button, so they open for a look first.
        let matching = model.config.matchingPreset?.id
        for preset in ButtonPreset.all {
            out.append(PaletteItem(id: "preset:" + preset.id, group: .buttons,
                                   title: String(localized: "Button preset: \(preset.title)", comment: "Search palette; %@ is a button preset's name"),
                                   detail: preset.detail,
                                   keywords: String(localized: "preset, buttons, layout", comment: "Search words for a button preset (comma-separated)"),
                                   symbol: preset.symbol, part: .clicks,
                                   trailing: matching == preset.id ? String(localized: "In use", comment: "Search palette: this is the current choice") : nil,
                                   isOn: matching == preset.id) {
                PaletteRouter.openButtonPreset(preset.id)
            })
        }

        // The window's own things.
        out.append(PaletteItem(id: "app:export", group: .actions, title: String(localized: "Export Settings…"),
                               detail: Findable.exportSettings.detail, keywords: Findable.exportSettings.keywords,
                               symbol: "square.and.arrow.up", trailing: "⌘E") {
            PaletteRouter.close()
            AppModel.shared.exportSettings()
        })
        out.append(PaletteItem(id: "app:import", group: .actions, title: String(localized: "Import Settings…"),
                               detail: Findable.importSettings.detail, keywords: Findable.importSettings.keywords,
                               symbol: "square.and.arrow.down", trailing: "⌘O") {
            PaletteRouter.close()
            AppModel.shared.importSettings()
        })
        // Share… for each part (an app's setup is shared from its row on the Apps page).
        for kind in ShareKind.choosable {
            out.append(PaletteItem(id: "app:share-\(kind.rawValue)", group: .actions, title: PageShareMenu.menuTitle(kind),
                                   detail: Findable.shareSetup.detail, keywords: Findable.shareSetup.keywords,
                                   symbol: "square.and.arrow.up") {
                PaletteRouter.close()
                AppModel.shared.requestShare(kind)
            })
        }
        if KensingtonWorksSource.found {
            out.append(PaletteItem(id: "app:kensingtonworks", group: .actions, title: String(localized: "Your KensingtonWorks settings"),
                                   detail: Findable.kensingtonWorks.detail, keywords: Findable.kensingtonWorks.keywords,
                                   symbol: Findable.kensingtonWorks.symbol) {
                PaletteRouter.close()
                AppModel.shared.previewKensingtonWorks()
            })
        }
        if RecapCenter.shared.recap(for: .lastWeek, model.delight) != nil {
            out.append(PaletteItem(id: "app:last-week", group: .actions, title: String(localized: "Last week", comment: "Search palette: open the weekly recap"),
                                   detail: String(localized: "Your recap: last week’s clicks, rolling and scrolling, and new badges.", comment: "Search palette: Last week (the weekly recap)"),
                                   keywords: String(localized: "recap, weekly, summary, week, stats", comment: "Search words for the weekly recap (comma-separated)"),
                                   symbol: "calendar") {
                PaletteRouter.close()
                AppModel.shared.showRecap()
            })
        }
        return out
    }

    static func modeDetail(_ mode: GlideMode) -> String {
        switch mode {
        case .precision: String(localized: "Slows the cursor for fine work until you switch it off.", comment: "Search palette: Precision")
        case .ballScroll: String(localized: "Rolling the ball scrolls and the cursor stays put, until you switch it off.", comment: "Search palette: Scroll with ball")
        case .dragLock: String(localized: "Holds the left button down so you can drag without holding it.", comment: "Search palette: Drag lock")
        }
    }

    static func modeKeywords(_ mode: GlideMode) -> String {
        switch mode {
        case .precision: String(localized: "slow, fine, sniper, accurate, mode", comment: "Search words for Precision (comma-separated)")
        case .ballScroll: String(localized: "scroll, pan, mode", comment: "Search words for Scroll with ball (comma-separated)")
        case .dragLock: String(localized: "drag, hold, click lock, mode", comment: "Search words for Drag lock (comma-separated)")
        }
    }

    static func modeSymbol(_ mode: GlideMode) -> String {
        switch mode {
        case .precision: "scope"
        case .ballScroll: "arrow.up.and.down.and.arrow.left.and.right"
        case .dragLock: "hand.draw"
        }
    }

    /// "speed 12", "pointer speed 4.5": set it straight away.
    static func numberItems(_ query: String) -> [PaletteItem] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " })
        guard words.count >= 2, let last = words.last,
              let parsed = Commands.command("pointer-speed")?.parameter?.parse(String(last).replacingOccurrences(of: ",", with: ".")),
              case .number(let speed) = parsed else { return [] }
        let rest = words.dropLast().joined(separator: " ")
        let speedWords = [String(localized: "speed", comment: "Search: the word typed before a number to set the pointer speed, like “speed 12”").lowercased(),
                          "speed", "pointer", "tracking"]
        guard speedWords.contains(where: { rest.contains($0) }) else { return [] }
        let text = Commands.speedText(speed)
        return [PaletteItem(id: "cmd:pointer-speed-set", group: .actions,
                            title: String(localized: "Set pointer speed to \(text)", comment: "Search palette action; %@ is a number"),
                            detail: String(localized: "Now \(Commands.speedText(AppCommandTarget.shared.pointerSpeed)). Try it for 10 seconds first with ⌥↩.", comment: "Search palette: set the pointer speed; %@ is the current speed"),
                            symbol: "gauge.with.dots.needle.67percent", part: .ball, boost: 40, command: "pointer-speed") {
            if NSEvent.modifierFlags.contains(.option) {
                PaletteRouter.tryPointerPreset(speed)
            } else {
                PaletteRouter.close()
                Commands.run("pointer-speed", .number(speed), on: AppCommandTarget.shared)
                Sounds.shared.detent(pitch: 1.1, volume: 0.45)
            }
        }]
    }

    // MARK: Buttons and combos

    static func buttons(_ model: AppModel) -> [PaletteItem] {
        var out: [PaletteItem] = []
        for b in 0..<4 {
            let name = AppModel.buttonName(b)
            let action = model.config.buttons[b] ?? .system
            let does = b == 0 ? String(localized: "Left click") : (action == .system ? AppModel.buttonDefault(b) : action.title)
            var words = [String(localized: "button, click, assign, remap", comment: "Search words for a trackball button (comma-separated)"), does]
            if case .gesture(let g) = action {
                for step in [g.up, g.down, g.left, g.right].compactMap({ $0 }) { words.append(step.action.title) }
                if g.tap != .system { words.append(g.tap.title) }
            }
            out.append(PaletteItem(id: "button:\(b)", group: .buttons,
                                   title: String(localized: "\(name): \(does)", comment: "Search palette: a trackball button and what it does, like “Top right: Back”"),
                                   detail: b == 0 ? String(localized: "Your primary click stays a left click, so Glideball can never lock you out.")
                                                  : String(localized: "Normally: \(AppModel.buttonDefault(b))"),
                                   keywords: words.joined(separator: ", "),
                                   symbol: action.symbol, part: .clicks, trailing: GlideTab.buttons.title,
                                   findable: Findable.buttonID(b)) {
                PaletteRouter.openButton(b)
            })
        }
        for chord in model.config.chords {
            let names = ListFormatter.localizedString(byJoining: chord.buttons.map(AppModel.buttonName))
            out.append(PaletteItem(id: "combo:\(chord.id)", group: .buttons,
                                   title: String(localized: "\(names) together: \(chord.action.title)", comment: "Search palette: a combo; the first %@ is its buttons, the second what it does"),
                                   detail: String(localized: "A combo: press these buttons at the same time.", comment: "Search palette: a combo"),
                                   keywords: String(localized: "combo, chord, together", comment: "Search words for a combo (comma-separated)") + ", " + chord.action.title,
                                   symbol: "circle.grid.2x1.fill", part: .clicks, trailing: GlideTab.buttons.title, findable: Findable.combos.id) {
                PaletteRouter.go(.combos)
            })
        }
        return out
    }

    // MARK: Badges

    static func badges(_ model: AppModel) -> [PaletteItem] {
        let d = model.delight
        return Milestone.all.map { m in
            let earned = d.ledger.earned[m.id]
            let fraction = min(d.ledger.progress(m, lifetime: d.lifetime) / m.threshold, 0.99)
            let state = earned.map { String(localized: "Earned \($0.formatted(date: .abbreviated, time: .omitted))", comment: "Search palette: when a badge was earned") }
                ?? (fraction > 0 ? String(localized: "\(fraction.wholePercent) of the way", comment: "Search palette: progress toward a badge") : m.shortGoal)
            return PaletteItem(id: "badge:" + m.id, group: .badges, title: m.title, detail: m.detail,
                               keywords: String(localized: "badge, milestone, achievement", comment: "Search words for a badge (comma-separated)") + ", " + m.group.title,
                               symbol: m.symbol, part: m.metric, trailing: state, isOn: earned != nil, findable: Findable.badges.id) {
                PaletteRouter.openBadge(m.id)
            }
        }
    }

    // MARK: Help

    static func help(_ model: AppModel) -> [PaletteItem] {
        func page(_ id: String, _ title: String, _ detail: String, _ keywords: String, _ symbol: String, _ url: URL) -> PaletteItem {
            PaletteItem(id: "help:" + id, group: .help, title: title, detail: detail, keywords: keywords, symbol: symbol,
                        trailing: String(localized: "Website", comment: "Search palette: this opens a page on the Glideball website")) {
                PaletteRouter.close()
                NSWorkspace.shared.open(url)
            }
        }
        func app(_ id: String, _ title: String, _ detail: String, _ keywords: String, _ symbol: String, trailing: String? = nil,
                 _ run: @escaping @MainActor () -> Void) -> PaletteItem {
            PaletteItem(id: "help:" + id, group: .help, title: title, detail: detail, keywords: keywords, symbol: symbol, trailing: trailing) {
                PaletteRouter.close()
                run()
            }
        }
        let base = SiteLinks.base
        return [
            app("shortcuts", String(localized: "Keyboard Shortcuts"),
                String(localized: "Every shortcut on one sheet.", comment: "Search palette: Keyboard Shortcuts"),
                String(localized: "keys, hot keys, cheat sheet, keyboard", comment: "Search words for Keyboard Shortcuts (comma-separated)"),
                "keyboard", trailing: "⌘/") { AppModel.shared.showingShortcuts = true },
            app("whats-new", String(localized: "What’s New", comment: "Search palette: What's New"),
                String(localized: "What changed in this version.", comment: "Search palette: What's New"),
                String(localized: "changes, new, release notes, update", comment: "Search words for What's New (comma-separated)"),
                "sparkles.rectangle.stack") { AppModel.shared.showWhatsNew() },
            app("tour", String(localized: "Show Welcome Tour…"),
                String(localized: "The five-step tour from the first launch.", comment: "Search palette: Welcome Tour"),
                String(localized: "tour, tutorial, intro, getting started, onboarding", comment: "Search words for the Welcome Tour (comma-separated)"),
                "figure.wave") { AppModel.shared.showWelcomeTour() },
            app("about", String(localized: "About & Help…"),
                String(localized: "The version, links and credits.", comment: "Search palette: About & Help"),
                String(localized: "about, version, credits, license", comment: "Search words for About & Help (comma-separated)"),
                "info.circle") { AppModel.shared.showingAbout = true },
            page("help", String(localized: "Glideball Help"),
                 String(localized: "How everything works, on the website.", comment: "Search palette: Glideball Help"),
                 String(localized: "help, guide, manual, docs, how to", comment: "Search words for Glideball Help (comma-separated)"),
                 "questionmark.circle", SiteLinks.help),
            page("troubleshooting", String(localized: "Troubleshooting"),
                 String(localized: "When something isn’t working the way it should.", comment: "Search palette: Troubleshooting"),
                 String(localized: "not working, broken, problem, fix, issue, bug", comment: "Search words for Troubleshooting (comma-separated)"),
                 "wrench.and.screwdriver", SiteLinks.troubleshooting),
            page("permissions", String(localized: "Why Glideball needs permissions", comment: "Search palette: the permissions help page"),
                 String(localized: "Accessibility and Input Monitoring, and what they’re for.", comment: "Search palette: the permissions help page"),
                 String(localized: "accessibility, input monitoring, privacy, allow, permission", comment: "Search words for the permissions help page (comma-separated)"),
                 "lock.shield", SiteLinks.permissions),
            page("uninstall-kensingtonworks", String(localized: "Uninstall KensingtonWorks", comment: "Search palette: a help page"),
                 String(localized: "How to remove Kensington’s own driver cleanly.", comment: "Search palette: the Uninstall KensingtonWorks page"),
                 String(localized: "kensingtonworks, remove, driver, conflict, trackballworks", comment: "Search words for Uninstall KensingtonWorks (comma-separated)"),
                 "trash", URL(string: base + "/help/uninstall-kensingtonworks/")!),
            page("uninstall-glideball", String(localized: "Uninstall Glideball", comment: "Search palette: a help page"),
                 String(localized: "How to remove Glideball and its settings.", comment: "Search palette: the Uninstall Glideball page"),
                 String(localized: "remove, delete, uninstall", comment: "Search words for Uninstall Glideball (comma-separated)"),
                 "xmark.bin", URL(string: base + "/help/uninstall-glideball/")!),
            page("changelog", String(localized: "Changelog", comment: "Search palette: the changelog page"),
                 String(localized: "Every version and what changed in it.", comment: "Search palette: the changelog page"),
                 String(localized: "history, versions, release notes", comment: "Search words for the changelog (comma-separated)"),
                 "clock.arrow.circlepath", SiteLinks.changelog),
            page("privacy", String(localized: "Privacy", comment: "Search palette: the privacy page"),
                 String(localized: "What Glideball keeps on your Mac, and what it can send.", comment: "Search palette: the privacy page"),
                 String(localized: "privacy, data, policy", comment: "Search words for the privacy page (comma-separated)"),
                 "hand.raised", URL(string: base + "/privacy/")!),
        ]
    }

    /// Every row id a page can carry that isn't in `Findable.all` (made from the
    /// settings: a button, an app setup, a system-wide shortcut).
    static func dynamicAnchors(_ model: AppModel) -> Set<String> {
        var ids = Set((0..<4).map(Findable.buttonID))
        ids.formUnion(model.config.appProfiles.map { Findable.appSetupID($0.id) })
        ids.formUnion(ShortcutsSettingsPane.findables.map(\.id))
        return ids
    }
}

// MARK: - Matching

/// How well an item matches what's typed. Words are matched at the start of a
/// word (in the title first, then the item's search words, then its line),
/// then as part of a word, then loosely (letters in order within a word, or
/// one letter off for longer words). Every typed word has to match something,
/// so a word that matches nothing ("dark") finds nothing rather than noise.
enum PaletteMatch {
    struct Fields {
        let title: [String]
        let keywords: [String]
        let detail: [String]
        let titleText: String
        let keywordText: String
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
    }

    static func words(_ s: String) -> [String] {
        normalize(s).split(separator: " ").map(String.init)
    }

    static func fields(title: String, keywords: String, detail: String) -> Fields {
        Fields(title: words(title), keywords: words(keywords), detail: words(detail),
               titleText: normalize(title), keywordText: normalize(keywords))
    }

    /// A score, or nil if it doesn't match.
    static func score(_ query: String, _ f: Fields) -> Int? {
        let tokens = words(query)
        guard !tokens.isEmpty else { return nil }
        var total = 0
        for t in tokens {
            guard let s = tokenScore(t, f) else { return nil }
            total += s
        }
        // The whole query as the start of the title, more so the more of the title it is;
        // the whole title typed out is the best match there is.
        let q = normalize(query).trimmingCharacters(in: .whitespaces)
        let title = f.titleText.trimmingCharacters(in: .whitespaces)
        if title.hasPrefix(q) { total += Int(40 * Double(q.count) / Double(max(title.count, 1))) }
        if title == q { total += 40 }
        return total
    }

    private static func tokenScore(_ t: String, _ f: Fields) -> Int? {
        var best: Int?
        func take(_ s: Int) { best = max(best ?? 0, s) }
        for w in f.title {
            if w == t { take(120) } else if w.hasPrefix(t) { take(100) }
        }
        for w in f.keywords {
            if w == t { take(90) } else if w.hasPrefix(t) { take(75) }
        }
        if best != nil { return best }
        // CJK and other languages without spaces, and words in the middle ("sideways" in "sideways").
        if t.count >= 2, f.titleText.contains(t) { take(70) }
        if t.count >= 3, f.keywordText.contains(t) { take(55) }
        if t.count >= 3, f.detail.contains(where: { $0.hasPrefix(t) }) { take(35) }
        if best != nil { return best }
        // Loose: letters in order inside one title word ("trkng"), or one letter off ("scrol", "trakcing").
        if t.count >= 3 {
            for w in f.title where w.first == t.first && isSubsequence(t, of: w) && t.count * 2 >= w.count { take(40) }
            if t.count >= 5 {
                for w in f.title + f.keywords where abs(w.count - t.count) <= 1 && editDistance(t, w, limit: 1) <= 1 { take(45) }
            }
        }
        return best
    }

    static func isSubsequence(_ a: String, of b: String) -> Bool {
        var i = a.startIndex
        for c in b where i < a.endIndex && c == a[i] { i = a.index(after: i) }
        return i == a.endIndex
    }

    /// Levenshtein distance with transpositions, stopping early past `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return max(x.count, y.count) }
        var d = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 0...x.count { d[i][0] = i }
        for j in 0...y.count { d[0][j] = j }
        for i in 1...x.count {
            var rowMin = Int.max
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
                rowMin = min(rowMin, d[i][j])
            }
            if rowMin > limit { return limit + 1 }
        }
        return d[x.count][y.count]
    }
}

// MARK: - What a search shows

/// A search's results: groups in order, best first within each.
struct PaletteResults {
    struct Section: Identifiable {
        let group: PaletteItem.Group
        var items: [PaletteItem]
        var id: Int { group.rawValue }
    }

    let sections: [Section]
    var flat: [PaletteItem] { sections.flatMap(\.items) }
    var isEmpty: Bool { sections.isEmpty }

    static let perGroup = 6

    /// `recent`: ids picked lately, newest first (shown when nothing's typed).

    static func search(_ query: String, in items: [PaletteItem], recent: [String]) -> PaletteResults {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var picked = recent.compactMap { byID[$0] }
            if picked.isEmpty {
                // Nothing yet: a few good places to start.
                let starters = ["find:tracking-speed", "find:scroll-mode", "cmd:pause", "cmd:precision", "find:ball-color", "help:shortcuts"]
                picked = starters.compactMap { byID[$0] }
                for i in picked.indices { picked[i].group = .recent }
                return PaletteResults(sections: [Section(group: .recent, items: picked)])
            }
            for i in picked.indices { picked[i].group = .recent }
            return PaletteResults(sections: [Section(group: .recent, items: Array(picked.prefix(7)))])
        }
        let recentRank = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var scored: [(PaletteItem, Int)] = []
        for item in items + SearchIndex.numberItems(q) {
            guard var s = PaletteMatch.score(q, PaletteMatch.fields(title: item.title, keywords: item.keywords, detail: item.detail)) else { continue }
            s += item.boost
            if let r = recentRank[item.id] { s += max(0, 12 - r * 2) }
            scored.append((item, s))
        }
        let grouped = Dictionary(grouping: scored, by: { $0.0.group })
        var sections: [(Section, Int)] = []
        for (group, list) in grouped {
            let sorted = list.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title < $1.0.title }
            sections.append((Section(group: group, items: sorted.prefix(perGroup).map(\.0)), sorted.first?.1 ?? 0))
        }
        // The group with the best match first; ties in the usual group order.
        sections.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.group < $1.0.group }
        return PaletteResults(sections: sections.map(\.0))
    }
}

// MARK: - Recents

enum PaletteRecents {
    static let key = "GlidePaletteRecent"
    static let keep = 8

    static var ids: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func used(_ id: String) {
        var list = ids.filter { $0 != id }
        list.insert(id, at: 0)
        UserDefaults.standard.set(Array(list.prefix(keep)), forKey: key)
    }
}

// MARK: - Requests to a page

/// Things the palette asks a page to do once it's on screen (open a badge's
/// details, a preset's preview, a button's picker). The page takes them.
@Observable
final class PageRequests {
    static let shared = PageRequests()
    var openBadge: String?
    var presetPreview: String?
    var buttonPicker: Int?
    /// Bumped with each request, for pages to notice.
    private(set) var serial = 0

    func ask(_ change: (PageRequests) -> Void) {
        change(self)
        serial &+= 1
    }

    /// Takes (and clears) one request.
    func take<T>(_ key: ReferenceWritableKeyPath<PageRequests, T?>) -> T? {
        guard let value = self[keyPath: key] else { return nil }
        self[keyPath: key] = nil
        return value
    }
}
