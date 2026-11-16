import AppKit
import Foundation
import Observation
import Security

/// Checks GitHub once a day for a newer Glide release and installs it in place.
/// This and iCloud Drive sync are the only times Glide touches the network.
/// Everyone gets full releases; people who turn on Early updates also get
/// prereleases (tagged like v2.4-beta.1).
///
/// Installing: download the release zip, unpack it, and only accept it if it's
/// signed with the same certificate and bundle identifier as the running app
/// (so a tampered download is refused — and macOS keeps the Accessibility and
/// Input Monitoring grants, which are tied to that signature). Then a tiny
/// helper waits for Glide to quit, swaps the app, and relaunches it.
@Observable
final class UpdateChecker {
    struct Update: Equatable {
        let version: String           // as tagged, without the "v": "2.4" or "2.4-beta.1"
        let page: URL
        let download: URL?
        let notes: String
        var isPrerelease = false

        /// What's new in this version, on Glideball's website.
        var notesPage: URL { SiteLinks.whatsNew(in: version) }

        /// "2.4" or "2.4 beta 1".
        var displayVersion: String { GlideVersion(version)?.display ?? version }
    }

    enum InstallState: Equatable {
        case idle
        case downloading(Double)
        case installing
        case failed(String)
    }

    private(set) var available: Update?
    private(set) var installState: InstallState = .idle

    static let maxReleaseListBytes = 10_000_000
    /// The biggest zip the updater will unpack (the app is a few MB), and how long unpacking may take.
    static let maxZipBytes: Int64 = 300_000_000
    static let unpackSeconds: TimeInterval = 120

    /// The newest releases, prereleases included (GitHub's "latest" never is one).
    static let releasesAPI = URL(string: "https://api.github.com/repos/leviholliday/glideball/releases?per_page=30")!
    /// What the app downloads when it updates itself. The same zip as
    /// `assetName`, attached under a second name so the website's download
    /// counter (which skips this one) counts people, not updates.
    static let updateAssetName = "Glideball-update.zip"
    /// What the website's download button links to; the app falls back to it
    /// for releases made before `updateAssetName` existed.
    static let assetName = "Glideball.zip"
    /// What versions before the rename (≤ 2.7.1) download; releases still attach it.
    static let legacyAssetName = "Glide.zip"
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var progressObservation: NSKeyValueObservation?
    /// Offer prereleases too — Early updates. Call `check()` after changing it.
    @ObservationIgnored var includePrereleases = EarlyUpdates.isEnabled

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    /// What a "Check for Updates" the user asked for found — shown next to the button.
    enum ManualCheck: Equatable { case idle, checking, upToDate, failed }
    private(set) var manualCheck: ManualCheck = .idle
    /// When GitHub last answered a check (automatic or asked for).
    private(set) var lastChecked: Date?

    /// A check the user asked for: reports back even when there's nothing new.
    func checkNow() {
        manualCheck = .checking
        check { [weak self] ok in
            guard let self else { return }
            self.manualCheck = !ok ? .failed : (self.available == nil ? .upToDate : .idle)
        }
    }

    func check(completion: ((Bool) -> Void)? = nil) {
        // Always ask GitHub fresh: a cached "latest release" would hide a new update.
        var request = URLRequest(url: Self.releasesAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let prereleases = includePrereleases
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self, let data, (response as? HTTPURLResponse)?.statusCode == 200 else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            let newest = Self.newest(in: data, includePrereleases: prereleases)
            let newer = newest.map { Self.isNewer($0.version, than: self.currentVersion) } ?? false
            DispatchQueue.main.async {
                // The Early updates switch changed while this was in flight: a fresh check is coming.
                guard prereleases == self.includePrereleases else { completion?(true); return }
                self.available = newer ? newest : nil
                self.lastChecked = Date()
                completion?(true)
            }
        }.resume()
    }

