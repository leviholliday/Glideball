import Foundation

// One list of everything a person can ask Glideball to do from outside its
// tabs: the menu-bar menu, the global hot keys and the glideball:// URLs
// (ExternalControl.swift) all go through `Commands`, so they behave the same.
// A later command palette, menu-bar popover or App Intents should too.
//
// Foundation only, on purpose: scripts/command-sim compiles this file with a
// fake `CommandTarget` and checks it without the app.

/// Glideball's modes that can be switched on and off from outside a button
/// (mirrors `Engine.ToggleMode`; the raw value is the command's id).
enum GlideMode: String, CaseIterable {
    case precision
    case ballScroll = "ball-scroll"
    case dragLock = "drag-lock"
}

/// The main window's tabs, by the names commands use (the app maps them to `GlideTab`).
enum CommandWindowTab: String, CaseIterable {
    case overview, pointer, scrolling, buttons, apps, sync
}

/// The Settings window's tabs, by the names commands use (the app maps them to `SettingsPane`).
enum CommandSettingsTab: String, CaseIterable {
    case general, trackball, look, sound, sharing, updates, privacy, shortcuts
}

/// An app setup a command can switch to.
struct CommandAppSetup: Equatable {
    var bundleID: String
    var name: String
}

/// What commands act on: the real app (`AppCommandTarget`) or a fake in scripts/command-sim.
/// Main thread only.
protocol CommandTarget: AnyObject {
    var isPaused: Bool { get }
    func setPaused(_ paused: Bool)

    func isOn(_ mode: GlideMode) -> Bool
    /// `on` nil toggles. `done` gets the new state, or nil if nothing could change (paused, no trackball…).
    func setMode(_ mode: GlideMode, on: Bool?, done: ((Bool?) -> Void)?)

    var scrollMode: ScrollMode { get }
    func setScrollMode(_ mode: ScrollMode)

    /// The main setup's pointer speed (an app setup with its own speed wins while it's in effect).
    var pointerSpeed: Double { get }
    func setPointerSpeed(_ speed: Double)

    /// Gesture buttons on (off: each does its tap action). The main setup's switch.
    var gesturesEnabled: Bool { get }
    func setGesturesEnabled(_ on: Bool)

    /// Per-display pointer speeds on (each display that has one uses it).
    var perDisplaySpeed: Bool { get }
    func setPerDisplaySpeed(_ on: Bool)

    var appSetups: [CommandAppSetup] { get }
    /// The setup chosen with `app-setup`, or nil when setups follow the app in front.
    var pinnedAppSetup: String? { get }
    /// The setup in effect right now, pinned or not.
    var activeAppSetupName: String? { get }
    /// nil goes back to following the app in front.
    func pinAppSetup(_ bundleID: String?)

    /// nil just shows the window.
    func openTab(_ tab: CommandWindowTab?)
    /// nil opens Settings where it was left.
    func openSettings(_ tab: CommandSettingsTab?)
    func checkForUpdates()
    func sendFeedback()
}

/// A command's argument, already checked against its parameter.
enum CommandArgument: Equatable {
    case none
    case on, off, toggle
    case choice(String)
    case number(Double)
    case name(String)
}

/// The one parameter a command can take, and how a text value becomes an argument.
struct CommandParameter {
    enum Kind {
        case onOffToggle
        case choice([String])
        case number(ClosedRange<Double>, step: Double)
        /// An app setup's name or bundle ID; only ever compared with the user's own setups.
        case setupName
    }

    /// Its name in a URL's query (`?state=on`).
    let key: String
    let kind: Kind
    /// Used when the URL leaves the parameter out; nil = the parameter is required.
    let fallback: CommandArgument?

    /// Longest value accepted. Setup names are short; nothing legitimate is longer.
    static let maxValueLength = 100

    /// The argument for `raw`, or nil if it isn't one this parameter accepts.
    func parse(_ raw: String) -> CommandArgument? {
        guard !raw.isEmpty, raw.count <= Self.maxValueLength,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        switch kind {
        case .onOffToggle:
            switch raw.lowercased() {
            case "on": return .on
            case "off": return .off
            case "toggle": return .toggle
            default: return nil
            }
        case .choice(let options):
            let value = raw.lowercased()
            return options.contains(value) ? .choice(value) : nil
        case .number(let range, let step):
            // Plain decimals only: no exponents, hex, "inf" or "nan", whatever Double() would take.
            guard raw.count <= 10,
                  raw.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                  raw.filter({ $0 == "." }).count <= 1,
                  let value = Double(raw), value.isFinite else { return nil }
            let stepped = (value / step).rounded() * step
            return .number(min(max(stepped, range.lowerBound), range.upperBound))
        case .setupName:
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : .name(trimmed)
        }
    }
}

