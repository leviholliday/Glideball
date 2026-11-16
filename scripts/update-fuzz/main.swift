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
                 requirement req: SecRequirement? = nil, budget: Double = 60) -> Bool {
    var accepted = false
    let before = tmpListing(), rootBefore = rootListing()
    worker.run("prepare: \(name)", budget: budget) {
        do {
            let app = try Checker.prepare(zip: zipFile, expectedVersion: expectedVersion, bundleID: id, requirement: req ?? pinned, workRoot: tmp)
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
for recipe in ["traversal", "symlink-write", "symlink-loop", "duplicates", "long-names"] + (deep ? ["many", "bomb"] : []) {
    prepareCase("zip with \(recipe)", hostileZip(recipe), expect: .either, budget: 120)
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