    /// The highest-versioned release in a GitHub release list. Drafts never
    /// count; prereleases only with Early updates. A tag that reads like a
    /// prerelease ("2.4-beta.1") counts as one even if GitHub isn't told so.
    static func newest(in data: Data, includePrereleases: Bool) -> Update? {
        // 30 releases with their notes are well under a megabyte; anything past this isn't GitHub's answer.
        guard data.count <= maxReleaseListBytes, nestingDepth(of: data) <= maxReleaseListDepth,
              let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        return list.compactMap { item -> (GlideVersion, Update)? in
            // One odd entry (a null, a string) costs only itself, not every update after it.
            guard let json = item as? [String: Any], json["draft"] as? Bool != true,
                  let update = parse(json), let version = GlideVersion(update.version),
                  includePrereleases || !update.isPrerelease else { return nil }
            return (version, update)
        }
        .max { $0.0 < $1.0 }?.1
    }

    /// A real release list is four or five levels deep; JSONSerialization overflows its stack on a few
    /// thousand levels of objects, so anything deeper is turned away before it's parsed.
    static let maxReleaseListDepth = 32

    /// How deep the brackets nest, counted without parsing (quoted text is skipped).
    static func nestingDepth(of data: Data) -> Int {
        var depth = 0, deepest = 0, inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x5B, 0x7B: depth += 1; deepest = max(deepest, depth)
            case 0x5D, 0x7D: depth = max(0, depth - 1)
            default: break
            }
        }
        return deepest
    }

    /// One release from the GitHub API.
    static func parse(_ json: [String: Any]) -> Update? {
        // Links come from the release list: only https ones are ever opened or downloaded
        // (the page is handed to the browser, so a file: or custom-scheme link would be an app launcher).
        func secure(_ string: String?) -> URL? {
            guard let url = string.flatMap(URL.init(string:)), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
            return url
        }
        guard let tag = json["tag_name"] as? String, !tag.isEmpty, tag.count <= 64,
              let page = secure(json["html_url"] as? String) else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zip = downloadURL(in: assets)
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Update(version: version,
                      page: page,
                      download: secure(zip),
                      notes: json["body"] as? String ?? "",
                      isPrerelease: json["prerelease"] as? Bool == true || GlideVersion(version)?.isPrerelease == true)
    }

    /// The zip to update from: Glideball-update.zip, else Glideball.zip, else the
    /// legacy Glide.zip. Whichever it is, `prepare` checks the signature.
    static func downloadURL(in assets: [[String: Any]]) -> String? {
        for name in [updateAssetName, assetName, legacyAssetName] {
            if let url = assets.first(where: { $0["name"] as? String == name })?["browser_download_url"] as? String {
                return url
            }
        }
        return nil
    }

    /// "1.10" > "1.9", and "2.4" > "2.4-beta.2" > "2.4-beta.1" > "2.3".
    /// Anything unreadable is never newer.
    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = GlideVersion(a) else { return false }
        guard let y = GlideVersion(b) else { return true }
        return x > y
    }

    // MARK: Installing

    func install() {
        guard let update = available, let download = update.download else {
            if let page = available?.page { NSWorkspace.shared.open(page) }
            return
        }
        installState = .downloading(0)
        let task = URLSession.shared.downloadTask(with: download) { [weak self] file, response, error in
            guard let self else { return }
            let result: Result<URL, Error>
            if let file, (response as? HTTPURLResponse)?.statusCode == 200 {
                result = Result { try Self.prepare(zip: file, expectedVersion: update.version) }
            } else {
                result = .failure(UpdateError(error.map { String(localized: "The download didn’t finish: \($0.localizedDescription)") }
                                              ?? String(localized: "The download didn’t finish.")))
            }
            DispatchQueue.main.async {
                self.progressObservation = nil
                switch result {
                case .success(let newApp): self.relaunch(into: newApp)
                case .failure(let error): self.installState = .failed(error.localizedDescription)
                }
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                if case .downloading = self?.installState { self?.installState = .downloading(progress.fractionCompleted) }
            }
        }
        task.resume()
    }

    struct UpdateError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Unpacks the downloaded zip and returns the new Glide.app — only if it's
    /// genuinely ours and genuinely the advertised version. `bundleID` and
    /// `requirement` are the running app's own unless a test names others.
    static func prepare(zip: URL, expectedVersion: String,
                        bundleID: String? = Bundle.main.bundleIdentifier,
                        requirement: SecRequirement? = nil,
                        workRoot: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: zip.path)[.size] as? Int64) ?? 0
        guard size > 0, size <= maxZipBytes else {
            throw UpdateError(String(localized: "The download isn’t the expected Glideball \(expectedVersion)."))
        }
        let work = workRoot.appendingPathComponent("GlideUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            return try unpack(zip: zip, into: work, expectedVersion: expectedVersion, bundleID: bundleID, requirement: requirement)
        } catch {
            removeTree(work)   // a refused or broken download leaves nothing behind
            throw error
        }
    }

    /// Deletes an unpacked folder. A zip can carry folders with no permissions, which a plain
    /// remove can't get into, so those are made writable first.
    static func removeTree(_ url: URL) {
        let fm = FileManager.default
        if (try? fm.removeItem(at: url)) != nil || !fm.fileExists(atPath: url.path) { return }
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-R", "u+rwX", url.path]
        chmod.standardError = FileHandle.nullDevice
        try? chmod.run()
        chmod.waitUntilExit()
        try? fm.removeItem(at: url)
    }

    private static func unpack(zip: URL, into work: URL, expectedVersion: String,
                               bundleID: String?, requirement: SecRequirement?) throws -> URL {
        let fm = FileManager.default
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, work.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        unzip.terminationHandler = { _ in finished.signal() }
        try unzip.run()
        if finished.wait(timeout: .now() + unpackSeconds) == .timedOut {
            unzip.terminate()   // a zip bomb or a stuck unpack
            throw UpdateError(String(localized: "Couldn’t unpack the update."))
        }
        guard unzip.terminationStatus == 0 else { throw UpdateError(String(localized: "Couldn’t unpack the update.")) }

        // "Glideball.app" since 2.8; older releases unpack "Glide.app". It must be a real folder
        // that came out of the zip: a link (to the installed app, say) would pass the checks below
        // by being the very thing they trust, and then be moved into place as a link.
        func isRealFolder(_ url: URL) -> Bool {
            guard let type = try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType else { return false }
            return type == .typeDirectory   // attributesOfItem doesn't follow a final link
        }
        let app = ["Glideball.app", "Glide.app"].map { work.appendingPathComponent($0) }.first { isRealFolder($0) }
            ?? work.appendingPathComponent("Glideball.app")
        guard isRealFolder(app), let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw UpdateError(String(localized: "The download isn’t the expected Glideball \(expectedVersion)."))
        }
        try verifySignature(of: app, against: requirement)
        return app
    }

    /// The new app must satisfy the running app's own designated requirement:
    /// same signing certificate, same identifier. (`requirement`: a test's own.)
    static func verifySignature(of app: URL, against pinned: SecRequirement? = nil) throws {
        var requirement = pinned
        if requirement == nil {
            var me: SecCode?
            var staticMe: SecStaticCode?
            guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
                  SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
                  SecCodeCopyDesignatedRequirement(staticMe, [], &requirement) == errSecSuccess, requirement != nil else {
                throw UpdateError(String(localized: "Couldn’t read Glideball’s own signature to compare against."))
            }
        }
        var candidate: SecStaticCode?
        guard let requirement, SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate,
              SecStaticCodeCheckValidity(candidate, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
            throw UpdateError(String(localized: "The update isn’t signed by Glideball’s developer, so it wasn’t installed."))
        }
    }

    /// The helper's whole script. Arguments: $1 where the app lives, $2 where it is now (differs
    /// only when Glide.app moves to Glideball.app), $3 the new app, $4 Glideball's process ID.
    static let swapScript = """
    current="$1"; old="$2"; new="$3"
    while kill -0 "$4" 2>/dev/null; do sleep 0.2; done
    rm -rf "$current.old"
    [ -d "$current" ] && mv "$current" "$current.old"
    if mv "$new" "$current"; then
      rm -rf "$current.old"
      [ "$old" != "$current" ] && rm -rf "$old"
    else
      rm -rf "$current"; [ -d "$current.old" ] && mv "$current.old" "$current"
      current="$old"
    fi
    xattr -dr com.apple.quarantine "$current" 2>/dev/null
    open "$current"
    """

    /// Hands off to a tiny shell helper that swaps the app once Glide has quit.
    private func relaunch(into newApp: URL) {
        installState = .installing
        let current = AppRename.installPath(for: Bundle.main.bundleURL).path
        let old = Bundle.main.bundleURL.path   // differs only when moving Glide.app → Glideball.app
        let pid = ProcessInfo.processInfo.processIdentifier
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The paths go in as arguments, never spliced into the script: a folder name with a quote or a $ in it can't change what runs.
        helper.arguments = ["-c", Self.swapScript, "glideball-update", current, old, newApp.path, String(pid)]
        do {
            try helper.run()
        } catch {
            installState = .failed(String(localized: "Couldn’t start the installer: \(error.localizedDescription)"))
            return
        }
        // Glide normally refuses to quit unless asked from its own menu; the
        // update's relaunch counts as asked.
        if let app = NSApp.delegate as? AppDelegate { app.quitNow() } else { NSApp.terminate(nil) }
    }
}