/// One thing Glideball can be asked to do.
struct Command {
    enum Reach {
        /// glideball:// can run it, once "Allow Raycast and scripts" is on.
        case url
        /// glideball:// can run it even with the switch off: it only shows a window.
        case urlNavigation
        /// Only Glideball's own menu, hot keys and window.
        case appOnly
    }

    let id: String
    let title: String
    let parameter: CommandParameter?
    let reach: Reach
    /// Does it. Returns false if there was nothing to do it to (an app setup that doesn't exist).
    /// `done` is for the modes and pause: the new on/running state, or nil if nothing changed.
    let perform: (CommandTarget, CommandArgument, ((Bool?) -> Void)?) -> Bool
    /// Its current state as a short word or number ("on", "paused", "flywheel", "4"), if it has one.
    let state: (CommandTarget) -> String?
}

enum Commands {
    /// The Pointer tab's slider range (`PointerView`); `pointer-speed` clamps to it.
    static let pointerSpeedRange: ClosedRange<Double> = 0.5...80
    static let pointerSpeedStep = 0.5
    /// `app-setup?name=automatic` goes back to following the app in front.
    static let automaticSetup = "automatic"

    static let all: [Command] = [
        Command(id: "pause", title: String(localized: "Pause Glideball"), parameter: nil, reach: .url,
                perform: { target, _, done in target.setPaused(true); done?(false); return true },
                state: pauseState),
        Command(id: "resume", title: String(localized: "Resume Glideball"), parameter: nil, reach: .url,
                perform: { target, _, done in target.setPaused(false); done?(true); return true },
                state: pauseState),
        Command(id: "toggle", title: String(localized: "Pause / Resume Glideball"), parameter: nil, reach: .url,
                perform: { target, _, done in
                    target.setPaused(!target.isPaused)
                    done?(!target.isPaused)
                    return true
                },
                state: pauseState),

        modeCommand(.precision, title: String(localized: "Precision", comment: "Mode that slows the pointer for fine work"), reach: .url),
        // Scroll with ball freezes the pointer and Drag lock holds the left
        // button down until switched off: fine from your own keyboard, but not
        // something a web page should be able to switch on. App only.
        modeCommand(.ballScroll, title: String(localized: "Scroll with ball", comment: "Mode: rolling the ball scrolls instead of moving the pointer"), reach: .appOnly),
        modeCommand(.dragLock, title: String(localized: "Drag lock", comment: "Mode: the left button stays held down so you can drag without holding it"), reach: .appOnly),

        Command(id: "scroll-mode", title: String(localized: "Scroll mode"),
                parameter: CommandParameter(key: "mode", kind: .choice(ScrollMode.allCases.map(\.rawValue)), fallback: nil),
                reach: .url,
                perform: { target, argument, _ in
                    guard case .choice(let raw) = argument, let mode = ScrollMode(rawValue: raw) else { return false }
                    if target.scrollMode != mode { target.setScrollMode(mode) }
                    return true
                },
                state: { $0.scrollMode.rawValue }),

        Command(id: "pointer-speed", title: String(localized: "Pointer speed"),
                parameter: CommandParameter(key: "value", kind: .number(pointerSpeedRange, step: pointerSpeedStep), fallback: nil),
                reach: .url,
                perform: { target, argument, _ in
                    guard case .number(let speed) = argument else { return false }
                    if target.pointerSpeed != speed { target.setPointerSpeed(speed) }
                    return true
                },
                state: { speedText($0.pointerSpeed) }),

        // Changes what buttons do, so never from a URL (see DEVELOPING.md, "Why the list is this short").
        switchCommand(id: "gestures", title: String(localized: "Gestures", comment: "Hold a button and roll the ball"), reach: .appOnly,
                      get: { $0.gesturesEnabled }, set: { $0.setGesturesEnabled($1) }),
        // Only picks between pointer speeds the user set, like pointer-speed: fine from a URL.
        switchCommand(id: "per-display-speed", title: String(localized: "Pointer speed per display"), reach: .url,
                      get: { $0.perDisplaySpeed }, set: { $0.setPerDisplaySpeed($1) }),

        Command(id: "app-setup", title: String(localized: "Use an app setup"),
                parameter: CommandParameter(key: "name", kind: .setupName, fallback: nil),
                reach: .url,
                perform: { target, argument, _ in
                    guard case .name(let name) = argument else { return false }
                    if name.lowercased() == automaticSetup {
                        target.pinAppSetup(nil)
                        return true
                    }
                    guard let setup = setup(named: name, in: target.appSetups) else { return false }
                    if target.pinnedAppSetup != setup.bundleID { target.pinAppSetup(setup.bundleID) }
                    return true
                },
                state: { target in target.pinnedAppSetup == nil ? automaticSetup : target.activeAppSetupName }),

        Command(id: "open", title: String(localized: "Open Glideball"),
                parameter: CommandParameter(key: "tab", kind: .choice(CommandWindowTab.allCases.map(\.rawValue)), fallback: CommandArgument.none),
                reach: .urlNavigation,
                perform: { target, argument, _ in
                    if case .choice(let raw) = argument { target.openTab(CommandWindowTab(rawValue: raw)) } else { target.openTab(nil) }
                    return true
                },
                state: { _ in nil }),

        Command(id: "settings", title: String(localized: "Settings…"),
                parameter: CommandParameter(key: "tab", kind: .choice(CommandSettingsTab.allCases.map(\.rawValue)), fallback: CommandArgument.none),
                reach: .urlNavigation,
                perform: { target, argument, _ in
                    if case .choice(let raw) = argument { target.openSettings(CommandSettingsTab(rawValue: raw)) } else { target.openSettings(nil) }
                    return true
                },
                state: { _ in nil }),

        Command(id: "check-for-updates", title: String(localized: "Check for Updates…"), parameter: nil, reach: .url,
                perform: { target, _, _ in target.checkForUpdates(); return true },
                state: { _ in nil }),

        // Opens a form with free text that's sent off the Mac: never from a URL.
        Command(id: "feedback", title: String(localized: "Send Feedback…"), parameter: nil, reach: .appOnly,
                perform: { target, _, _ in target.sendFeedback(); return true },
                state: { _ in nil }),
    ]

