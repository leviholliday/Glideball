import Foundation
import Observation

/// What the person said Glideball may send Levi: nothing (the default), crash
/// reports, or crash reports plus anonymous settings stats. Asked once on the
/// "A small favor" card (`SmallFavorCard`), changed any time in Settings ›
/// Privacy (`ShareDataRow`).
enum ShareChoice: String, CaseIterable, Identifiable {
    case nothing, crashes, crashesAndStats
    var id: String { rawValue }

    var sendsCrashes: Bool { self != .nothing }
    var sendsStats: Bool { self == .crashesAndStats }

    var title: String {
        switch self {
        case .nothing: String(localized: "Nothing", comment: "Data sharing choice: send nothing")
        case .crashes: String(localized: "Crash reports only", comment: "Data sharing choice")
        case .crashesAndStats: String(localized: "Crash reports and settings stats", comment: "Data sharing choice")
        }
    }
}

/// Opt-in crash reports and settings stats, sent to glideball.netlify.app
/// (/api/crash and /api/usage, the same server as feedback). With the choice
/// at Nothing this does nothing at all: no install ID, no files read, no
/// network.
///
/// - The install ID ("GB-…", see `RandomID`) is made the first time someone
///   says yes, for this feature only, and kept only in this Mac's
///   preferences (never in `GlideConfig`, so it never syncs). It isn't made
///   from anything about the person or the Mac. The server keeps only its
///   SHA-256, so only the person can see it (in Settings › Privacy, to give
///   Levi if they ever want their data looked up or deleted). Delete my data
///   forgets it; saying yes again later makes a new one.
/// - Crash reports: on launch, any crash of Glideball since the last look
///   (and since the person said yes), read from macOS's own report
///   (`CrashReports`).
/// - Stats: at most one ping a (UTC) day, with versions, language, chip, which
///   Kensington trackballs are connected, and which settings are in use (`Stats`)
///   — switches, choices, small counts and ranges only, never shortcuts, app
///   names, setup names, display names, custom colors, paths or anything typed.
///
/// Everything happens off the main thread except reading the settings, never
/// near the input path, and any failure is silent (it's tried again later).
@Observable
final class ShareData {
    static let shared = ShareData()

    static let choiceKey = "GlideShareChoice"
    static let askedKey = "GlideShareAsked"
    static let installIDKey = "GlideShareInstallID"
    static let lastStatsDayKey = "GlideShareLastStatsDay"
    static let crashesSinceKey = "GlideShareCrashesSince"
    static let lastSentKey = "GlideShareLastSent"

    /// The privacy page's part about this.
    static let explainer = URL(string: "https://glideball.netlify.app/privacy/#app-data")!

    var choice: ShareChoice {
        didSet {
            guard choice != oldValue else { return }
            defaults.set(choice.rawValue, forKey: Self.choiceKey)
            asked = true   // chosen in Settings › Privacy: the card needn't ask
            if choice != .nothing && installID == nil, let id = RandomID.make() {
                installID = id
                defaults.set(id, forKey: Self.installIDKey)
            }
            // Crash reports only from crashes after saying yes.
            if choice.sendsCrashes && !oldValue.sendsCrashes { defaults.set(Date(), forKey: Self.crashesSinceKey) }
            if choice.sendsStats { sendStatsIfDue() }
        }
    }
    /// The card has been answered (any answer). It doesn't show again.
    var asked: Bool {
        didSet { defaults.set(asked, forKey: Self.askedKey) }
    }
    /// Made the first time the person says yes to anything; gone after Delete my data.
    private(set) var installID: String?
    private(set) var deleting = false
    /// When this Mac last sent something (stats or a crash report), as far as it knows.
    private(set) var lastSent: Date?

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var sendingStats = false
    @ObservationIgnored private var lookingForCrashes = false

    private init() {
        choice = defaults.string(forKey: Self.choiceKey).flatMap(ShareChoice.init) ?? .nothing
        asked = defaults.bool(forKey: Self.askedKey)
        // (Anything not in today's form, from a test build say, is replaced when next needed.)
        installID = defaults.string(forKey: Self.installIDKey).flatMap { RandomID.isValid($0) ? $0 : nil }
        lastSent = defaults.object(forKey: Self.lastSentKey) as? Date ?? defaults.string(forKey: Self.lastStatsDayKey).flatMap {
            // Before this was kept: the day of the last stats ping.
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            return f.date(from: $0)
        }
    }

    /// `--render-ui`: a choice as if made a while ago (`lastSent` that long back), or back to a fresh Mac.
    func sandboxSet(_ choice: ShareChoice, installID: String?, lastSent: Date?) {
        guard Sandbox.isActive else { return }
        self.installID = installID
        self.choice = choice
        self.installID = installID ?? (choice == .nothing ? nil : self.installID)
        self.lastSent = lastSent
    }

    /// Something went in (main thread).
    private func sent() {
        lastSent = Date()
        defaults.set(lastSent, forKey: Self.lastSentKey)
    }

    /// Whether the card should be offered: never answered, on a Mac that
    /// doesn't already share (a choice made with `defaults write` counts).
    var shouldAsk: Bool { !asked && choice == .nothing }

    // MARK: Running

