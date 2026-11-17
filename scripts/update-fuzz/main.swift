import AppKit
import Foundation
import Security

// Hostile input for the updater: see run.sh. Everything runs the real UpdateChecker code.

// MARK: - Harness

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let deep = args.contains("--deep")
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
let seed: UInt64 = option("--seed").flatMap { UInt64($0) } ?? UInt64.random(in: 1...UInt64(UInt32.max))
let totalBudget: Double = option("--budget").flatMap { Double($0) } ?? (deep ? 900 : 240)
let helperDir = URL(fileURLWithPath: option("--helper-dir") ?? "scripts/update-fuzz")
let runStart = Date()

let fm = FileManager.default
let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("glide-update-fuzz-\(UUID().uuidString.prefix(8))", isDirectory: true)
let tmp = root.appendingPathComponent("tmp/unpack", isDirectory: true)   // where prepare() unpacks: two levels down, so a "../../" in a zip stays inside root and is seen
try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
let decoy = root.appendingPathComponent("decoy", isDirectory: true)   // what hostile zips aim at: must stay empty
try! fm.createDirectory(at: decoy, withIntermediateDirectories: true)
let tmpParent = tmp.deletingLastPathComponent()
defer { try? fm.removeItem(at: root) }

var failures = 0
var sectionFailures = 0
var sectionCases = 0
var sectionStart = Date()
func fail(_ msg: String) {
    failures += 1
    sectionFailures += 1
    if sectionFailures <= 15 { print("  FAIL:", msg) }
}
func check(_ ok: Bool, _ msg: @autoclosure () -> String) { if !ok { fail(msg()) } }
func beginSection() { sectionFailures = 0; sectionCases = 0; sectionStart = Date() }
func endSection(_ title: String, _ detail: String = "") {
    let t = String(format: "%.1f", Date().timeIntervalSince(sectionStart))
    print("\(title): \(sectionCases) cases\(detail.isEmpty ? "" : ", " + detail), \(sectionFailures == 0 ? "ok" : "\(sectionFailures) FAILED") (\(t) s)")
}

// The case running now, for the crash report and the watchdog.
let caseBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 512)
caseBuffer.initialize(repeating: 0, count: 512)
nonisolated(unsafe) var lastProgress = Date()
let progressLock = NSLock()
func setCase(_ name: String) {
    let bytes = Array(name.utf8.prefix(500))
    for (i, b) in bytes.enumerated() { caseBuffer[i] = CChar(bitPattern: b) }
    caseBuffer[bytes.count] = 0
    progressLock.lock(); lastProgress = Date(); progressLock.unlock()
}
func altStack() {
    let size = 128 * 1024
    var ss = stack_t(ss_sp: malloc(size), ss_size: size, ss_flags: 0)
    sigaltstack(&ss, nil)
}
for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
    var sa = sigaction()
    sa.__sigaction_u.__sa_handler = { _ in
        let head = "\nFAIL: CRASHED in case: "
        _ = head.withCString { write(2, $0, strlen($0)) }
        _ = write(2, caseBuffer, strlen(caseBuffer))
        _ = write(2, "\n", 1)
        _exit(1)
    }
    sa.sa_flags = SA_ONSTACK
    sigaction(sig, &sa, nil)
}
altStack()

func stopRun(_ why: String) -> Never {
    print("\nFAIL: \(why), in case: \(String(cString: caseBuffer)) (seed \(seed))")
    print("\(failures + 1) FAILURES (seed \(seed))")
    try? fm.removeItem(at: root)
    exit(1)
}

/// A thread of its own: stops the run, naming the case, if nothing finishes for 90 s or the whole run passes its budget.
Thread {
    while true {
        Thread.sleep(forTimeInterval: 1)
        progressLock.lock(); let idle = Date().timeIntervalSince(lastProgress); progressLock.unlock()
        if idle > 90 { stopRun("nothing finished for \(Int(idle)) s") }
        if Date().timeIntervalSince(runStart) > totalBudget { stopRun("over the \(Int(totalBudget)) s budget") }
    }
}.start()

/// One long-lived worker with a GCD-sized stack (512 KB, like the URLSession queue the updater runs on).
final class Worker {
    private let lock = NSCondition()
    private var job: (() -> Void)?
    private let done = DispatchSemaphore(value: 0)
    init() {
        let t = Thread { [self] in
            altStack()
            while true {
                lock.lock()
                while job == nil { lock.wait() }
                let j = job!
                job = nil
                lock.unlock()
                j()
                done.signal()
            }
        }
        t.stackSize = 512 * 1024
        t.start()
    }
    /// A case over `budget` seconds is a hang: report and stop.
    func run(_ name: String, budget: Double = 20, _ body: @escaping () -> Void) {
        sectionCases += 1
        setCase(name)
        let began = Date()
        lock.lock(); job = body; lock.signal(); lock.unlock()
        if done.wait(timeout: .now() + budget) == .timedOut { stopRun("\(name): no answer after \(budget) s (hang)") }
        let took = Date().timeIntervalSince(began)
        if took > 5 { print("  slow: \(name.prefix(100)) took \(String(format: "%.1f", took)) s") }
    }
}
let worker = Worker()

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
var rng = SplitMix(state: seed)

typealias Checker = UpdateChecker
let current = "2.10-beta.14"   // what "this app" is, for the downgrade questions

// MARK: - Live check (opt-in: run.sh --live)