    static func command(_ id: String) -> Command? { all.first { $0.id == id } }

    /// Runs a command from inside the app (menu, hot keys). Returns false if
    /// there's no such command or it had nothing to act on.
    @discardableResult
    static func run(_ id: String, _ argument: CommandArgument = .none, on target: CommandTarget,
                    done: ((Bool?) -> Void)? = nil) -> Bool {
        guard let command = command(id) else { return false }
        return command.perform(target, argument, done)
    }

    // MARK: Helpers

    private static func modeCommand(_ mode: GlideMode, title: String, reach: Command.Reach) -> Command {
        Command(id: mode.rawValue, title: title,
                parameter: CommandParameter(key: "state", kind: .onOffToggle, fallback: .toggle),
                reach: reach,
                perform: { target, argument, done in
                    switch argument {
                    case .on: target.setMode(mode, on: true, done: done)
                    case .off: target.setMode(mode, on: false, done: done)
                    default: target.setMode(mode, on: nil, done: done)
                    }
                    return true
                },
                state: { $0.isOn(mode) ? "on" : "off" })
    }

    /// An on/off setting: `state=on|off|toggle` (toggle when left out); "on" twice stays on.
    private static func switchCommand(id: String, title: String, reach: Command.Reach,
                                      get: @escaping (CommandTarget) -> Bool,
                                      set: @escaping (CommandTarget, Bool) -> Void) -> Command {
        Command(id: id, title: title,
                parameter: CommandParameter(key: "state", kind: .onOffToggle, fallback: .toggle),
                reach: reach,
                perform: { target, argument, done in
                    let new: Bool = switch argument {
                    case .on: true
                    case .off: false
                    default: !get(target)
                    }
                    if new != get(target) { set(target, new) }
                    done?(get(target))
                    return true
                },
                state: { get($0) ? "on" : "off" })
    }

    private static func pauseState(_ target: CommandTarget) -> String? { target.isPaused ? "paused" : "running" }

    /// "4", "4.5": the speed as status.json and the logs write it.
    static func speedText(_ speed: Double) -> String {
        speed == speed.rounded() ? String(Int(speed)) : String(speed)
    }

    /// A setup by its bundle ID (exactly) or its name (ignoring case); the first if two share a name.
    static func setup(named name: String, in setups: [CommandAppSetup]) -> CommandAppSetup? {
        setups.first { $0.bundleID == name }
            ?? setups.first { $0.name.compare(name, options: [.caseInsensitive]) == .orderedSame }
    }
}