    /// Called once at launch. Waits a little so the engine has found the
    /// trackball and launch has settled, then checks every few hours.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.tick()
            self?.timer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { _ in self?.tick() }
            self?.timer?.tolerance = 600
        }
    }

    private func tick() {
        guard choice != .nothing else { return }
        sendCrashReports()
        sendStatsIfDue()
    }

    // MARK: Stats

    struct Stats: Encodable {
        var installId: String
        var version: String
        var build: String
        var os: String
        var lang: String
        var arch: String
        var trackballs: [Trackball]
        var scrollMode: String
        var performance: String
        var pointerSpeed: String
        var beta: Bool            // Other Kensington trackballs
        var earlyUpdates: Bool
        var appProfiles: Int
        var combos: Int
        var buttons: [String: Int]

        // Since 2.10 beta 15: which settings are in use. Choices from fixed lists, switches,
        // small counts and ranges only (never an exact slider value). Never app names or
        // bundle IDs, setup names, shortcut keys, display names, custom colors, paths or
        // anything typed. The server (website/netlify/lib/usage.mjs, SETTINGS) keeps the same lists.

        // Look
        var ballColor: String            // a curated theme's id, or "custom" (never its colors)
        var appIcon: String
        var light: String                // "off" or a percent range
        var launchStyle: String
        var celebrations: Bool
        var weeklyRecap: Bool
        // Sound
        var sounds: Bool
        var soundVolume: String          // a percent range
        var soundKinds: [String: Bool]   // each kind's own switch
        // Pointer
        var precisionSpeed: String
        var perDisplaySpeed: Bool
        var ballScrollSpeed: String
        // Scrolling
        var smoothScrolling: Bool
        var flipDirection: Bool
        var shiftSideways: Bool
        var nativeSpeed: String
        var flyDistance: String
        var flyPower: String
        var flyReach: String
        var flyGlide: String
        var followDistance: String
        var followSmoothness: String
        var followAcceleration: String
        var throwOn: Bool
        var throwDistance: String
        // Buttons and gestures
        var gestures: Bool
        var gestureButtons: Int
        var gestureDistance: String
        var steadyHands: Bool
        var gestureActions: [String: Int]   // by kind, like `buttons`
        var gestureShow: [String: Int]      // how many Gestures buttons show the ring never / after a pause / right away
        var gestureEight: Int               // how many use eight directions
        var gestureMore: Int                // how many have a More
        var switcherHidden: Int             // how many apps are hidden from Switchers in all (never which)
        var modesSetUp: [String: Bool]      // Precision, Scroll with ball, Drag lock on a button, combo or shortcut
        // The app
        var menuBarIcon: Bool
        var menuBarStyle: String
        var menuBarOpens: String
        var showInDock: Bool
        var askBeforeQuitting: Bool
        var openAtLogin: Bool
        var allowScripts: Bool
        var ownLanguage: Bool               // a language picked just for Glideball (not which one: that's `lang`)
        var lowBatteryAlerts: Bool
        var sync: Bool
        var autoBackups: Bool
        var autoUpdate: Bool                // Install updates automatically
        var globalShortcuts: Int            // how many are set, never which keys
        var displays: String                // "1", "2" or "3+"
        var windowLayout: String            // the main window's last layout class, or "unknown"
        var used: [String: Bool]            // `FeatureUse`: tried at least once on this Mac

        struct Trackball: Encodable {
            var name: String
            var product: Int
        }
    }

    // MARK: Ranges

    /// A number as one of a few ranges, never the number: below the first edge "<e",
    /// between two "a-b", from the last "e+". (`scale` 100 turns 0…1 into percent.)
    static func range(_ value: Double, _ edges: [Double], scale: Double = 1) -> String {
        func text(_ d: Double) -> String {
            let x = (d * scale * 100).rounded() / 100
            return x == x.rounded() ? String(Int(x)) : String(x)
        }
        let v = value.isFinite ? value : 0
        guard let first = edges.first, v >= first else { return "<" + text(edges.first ?? 0) }
        for (a, b) in zip(edges, edges.dropFirst()) where v < b { return text(a) + "-" + text(b) }
        return text(edges.last ?? 0) + "+"
    }

    /// 0…1 sliders (glide, reach, smoothness, volume…): a quarter at a time, in percent.
    static func unitRange(_ value: Double) -> String { range(value, [0.25, 0.5, 0.75], scale: 100) }

    /// This build's version and build number (any thread, unlike `FeedbackDraft.appInfo`).
    static var appInfo: [String: String] {
        let info = Bundle.main.infoDictionary
        return ["version": info?["CFBundleShortVersionString"] as? String ?? "?",
                "build": info?["CFBundleVersion"] as? String ?? "0"]
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }

    static var arch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    /// The tracking speed in a few ranges, not the exact number.
    static func speedBucket(_ speed: Double) -> String { range(speed, [2, 4, 8, 16, 32]) }

    private static let productCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ()+.,/&'-")

    /// Today's ping, from the settings as they are now. Main thread.
    func stats(_ model: AppModel, installID: String) -> Stats {
        let c = model.config
        var buttons: [String: Int] = [:]
        for action in Array(c.buttons.values) + c.chords.map(\.action) { buttons[action.kind, default: 0] += 1 }
        // Gesture buttons and combos, and what their directions do (by kind only).
        let gestures: [ButtonGesture] = (Array(c.buttons.values) + c.chords.map(\.action)).compactMap {
            if case .gesture(let g) = $0 { g } else { nil }
        }
        var gestureActions: [String: Int] = [:]
        // Every way in use, and what's inside a More (by kind only; More itself isn't a kind the
        // server knows, so it isn't sent: how many show the ring or use More would need new fields).
        for g in gestures {
            for d in g.usedDirections {
                guard let step = g[d] else { continue }
                for s in step.more ?? [step] { if let s { gestureActions[s.action.kind, default: 0] += 1 } }
            }
        }
        var gestureShow: [String: Int] = [:]
        for g in gestures { gestureShow[g.show.rawValue, default: 0] += 1 }
        let switcherHidden = (Array(c.buttons.values) + c.chords.map(\.action)).reduce(0) {
            if case .switcher(let s) = $1 { $0 + s.hidden.count } else { $0 }
        }
        let app = ShareData.appInfo
        return Stats(
            installId: installID,
            version: app["version"] ?? "?",
            build: app["build"] ?? "0",
            os: Self.osVersion,
            lang: Bundle.main.preferredLocalizations.first ?? "en",
            arch: Self.arch,
            trackballs: model.status.kensingtonModels.prefix(8).map {
                var name = CrashReports.clean($0.name, allowed: Self.productCharacters, max: 60)
                if name.first.map({ !$0.isLetter && !$0.isNumber }) ?? true { name = "Kensington trackball" }
                return .init(name: name, product: min(max($0.productID, 0), 0xFFFF))
            },
            scrollMode: c.scrollMode.rawValue,
            performance: model.performance.rawValue,
            pointerSpeed: Self.speedBucket(c.trackingSpeed),
            beta: model.otherTrackballs,
            earlyUpdates: model.earlyUpdates,
            appProfiles: min(c.appProfiles.count, 1000),
            combos: min(c.chords.count, 1000),
            buttons: buttons.mapValues { min($0, 100) },
            ballColor: Self.ballColor(BallThemeStore.shared.theme.id),
            appIcon: AppIconChoice.shared.style.rawValue,
            light: model.lightIntensity <= 0 ? "off" : Self.unitRange(model.lightIntensity),
            launchStyle: LaunchExperience.shared.style.rawValue,
            celebrations: model.delight.celebrationsOn,
            weeklyRecap: RecapCenter.shared.enabled,
            sounds: Sounds.shared.enabled,
            soundVolume: Self.unitRange(Sounds.shared.volume),
            soundKinds: Dictionary(uniqueKeysWithValues: SoundKind.allCases.map { ($0.rawValue, Sounds.shared.isOn($0)) }),
            precisionSpeed: Self.range(c.precisionSpeed, [0.5, 1, 1.5]),
            perDisplaySpeed: c.displaySpeeds.isActive,
            ballScrollSpeed: Self.range(c.ballScrollSpeed, [0.5, 1, 2]),
            smoothScrolling: c.smoothScrolling,
            flipDirection: c.reverseScroll,
            shiftSideways: c.shiftScrollsHorizontally,
            nativeSpeed: Self.range(c.nativeScrollSpeed, [0.5, 1, 1.7]),
            flyDistance: Self.range(c.flyDistance, [4, 8, 12]),
            flyPower: Self.unitRange(c.flyAcceleration),
            flyReach: Self.unitRange(c.flyReach),
            flyGlide: Self.unitRange(c.flyGlide),
            followDistance: Self.range(c.scrollDistance, [8, 16, 24]),
            followSmoothness: Self.unitRange(c.scrollSmoothness),
            followAcceleration: Self.unitRange(c.scrollAcceleration),
            throwOn: c.throwEnabled,
            throwDistance: Self.unitRange(c.throwAmount),
            gestures: c.gesturesEnabled,
            gestureButtons: min(gestures.count, 100),
            gestureDistance: c.gestureDistance.rawValue,
            steadyHands: c.gestureSteadyHands,
            gestureActions: gestureActions.mapValues { min($0, 100) },
            gestureShow: gestureShow.mapValues { min($0, 100) },
            gestureEight: min(gestures.filter(\.eight).count, 100),
            gestureMore: min(gestures.filter { g in g.usedDirections.contains { g[$0]?.isMore == true } }.count, 100),
            switcherHidden: min(switcherHidden, 100),
            modesSetUp: Self.modesSetUp(c),
            menuBarIcon: model.menuBarIcon,
            menuBarStyle: model.menuBarIconStyle.rawValue,
            menuBarOpens: MenuBarPanelController.shared.opens.rawValue,
            showInDock: model.showInDock,
            askBeforeQuitting: model.confirmQuit,
            openAtLogin: model.launchAtLogin,
            allowScripts: model.allowExternalControl,
            ownLanguage: AppLanguage.chosen != nil,
            lowBatteryAlerts: model.lowBatteryAlerts,
            sync: model.sync.isEnabled,
            autoBackups: model.backups.isEnabled,
            autoUpdate: AutoUpdateSetting.isEnabled,
            globalShortcuts: GlobalShortcuts.Action.allCases.filter { c.globalShortcuts[$0] != nil }.count,
            displays: model.displays.count >= 3 ? "3+" : String(max(model.displays.count, 1)),
            windowLayout: WindowLayoutMemory.last ?? "unknown",
            used: Dictionary(uniqueKeysWithValues: FeatureUse.allCases.map { ($0.rawValue, $0.wasUsed) }))
    }

    /// The theme's id if it's one Glideball ships (or "custom"), so nothing else can ever go out.
    static func ballColor(_ id: String) -> String {
        id == "custom" || BallTheme.curated.contains { $0.id == id } ? id : "orb"
    }

    /// Whether each mode can be reached from the trackball or the keyboard: a button,
    /// combo or app setup that does it, or a global shortcut for it (never which one).
    static func modesSetUp(_ c: GlideConfig) -> [String: Bool] {
        var actions = Array(c.buttons.values) + c.chords.map(\.action)
        for p in c.appProfiles { actions += Array((p.buttons ?? [:]).values) + (p.chords ?? []).map(\.action) }
        let kinds = Set(actions.map(\.kind))
        return [
            "precision": kinds.contains("precisionHold") || kinds.contains("precisionToggle") || c.globalShortcuts.precision != nil,
            "ballScroll": kinds.contains("ballScrollHold") || c.globalShortcuts.ballScroll != nil,
            "dragLock": kinds.contains("dragLock") || c.globalShortcuts.dragLock != nil,
        ]
    }

    private static var today: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    func sendStatsIfDue() {
        guard choice.sendsStats, let installID, !sendingStats,
              defaults.string(forKey: Self.lastStatsDayKey) != Self.today,
              let body = try? JSONEncoder().encode(stats(AppModel.shared, installID: installID)) else { return }
        sendingStats = true
        let day = Self.today
        Self.send("/api/usage", method: "POST", body: body) { [weak self] ok, _ in
            DispatchQueue.main.async {
                self?.sendingStats = false
                // Sent, or turned down for good (a 4xx): either way, not again today.
                if ok != nil { self?.defaults.set(day, forKey: Self.lastStatsDayKey) }
                if ok == true { self?.sent() }
            }
        }
    }

    // MARK: Crash reports

    func sendCrashReports() {
        guard choice.sendsCrashes, let installID, !lookingForCrashes else { return }
        lookingForCrashes = true
        let since = defaults.object(forKey: Self.crashesSinceKey) as? Date ?? Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // At most a few at a time, oldest first, and nothing over three months old.
            let found = CrashReports.find(after: max(since, Date().addingTimeInterval(-90 * 86400))).prefix(5)
            self?.sendCrashes(Array(found), installID: installID)
        }
    }

    /// One at a time, so the next is only sent once the last one's in (and a
    /// failed one is tried again at the next launch or check).
    private func sendCrashes(_ list: [(url: URL, date: Date)], installID: String) {
        // (Turned off meanwhile: stop. UserDefaults can be read from any thread.)
        let stillOn = defaults.string(forKey: Self.choiceKey).flatMap(ShareChoice.init)?.sendsCrashes ?? false
        guard stillOn, let next = list.first else {
            DispatchQueue.main.async { self.lookingForCrashes = false }
            return
        }
        let done = { [weak self] in
            // Past this one either way: sent, or not one to send.
            DispatchQueue.main.async {
                if let self, self.choice.sendsCrashes {
                    let was = self.defaults.object(forKey: Self.crashesSinceKey) as? Date ?? .distantPast
                    self.defaults.set(max(was, next.date), forKey: Self.crashesSinceKey)
                }
            }
            self?.sendCrashes(Array(list.dropFirst()), installID: installID)
        }
        guard let report = CrashReports.read(next.url, date: next.date, installID: installID),
              let body = try? JSONEncoder().encode(report) else { return done() }
        Self.send("/api/crash", method: "POST", body: body) { [weak self] ok, _ in
            if ok == true { DispatchQueue.main.async { self?.sent() } }
            if ok != nil { return done() }
            DispatchQueue.main.async { self?.lookingForCrashes = false }   // offline: next time
        }
    }

    // MARK: Delete my data

    /// Asks the server to delete everything this install sent, then turns
    /// sharing off and forgets the install ID. `done(true)` once it's gone.
    func deleteMyData(_ done: @escaping (Bool) -> Void) {
        guard let installID, !deleting else { return done(installID == nil) }
        deleting = true
        let body = (try? JSONSerialization.data(withJSONObject: ["installId": installID])) ?? Data()
        Self.send("/api/usage", method: "DELETE", body: body) { [weak self] ok, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.deleting = false
                guard ok == true else { return done(false) }
                self.choice = .nothing
                self.installID = nil
                self.lastSent = nil
                for key in [Self.installIDKey, Self.lastStatsDayKey, Self.crashesSinceKey, Self.lastSentKey] { self.defaults.removeObject(forKey: key) }
                done(true)
            }
        }
    }

    // MARK: Network

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpAdditionalHeaders = ["User-Agent": "Glide-Share"]
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// One request to the feedback server (or the development one, see
    /// `FeedbackClient.server`). `done` gets true for a 2xx, false for a 4xx
    /// (turned down: don't send that again), nil for no answer or a 5xx.
    /// Called on a background queue.
    private static func send(_ path: String, method: String, body: Data, done: @escaping (Bool?, Int) -> Void) {
        guard !Sandbox.isActive else { return done(nil, 0) }   // a render or self-test never sends
        var c = URLComponents(url: FeedbackClient.server, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + path
        guard let url = c.url else { return done(nil, 0) }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.httpBody = body
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(FeedbackClient.appKey, forHTTPHeaderField: "x-glide-key")
        session.dataTask(with: r) { _, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200..<300: done(true, code)
            case 400..<500 where code != 408 && code != 429: done(false, code)
            default: done(nil, code)
            }
        }.resume()
    }
}