// The real updater code on the real network: the release list from GitHub, the newest prerelease as a beta user
// would be offered it, its updater zip through startDownload on URLSession.shared, and prepare() on that, against the
// installed app's own designated requirement (read only). Ends with the verified app in a temp folder, which is
// deleted. Nothing is installed, moved or launched.
if args.contains("--live") {
    func stage(_ text: String) { print("[live] \(text)"); setCase("live: \(text)") }
    func finish(_ ok: Bool, _ why: String) -> Never {
        print(ok ? "LIVE OK: \(why)" : "LIVE FAILED: \(why)")
        try? fm.removeItem(at: root)
        exit(ok ? 0 : 1)
    }
    stage("release list: \(Checker.releasesAPI.absoluteString)")
    var request = URLRequest(url: Checker.releasesAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    let listed = DispatchSemaphore(value: 0)
    var listData: Data?, listStatus = 0
    URLSession.shared.dataTask(with: request) { data, response, _ in
        listData = data; listStatus = (response as? HTTPURLResponse)?.statusCode ?? 0; listed.signal()
    }.resume()
    if listed.wait(timeout: .now() + 30) == .timedOut { finish(false, "the release list didn't arrive in 30 s") }
    guard listStatus == 200, let listData else { finish(false, "GitHub answered \(listStatus) for the release list") }
    print("[live] release list: \(listData.count) bytes")
    guard let update = Checker.newest(in: listData, includePrereleases: true) else { finish(false, "no release in the list") }
    print("[live] newest with Early updates: \(update.version) (prerelease: \(update.isPrerelease))")
    guard let url = update.download else { finish(false, "release \(update.version) has no updater asset") }
    print("[live] asset: \(url.absoluteString)")
    check(url.lastPathComponent == Checker.updateAssetName, "the asset taken is \(url.lastPathComponent), not \(Checker.updateAssetName)")

    stage("designated requirement of /Applications/Glideball.app (read only)")
    var installedCode: SecStaticCode?, designated: SecRequirement?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/Applications/Glideball.app") as CFURL, [], &installedCode) == errSecSuccess, let installedCode,
          SecCodeCopyDesignatedRequirement(installedCode, [], &designated) == errSecSuccess, let designated else { finish(false, "couldn't read the installed app's requirement") }
    var text: CFString?
    SecRequirementCopyString(designated, [], &text)
    print("[live] requirement: \(text as String? ?? "?")")

    stage("download through startDownload on URLSession.shared")
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var outcome: Result<URL, Error>?
    var lastPrinted = -1.0, reports = 0
    let began = Date()
    let live = Checker.startDownload(url, expectedVersion: update.version, bundleID: "com.leviholliday.glide", requirement: designated, workRoot: tmp,
                                     progress: { p in
        lock.lock(); defer { lock.unlock() }
        reports += 1
        if p - lastPrinted >= 0.25 || p >= 1 { lastPrinted = p; print("[live] progress \(Int(p * 100))%") }
    }, completion: { r in lock.lock(); outcome = r; lock.unlock(); done.signal() })
    if done.wait(timeout: .now() + 180) == .timedOut { live.task.cancel(); finish(false, "no end after 180 s") }
    lock.lock(); let result = outcome; let count = reports; lock.unlock()
    print("[live] download and prepare took \(String(format: "%.1f", Date().timeIntervalSince(began))) s, \(count) progress reports, \(live.task.countOfBytesReceived) bytes received")
    switch result {
    case .success(let app)?:
        stage("verified app: \(app.path)")
        let info = Bundle(url: app)?.infoDictionary
        print("[live] identifier \(info?["CFBundleIdentifier"] ?? "?"), version \(info?["CFBundleShortVersionString"] ?? "?")")
        check(fm.fileExists(atPath: app.path), "the unpacked app isn't there")
        check(app.path.hasPrefix(tmp.path), "the app isn't under the temp folder")
        check((try? Checker.verifySignature(of: app, against: designated)) != nil, "verifySignature disagrees with prepare")
        check(count > 0, "no progress was reported")
        print("[live] deleting the temp folder")
        finish(failures == 0, failures == 0 ? "\(update.version) downloaded, unpacked and verified; nothing installed" : "\(failures) checks failed")
    case .failure(let error)?: finish(false, "prepare refused: \(error.localizedDescription)")
    case nil: finish(false, "no result")
    }
}

// MARK: - 1. Versions

beginSection()
let validVersions: [(String, String)] = [   // text, how it reads aloud
    ("2.4", "2.4"), ("v2.4", "2.4"), ("V2.4", "2.4"), ("2.4.1", "2.4.1"), ("1.10", "1.10"), ("2.10-beta.14", "2.10 beta 14"),
    ("2.4b1", "2.4 beta 1"), ("2.4 beta 1", "2.4 beta 1"), ("2.4-rc.1", "2.4 RC 1"), ("2.4-alpha.1", "2.4 alpha 1"), ("2.4-beta", "2.4 beta"),
    ("  2.4 ", "2.4"), ("0", "0"), ("0.0.0.0", "0.0.0.0"), ("2.4-BETA.3", "2.4 beta 3"),
]
for (text, reads) in validVersions {
    worker.run("version \(text.debugDescription)") {
        guard let v = GlideVersion(text) else { return fail("version \(text.debugDescription): not read") }
        check(v.display == reads, "version \(text.debugDescription): displays \(v.display), expected \(reads)")
        check(GlideVersion(v.display) == v, "version \(text.debugDescription): its display \(v.display.debugDescription) doesn't read back equal")
    }
}
let hostileVersions: [String] = [
    "", " ", "v", "V", ".", "..", "2.", ".2", "2..4", "2.4.", "-", "-1", "2.-4", "2.4-", "2.4-beta.", "2.4-beta.-1", "2.4-beta.x", "2.4-gamma.1",
    "2.4beta1.2", "2.4-beta.1.2", "2.4-beta 1 2", "2.4-b", "2.4-a-1", "2.4\n", "2.4\u{0}", "\u{0}", "2.4;rm -rf /", "../2.4", "2.4/../../x", "2.4#frag", "2.4?x=1",
    "99999999999999999999", "9223372036854775807", "9223372036854775808", "2.99999999999999999999", "2.4-beta.99999999999999999999", "2.4-beta.9223372036854775807",
    "٢.٤", "２.４", "２", "²", "½", "2.4-βeta.1", "2.4-beta.١", "\u{202E}2.4", "2.4\u{200B}", "🙂", "２.４-beta.1",
    String(repeating: "9", count: 100_000), String(repeating: "1.", count: 100_000) + "1", String(repeating: "1.", count: 100_000),
    "2.4-" + String(repeating: "beta", count: 100_000), String(repeating: " ", count: 1_000_000) + "2.4", "2.4" + String(repeating: "\u{301}", count: 100_000),
    String(repeating: "v", count: 100_000) + "2.4", "2.4-beta." + String(repeating: "9", count: 100_000),
]
var parsedHostile: [GlideVersion] = []
for text in hostileVersions {
    worker.run("hostile version \(text.prefix(40).debugDescription) (\(text.count) characters)") {
        if let v = GlideVersion(text) {
            parsedHostile.append(v)
            _ = v.display
            _ = v < v
        }
        _ = Checker.isNewer(text, than: current)
        _ = Checker.isNewer(current, than: text)
    }
}
// Ordering the updater relies on, from oldest to newest (a downgrade is never "newer").
let ordered = ["1.9", "1.10", "2.3", "2.4-alpha.1", "2.4-alpha.2", "2.4-beta.1", "2.4-beta.2", "2.4-beta.10", "2.4-rc.1", "2.4", "2.4.1", "2.10-beta.1", "2.10-beta.14", "2.10", "2.11", "10.0"]
worker.run("ordering") {
    for i in ordered.indices { for j in ordered.indices {
        let newer = Checker.isNewer(ordered[i], than: ordered[j])
        check(newer == (i > j), "isNewer(\(ordered[i]), than: \(ordered[j])) is \(newer)")
    } }
    check(!Checker.isNewer("2.10.0", than: "2.10"), "2.10.0 is newer than 2.10")
    check(!Checker.isNewer("2.10", than: "2.10.0"), "2.10 is newer than 2.10.0")
    check(!Checker.isNewer("garbage", than: "2.10"), "garbage counts as newer than 2.10")
    check(Checker.isNewer("2.10", than: "garbage"), "2.10 isn't newer than an unreadable current version")
    check(!Checker.isNewer("garbage", than: "garbage"), "garbage vs garbage")
}
// Laws over everything readable: antisymmetry, ==, transitivity.
worker.run("ordering laws over \(validVersions.count + parsedHostile.count) versions") {
    let all = validVersions.compactMap { GlideVersion($0.0) } + parsedHostile + ordered.compactMap { GlideVersion($0) }
    for a in all { for b in all {
        check(!(a < b && b < a), "\(a) and \(b) are each before the other")
        check((a == b) == (!(a < b) && !(b < a)), "== disagrees with < on \(a), \(b)")
    } }
    var local = SplitMix(state: seed)
    for _ in 0..<20_000 {
        let a = all.randomElement(using: &local)!, b = all.randomElement(using: &local)!, c = all.randomElement(using: &local)!
        if a < b && b < c { check(a < c, "not transitive: \(a) < \(b) < \(c)") }
        if a == b && b == c { check(a == c, "== not transitive: \(a), \(b), \(c)") }
    }
}
endSection("versions", "\(hostileVersions.count) hostile strings")

// MARK: - 2. Release lists

beginSection()
func release(tag: String? = "v2.11", page: Any? = "https://github.com/x/y/releases/tag/v2.11", draft: Any? = false, prerelease: Any? = false,
             assets: Any? = nil, body: Any? = "notes") -> [String: Any] {
    var d: [String: Any] = [:]
    if let tag { d["tag_name"] = tag }
    if let page { d["html_url"] = page }
    if let draft { d["draft"] = draft }
    if let prerelease { d["prerelease"] = prerelease }
    if let body { d["body"] = body }
    d["assets"] = assets ?? [["name": "Glideball-update.zip", "browser_download_url": "https://github.com/x/y/releases/download/\(tag ?? "t")/Glideball-update.zip"]]
    return d
}
func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

func listCase(_ name: String, _ data: Data, early: Bool = false, expectVersion: String?? = nil) {
    worker.run("release list: \(name)") {
        let u = Checker.newest(in: data, includePrereleases: early)
        if let expectVersion { check(u?.version == expectVersion, "\(name): got \(u?.version ?? "nothing"), expected \(expectVersion ?? "nothing")") }
        guard let u else { return }
        check(u.page.scheme?.lowercased() == "https", "\(name): page \(u.page) isn't https")
        check(u.download == nil || u.download?.scheme?.lowercased() == "https", "\(name): download \(u.download!) isn't https")
        check(GlideVersion(u.version) != nil, "\(name): unreadable version \(u.version.debugDescription) offered")
        check(early || !u.isPrerelease, "\(name): a prerelease offered without Early updates")
        _ = u.notesPage; _ = u.displayVersion
        // The downgrade question the updater asks next.
        _ = Checker.isNewer(u.version, than: current)
    }
}

// Not a release list at all.
for (name, bytes) in [("empty", Data()), ("one byte", Data([0x5b])), ("text", Data("not json".utf8)), ("html error page", Data("<html><h1>502 Bad Gateway</h1></html>".utf8)),
                      ("object", json(["message": "API rate limit exceeded"])), ("null", Data("null".utf8)), ("number", Data("42".utf8)), ("string", Data("\"[]\"".utf8)),
                      ("empty array", Data("[]".utf8)), ("array of nulls", Data("[null,null]".utf8)), ("array of arrays", Data("[[],[[]]]".utf8)), ("array of strings", Data("[\"v9.9\"]".utf8)),
                      ("NaN", Data("[NaN]".utf8)), ("trailing garbage", Data("[]xyz".utf8)), ("BOM", Data([0xEF, 0xBB, 0xBF] + Array("[]".utf8))), ("binary", Data((0..<4096).map { UInt8($0 % 251) })),
                      ("utf16", "[]".data(using: .utf16)!), ("unterminated", Data("[{\"tag_name\":\"v9".utf8))] {
    listCase(name, bytes, expectVersion: .some(nil))
}
// Depth and size.
listCase("100,000 deep", Data((String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)).utf8), expectVersion: .some(nil))
listCase("100,000 deep objects", Data((String(repeating: "{\"a\":", count: 100_000) + "1" + String(repeating: "}", count: 100_000)).utf8), expectVersion: .some(nil))
listCase("deep inside a release", Data(("[{\"tag_name\":\"v9.0\",\"html_url\":\"https://github.com/x\",\"x\":" + String(repeating: "[", count: 50_000) + String(repeating: "]", count: 50_000) + "}]").utf8))
listCase("11 MB of notes (over the cap)", json([release(tag: "v9.0", body: String(repeating: "x", count: 11_000_000))]), expectVersion: .some(nil))
listCase("5 MB of notes (a release still offered)", json([release(tag: "v9.0", body: String(repeating: "x", count: 5_000_000))]), expectVersion: "9.0")
listCase("100,000 releases", json((0..<100_000).map { release(tag: "v1.\($0)") }), expectVersion: .some(nil))
listCase("30,000 releases", json((0..<30_000).map { release(tag: "v1.\($0)", body: "") }), expectVersion: "1.29999")
listCase("100,000 assets", json([release(tag: "v9.0", assets: (0..<100_000).map { ["name": "a\($0)", "browser_download_url": "https://x/\($0)"] })]), expectVersion: "9.0")
listCase("a 5 MB tag", json([release(tag: "v" + String(repeating: "1", count: 5_000_000))]), expectVersion: .some(nil))
listCase("a 5 MB url", json([release(page: "https://github.com/" + String(repeating: "a", count: 5_000_000))]))
// What a good list looks like, and the rules.
listCase("good", json([release(tag: "v2.11")]), expectVersion: "2.11")
listCase("newest wins whatever the order", json([release(tag: "v2.9"), release(tag: "v2.11"), release(tag: "v2.10")]), expectVersion: "2.11")
listCase("a 1.10 beats a 1.9", json([release(tag: "v1.9"), release(tag: "v1.10")]), expectVersion: "1.10")
listCase("drafts never count", json([release(tag: "v9.0", draft: true), release(tag: "v2.11")]), expectVersion: "2.11")
listCase("draft as a string isn't a draft", json([release(tag: "v9.0", draft: "true")]), expectVersion: "9.0")
listCase("prerelease hidden without Early updates", json([release(tag: "v3.0-beta.1", prerelease: true), release(tag: "v2.11")]), expectVersion: "2.11")
listCase("prerelease offered with Early updates", json([release(tag: "v3.0-beta.1", prerelease: true), release(tag: "v2.11")]), early: true, expectVersion: "3.0-beta.1")
listCase("a beta tag GitHub forgot to flag", json([release(tag: "v3.0-beta.1", prerelease: false), release(tag: "v2.11")]), expectVersion: "2.11")
listCase("prerelease flag as a number (read as true)", json([release(tag: "v3.0", prerelease: 1)]), expectVersion: .some(nil))
listCase("a final beats its own beta", json([release(tag: "v3.0-rc.1"), release(tag: "v3.0")]), early: true, expectVersion: "3.0")
listCase("an odd entry doesn't hide the rest", json([NSNull(), "v9", 5, release(tag: "v2.11"), [1]] as [Any]), expectVersion: "2.11")
listCase("a tag with no v", json([release(tag: "2.11")]), expectVersion: "2.11")
listCase("a downgrade: only older releases", json([release(tag: "v2.9"), release(tag: "v1.0")]), expectVersion: "2.9")
for (name, tag) in [("empty tag", ""), ("v only", "v"), ("number tag", nil as String?), ("script tag", "v<script>"), ("space tag", "v2.11 beta"), ("path tag", "v../../x"), ("newline tag", "v2.11\n"), ("emoji tag", "v🙂"), ("huge tag", "v" + String(repeating: "9", count: 70))] {
    listCase("tag: \(name)", json([release(tag: tag)]))
}
var numberTag = release(); numberTag["tag_name"] = 2.11
listCase("tag as a number", json([numberTag]), expectVersion: .some(nil))
// Links. Only https ever leaves the release list.
for (name, url) in [("file:", "file:///Applications/Calculator.app"), ("javascript:", "javascript:alert(1)"), ("http:", "http://github.com/x"), ("custom scheme", "glideball://import?x=1"),
                    ("ftp:", "ftp://x/y.zip"), ("no scheme", "github.com/x"), ("empty", ""), ("https, no host", "https://"), ("data:", "data:text/html,hi"), ("HTTPS upper-case", "HTTPS://github.com/x"),
                    ("spaces", "https://github.com/a b"), ("tel:", "tel:123"), ("smb:", "smb://host/share"), ("ssh:", "ssh://host")] {
    worker.run("release list: page link \(name)") {
        let u = Checker.newest(in: json([release(tag: "v2.11", page: url)]), includePrereleases: false)
        check(u == nil || u!.page.scheme?.lowercased() == "https", "page link \(name) offered: \(u!.page)")
    }
    worker.run("release list: download link \(name)") {
        let assets: [[String: Any]] = [["name": "Glideball-update.zip", "browser_download_url": url]]
        let u = Checker.newest(in: json([release(tag: "v2.11", assets: assets)]), includePrereleases: false)
        check(u?.download == nil || u!.download!.scheme?.lowercased() == "https", "download link \(name) offered: \(u!.download!)")
    }
}
worker.run("release list: asset choice") {
    func pick(_ names: [String]) -> String? {
        let assets = names.map { ["name": $0, "browser_download_url": "https://x/\($0)"] }
        return Checker.downloadURL(in: assets)
    }
    check(pick(["Glideball.zip", "Glideball-update.zip", "Glide.zip"]) == "https://x/Glideball-update.zip", "update zip not preferred")
    check(pick(["Glide.zip", "Glideball.zip"]) == "https://x/Glideball.zip", "Glideball.zip not preferred to Glide.zip")
    check(pick(["notes.txt", "evil.zip"]) == nil, "an unrelated asset was taken")
    check(pick([]) == nil, "an empty list offered a download")
    check(pick(["glideball-update.zip"]) == nil, "asset names are matched case-sensitively")
    check(Checker.downloadURL(in: [["name": 5, "browser_download_url": 5], ["name": "Glideball.zip"], ["browser_download_url": "https://x"]]) == nil, "odd assets offered a download")
}
endSection("release lists")

