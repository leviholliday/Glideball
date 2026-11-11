import Foundation

// glideball:// — how Raycast, Stream Deck and shell scripts control
// Glideball (`open -g "glideball://pause"`). The grammar is in docs/DEVELOPING.md,
// "Controlling Glideball from other apps".
//
// Why the list is so short: any web page, any app and any script can open a
// custom URL scheme, with no prompt beyond the browser's own "Open Glideball?"
// (and none at all from a script). So a URL may only do things that are safe
// whoever asks, can be undone by asking again, and leave nothing behind:
// pause and resume, Precision, scroll mode, pointer speed, which app setup
// is in use, which window or tab is showing, and an update check. Never
// anything that deletes, imports, exports, changes what a button does, grants
// a permission, sends something off the Mac or runs anything. Scroll with ball
// and Drag lock stay out too: they freeze the pointer or hold the button down.
//
// And even those only work once "Allow Raycast and scripts" is on (per Mac,
// never synced, off by default). With it off, a URL that would change
// something gets one short explanation per launch and nothing else; `open`
// and `settings` only show a window, so they work either way.
//
// URL text is only ever compared with fixed lists, parsed as a plain decimal or
// matched against the user's own app setup names. It never reaches a shell,
// AppleScript, a file path, a format string or the log (the log gets the
// command's id and why it was ignored). Unknown commands and bad values are
// ignored silently. At most 20 URLs a second are looked at, so a page can't
// hammer it; the rest are dropped.
//
// Foundation only, so scripts/command-sim can check it with a fake target.

/// "Allow Raycast and scripts". Per Mac, never synced (it isn't part of
/// `GlideConfig`), off by default. `AppModel.allowExternalControl` is the switch.
enum ExternalControlSetting {
    static let defaultsKey = "GlideAllowExternalControl"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
}

/// Turns glideball:// URLs into commands, behind the switch and the rate limit. Main thread only.
final class ExternalControl {
    static let scheme = "glideball"
    static let maxURLLength = 1024
    static let maxQueryItems = 8
    /// The rate limit: a bucket of this many, refilled at this many per second.
    static let perSecond = 20.0

    /// Why a URL was ignored. Logged as `rawValue`; never the URL's own text.
    enum Rejection: String, Error {
        case notGlideball = "not a glideball URL"
        case tooLong = "too long"
        case malformed = "malformed"
        case unknownCommand = "unknown command"
        case appOnly = "not available from URLs"
        case badParameter = "bad or missing parameter"
        case noSuchSetup = "no app setup by that name"
    }

    enum Outcome: Equatable {
        case performed(String)
        case ignored(Rejection)
        /// The switch is off; `explained` is true the one time the explanation was shown.
        case needsSwitch(explained: Bool)
        case rateLimited
    }

    private let target: CommandTarget
    private let isAllowed: () -> Bool
    private let now: () -> Double
    private let log: (String) -> Void
    private let explain: () -> Void
    private var explained = false
    private var tokens = ExternalControl.perSecond
    private var lastRefill: Double
    private var dropped = 0

    init(target: CommandTarget, isAllowed: @escaping () -> Bool, now: @escaping () -> Double,
         log: @escaping (String) -> Void, explain: @escaping () -> Void) {
        self.target = target
        self.isAllowed = isAllowed
        self.now = now
        self.log = log
        self.explain = explain
        lastRefill = now()
    }

    @discardableResult
    func handle(_ url: URL) -> Outcome {
        guard takeToken() else {
            if dropped == 0 { log("url: over \(Int(Self.perSecond))/s, dropping") }
            dropped += 1
            return .rateLimited
        }
        if dropped > 0 {
            log("url: dropped \(dropped)")
            dropped = 0
        }
        let command: Command, argument: CommandArgument
        switch Self.parse(url) {
        case .failure(let why):
            log("url ignored: \(why.rawValue)")
            return .ignored(why)
        case .success(let parsed):
            (command, argument) = parsed
        }
        if command.reach != .urlNavigation && !isAllowed() {
            let first = !explained
            explained = true
            log("url ignored: \(command.id), Allow Raycast and scripts is off")
            if first { explain() }
            return .needsSwitch(explained: first)
        }
        guard command.perform(target, argument, nil) else {
            log("url ignored: \(command.id), \(Rejection.noSuchSetup.rawValue)")
            return .ignored(.noSuchSetup)
        }
        log("url: \(command.id)\(Self.logText(argument))")
        return .performed(command.id)
    }

    /// The command and argument a URL asks for, or why it's ignored. Strict on
    /// purpose: anything unexpected is a rejection, not a guess.
    static func parse(_ url: URL) -> Result<(Command, CommandArgument), Rejection> {
        guard url.scheme?.lowercased() == scheme else { return .failure(.notGlideball) }
        guard url.absoluteString.utf8.count <= maxURLLength else { return .failure(.tooLong) }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/",
              let host = parts.percentEncodedHost, !host.isEmpty else { return .failure(.malformed) }
        // The command is plain letters and hyphens, as typed: "pa%75se" isn't "pause".
        guard host.count <= 32, host.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }) else {
            return .failure(.unknownCommand)
        }
        guard let command = Commands.command(host.lowercased()) else { return .failure(.unknownCommand) }
        guard command.reach != .appOnly else { return .failure(.appOnly) }

        let items = parts.queryItems ?? []
        guard items.count <= maxQueryItems else { return .failure(.badParameter) }
        guard let parameter = command.parameter else { return .success((command, .none)) }
        // Unknown keys are ignored; the command's own key must appear at most once.
        let values = items.filter { $0.name.lowercased() == parameter.key }
        guard values.count <= 1 else { return .failure(.badParameter) }
        guard let item = values.first else {
            if let fallback = parameter.fallback { return .success((command, fallback)) }
            return .failure(.badParameter)
        }
        guard let raw = item.value, let argument = parameter.parse(raw) else { return .failure(.badParameter) }
        return .success((command, argument))
    }

    /// The argument for the log: only values from Glideball's own lists, never a name.
    private static func logText(_ argument: CommandArgument) -> String {
        switch argument {
        case .none: ""
        case .on: " on"
        case .off: " off"
        case .toggle: " toggle"
        case .choice(let value): " \(value)"   // one of the command's own options
        case .number(let value): " \(Commands.speedText(value))"
        case .name: " (a setup)"
        }
    }

    private func takeToken() -> Bool {
        let t = now()
        tokens = min(Self.perSecond, tokens + max(0, t - lastRefill) * Self.perSecond)
        lastRefill = t
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