extension ButtonAction {
    /// The kind of action, without what's in it (never a shortcut's keys).
    var kind: String {
        switch self {
        case .system: "system"
        case .leftClick: "leftClick"
        case .rightClick: "rightClick"
        case .middleClick: "middleClick"
        case .back: "back"
        case .forward: "forward"
        case .shortcut: "shortcut"
        case .holdShortcut: "holdShortcut"
        case .modifiedClick: "modifiedClick"
        case .disabled: "disabled"
        case .precisionHold: "precisionHold"
        case .precisionToggle: "precisionToggle"
        case .ballScrollHold: "ballScrollHold"
        case .dragLock: "dragLock"
        case .media: "media"
        case .openApp: "openApp"
        case .gesture, .wheel: "gesture"   // the Wheel is Gestures now (never sent as one after clamping anyway)
        case .switcher: "switcher"
        }
    }
}

/// A few things worth knowing whether people find: each is marked the first time
/// it's used on this Mac (this Mac's preferences only, never synced) and goes out
/// as a yes or no in the opt-in stats. Nothing about what was searched, tried or shared.
enum FeatureUse: String, CaseIterable {
    case search, tryBeforeChange, share, kensingtonWorks, buttonPreset

    static let key = "GlideFeaturesUsed"

    static func mark(_ feature: FeatureUse) {
        let d = UserDefaults.standard
        var list = d.stringArray(forKey: key) ?? []
        guard !list.contains(feature.rawValue) else { return }
        list.append(feature.rawValue)
        d.set(list, forKey: key)
    }