// MARK: - 3. Unpacking and verifying

beginSection()
let bundleID = "com.test.glideball-fuzz"
let version = "2.11"
func requirement(_ text: String) -> SecRequirement {
    var r: SecRequirement?
    precondition(SecRequirementCreateWithString(text as CFString, [], &r) == errSecSuccess && r != nil, "bad requirement \(text)")
    return r!
}
let pinned = requirement("identifier \"\(bundleID)\"")
let fixtures = root.appendingPathComponent("fixtures", isDirectory: true)
try! fm.createDirectory(at: fixtures, withIntermediateDirectories: true)

@discardableResult
func sh(_ exe: String, _ arguments: [String], env: [String: String]? = nil) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = arguments
    if let env { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try! p.run()
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: out, as: UTF8.self))
}

var fixtureCount = 0
nonisolated(unsafe) var appMasters: [String: URL] = [:]
/// A small app: Info.plist and a copy of a system tool as its executable, optionally ad-hoc signed.
func makeApp(named name: String = "Glideball.app", id: String = bundleID, version v: String = version, signedAs signID: String? = bundleID,
             in dir: URL? = nil) -> URL {
    fixtureCount += 1
    let parent = dir ?? fixtures.appendingPathComponent("app\(fixtureCount)", isDirectory: true)
    let app = parent.appendingPathComponent(name)
    // Signing is the slow part: each kind of app is signed once, in a folder of its own, and copied (a copy keeps the signature).
    let key = "\(name)|\(id)|\(v)|\(signID ?? "-")"
    if appMasters[key] == nil {
        let master = fixtures.appendingPathComponent("master\(appMasters.count)", isDirectory: true).appendingPathComponent(name)
        buildApp(at: master, id: id, version: v, signedAs: signID)
        appMasters[key] = master
    }
    try! fm.createDirectory(at: parent, withIntermediateDirectories: true)
    let (code, out) = sh("/usr/bin/ditto", [appMasters[key]!.path, app.path])
    precondition(code == 0, "ditto copy failed: \(out)")
    return app
}
func buildApp(at app: URL, id: String, version v: String, signedAs signID: String?) {
    let macOS = app.appendingPathComponent("Contents/MacOS"), res = app.appendingPathComponent("Contents/Resources")
    try! fm.createDirectory(at: macOS, withIntermediateDirectories: true)
    try! fm.createDirectory(at: res, withIntermediateDirectories: true)
    try! fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Glide"))
    try! Data("hello".utf8).write(to: res.appendingPathComponent("data.txt"))
    let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": v, "CFBundleExecutable": "Glide", "CFBundlePackageType": "APPL", "CFBundleName": "Glideball"]
    try! (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
    if let signID {
        let (code, out) = sh("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", signID, app.path])
        precondition(code == 0, "codesign failed: \(out)")
    }
}
func zip(_ app: URL, keepParent: Bool = true) -> URL {
    fixtureCount += 1
    let out = fixtures.appendingPathComponent("z\(fixtureCount).zip")
    let (code, text) = sh("/usr/bin/ditto", ["-c", "-k"] + (keepParent ? ["--keepParent"] : []) + [app.path, out.path])
    precondition(code == 0, "ditto failed: \(text)")
    return out
}