/// A Glide version number: "2.4", "2.4.1", or a prerelease of one — "2.4-beta.1"
/// (the form release.sh tags and writes to CFBundleShortVersionString). Also
/// reads "2.4b1", "2.4 beta 1", "2.4-rc.1" and "2.4-alpha.1". A prerelease
/// comes before its final release: 2.4-beta.1 < 2.4-beta.2 < 2.4-rc.1 < 2.4.
struct GlideVersion: Comparable, CustomStringConvertible {
    enum Stage: Int, Comparable {
        case alpha, beta, rc
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
        var name: String { switch self { case .alpha: "alpha"; case .beta: "beta"; case .rc: "RC" } }
    }

    let numbers: [Int]
    let prerelease: (stage: Stage, number: Int)?

    var isPrerelease: Bool { prerelease != nil }

    init?(_ string: String) {
        var s = Substring(string.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        // Numbers first: "2.4" or "2.4.1".
        let core = s.prefix { $0.isNumber || $0 == "." }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !core.isEmpty, !core.hasSuffix("."), numbers.allSatisfy({ $0 != nil }) else { return nil }
        self.numbers = numbers.map { $0! }
        // Then an optional prerelease: "-beta.1", "b1", " beta 1", "-rc.2"…
        var rest = s.dropFirst(core.count).lowercased()[...]
        if rest.isEmpty { prerelease = nil; return }
        rest = rest.drop { $0 == "-" || $0 == " " || $0 == "." }
        let label = rest.prefix { $0.isLetter }
        let stage: Stage
        switch label {
        case "a", "alpha": stage = .alpha
        case "b", "beta": stage = .beta
        case "rc": stage = .rc
        default: return nil
        }
        let numberText = rest.dropFirst(label.count).drop { $0 == "." || $0 == " " || $0 == "-" }
        if numberText.isEmpty {
            prerelease = (stage, 0)
        } else if let n = Int(numberText), n >= 0 {
            prerelease = (stage, n)
        } else {
            return nil
        }
    }

    /// For people: "2.4", "2.4 beta 1".
    var display: String {
        let base = numbers.map(String.init).joined(separator: ".")
        guard let p = prerelease else { return base }
        return p.number > 0 ? "\(base) \(p.stage.name) \(p.number)" : "\(base) \(p.stage.name)"
    }

    var description: String { display }

    static func == (a: GlideVersion, b: GlideVersion) -> Bool { !(a < b) && !(b < a) }

    static func < (a: GlideVersion, b: GlideVersion) -> Bool {
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let l = i < a.numbers.count ? a.numbers[i] : 0, r = i < b.numbers.count ? b.numbers[i] : 0
            if l != r { return l < r }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil), (nil, _?): return false        // a final release is never before its prerelease
        case (_?, nil): return true
        case let (x?, y?): return (x.stage.rawValue, x.number) < (y.stage.rawValue, y.number)
        }
    }
}