    var wasUsed: Bool {
        if (UserDefaults.standard.stringArray(forKey: Self.key) ?? []).contains(rawValue) { return true }
        // From before this was kept: what the Mac already remembers.
        switch self {
        case .search: return !PaletteRecents.ids.isEmpty
        case .buttonPreset: return AppModel.shared.delight.ledger.explored.contains(.preset)
        default: return false
        }
    }

    var title: String {
        switch self {
        case .search: String(localized: "Search", comment: "Privacy preview: a feature used (the search palette)")
        case .tryBeforeChange: String(localized: "Try before you keep", comment: "Privacy preview: a feature used")
        case .share: String(localized: "Share…", comment: "Privacy preview: a feature used (sharing a setup or a picture)")
        case .kensingtonWorks: String(localized: "KensingtonWorks import", comment: "Privacy preview: a feature used")
        case .buttonPreset: String(localized: "A button preset", comment: "Privacy preview: a feature used")
        }
    }
}

/// The main window's last layout class (`PageWidth`: one column, two, two roomy, three),
/// for the opt-in stats. Written only when it changes.
enum WindowLayoutMemory {
    static let key = "GlideWindowLayout"

    static func name(_ w: PageWidth) -> String {
        switch w {
        case .single: "single"
        case .double: "double"
        case .roomy: "roomy"
        case .triple: "triple"
        }
    }