/// prepare()'s unpack folders.
func tmpListing() -> [String] { ((try? fm.contentsOfDirectory(atPath: tmp.path)) ?? []).sorted() }
/// Files the hostile zips try to plant beside the unpack folder, above it, in /tmp or in /: none may appear.
func rootListing() -> [String] {
    var out = ((try? fm.contentsOfDirectory(atPath: tmpParent.path)) ?? []).filter { $0 != "unpack" }.map { "tmp/" + $0 }
    out += ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { !["tmp", "decoy", "fixtures", "fakebin", "open.log"].contains($0) && !$0.hasPrefix("swap-") }
    for dir in ["/private/tmp", "/"] {
        out += ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("escape-") || $0 == "pwn.txt" || $0 == "pwn3.txt" }.map { dir + "/" + $0 }
    }
    return out.sorted()
}
func sweepStrays() {
    for f in rootListing() { try? fm.removeItem(atPath: f.hasPrefix("/") ? f : (f.hasPrefix("tmp/") ? tmpParent.path + "/" + f.dropFirst(4) : root.path + "/" + f)) }
}
func decoyEmpty() -> Bool { ((try? fm.contentsOfDirectory(atPath: decoy.path)) ?? []).isEmpty }

enum Expect { case accept, refuse, either }

/// prepare() on a zip: accepted or refused as expected, no throw other than UpdateError, nothing left behind
/// when refused, nothing written outside the unpack folder either way.
@discardableResult
func prepareCase(_ name: String, _ zipFile: URL, expect: Expect, expectedVersion: String = version, id: String = bundleID,
                 requirement req: SecRequirement? = nil, limits: Checker.ZipLimits = .standard, budget: Double = 60) -> Bool {
    var accepted = false
    let before = tmpListing(), rootBefore = rootListing()
    worker.run("prepare: \(name)", budget: budget) {
        do {
            let app = try Checker.prepare(zip: zipFile, expectedVersion: expectedVersion, bundleID: id, requirement: req ?? pinned, workRoot: tmp, limits: limits)
            accepted = true
            check(expect != .refuse, "\(name): accepted, should have been refused")
            check(app.pathExtension == "app" && fm.fileExists(atPath: app.path), "\(name): returned \(app.path), which isn't an app")
            check(app.resolvingSymlinksInPath().path.hasPrefix(tmp.path), "\(name): unpacked outside the temp folder: \(app.path)")
            var type = (try? fm.attributesOfItem(atPath: app.path)[.type] as? FileAttributeType) ?? nil
            check(type == .typeDirectory, "\(name): the app is a \(String(describing: type)), not a folder")
            type = nil
            Checker.removeTree(app.deletingLastPathComponent())   // the caller would move it into place
        } catch is Checker.UpdateError {
            check(expect != .accept, "\(name): refused, should have been accepted")
        } catch {
            fail("\(name): threw \(error), not an UpdateError")
        }
    }
    if expect == .either && (name.contains("observed") || name.hasPrefix("zip with")) { print("  note: \(name): \(accepted ? "accepted" : "refused")") }
    check(tmpListing() == before, "\(name): left \(Set(tmpListing()).subtracting(before).sorted()) behind in the temp folder")
    check(rootListing() == rootBefore, "\(name): wrote outside the unpack folder: \(Set(rootListing()).subtracting(rootBefore).sorted())")
    sweepStrays()
    check(decoyEmpty(), "\(name): something was written into the decoy folder: \((try? fm.contentsOfDirectory(atPath: decoy.path)) ?? [])")
    if !decoyEmpty() { for f in (try? fm.contentsOfDirectory(atPath: decoy.path)) ?? [] { try? fm.removeItem(at: decoy.appendingPathComponent(f)) } }
    return accepted
}

// A good one first: if this doesn't pass, nothing below means anything.
let goodApp = makeApp()
let goodZip = zip(goodApp)
check(prepareCase("good app", goodZip, expect: .accept), "the good fixture was refused: the checks below mean nothing")
prepareCase("the legacy Glide.app name", zip(makeApp(named: "Glide.app")), expect: .accept)
prepareCase("zipped without its parent folder (app contents at the top)", zip(goodApp, keepParent: false), expect: .refuse)

// The wrong app.
prepareCase("wrong version inside", zip(makeApp(version: "2.9")), expect: .refuse)
prepareCase("downgrade: older signed build advertised as newer", zip(makeApp(version: "2.10")), expect: .refuse)
prepareCase("newer than advertised", zip(makeApp(version: "2.12")), expect: .refuse)
prepareCase("same version, written 2.11.0", zip(makeApp(version: "2.11.0")), expect: .refuse)
prepareCase("wrong bundle identifier", zip(makeApp(id: "com.evil.app", signedAs: "com.evil.app")), expect: .refuse)
prepareCase("bundle identifier right but signed as another", zip(makeApp(signedAs: "com.evil.app")), expect: .refuse)
prepareCase("bundle identifier differs only in case", zip(makeApp(id: bundleID.uppercased(), signedAs: bundleID.uppercased())), expect: .refuse)
prepareCase("not signed at all", zip(makeApp(signedAs: nil)), expect: .refuse)
prepareCase("expected version empty", goodZip, expect: .refuse, expectedVersion: "")
prepareCase("expected version a different one", goodZip, expect: .refuse, expectedVersion: "2.11-beta.1")
prepareCase("running app has another identifier", goodZip, expect: .refuse, id: "com.other")
prepareCase("pinned to a certificate the app doesn't have", goodZip, expect: .refuse,
            requirement: requirement("identifier \"\(bundleID)\" and certificate leaf = H\"a729ea121c1117802453b860d127d1b07804ac32\""))
prepareCase("pinned to Apple's anchor", goodZip, expect: .refuse, requirement: requirement("anchor apple"))
worker.run("verifySignature against this fuzzer's own requirement") {
    check((try? Checker.verifySignature(of: goodApp)) == nil, "an unrelated app passed the running app's own requirement")
}
worker.run("verifySignature: not an app") {
    check((try? Checker.verifySignature(of: fixtures.appendingPathComponent("nothing.app"), against: pinned)) == nil, "a missing app verified")
    check((try? Checker.verifySignature(of: fixtures, against: pinned)) == nil, "a plain folder verified")
}

