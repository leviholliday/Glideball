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
///   Kensington trackballs are connected, and a few settings — counts and
///   choices only, never shortcuts, app names or anything typed.
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

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var sendingStats = false
    @ObservationIgnored private var lookingForCrashes = false

    private init() {
        choice = defaults.string(forKey: Self.choiceKey).flatMap(ShareChoice.init) ?? .nothing
        asked = defaults.bool(forKey: Self.askedKey)
        // (Anything not in today's form, from a test build say, is replaced when next needed.)
        installID = defaults.string(forKey: Self.installIDKey).flatMap { RandomID.isValid($0) ? $0 : nil }
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

        struct Trackball: Encodable {
            var name: String
            var product: Int
        }
    }

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
    static func speedBucket(_ speed: Double) -> String {
        switch speed {
        case ..<2: "<2"
        case ..<4: "2-4"
        case ..<8: "4-8"
        case ..<16: "8-16"
        case ..<32: "16-32"
        default: "32+"
        }
    }

    private static let productCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ()+.,/&'-")

    /// Today's ping, from the settings as they are now. Main thread.
    func stats(_ model: AppModel, installID: String) -> Stats {
        let c = model.config
        var buttons: [String: Int] = [:]
        for action in Array(c.buttons.values) + c.chords.map(\.action) { buttons[action.kind, default: 0] += 1 }
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
            buttons: buttons.mapValues { min($0, 100) })
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
                for key in [Self.installIDKey, Self.lastStatsDayKey, Self.crashesSinceKey] { self.defaults.removeObject(forKey: key) }
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
        }
    }
}