    static func save(_ w: PageWidth) {
        if last != name(w) { UserDefaults.standard.set(name(w), forKey: key) }
    }

    static var last: String? {
        UserDefaults.standard.string(forKey: key).flatMap { ["single", "double", "roomy", "triple"].contains($0) ? $0 : nil }
    }
}

// MARK: - What this sends (Settings › Privacy)

/// Settings › Privacy's "What this sends": the fields of the real payloads
/// with this Mac's real values, made by encoding the very structs that are
/// sent (`ShareData.stats` and `CrashReports.Report.example`) and labelling
/// each key. A key without a label still shows (raw), and the self-test fails
/// until it has one, so the preview can't leave anything out or drift.
struct SendPreview {
    struct Field: Identifiable, Equatable {
        /// The payload keys this line covers.
        let keys: [String]
        let label: String
        let value: String
        /// The heading it's listed under (stats only: Look, Sound, Pointer…).
        var group: String? = nil
        var id: String { keys.joined(separator: "+") }
    }

    /// What a crash report carries (empty for Nothing).
    var crash: [Field] = []
    /// What the daily stats carry (empty unless stats are on).
    var stats: [Field] = []

    static func make(_ choice: ShareChoice, model: AppModel, installID: String?) -> SendPreview {
        let id = installID ?? "GB-…"
        var p = SendPreview()
        if choice.sendsCrashes { p.crash = fields(of: CrashReports.Report.example(installID: id), labels: crashLabels) }
        if choice.sendsStats { p.stats = fields(of: ShareData.shared.stats(model, installID: id), groups: statsGroups) }
        return p
    }