// Tampered after signing.
func tampered(_ name: String, expect: Expect = .refuse, _ change: (URL) -> Void) {
    let app = makeApp()
    change(app)
    prepareCase("tampered: \(name)", zip(app), expect: expect)
}
tampered("executable changed") { try! Data("#!/bin/sh\necho pwned\n".utf8).write(to: $0.appendingPathComponent("Contents/MacOS/Glide")) }
tampered("executable replaced by a link to /bin/echo") { let p = $0.appendingPathComponent("Contents/MacOS/Glide"); try! fm.removeItem(at: p); try! fm.createSymbolicLink(atPath: p.path, withDestinationPath: "/bin/echo") }
tampered("a resource changed") { try! Data("tampered".utf8).write(to: $0.appendingPathComponent("Contents/Resources/data.txt")) }
tampered("a resource deleted") { try! fm.removeItem(at: $0.appendingPathComponent("Contents/Resources/data.txt")) }
tampered("a resource replaced by a link") { let p = $0.appendingPathComponent("Contents/Resources/data.txt"); try! fm.removeItem(at: p); try! fm.createSymbolicLink(atPath: p.path, withDestinationPath: "/etc/hosts") }
tampered("Info.plist version changed (signature stale)") {
    let p = $0.appendingPathComponent("Contents/Info.plist")
    var d = NSDictionary(contentsOf: p) as! [String: Any]; d["CFBundleShortVersionString"] = "2.11"; d["CFBundleName"] = "Changed"
    try! (d as NSDictionary).write(to: p)
}
tampered("code signature removed") { try! fm.removeItem(at: $0.appendingPathComponent("Contents/_CodeSignature")) }
tampered("code signature emptied") { try! Data().write(to: $0.appendingPathComponent("Contents/_CodeSignature/CodeResources")) }
tampered("code signature from another app (same files, so it still verifies)", expect: .either) {
    let other = makeApp(signedAs: "com.evil.app")
    try! fm.removeItem(at: $0.appendingPathComponent("Contents/_CodeSignature"))
    try! fm.copyItem(at: other.appendingPathComponent("Contents/_CodeSignature"), to: $0.appendingPathComponent("Contents/_CodeSignature"))
}
tampered("an unsealed file added (observed only)", expect: .either) { try! Data("extra".utf8).write(to: $0.appendingPathComponent("Contents/Resources/extra.txt")) }
tampered("a helper added in MacOS (observed only)", expect: .either) { try! fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/false"), to: $0.appendingPathComponent("Contents/MacOS/helper")) }

// The strict signature flags (all architectures, nested code, strict validation). Each fixture below is
// refused by them; the note says whether the old flags (all architectures only) would have let it in.
func staticVerdict(_ app: URL, _ flags: SecCSFlags) -> Bool {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
    return SecStaticCodeCheckValidity(code, flags, pinned) == errSecSuccess
}
let oldFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
func strictCase(_ name: String, _ app: URL) {
    var old = false, new = true
    worker.run("strict flags: \(name)") {
        old = staticVerdict(app, oldFlags)
        new = staticVerdict(app, Checker.signatureCheckFlags)
    }
    check(!new, "\(name): passed the strict flags")
    print("  note: strict flags: \(name): refused; the old flags \(old ? "accepted" : "refused") it")
    prepareCase("strict flags: \(name)", zip(app), expect: .refuse)
}
check({ var ok = false; worker.run("strict flags: good app") { ok = staticVerdict(goodApp, Checker.signatureCheckFlags) }; return ok }(), "the good fixture fails the strict flags")
do {
    let a = makeApp(); try! Data("x".utf8).write(to: a.appendingPathComponent("extra.txt"))
    strictCase("a file in the bundle root, outside the seal", a)
    let b = makeApp(); try! fm.createSymbolicLink(atPath: b.appendingPathComponent("Contents/Resources/lnk").path, withDestinationPath: "/etc/hosts")
    strictCase("a link added to Resources after signing", b)
    let c = makeApp(); try! fm.createSymbolicLink(atPath: c.appendingPathComponent("Contents/MacOS/Glide2").path, withDestinationPath: "/usr/bin/false")
    strictCase("a link added beside the executable", c)
    // Nested code: a helper app signed on its own, sealed into the outer app, then changed.
    func nestedApp(tamper: Bool, helperSigned: Bool) -> URL {
        let app = makeApp(signedAs: nil)
        let helper = app.appendingPathComponent("Contents/Library/H.app")
        buildApp(at: helper, id: "com.test.helper", version: "1", signedAs: helperSigned ? "com.test.helper" : nil)
        let (code, out) = sh("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", bundleID, app.path])
        precondition(code == 0 || !helperSigned, "codesign (nested) failed: \(out)")
        if tamper { try! Data("#!/bin/sh\necho pwned\n".utf8).write(to: helper.appendingPathComponent("Contents/MacOS/Glide")) }
        return app
    }
    strictCase("a nested helper app changed after signing", nestedApp(tamper: true, helperSigned: true))
    let ok = nestedApp(tamper: false, helperSigned: true)
    check({ var v = false; worker.run("strict flags: untampered nested helper") { v = staticVerdict(ok, Checker.signatureCheckFlags) }; return v }(), "an untampered, signed nested helper failed the strict flags")
    prepareCase("an app with a signed nested helper (a normal one)", zip(ok), expect: .accept)
}
// A release built the way release.sh builds one: ~105 files, a universal binary, xattr -cr, signed, ditto --sequesterRsrc.
do {
    let dir = fixtures.appendingPathComponent("release-shaped", isDirectory: true)
    let app = dir.appendingPathComponent("Glideball.app")
    buildApp(at: app, id: bundleID, version: version, signedAs: nil)
    let res = app.appendingPathComponent("Contents/Resources")
    for lang in ["en", "de", "fr", "es", "ja", "zh-Hans", "pt-BR", "it", "ko", "nl", "ru", "tr", "pl", "sv"] {
        let l = res.appendingPathComponent("\(lang).lproj", isDirectory: true)
        try! fm.createDirectory(at: l, withIntermediateDirectories: true)
        for n in ["Localizable", "InfoPlist", "Main"] { try! Data(String(repeating: "\"key\" = \"value \(lang)\";\n", count: 400).utf8).write(to: l.appendingPathComponent("\(n).strings")) }
    }
    for n in 0..<40 { try! Data(count: 1).write(to: res.appendingPathComponent("tick\(n).caf")); try! Data((0..<40_000).map { _ in UInt8.random(in: 0...255, using: &rng) }).write(to: res.appendingPathComponent("icon\(n).png")) }
    var icns = Data(count: 12_000_000)   // incompressible, like real PNG data inside an icns
    _ = icns.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
    try! icns.write(to: res.appendingPathComponent("AppIcon.icns"))
    sh("/usr/bin/xattr", ["-cr", app.path])
    let (code, out) = sh("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", bundleID, app.path])
    precondition(code == 0, "codesign failed: \(out)")
    let z = dir.appendingPathComponent("Glideball-update.zip")
    let (zc, zo) = sh("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, z.path])
    precondition(zc == 0, "ditto failed: \(zo)")
    let files = (fm.enumerator(atPath: app.path)?.allObjects.count) ?? 0
    check(files >= 100, "the release-shaped fixture has only \(files) files")
    check(reasonable(z), "a release-shaped zip's index reads as unreasonable")
    prepareCase("release-shaped zip (\(files) files, sequestered, strict flags)", z, expect: .accept)
}
// The genuine installed app, read only (nothing is launched or changed): it must pass the same flags.
if fm.fileExists(atPath: "/Applications/Glideball.app") {
    worker.run("strict flags: the genuine installed Glideball.app") {
        do { try Checker.verifySignature(of: URL(fileURLWithPath: "/Applications/Glideball.app"), against: requirement("identifier \"com.leviholliday.glide\"")) }
        catch { fail("the installed Glideball.app fails the strict flags: \(error.localizedDescription)") }
    }
    // And zipped the way release.sh zips it (a copy: the installed app is only read), a whole update through prepare().
    let installed = URL(fileURLWithPath: "/Applications/Glideball.app")
    let installedVersion = Bundle(url: installed)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    let genuineZip = fixtures.appendingPathComponent("genuine.zip")
    let (gc, go) = sh("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", installed.path, genuineZip.path])
    if gc == 0 {
        check(reasonable(genuineZip), "the installed app's own zip reads as unreasonable")
        prepareCase("the installed Glideball.app, zipped like a release", genuineZip, expect: .accept, expectedVersion: installedVersion, id: "com.leviholliday.glide",
                    requirement: requirement("identifier \"com.leviholliday.glide\""))
        try? fm.removeItem(at: genuineZip)
    } else { fail("couldn't zip the installed app: \(go)") }
} else {
    print("  note: /Applications/Glideball.app isn't installed here; the genuine-app check was skipped")
}

// Links where the app should be.
do {
    let realFolder = fixtures.appendingPathComponent("linkdir", isDirectory: true)
    try! fm.createDirectory(at: realFolder, withIntermediateDirectories: true)
    let target = makeApp(named: "Target.app", in: realFolder)
    let linkZipDir = fixtures.appendingPathComponent("linkzip", isDirectory: true)
    try! fm.createDirectory(at: linkZipDir, withIntermediateDirectories: true)
    try! fm.createSymbolicLink(atPath: linkZipDir.appendingPathComponent("Glideball.app").path, withDestinationPath: target.path)
    prepareCase("Glideball.app is a link to a good signed app", zip(linkZipDir.appendingPathComponent("Glideball.app"), keepParent: true), expect: .refuse)
    let nested = fixtures.appendingPathComponent("nested", isDirectory: true)
    _ = makeApp(in: nested.appendingPathComponent("Sub"))
    prepareCase("the app one folder down", zip(nested), expect: .refuse)
    let file = fixtures.appendingPathComponent("fileapp", isDirectory: true)
    try! fm.createDirectory(at: file, withIntermediateDirectories: true)
    try! Data("not an app".utf8).write(to: file.appendingPathComponent("Glideball.app"))
    prepareCase("Glideball.app is a plain file", zip(file.appendingPathComponent("Glideball.app")), expect: .refuse)
    let both = fixtures.appendingPathComponent("both", isDirectory: true)
    _ = makeApp(named: "Glideball.app", version: "2.11", in: both)
    _ = makeApp(named: "Glide.app", version: "1.0", in: both)
    prepareCase("both names present: Glideball.app wins", zip(both, keepParent: false), expect: .accept)
}

// Hostile zips built around the good one.
let helper = helperDir.appendingPathComponent("mkzip.py")
func hostileZip(_ recipe: String, aim: String? = nil) -> URL {
    fixtureCount += 1
    let out = fixtures.appendingPathComponent("h\(fixtureCount).zip")
    let (code, text) = sh("/usr/bin/python3", ["-I", helper.path, recipe, goodZip.path, out.path, aim ?? decoy.path])
    precondition(code == 0, "mkzip \(recipe): \(text)")
    return out
}
// A good app plus extra entries: may be accepted, but nothing may land outside the unpack folder.
for recipe in ["traversal", "symlink-write", "symlink-loop", "duplicates", "long-names"] {
    prepareCase("zip with \(recipe)", hostileZip(recipe), expect: .either, budget: 120)
}
// Zip bombs and their cousins. What the zip's index says is read before anything is unpacked.
func reasonable(_ zipFile: URL, limits: Checker.ZipLimits = .standard) -> Bool {
    var answer = false
    worker.run("zipIsReasonable \(zipFile.lastPathComponent)") { answer = Checker.zipIsReasonable(at: zipFile, limits: limits) }
    return answer
}
func indexCase(_ name: String, _ recipe: String, reasonable expected: Bool, prepare expect: Expect) {
    let z = hostileZip(recipe)
    check(reasonable(z) == expected, "\(name): the index reads as \(expected ? "unreasonable" : "reasonable"), expected the opposite")
    prepareCase(name, z, expect: expect, budget: 120)
}
check(reasonable(goodZip), "the good zip's index reads as unreasonable")
indexCase("zip bomb by ratio (64 MB of zeros in ~64 KB)", "bomb", reasonable: false, prepare: .refuse)
indexCase("zip bomb by entry count (25,000 entries)", "many", reasonable: false, prepare: .refuse)
indexCase("an index claiming 600 MB in all", "lying-total", reasonable: false, prepare: .refuse)
indexCase("an index claiming 12 GB in all, in zip64 fields", "lying-total-zip64", reasonable: false, prepare: .refuse)
indexCase("a high ratio under 10 MB is not a bomb (8 MB of zeros)", "bomb-small", reasonable: true, prepare: .accept)
indexCase("19,000 small entries are fine (under the 20,000 cap)", "many-ok", reasonable: true, prepare: .accept)
indexCase("the good zip with zip64 end records reads fine", "zip64-plain", reasonable: true, prepare: .either)
do {   // the same limits, tightened, on the good zip: each one on its own refuses it
    var l = Checker.ZipLimits(); l.maxEntries = 3
    check(!reasonable(goodZip, limits: l), "a zip with more entries than allowed read as reasonable")
    prepareCase("prepare with the entry cap at 3", goodZip, expect: .refuse, limits: l)
    l = Checker.ZipLimits(); l.maxUncompressedBytes = 100
    check(!reasonable(goodZip, limits: l), "a zip with more bytes than allowed read as reasonable")
    l = Checker.ZipLimits(); l.ratioFloorBytes = 1; l.maxRatio = 0
    check(!reasonable(goodZip, limits: l), "a zip over the ratio read as reasonable")
    l = Checker.ZipLimits(); l.maxDirectoryBytes = 10
    check(!reasonable(goodZip, limits: l), "a zip with a too-large index read as reasonable")
}
// The index lies: it says 1 KB, the data inflates to 64 MB. The unpack folder is watched and the unpack stopped.
do {
    var l = Checker.ZipLimits(); l.maxUncompressedBytes = 8_000_000
    let z = hostileZip("lying-bomb")
    check(reasonable(z, limits: l), "the lying bomb's index should look innocent")
    // The case only proves the watch if ditto really does inflate the data past what the index claims.
    let control = fixtures.appendingPathComponent("lying-bomb-control", isDirectory: true)
    sh("/usr/bin/ditto", ["-x", "-k", z.path, control.path])
    let inflated = (try? fm.attributesOfItem(atPath: control.appendingPathComponent("big1.bin").path)[.size] as? Int64) ?? 0
    check(inflated > 8_000_000, "ditto inflated the lying bomb to only \(inflated) bytes: the folder watch isn't being tested")
    try? fm.removeItem(at: control)
    let started = Date()
    prepareCase("an index that understates a bomb (unpack watched, 8 MB limit)", z, expect: .refuse, limits: l)
    check(Date().timeIntervalSince(started) < 30, "stopping the lying bomb took \(Date().timeIntervalSince(started)) s")
}
// Unreadable indexes are refused, not crashed on.
worker.run("zipIsReasonable on junk") {
    for (name, bytes) in [("empty", Data()), ("21 bytes", Data(count: 21)), ("22 zeros", Data(count: 22)), ("EOCD only", Data([0x50, 0x4b, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))),
                          ("EOCD claiming a huge index", Data([0x50, 0x4b, 0x05, 0x06, 0, 0, 0, 0, 1, 0, 1, 0, 0xFF, 0xFF, 0xFF, 0x7F, 0, 0, 0, 0, 0, 0])),
                          ("zip64 EOCD without its record", Data([0x50, 0x4b, 0x05, 0x06, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0])),
                          ("random", Data((0..<70_000).map { _ in UInt8.random(in: 0...255, using: &rng) }))] {
        let f = fixtures.appendingPathComponent("junk-index.zip")
        try! bytes.write(to: f)
        check(!Checker.zipIsReasonable(at: f), "zipIsReasonable accepted \(name)")
    }
    check(!Checker.zipIsReasonable(at: fixtures.appendingPathComponent("not-there.zip")), "zipIsReasonable accepted a missing file")
    check(!Checker.zipIsReasonable(at: fixtures), "zipIsReasonable accepted a folder")
}
prepareCase("Glideball.app inside the zip is a link to the decoy", hostileZip("app-is-symlink", aim: goodApp.path), expect: .refuse)
// The size cap, with a sparse file (no disk used).
do {
    let big = fixtures.appendingPathComponent("big.zip")
    fm.createFile(atPath: big.path, contents: nil)
    let h = try! FileHandle(forWritingTo: big)
    try! h.truncate(atOffset: UInt64(Checker.maxZipBytes) + 1)
    try! h.close()
    let started = Date()
    prepareCase("a zip over the size cap", big, expect: .refuse)
    check(Date().timeIntervalSince(started) < 5, "a zip over the size cap took \(Date().timeIntervalSince(started)) s to refuse")
    try? fm.removeItem(at: big)
}