    /// A payload's top-level keys and values, as JSON has them.
    static func json<T: Encodable>(_ payload: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    typealias Label = (keys: [String], label: String, value: ([String: Any]) -> String)

    /// Lines in order for the keys the labels know, then any key they don't (raw).
    static func fields<T: Encodable>(of payload: T, labels: [Label]) -> [Field] {
        fields(of: payload, groups: [(nil, labels)])
    }

    /// The same, with each line under its group's heading.
    static func fields<T: Encodable>(of payload: T, groups: [(title: String?, labels: [Label])]) -> [Field] {
        let json = json(payload)
        var out: [Field] = []
        var covered = Set<String>()
        for g in groups {
            for l in g.labels where l.keys.allSatisfy({ json[$0] != nil }) {
                out.append(Field(keys: l.keys, label: l.label, value: l.value(json), group: g.title))
                covered.formUnion(l.keys)
            }
        }
        for key in json.keys.sorted() where !covered.contains(key) {
            out.append(Field(keys: [key], label: key, value: json[key].map { "\($0)" } ?? ""))
        }
        return out
    }

    // MARK: Labels

    private static func string(_ j: [String: Any], _ k: String) -> String { j[k] as? String ?? (j[k]).map { "\($0)" } ?? "" }
    private static func onOff(_ j: [String: Any], _ k: String) -> String {
        (j[k] as? Bool ?? false) ? String(localized: "On", comment: "Privacy preview: a switch that's on")
                                 : String(localized: "Off", comment: "Privacy preview: a switch that's off")
    }
    private static func count(_ j: [String: Any], _ k: String) -> String { ((j[k] as? Int) ?? 0).formatted() }

    // (Shortened: the whole ID is just below, under Your install ID.)
    private static let installID: Label = (["installId"], String(localized: "Install ID", comment: "Privacy preview: field"), { j in
        let id = string(j, "installId")
        return id.count > 16 ? id.prefix(7) + "…" + id.suffix(4) : id
    })
    private static let version: Label = (["version", "build"], String(localized: "Glideball", comment: "Privacy preview: field, the app's version"), { j in
        String(localized: "\(string(j, "version")) (build \(string(j, "build")))", comment: "Privacy preview: version and build, like “2.10 (build 512)”")
    })
    private static let os: Label = (["os"], String(localized: "macOS", comment: "Privacy preview: field"), { string($0, "os") })
    private static let arch: Label = (["arch"], String(localized: "Chip", comment: "Privacy preview: field, Apple silicon or Intel"), { j in
        string(j, "arch") == "arm64" ? String(localized: "Apple silicon") : String(localized: "Intel")
    })

    static let crashLabels: [Label] = [
        installID, version, os, arch,
        (["crashedAt", "exception", "signal", "termination", "reason"],
         String(localized: "The crash", comment: "Privacy preview: field"),
         { _ in String(localized: "When it happened, and the error macOS gave", comment: "Privacy preview: what a crash report says about the crash") }),
        (["ownImage", "frames"],
         String(localized: "Where", comment: "Privacy preview: field, where in the code it crashed"),
         { _ in String(localized: "Function names in Glideball’s own code", comment: "Privacy preview: a crash report's stack") }),
    ]

    /// A range as the stats send it ("<2", "4-8", "32+", in percent for 0…1 sliders), in words.
    static func rangeText(_ raw: String, percent: Bool = false) -> String {
        func number(_ s: String) -> String {
            guard let d = Double(s) else { return s }
            return percent ? (d / 100).formatted(.percent.precision(.fractionLength(0))) : d.formatted()
        }
        if raw.hasPrefix("<") {
            let edge = number(String(raw.dropFirst()))
            return String(localized: "Under \(edge)", comment: "Privacy preview: a range, like “Under 2” or “Under 25%”")
        }
        if raw.hasSuffix("+") {
            let edge = number(String(raw.dropLast()))
            return String(localized: "\(edge) or more", comment: "Privacy preview: a range, like “32 or more” or “75% or more”")
        }
        let range = raw.split(separator: "-").map(String.init)
        guard range.count == 2 else { return raw }
        let low = number(range[0]), high = number(range[1])
        return String(localized: "Between \(low) and \(high)", comment: "Privacy preview: the pointer speed's range, like “Between 4 and 8”")
    }
    private static func range(_ j: [String: Any], _ k: String) -> String { rangeText(string(j, k)) }
    private static func percent(_ j: [String: Any], _ k: String) -> String { rangeText(string(j, k), percent: true) }
    private static func flags(_ j: [String: Any], _ k: String) -> [String] {
        (j[k] as? [String: Bool] ?? [:]).filter(\.value).map(\.key)
    }

    static let statsLabels: [Label] = statsGroups.flatMap(\.labels)

    /// The stats in the order Privacy lists them, under the same headings the Usage page uses.
    static let statsGroups: [(title: String?, labels: [Label])] = [
        (nil, [
            installID, version, os, arch,
            (["lang"], String(localized: "Language", comment: "Privacy preview: field"), { j in
                let code = string(j, "lang")
                return Locale.current.localizedString(forIdentifier: code) ?? code
            }),
            (["trackballs"], String(localized: "Trackballs", comment: "Privacy preview: field, the Kensington trackballs connected"), { j in
                let names = (j["trackballs"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                return names.isEmpty ? String(localized: "None connected", comment: "Privacy preview: no trackball") : names.formatted(.list(type: .and))
            }),
        ]),
        (String(localized: "Look"), [
            (["ballColor"], String(localized: "Ball color"), { j in
                let id = string(j, "ballColor")
                return id == "custom" ? BallTheme.custom([]).title : BallTheme.curated.first { $0.id == id }?.title ?? id
            }),
            (["appIcon"], String(localized: "App icon"), { AppIconStyle(rawValue: string($0, "appIcon"))?.title ?? string($0, "appIcon") }),
            (["light"], String(localized: "Light"), { j in
                string(j, "light") == "off" ? String(localized: "Off", comment: "Privacy preview: a switch that's off") : percent(j, "light")
            }),
            (["performance"], String(localized: "Performance", comment: "Privacy preview: field"), { j in
                PerformanceMode(rawValue: string(j, "performance"))?.title ?? string(j, "performance")
            }),
            (["launchStyle"], String(localized: "When Glideball opens"), { j in
                LaunchExperience.Style(rawValue: string(j, "launchStyle"))?.title ?? string(j, "launchStyle")
            }),
            (["celebrations"], String(localized: "Celebrations"), { onOff($0, "celebrations") }),
            (["weeklyRecap"], String(localized: "Weekly recap"), { onOff($0, "weeklyRecap") }),
        ]),
        (String(localized: "Sound"), [
            (["sounds"], String(localized: "Sounds"), { onOff($0, "sounds") }),
            (["soundVolume"], String(localized: "Volume"), { percent($0, "soundVolume") }),
            (["soundKinds"], String(localized: "Kinds of sound", comment: "Privacy preview: field, which of the sound kinds' own switches are on"), { j in
                let kinds = j["soundKinds"] as? [String: Bool] ?? [:]
                return String(localized: "\(flags(j, "soundKinds").count) of \(kinds.count) on", comment: "Privacy preview: how many switches are on, like “4 of 5 on”")
            }),
        ]),
        (String(localized: "Pointer"), [
            (["pointerSpeed"], String(localized: "Pointer speed", comment: "Privacy preview: field"), { range($0, "pointerSpeed") }),
            (["precisionSpeed"], String(localized: "Precision speed"), { range($0, "precisionSpeed") }),
            (["perDisplaySpeed"], String(localized: "Per-display speeds"), { onOff($0, "perDisplaySpeed") }),
            (["ballScrollSpeed"], String(localized: "Ball scroll speed"), { range($0, "ballScrollSpeed") }),
        ]),
        (String(localized: "Scrolling"), [
            (["scrollMode"], String(localized: "Scroll mode", comment: "Privacy preview: field"), { j in
                ScrollMode(rawValue: string(j, "scrollMode"))?.title ?? string(j, "scrollMode")
            }),
            (["smoothScrolling"], String(localized: "Smooth scrolling"), { onOff($0, "smoothScrolling") }),
            (["flipDirection"], String(localized: "Flip direction"), { onOff($0, "flipDirection") }),
            (["shiftSideways"], String(localized: "Shift scrolls sideways"), { onOff($0, "shiftSideways") }),
            (["nativeSpeed"], String(localized: "Native scroll speed", comment: "Privacy preview: field, the Native mode's speed slider"), { range($0, "nativeSpeed") }),
            (["flyDistance"], String(localized: "Slow-turn distance"), { range($0, "flyDistance") }),
            (["flyPower"], String(localized: "Spin power"), { percent($0, "flyPower") }),
            (["flyReach"], String(localized: "Fast-spin reach"), { percent($0, "flyReach") }),
            (["flyGlide"], String(localized: "Glide"), { percent($0, "flyGlide") }),
            (["followDistance"], String(localized: "Distance per notch"), { range($0, "followDistance") }),
            (["followSmoothness"], String(localized: "Follow"), { percent($0, "followSmoothness") }),
            (["followAcceleration"], String(localized: "Spin acceleration"), { percent($0, "followAcceleration") }),
            (["throwOn"], String(localized: "Throw to coast"), { onOff($0, "throwOn") }),
            (["throwDistance"], String(localized: "Throw distance"), { percent($0, "throwDistance") }),
        ]),
        (String(localized: "Buttons and gestures", comment: "Privacy preview: heading"), [
            (["buttons"], String(localized: "Button actions", comment: "Privacy preview: field"), { j in
                let n = (j["buttons"] as? [String: Int] ?? [:]).values.reduce(0, +)
                return String(localized: "\(n) set, by kind only, never the keys", comment: "Privacy preview: how many button actions; %lld is a number")
            }),
            (["combos"], String(localized: "Combos", comment: "Privacy preview: field, how many"), { count($0, "combos") }),
            (["gestures"], String(localized: "Gestures"), { onOff($0, "gestures") }),
            (["gestureButtons"], String(localized: "Gesture buttons", comment: "Privacy preview: field, how many buttons and combos are gestures"), { count($0, "gestureButtons") }),
            (["gestureActions"], String(localized: "Gesture directions", comment: "Privacy preview: field"), { j in
                let n = (j["gestureActions"] as? [String: Int] ?? [:]).values.reduce(0, +)
                return String(localized: "\(n) set, by kind only, never the keys", comment: "Privacy preview: how many button actions; %lld is a number")
            }),
            (["gestureShow"], String(localized: "Show the ring"), { j in
                let m = j["gestureShow"] as? [String: Int] ?? [:]
                let parts = RingShow.allCases.compactMap { r in m[r.rawValue].map { "\(r.title) \($0.formatted())" } }
                return parts.isEmpty ? String(localized: "None") : parts.joined(separator: " · ")
            }),
            (["gestureEight"], String(localized: "8 directions"), { count($0, "gestureEight") }),
            (["gestureMore"], String(localized: "More"), { count($0, "gestureMore") }),
            (["switcherHidden"], String(localized: "Hidden from the Switcher"), { count($0, "switcherHidden") }),
            (["gestureDistance"], String(localized: "Gesture distance"), { GestureDistance(rawValue: string($0, "gestureDistance"))?.title ?? string($0, "gestureDistance") }),
            (["steadyHands"], String(localized: "Steady hands"), { onOff($0, "steadyHands") }),
            (["modesSetUp"], String(localized: "Modes you can reach", comment: "Privacy preview: field, which of Precision, Scroll with ball and Drag lock are on a button or a shortcut"), { j in
                let on = Set(flags(j, "modesSetUp"))
                let names = [("precision", GlobalShortcuts.Action.precision.title), ("ballScroll", GlobalShortcuts.Action.ballScroll.title),
                             ("dragLock", GlobalShortcuts.Action.dragLock.title)].filter { on.contains($0.0) }.map(\.1)
                return names.isEmpty ? String(localized: "None") : names.formatted(.list(type: .and))
            }),
        ]),
        (String(localized: "General"), [
            (["appProfiles"], String(localized: "App setups", comment: "Privacy preview: field, how many"), { count($0, "appProfiles") }),
            (["menuBarIcon"], String(localized: "Menu bar icon"), { onOff($0, "menuBarIcon") }),
            (["menuBarStyle"], String(localized: "Menu bar icon style"), { MenuBarIcon.Style(rawValue: string($0, "menuBarStyle"))?.title ?? string($0, "menuBarStyle") }),
            (["menuBarOpens"], String(localized: "Menu bar icon opens"), { MenuBarClick(rawValue: string($0, "menuBarOpens"))?.title ?? string($0, "menuBarOpens") }),
            (["showInDock"], String(localized: "Show in Dock and app switcher"), { onOff($0, "showInDock") }),
            (["askBeforeQuitting"], String(localized: "Ask before quitting"), { onOff($0, "askBeforeQuitting") }),
            (["openAtLogin"], String(localized: "Open at login"), { onOff($0, "openAtLogin") }),
            (["allowScripts"], String(localized: "Allow Raycast and scripts"), { onOff($0, "allowScripts") }),
            (["ownLanguage"], String(localized: "A language just for Glideball", comment: "Privacy preview: field, whether a language is picked in Settings › General (not which one)"), { onOff($0, "ownLanguage") }),
            (["lowBatteryAlerts"], String(localized: "Low battery alerts"), { onOff($0, "lowBatteryAlerts") }),
            (["sync"], String(localized: "Sync"), { onOff($0, "sync") }),
            (["autoBackups"], String(localized: "Automatic backups"), { onOff($0, "autoBackups") }),
            (["autoUpdate"], String(localized: "Install updates automatically"), { onOff($0, "autoUpdate") }),
            (["globalShortcuts"], String(localized: "Keyboard shortcuts set", comment: "Privacy preview: field, how many global shortcuts are set (never which keys)"), { count($0, "globalShortcuts") }),
            (["beta"], String(localized: "Other Kensington trackballs"), { onOff($0, "beta") }),
            (["earlyUpdates"], String(localized: "Early updates"), { onOff($0, "earlyUpdates") }),
            (["displays"], String(localized: "Displays", comment: "Privacy preview: field, how many displays are connected"), { range($0, "displays") }),
            (["windowLayout"], String(localized: "Window layout", comment: "Privacy preview: field, how many columns the main window's pages had room for"), { j in
                switch string(j, "windowLayout") {
                case "single": String(localized: "One column", comment: "Privacy preview: window layout")
                case "double": String(localized: "Two columns", comment: "Privacy preview: window layout")
                case "roomy": String(localized: "Two wide columns", comment: "Privacy preview: window layout")
                case "triple": String(localized: "Three columns", comment: "Privacy preview: window layout")
                default: String(localized: "Not opened yet", comment: "Privacy preview: window layout, before the window has opened")
                }
            }),
            (["used"], String(localized: "Used at least once", comment: "Privacy preview: field, which of a few features this Mac has used"), { j in
                let on = Set(flags(j, "used"))
                let names = FeatureUse.allCases.filter { on.contains($0.rawValue) }.map(\.title)
                return names.isEmpty ? String(localized: "None yet", comment: "Privacy preview: no feature used yet") : names.formatted(.list(type: .and))
            }),
        ]),
    ]
}

extension CrashReports.Report {
    /// A report with this Mac's versions and placeholders where a real crash fills
    /// in what happened: the same struct, so the same keys, as a real one.
    static func example(installID: String) -> CrashReports.Report {
        let app = ShareData.appInfo
        return CrashReports.Report(installId: installID, crashedAt: ISO8601DateFormatter().string(from: Date()),
                                   version: app["version"] ?? "?", build: app["build"] ?? "0", os: ShareData.osVersion,
                                   arch: ShareData.arch, exception: "EXC_BAD_ACCESS", signal: "SIGSEGV", termination: "",
                                   reason: "", ownImage: CrashReports.executableName,
                                   frames: [.init(image: CrashReports.executableName, symbol: "Engine.handle", offset: 0)])
    }
}