// Broken downloads.
let goodBytes = try! Data(contentsOf: goodZip)
func bytesZip(_ data: Data) -> URL {
    fixtureCount += 1
    let u = fixtures.appendingPathComponent("b\(fixtureCount).zip")
    try! data.write(to: u)
    return u
}
for (name, data) in [("empty file", Data()), ("one byte", Data([0x50])), ("PK header only", Data([0x50, 0x4b, 0x03, 0x04])), ("empty zip", Data([0x50, 0x4b, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))),
                     ("GitHub 404 page", Data("{\"message\":\"Not Found\"}".utf8)), ("HTML page", Data("<!doctype html><title>Login</title>".utf8)), ("a gzip file", Data([0x1f, 0x8b, 0x08] + [UInt8](repeating: 0, count: 40))),
                     ("zeros", Data(count: 100_000)), ("the zip twice", goodBytes + goodBytes), ("junk then the zip", Data(count: 1000) + goodBytes), ("the zip then junk", goodBytes + Data(count: 1000)),
                     ("the zip with another zip's tail", goodBytes.prefix(goodBytes.count / 2) + goodBytes.suffix(goodBytes.count / 2))] {
    prepareCase("download: \(name)", bytesZip(data), expect: name == "the zip then junk" || name == "junk then the zip" || name == "the zip twice" || name.contains("tail") ? .either : .refuse)
}
let cuts: [Int] = Array(Set([1, 2, 4, 22, 30, goodBytes.count / 8, goodBytes.count / 4, goodBytes.count / 2, goodBytes.count * 3 / 4, goodBytes.count - 100, goodBytes.count - 23, goodBytes.count - 22, goodBytes.count - 21, goodBytes.count - 1])).sorted()
for cut in cuts where cut > 0 && cut < goodBytes.count {
    // Past the last file, the cut only takes the zip's index; ditto still unpacks every file, and the signature vouches for them.
    prepareCase("download truncated at \(cut) of \(goodBytes.count) bytes", bytesZip(goodBytes.prefix(cut)), expect: cut >= goodBytes.count - 150 ? .either : .refuse)
}
prepareCase("a zip that isn't there", fixtures.appendingPathComponent("no-such-file.zip"), expect: .refuse)
prepareCase("a zip that's a folder", fixtures, expect: .refuse)
// Damage in the middle: whatever comes out must pass the checks or be refused, never crash or leak.
var damaged = 0
let damageCount = deep ? 300 : 12
for _ in 0..<damageCount {
    var d = goodBytes
    for _ in 0..<Int.random(in: 1...6, using: &rng) { d[Int.random(in: 0..<d.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
    damaged += 1
    prepareCase("download with damaged bytes #\(damaged) (seed \(seed))", bytesZip(d), expect: .either)
}
endSection("unpacking and verifying", "\(fixtureCount) fixtures")

// MARK: - 3b. Downloads

// A URLProtocol that plays a server: no network. It streams `total` bytes (nil: forever) in 64 KB chunks, announcing
// `declared` as the Content-Length (nil: none), and records how much it sent and whether the client hung up first.
final class StubServer: URLProtocol {
    struct Script { var status = 200; var declared: Int64?; var total: Int64?; var body: Data? }
    nonisolated(unsafe) static var script = Script()
    nonisolated(unsafe) static var sent: Int64 = 0
    nonisolated(unsafe) static var hungUp = false
    nonisolated(unsafe) static var finished = false
    private let stop = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let s = Self.script
        Self.sent = 0; Self.hungUp = false; Self.finished = false
        var headers: [String: String] = [:]
        if let d = s.declared { headers["Content-Length"] = String(d) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: s.status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async { [self] in
            if let body = s.body {
                client?.urlProtocol(self, didLoad: body); Self.sent = Int64(body.count)
                client?.urlProtocolDidFinishLoading(self); Self.finished = true
                return
            }
            let chunk = Data(count: 65_536)
            while true {
                stop.lock(); let done = stopped; stop.unlock()
                if done { return }
                if let total = s.total, Self.sent >= total { break }
                let n = s.total.map { min(Int64(chunk.count), $0 - Self.sent) } ?? Int64(chunk.count)
                client?.urlProtocol(self, didLoad: chunk.prefix(Int(n))); Self.sent += n
                Thread.sleep(forTimeInterval: 0.0005)
            }
            client?.urlProtocolDidFinishLoading(self); Self.finished = true
        }
    }
    override func stopLoading() { stop.lock(); stopped = true; stop.unlock(); if !Self.finished { Self.hungUp = true } }
}
let stubSession: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [StubServer.self]
    return URLSession(configuration: c)
}()
let stubURL = URL(string: "https://example.invalid/Glideball-update.zip")!

/// Plays one download against the stub and waits for its end. Returns the outcome and how long it took.
func playDownload(_ name: String, _ script: StubServer.Script, cap: Int64, expectedVersion: String = version) -> (result: Result<URL, Error>?, progress: [Double], seconds: Double) {
    StubServer.script = script
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var result: Result<URL, Error>?
    var progress: [Double] = []
    let began = Date()
    let download = Checker.startDownload(stubURL, session: stubSession, maxBytes: cap, expectedVersion: expectedVersion, bundleID: bundleID, requirement: pinned, workRoot: tmp,
                                         progress: { p in lock.lock(); progress.append(p); lock.unlock() },
                                         completion: { r in lock.lock(); result = r; lock.unlock(); done.signal() })
    if done.wait(timeout: .now() + 30) == .timedOut { download.task.cancel(); fail("download \(name): no end after 30 s"); }
    lock.lock(); defer { lock.unlock() }
    return (result, progress, Date().timeIntervalSince(began))
}

beginSection()
let downloadMessage = "The download isn’t the expected Glideball \(version)."
let cap: Int64 = 2_000_000
func downloadMessageIs(_ r: Result<URL, Error>?, _ text: String) -> Bool {
    if case .failure(let e)? = r { return e.localizedDescription == text }
    return false
}
// With the real 300 MB cap, only the announced size can stop this one before 300 MB have gone by.
worker.run("download: announces a size over the cap (10 GB), then would stream forever", budget: 40) {
    let r = playDownload("announced", .init(declared: 10_000_000_000, total: nil), cap: Checker.maxZipBytes)
    check(downloadMessageIs(r.result, downloadMessage), "announced too big: \(String(describing: r.result))")
    check(StubServer.sent < 8_000_000, "announced too big: the server had already sent \(StubServer.sent) bytes when the download was cancelled")
    check(StubServer.hungUp, "announced too big: the connection was never closed")
}
worker.run("download: no Content-Length, endless stream, past a 2 MB cap", budget: 40) {
    let r = playDownload("endless", .init(declared: nil, total: nil), cap: cap)
    check(downloadMessageIs(r.result, downloadMessage), "endless: \(String(describing: r.result))")
    check(StubServer.sent > cap, "endless: cancelled at \(StubServer.sent) bytes, before the cap of \(cap)")
    check(StubServer.sent < cap + 4_000_000, "endless: \(StubServer.sent) bytes went by before the cancel (cap \(cap))")
    check(StubServer.hungUp, "endless: the connection was never closed")
    check(r.seconds < 20, "endless: took \(r.seconds) s")
}
worker.run("download: Content-Length says 1 KB, the stream never ends", budget: 40) {
    let r = playDownload("lying length", .init(declared: 1000, total: nil), cap: cap)
    check(downloadMessageIs(r.result, downloadMessage), "lying length: \(String(describing: r.result))")
    check(StubServer.sent < cap + 4_000_000 && StubServer.hungUp, "lying length: \(StubServer.sent) bytes sent, hung up: \(StubServer.hungUp)")
}
worker.run("download: a finite stream just over the cap", budget: 40) {
    let r = playDownload("just over", .init(declared: cap + 1000, total: cap + 1000), cap: cap)
    check(downloadMessageIs(r.result, downloadMessage), "just over: \(String(describing: r.result))")
}
worker.run("download: exactly the cap is let through (then refused as not a zip)", budget: 40) {
    let r = playDownload("exactly the cap", .init(declared: cap, total: cap), cap: cap)
    check(!StubServer.hungUp, "exactly the cap: cancelled")
    if case .success = r.result { fail("exactly the cap: junk accepted") }
}
worker.run("download: a normal update comes through, with progress", budget: 40) {
    let r = playDownload("normal", .init(declared: Int64(goodBytes.count), body: goodBytes), cap: Checker.maxZipBytes)
    switch r.result {
    case .success(let app)?:
        check(app.pathExtension == "app" && fm.fileExists(atPath: app.path), "normal: returned \(app.path)")
        Checker.removeTree(app.deletingLastPathComponent())
    default: fail("normal: \(String(describing: r.result))")
    }
    check(!r.progress.isEmpty, "normal: no progress reported")
    check(r.progress.allSatisfy { $0 >= 0 && $0 <= 1 }, "normal: progress outside 0...1: \(r.progress)")
}
worker.run("download: a normal update with no Content-Length", budget: 40) {
    let r = playDownload("normal, no length", .init(declared: nil, body: goodBytes), cap: Checker.maxZipBytes)
    if case .success(let app)? = r.result { Checker.removeTree(app.deletingLastPathComponent()) } else { fail("normal, no length: \(String(describing: r.result))") }
}
worker.run("download: HTTP 404 keeps its own wording", budget: 40) {
    let r = playDownload("404", .init(status: 404, declared: 5, body: Data("nope\n".utf8)), cap: Checker.maxZipBytes)
    check(downloadMessageIs(r.result, "The download didn’t finish."), "404: \(String(describing: r.result))")
}
worker.run("download: a wrong zip is still refused after a full download", budget: 40) {
    let r = playDownload("wrong version", .init(declared: Int64(goodBytes.count), body: goodBytes), cap: Checker.maxZipBytes, expectedVersion: "9.9")
    check(downloadMessageIs(r.result, "The download isn’t the expected Glideball 9.9."), "wrong version: \(String(describing: r.result))")
}
check(tmpListing().isEmpty, "downloads left unpack folders behind: \(tmpListing())")
endSection("downloads", "cap enforced while streaming, through a stub server")

// MARK: - 4. The install helper

beginSection()
let fakeBin = root.appendingPathComponent("fakebin", isDirectory: true)
try! fm.createDirectory(at: fakeBin, withIntermediateDirectories: true)
let openLog = root.appendingPathComponent("open.log")
for tool in ["open", "xattr"] {
    let path = fakeBin.appendingPathComponent(tool)
    try! Data("#!/bin/sh\n[ \(tool) = open ] && printf '%s\\n' \"$@\" >> '\(openLog.path)'\nexit 0\n".utf8).write(to: path)
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
}
/// Runs the helper's script the way relaunch() does, in a sandbox folder, with a fake `open`.
func swap(_ name: String, folderName: String, currentName: String = "Glideball.app", oldName: String? = nil, makeNew: Bool = true, makeCurrent: Bool = true,
          expectNew: Bool = true) {
    worker.run("install script: \(name)") {
        let box = root.appendingPathComponent("swap-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let dir = box.appendingPathComponent(folderName, isDirectory: true)
        let pwned = box.appendingPathComponent("pwned")
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let current = dir.appendingPathComponent(currentName)
        let old = oldName.map { dir.appendingPathComponent($0) } ?? current
        let new = dir.appendingPathComponent("new-" + currentName)
        if makeCurrent { try! fm.createDirectory(at: current, withIntermediateDirectories: true); try! Data("old".utf8).write(to: current.appendingPathComponent("v")) }
        if oldName != nil && makeCurrent == false { try! fm.createDirectory(at: old, withIntermediateDirectories: true); try! Data("old".utf8).write(to: old.appendingPathComponent("v")) }
        if makeNew { try! fm.createDirectory(at: new, withIntermediateDirectories: true); try! Data("new".utf8).write(to: new.appendingPathComponent("v")) }
        try? fm.removeItem(at: openLog)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", Checker.swapScript, "glideball-update", current.path, old.path, new.path, "4000000"]   // a process ID that can't exist: "Glideball has quit"
        p.environment = ["PATH": fakeBin.path + ":/usr/bin:/bin", "HOME": box.path]
        p.currentDirectoryURL = box
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try! p.run()
        p.waitUntilExit()
        check(!fm.fileExists(atPath: pwned.path), "\(name): the folder name ran a command")
        let installed = try? String(contentsOf: current.appendingPathComponent("v"), encoding: .utf8)
        check(installed == (expectNew ? "new" : "old"), "\(name): the app in place says \(installed ?? "nothing"), expected \(expectNew ? "new" : "old")")
        check(!fm.fileExists(atPath: current.path + ".old"), "\(name): a .old copy was left")
        if oldName != nil && expectNew { check(!fm.fileExists(atPath: old.path), "\(name): the old-named app was left") }
        let opened = (try? String(contentsOf: openLog, encoding: .utf8)) ?? ""
        check(opened == current.path + "\n", "\(name): opened \(opened.debugDescription), expected \(current.path)")
        try? fm.removeItem(at: box)
    }
}
let awkward = ["plain", "with space", "it's", "double\"quote", "dollar $HOME", "sub $(touch ../pwned)", "back `touch ../pwned`", "semi; touch ../pwned", "amp & touch ../pwned",
               "star *", "tilde ~", "-dash", "new\nline", "emoji 🙂", "back\\slash", "pipe | cat", "ünïcode", String(repeating: "long", count: 40), "a  b", "!bang", "{brace}", "#hash"]
for folder in awkward { swap("folder \(folder.debugDescription)", folderName: folder) }
swap("renaming Glide.app to Glideball.app", folderName: "rename", currentName: "Glideball.app", oldName: "Glide.app", makeCurrent: false)
swap("no new app: the old one is put back and opened", folderName: "failed swap", makeNew: false, expectNew: false)
swap("nothing installed yet", folderName: "fresh", makeCurrent: false)
endSection("install helper", "\(awkward.count) awkward folder names")

// MARK: - 5. Random mutations of a release list

beginSection()
let seedList: [[String: Any]] = [release(tag: "v2.11"), release(tag: "v2.10-beta.14", prerelease: true), release(tag: "v2.9", assets: [["name": "Glideball.zip", "browser_download_url": "https://github.com/x/y/z.zip"]])]
let junkValues: [Any] = [NSNull(), 0, -1, 1e308, "", "v", "x" , "http://x", "file:///", "javascript:1", true, false, [] as [Any], [String: Any](), [[1]] as [Any], String(repeating: "9", count: 5000), "v2.99", "v0.0", "2.11", "💥"]
func mutateList() -> Data {
    var list = seedList
    for _ in 0..<Int.random(in: 1...4, using: &rng) {
        let i = Int.random(in: 0..<list.count, using: &rng)
        let key = ["tag_name", "html_url", "draft", "prerelease", "assets", "body", "name", "zz"].randomElement(using: &rng)!
        switch Int.random(in: 0..<4, using: &rng) {
        case 0: list[i][key] = junkValues.randomElement(using: &rng)!
        case 1: list[i][key] = nil
        case 2: list.append(list[i])
        default: list[i]["assets"] = [["name": ["Glideball-update.zip", "Glideball.zip", "Glide.zip", 5].randomElement(using: &rng)!, "browser_download_url": junkValues.randomElement(using: &rng)!]]
        }
    }
    var data = json(list)
    if Int.random(in: 0..<4, using: &rng) == 0, !data.isEmpty {
        for _ in 0..<Int.random(in: 1...6, using: &rng) {
            let i = Int.random(in: 0..<data.count, using: &rng)
            switch Int.random(in: 0..<3, using: &rng) {
            case 0: data[i] = UInt8.random(in: 0...255, using: &rng)
            case 1: data = data.prefix(i)
            default: data.insert(UInt8.random(in: 0...255, using: &rng), at: i)
            }
            if data.isEmpty { break }
        }
    }
    return data
}
let randomEnd = Date().addingTimeInterval(min(deep ? 120 : 2, max(2, totalBudget - Date().timeIntervalSince(runStart) - 30)))
var mutations = 0, offered = 0
while Date() < randomEnd {
    mutations += 1
    let data = mutateList()
    let early = Bool.random(using: &rng)
    let n = mutations
    worker.run("list mutation \(n) (seed \(seed))", budget: 10) {
        guard let u = Checker.newest(in: data, includePrereleases: early) else { return }
        offered += 1
        check(u.page.scheme?.lowercased() == "https" && (u.download == nil || u.download!.scheme?.lowercased() == "https"), "list mutation \(n) (seed \(seed)): a link that isn't https: \(u.page) \(String(describing: u.download))")
        check(GlideVersion(u.version) != nil, "list mutation \(n) (seed \(seed)): unreadable version offered")
        check(early || !u.isPrerelease, "list mutation \(n) (seed \(seed)): prerelease without Early updates")
    }
}
endSection("random release lists", "seed \(seed), \(mutations) lists, \(offered) offered an update")

check(tmpListing().isEmpty, "unpack folders left at the end: \(tmpListing())")
print(failures == 0 ? "ALL GOOD" : "\(failures) FAILURES (seed \(seed))")
try? fm.removeItem(at: root)
exit(failures == 0 ? 0 : 1)
