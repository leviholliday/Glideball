import Carbon.HIToolbox
import CoreGraphics
import Foundation

// Hostile files against everything Glideball reads back, through the real code:
// the settings importer (ImportFile.read: settings files and shared setups),
// glideball://import links, KensingtonWorks' settings, backup listing, restore and
// pruning (BackupStore), sync with "other Macs" (SettingsSync, driven on the main
// run loop like the app), daily totals, the milestone ledger, the low-battery
// state and crash-report scrubbing. Every path is inside one fresh temp folder;
// UserDefaults are in memory. Checks, for every case: no crash, no hang (a time
// budget per case), nothing written outside the temp app folder, a rejected file
// changes no settings, and every config that's accepted is inside ConfigLimits.
// Ordinary settings must come through clamping unchanged.

// MARK: - Harness

setvbuf(stdout, nil, _IOLBF, 0)   // every line out before a crash report
let args = CommandLine.arguments
let deep = args.contains("--deep")
let seed: UInt64 = args.firstIndex(of: "--seed").flatMap { args.indices.contains($0 + 1) ? UInt64(args[$0 + 1]) : nil }
    ?? UInt64.random(in: 1...UInt64(UInt32.max))

let fm = FileManager.default
let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("glide-file-fuzz-\(UUID().uuidString)", isDirectory: true)
let appFolder = root.appendingPathComponent("app", isDirectory: true)       // everything Glideball may write
let outside = root.appendingPathComponent("outside", isDirectory: true)     // decoys links point at; must never change
try! fm.createDirectory(at: appFolder, withIntermediateDirectories: true)
try! fm.createDirectory(at: outside, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

var failures = 0
var sectionFailures = 0
var sectionCases = 0
func fail(_ msg: String) {
    failures += 1
    sectionFailures += 1
    if sectionFailures <= 12 { print("  FAIL:", msg) }
}
func check(_ ok: Bool, _ msg: @autoclosure () -> String) { if !ok { fail(msg()) } }

// The case running now, for the crash report (a signal handler can only write raw bytes).
let caseBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 512)
caseBuffer.initialize(repeating: 0, count: 512)
/// FUZZ_TRACE=1 names every case as it starts: a crash on one of macOS's own
/// threads (the sync queue) can't be caught here, so that's how to find it.
let trace = ProcessInfo.processInfo.environment["FUZZ_TRACE"] != nil
func setCase(_ name: String) {
    if trace { FileHandle.standardError.write(Data("case: \(name.prefix(200))\n".utf8)) }
    let bytes = Array(name.utf8.prefix(500))
    for (i, b) in bytes.enumerated() { caseBuffer[i] = CChar(bitPattern: b) }
    caseBuffer[bytes.count] = 0
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

/// One long-lived worker with a GCD-sized stack (512 KB, like the sync queue's
/// threads), so deep recursion fails here the way it would in the app.
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

    /// Runs `body` on the worker; a case over `budget` seconds is a hang: report and stop.
    func run(_ name: String, budget: Double = 2, _ body: @escaping () -> Void) {
        sectionCases += 1
        setCase(name)
        let start = Date()
        lock.lock(); job = body; lock.signal(); lock.unlock()
        if done.wait(timeout: .now() + budget) == .timedOut {
            print("  FAIL: \(name): no answer after \(budget) s (hang)")
            print("\(failures + 1) FAILURES (seed \(seed))")
            try? fm.removeItem(at: root)
            exit(1)
        }
        let took = Date().timeIntervalSince(start)
        if took > budget { fail("\(name): took \(String(format: "%.2f", took)) s") }
    }
}
let worker = Worker()

/// In-memory UserDefaults: nothing touches ~/Library/Preferences.
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private let lock = NSLock()
    init() { super.init(suiteName: "glide-file-fuzz.memory")! }
    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override func removeObject(forKey key: String) { lock.withLock { values[key] = nil } }
    override func dictionaryRepresentation() -> [String: Any] { lock.withLock { values } }
    override func synchronize() -> Bool { true }
}

// Snapshot of everything under the temp root except the app folder: what's there,
// its size and modification time. Any change means something wrote outside.
func snapshot() -> [String: String] {
    var out: [String: String] = [:]
    let e = fm.enumerator(atPath: root.path)   // doesn't follow links
    while let rel = e?.nextObject() as? String {
        if rel == "app" { e?.skipDescendants(); continue }
        var st = stat()
        lstat(root.appendingPathComponent(rel).path, &st)
        out[rel] = "\(st.st_mode) \(st.st_size) \(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
    }
    return out
}

var sectionStart = Date()
var baseline: [String: String] = [:]
func beginSection() {
    sectionFailures = 0
    sectionCases = 0
    sectionStart = Date()
}
func endSection(_ title: String, _ detail: String = "") {
    let now = snapshot()
    if now != baseline {
        let changed = Set(now.keys).symmetricDifference(baseline.keys).union(now.keys.filter { baseline[$0] != nil && baseline[$0] != now[$0] })
        fail("wrote outside the app folder: \(changed.sorted().prefix(5))")
        baseline = now
    }
    let t = String(format: "%.1f", Date().timeIntervalSince(sectionStart))
    print("\(title): \(sectionCases) cases\(detail.isEmpty ? "" : ", " + detail), \(sectionFailures == 0 ? "ok" : "\(sectionFailures) FAILED") (\(t) s)")
}

// MARK: - Limits

func inRange(_ v: Double, _ r: ClosedRange<Double>) -> Bool { !v.isNaN && r.contains(v) }
func nameOK(_ s: String) -> Bool { s.utf8.count <= ConfigLimits.maxNameLength }

/// Why `a` is outside the limits, or nil.
func actionProblem(_ a: ButtonAction, insideGesture: Bool = false) -> String? {
    switch a {
    case .shortcut(let s), .holdShortcut(let s):
        if s.modifiers & ~ConfigLimits.modifierMask != 0 { return "shortcut modifiers \(s.modifiers)" }
        if !nameOK(s.keyName) { return "shortcut key name \(s.keyName.utf8.count) bytes" }
    case .modifiedClick(let b, let m):
        if !ConfigLimits.buttonNumber.contains(b) { return "modified click button \(b)" }
        if m & ~ConfigLimits.modifierMask != 0 { return "modified click modifiers \(m)" }
    case .openApp(let id):
        if id.isEmpty || !nameOK(id) { return "open app id of \(id.utf8.count) bytes" }
    case .gesture(let g):
        if insideGesture { return "gesture inside a gesture" }
        for d in GestureDirection.allCases {
            if let s = g[d], let p = actionProblem(s.action, insideGesture: true) { return "gesture \(d): \(p)" }
        }
        if let p = actionProblem(g.tap, insideGesture: true) { return "gesture tap: \(p)" }
    default: break
    }
    return nil
}

func buttonsProblem(_ map: [Int: ButtonAction]) -> String? {
    for (b, a) in map {
        if !ConfigLimits.buttonNumber.contains(b) { return "button number \(b)" }
        if let p = actionProblem(a) { return "button \(b): \(p)" }
    }
    return nil
}

func chordsProblem(_ chords: [Chord]) -> String? {
    if chords.count > ConfigLimits.maxChords { return "\(chords.count) combos" }
    for c in chords {
        if c.buttons.count < 2 { return "combo of \(c.buttons.count) buttons" }
        if c.buttons != Array(Set(c.buttons)).sorted() { return "combo buttons not sorted/unique: \(c.buttons.prefix(8))" }
        if let b = c.buttons.first(where: { !ConfigLimits.buttonNumber.contains($0) }) { return "combo button \(b)" }
        if let p = actionProblem(c.action) { return "combo: \(p)" }
    }
    return nil
}

func scrollProblem(_ s: ScrollSettings) -> String? {
    let checks: [(String, Double, ClosedRange<Double>)] = [
        ("nativeScrollSpeed", s.nativeScrollSpeed, ConfigLimits.nativeScrollSpeed),
        ("flyDistance", s.flyDistance, ConfigLimits.flyDistance),
        ("flyAcceleration", s.flyAcceleration, ConfigLimits.flyAcceleration),
        ("flyGlide", s.flyGlide, ConfigLimits.unit),
        ("flyReach", s.flyReach, ConfigLimits.unit),
        ("scrollDistance", s.scrollDistance, ConfigLimits.scrollDistance),
        ("scrollSmoothness", s.scrollSmoothness, ConfigLimits.unit),
        ("scrollAcceleration", s.scrollAcceleration, ConfigLimits.unit),
        ("throwAmount", s.throwAmount, ConfigLimits.unit),
    ]
    for (name, v, r) in checks where !inRange(v, r) { return "\(name) = \(v)" }
    return nil
}

/// Every value of an accepted config inside `ConfigLimits`.
func limitsProblem(_ c: GlideConfig) -> String? {
    if !inRange(c.trackingSpeed, ConfigLimits.trackingSpeed) { return "trackingSpeed = \(c.trackingSpeed)" }
    if !inRange(c.precisionSpeed, ConfigLimits.precisionSpeed) { return "precisionSpeed = \(c.precisionSpeed)" }
    if !inRange(c.ballScrollSpeed, ConfigLimits.ballScrollSpeed) { return "ballScrollSpeed = \(c.ballScrollSpeed)" }
    if let p = scrollProblem(c.scrollSettings) { return p }
    if let p = buttonsProblem(c.buttons) { return p }
    if let p = chordsProblem(c.chords) { return p }
    for a in GlobalShortcuts.Action.allCases {
        guard let s = c.globalShortcuts[a] else { continue }
        if s.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty { return "global shortcut \(a) without ⌘⌃⌥" }
        if s.modifiers & ~ConfigLimits.modifierMask != 0 { return "global shortcut \(a) modifiers \(s.modifiers)" }
        if !nameOK(s.keyName) { return "global shortcut \(a) key name \(s.keyName.utf8.count) bytes" }
    }
    let ds = c.displaySpeeds
    if ds.speeds.count > ConfigLimits.maxDisplays { return "\(ds.speeds.count) display speeds" }
    if ds.names.count > ConfigLimits.maxDisplays { return "\(ds.names.count) display names" }
    for (k, v) in ds.speeds {
        if k.isEmpty || !nameOK(k) { return "display key of \(k.utf8.count) bytes" }
        if !inRange(v, ConfigLimits.trackingSpeed) { return "display speed \(v)" }
    }
    for (k, v) in ds.names where k.isEmpty || !nameOK(k) || !nameOK(v) { return "display name of \(v.utf8.count) bytes" }
    if c.appProfiles.count > ConfigLimits.maxAppProfiles { return "\(c.appProfiles.count) app setups" }
    if Set(c.appProfiles.map(\.bundleID)).count != c.appProfiles.count { return "duplicate app setups" }
    for p in c.appProfiles {
        if p.bundleID.isEmpty || !nameOK(p.bundleID) { return "app setup id of \(p.bundleID.utf8.count) bytes" }
        if !nameOK(p.name) { return "app setup name of \(p.name.utf8.count) bytes" }
        if let s = p.trackingSpeed, !inRange(s, ConfigLimits.trackingSpeed) { return "app setup speed \(s)" }
        if let s = p.scroll, let q = scrollProblem(s) { return "app setup \(q)" }
        if let b = p.buttons, let q = buttonsProblem(b) { return "app setup \(q)" }
        if let ch = p.chords, let q = chordsProblem(ch) { return "app setup \(q)" }
    }
    return nil
}

/// An accepted config: in limits, already clamped, and it survives being saved and read back.
func assertInLimits(_ c: GlideConfig, _ name: String) {
    if let p = limitsProblem(c) { fail("\(name): accepted config out of limits: \(p)") }
    if c.clamped() != c { fail("\(name): clamping an accepted config changes it again") }
    guard let back = try? BackupStore.decode(BackupStore.encode(c)).validatedConfig() else {
        return fail("\(name): an accepted config can't be saved and read back")
    }
    if back != c { fail("\(name): saving and reading back an accepted config changes it") }
}

// MARK: - Normal configs

func richConfig() -> GlideConfig {
    var c = GlideConfig()
    c.trackingSpeed = 6.5
    c.precisionSpeed = 0.5
    c.scrollMode = .follow
    c.flyDistance = 7
    c.flyReach = 1
    c.nativeScrollSpeed = 1.7
    c.ballScrollSpeed = 2.25
    c.reverseScroll = true
    c.buttons = [1: .gesture(.media), 2: .modifiedClick(button: 0, modifiers: CGEventFlags.maskControl.rawValue),
                 3: .openApp(bundleID: "com.apple.Safari"), 4: .holdShortcut(.wisprFlow), 5: .media(.mute),
                 6: .gesture(ButtonGesture(up: GestureStep(.holdShortcut(.zoomIn), repeats: true), down: nil,
                                           left: GestureStep(.back, once: true), right: GestureStep(.openApp(bundleID: "com.apple.Terminal")),
                                           tap: .modifiedClick(button: 1, modifiers: CGEventFlags.maskShift.rawValue), distance: .long))]
    c.chords = [Chord(buttons: [2, 3], action: .shortcut(.missionControl)),
                Chord(buttons: [0, 2, 3], action: .holdShortcut(.wisprFlow)),
                Chord(buttons: [1, 3], action: .gesture(.tabs))]
    var safari = AppProfile(bundleID: "com.apple.Safari", name: "Safari")
    safari.trackingSpeed = 3.25
    var s = GlideConfig().scrollSettings
    s.scrollMode = .native
    s.nativeScrollSpeed = 0
    safari.scroll = s
    safari.buttons = [2: .back, 3: .gesture(.zoom)]
    safari.chords = [Chord(buttons: [1, 3], action: .shortcut(.closeTab))]
    var xcode = AppProfile(bundleID: "com.apple.dt.Xcode", name: "Xcode")
    xcode.chords = []
    c.appProfiles = [safari, xcode, AppProfile(bundleID: "com.figma.Desktop", name: "Figma")]
    c.globalShortcuts.precision = KeyShortcut.make(kVK_ANSI_P, "P", [.maskControl, .maskAlternate])
    c.globalShortcuts.dragLock = KeyShortcut.make(kVK_F5, "F5", [.maskCommand, .maskSecondaryFn])
    c.gesturesEnabled = false
    c.gestureDistance = .short
    c.gestureSteadyHands = true
    c.displaySpeeds.enabled = true
    c.displaySpeeds.speeds = ["610-41011-0": 6, "37D8832A-2D66-02CA-B9F7-8F30A301B230": 0.5, "1e6d-5b09-1234": 80]
    c.displaySpeeds.names = ["610-41011-0": "Studio Display", "37D8832A-2D66-02CA-B9F7-8F30A301B230": "Built-in Retina Display"]
    return c
}

var normalConfigs: [(String, GlideConfig)] = [("defaults", GlideConfig())]
for p in ButtonPreset.all {
    var c = GlideConfig()
    c.apply(p)
    normalConfigs.append(("preset \(p.id)", c))
}
var wispr = GlideConfig()
wispr.applySpacesAndWisprFlow()
normalConfigs.append(("Spaces + Wispr Flow", wispr))
var paused = richConfig()
paused.enabled = false
normalConfigs.append(("rich (gestures, app setups, display speeds)", richConfig()))
normalConfigs.append(("rich, paused", paused))
var edges = GlideConfig()   // every number at an end of its slider
edges.trackingSpeed = 80; edges.precisionSpeed = 0.25; edges.nativeScrollSpeed = 5; edges.flyDistance = 1
edges.flyAcceleration = 1.5; edges.flyGlide = 0; edges.flyReach = 1; edges.scrollDistance = 40
edges.scrollSmoothness = 1; edges.scrollAcceleration = 0; edges.throwAmount = 1; edges.ballScrollSpeed = 0.25
normalConfigs.append(("every slider at an end", edges))

// MARK: - JSON trees (to write files no encoder would)

indirect enum J {
    case obj([String: J]), arr([J]), str(String), num(Double), bool(Bool), null, raw(String)

    init(_ any: Any) {
        switch any {
        case let d as [String: Any]: self = .obj(d.mapValues(J.init))
        case let a as [Any]: self = .arr(a.map(J.init))
        case let s as String: self = .str(s)
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .num(n.doubleValue)
        default: self = .null
        }
    }

    init(data: Data) { self.init(try! JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) }

    var text: String {
        var out = ""
        write(to: &out)
        return out
    }

    func write(to out: inout String) {
        switch self {
        case .obj(let d):
            out += "{"
            for (i, k) in d.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                J.str(k).write(to: &out)
                out += ":"
                d[k]!.write(to: &out)
            }
            out += "}"
        case .arr(let a):
            out += "["
            for (i, x) in a.enumerated() {
                if i > 0 { out += "," }
                x.write(to: &out)
            }
            out += "]"
        case .str(let s):
            out += "\""
            for u in s.unicodeScalars {
                switch u {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
                default: out.unicodeScalars.append(u)
                }
            }
            out += "\""
        case .num(let d):
            out += d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : "\(d)"
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        case .raw(let r): out += r
        }
    }

    var data: Data { Data(text.utf8) }

    enum Step: CustomStringConvertible {
        case key(String), index(Int)
        var description: String { switch self { case .key(let k): k; case .index(let i): "[\(i)]" } }
    }

    /// Every node's path, depth first.
    func paths(_ prefix: [Step] = []) -> [[Step]] {
        var out = [prefix]
        switch self {
        case .obj(let d): for k in d.keys.sorted() { out += d[k]!.paths(prefix + [.key(k)]) }
        case .arr(let a): for (i, x) in a.enumerated() { out += x.paths(prefix + [.index(i)]) }
        default: break
        }
        return out
    }

    /// This tree with the node at `path` replaced (nil: removed).
    func replacing(_ path: ArraySlice<Step>, with new: J?) -> J? {
        guard let first = path.first else { return new }
        switch (self, first) {
        case (.obj(var d), .key(let k)):
            guard let child = d[k] else { return self }
            d[k] = child.replacing(path.dropFirst(), with: new)
            return .obj(d)
        case (.arr(var a), .index(let i)) where a.indices.contains(i):
            if let x = a[i].replacing(path.dropFirst(), with: new) { a[i] = x } else { a.remove(at: i) }
            return .arr(a)
        default: return self
        }
    }

    func at(_ path: ArraySlice<Step>) -> J? {
        guard let first = path.first else { return self }
        switch (self, first) {
        case (.obj(let d), .key(let k)): return d[k]?.at(path.dropFirst())
        case (.arr(let a), .index(let i)) where a.indices.contains(i): return a[i].at(path.dropFirst())
        default: return nil
        }
    }

    subscript(key: String) -> J? {
        get { if case .obj(let d) = self { d[key] } else { nil } }
        set { if case .obj(var d) = self { d[key] = newValue; self = .obj(d) } }
    }
}

func fileData(_ c: GlideConfig) -> Data { try! BackupStore.encode(c) }
let richOnce = richConfig()
let richFile = J(data: fileData(richConfig()))
/// A settings file around a raw config body.
func file(config: String, version: String = "1", extra: String = "") -> Data {
    Data("{\"version\":\(version),\"config\":\(config)\(extra)}".utf8)
}
func withConfig(_ change: (inout J) -> Void) -> Data {
    var f = richFile
    var c = f["config"]!
    change(&c)
    f["config"] = c
    return f.data
}

/// Swift's own JSON for an action, so hand-built files use the real shape.
func actionJSON(_ a: ButtonAction) -> String { String(decoding: try! JSONEncoder().encode(a), as: UTF8.self) }

// MARK: - Hostile inputs (shared by import, backups and sync)

let big = String(repeating: "x", count: 10_000_000)
let oddNames = ["../../x", "/etc/passwd", "a\u{0}b", "line\nbreak", String(repeating: "n", count: 300), ".", "..", "",
                "~/Library", "%2e%2e%2f", "\u{202E}gnp.exe", "名前", "a/b\\c:d"]
let weirdNumbers = ["\"4\"", "[]", "{}", "null", "true", "1e308", "-1e308", "1e400", "-1e400", "-0", "-1", "0",
                    "9223372036854775807", "9223372036854775808", "-9223372036854775809", "2.5", "1e-320",
                    "\"\\u0000../../x\"", "[[[[[[[[1]]]]]]]]", "NaN", "Infinity"]
let gestureOnlyTap = actionJSON(.gesture(ButtonGesture(tap: .leftClick)))

/// A gesture whose tap is a gesture whose tap is… `levels` deep.
func nestedGesture(_ levels: Int) -> String {
    let shape = actionJSON(.gesture(ButtonGesture(tap: .disabled)))   // {"gesture":{"_0":{"tap":{"disabled":{}}}}}
    guard let r = shape.range(of: actionJSON(.disabled)) else { return shape }
    let open = String(shape[..<r.lowerBound]), close = String(shape[r.upperBound...])
    return String(repeating: open, count: levels) + actionJSON(.leftClick) + String(repeating: close, count: levels)
}

var hostile: [(name: String, data: Data)] = []
func add(_ name: String, _ data: Data) { hostile.append((name, data)) }
func add(_ name: String, _ text: String) { hostile.append((name, Data(text.utf8))) }

let valid = richFile.data
add("empty file", Data())
add("whitespace", "   \n\t ")
add("null", "null")
add("array", "[]")
add("string", "\"version\"")
add("number", "1")
add("just {", "{")
for cut in [1, 10, valid.count / 3, valid.count / 2, valid.count - 1] { add("truncated at \(cut)", valid.prefix(cut)) }
add("BOM + valid", Data([0xEF, 0xBB, 0xBF]) + valid)
add("UTF-16 valid", valid.isEmpty ? Data() : String(decoding: valid, as: UTF8.self).data(using: .utf16)!)
add("invalid UTF-8 in a name", Data(String(decoding: withConfig {
    $0["appProfiles"] = .arr([.obj(["bundleID": .raw("\"a@@BAD@@\""), "name": .str("x")])])
}, as: UTF8.self).components(separatedBy: "@@BAD@@").map { Data($0.utf8) }.joined(separator: Data([0xC3, 0x28, 0xFF]))))
add("invalid UTF-8 everywhere", Data(valid.map { $0 == UInt8(ascii: "a") ? 0xFF : $0 }))
add("NUL bytes", Data(valid.map { $0 == UInt8(ascii: " ") ? 0 : $0 }))
add("trailing junk", valid + Data("}}}garbage".utf8))
add("two files", valid + valid)
add("version missing", Data(#"{"config":{}}"#.utf8))
add("config missing", Data(#"{"version":1}"#.utf8))
for v in ["0", "-1", "2", "3", "999", "9223372036854775807", "-9223372036854775808", "9223372036854775808", "1.5", "1.0", "\"1\"", "null", "true", "[1]", "1e400"] {
    add("version \(v)", file(config: "{}", version: v))
}
add("duplicate version keys (1 then 3)", Data(#"{"version":1,"version":3,"config":{}}"#.utf8))
add("duplicate version keys (3 then 1)", Data(#"{"version":3,"version":1,"config":{}}"#.utf8))
add("duplicate config keys", Data(#"{"version":1,"config":{"trackingSpeed":4,"trackingSpeed":1e308}}"#.utf8))
add("config is an array", file(config: "[]"))
add("config is null", file(config: "null"))
add("config is a string", file(config: "\"{}\""))
add("unknown fields everywhere", file(config: #"{"zzz":1,"buttons":[],"future":{"a":[1,2,3]}}"#, extra: #","newThing":[{}]"#))
for n in weirdNumbers {
    for key in ["trackingSpeed", "precisionSpeed", "flyDistance", "flyGlide", "scrollDistance", "ballScrollSpeed", "nativeScrollSpeed"] {
        add("\(key) = \(n)", file(config: "{\"\(key)\":\(n)}"))
    }
}
for n in ["1e308", "-1e308", "-0", "0", "1e-300", "-5", "3.5", "99999"] {
    add("every number = \(n)", file(config: "{" + ["trackingSpeed", "precisionSpeed", "nativeScrollSpeed", "flyDistance", "flyAcceleration",
        "flyGlide", "flyReach", "scrollDistance", "scrollSmoothness", "scrollAcceleration", "throwAmount", "ballScrollSpeed"]
        .map { "\"\($0)\":\(n)" }.joined(separator: ",") + "}"))
}
// Buttons are a [Int: ButtonAction], which JSON writes as {"2": action}.
for b in ["-1", "32", "999", "9223372036854775807", "9223372036854775808", "-9223372036854775808", "1.5", "1e3", " 2", "02", "+2", "x", ""] {
    add("button number \(b)", file(config: "{\"buttons\":{\"\(b)\":\(actionJSON(.rightClick))}}"))
}
add("buttons as an array", file(config: "{\"buttons\":[1,\(actionJSON(.rightClick))]}"))
add("duplicate button keys", file(config: "{\"buttons\":{\"1\":\(actionJSON(.rightClick)),\"1\":\(actionJSON(.middleClick))}}"))
add("primary button remapped", file(config: "{\"buttons\":{\"0\":\(actionJSON(.disabled))}}"))
for (label, a) in [("click on button 999", #"{"modifiedClick":{"button":999,"modifiers":0}}"#),
                   ("click on button -1", #"{"modifiedClick":{"button":-1,"modifiers":1048576}}"#),
                   ("click on button Int.max", #"{"modifiedClick":{"button":9223372036854775807,"modifiers":0}}"#),
                   ("click with every modifier bit", #"{"modifiedClick":{"button":1,"modifiers":18446744073709551615}}"#),
                   ("click with negative modifiers", #"{"modifiedClick":{"button":1,"modifiers":-1}}"#),
                   ("shortcut with every modifier bit", #"{"shortcut":{"_0":{"keyCode":0,"modifiers":18446744073709551615,"keyName":"A"}}}"#),
                   ("shortcut key code 70000", #"{"shortcut":{"_0":{"keyCode":70000,"modifiers":0,"keyName":"A"}}}"#),
                   ("shortcut key code -1", #"{"shortcut":{"_0":{"keyCode":-1,"modifiers":0,"keyName":"A"}}}"#),
                   ("shortcut 300-char key name", "{\"shortcut\":{\"_0\":{\"keyCode\":0,\"modifiers\":0,\"keyName\":\"\(String(repeating: "K", count: 300))\"}}}"),
                   ("shortcut key name of 2,000 combining marks", "{\"shortcut\":{\"_0\":{\"keyCode\":0,\"modifiers\":0,\"keyName\":\"a\(String(repeating: "\u{301}", count: 2000))\"}}}"),
                   ("open app empty id", #"{"openApp":{"bundleID":""}}"#),
                   ("open app ../../x", #"{"openApp":{"bundleID":"../../x"}}"#),
                   ("open app 300-char id", "{\"openApp\":{\"bundleID\":\"\(String(repeating: "a", count: 300))\"}}"),
                   ("media key 99", #"{"media":{"_0":99}}"#),
                   ("unknown action", #"{"teleport":{}}"#),
                   ("action is a number", "7"),
                   ("two actions in one", #"{"leftClick":{},"rightClick":{}}"#),
                   ("gesture with a gesture tap", nestedGesture(2)),
                   ("gesture 50 deep", nestedGesture(50)),
                   ("gesture 150 deep (regression: stack overflow on the sync queue)", nestedGesture(150)),
                   ("gesture 100,000 deep", nestedGesture(100_000)),
                   ("gesture step with a gesture", "{\"gesture\":{\"_0\":{\"up\":{\"action\":\(gestureOnlyTap)}}}}"),
                   ("gesture step without an action", #"{"gesture":{"_0":{"up":{"repeats":true}}}}"#)] {
    add("button: \(label)", file(config: "{\"buttons\":{\"2\":\(a)}}"))
    add("combo: \(label)", file(config: "{\"chords\":[{\"id\":\"\(UUID().uuidString)\",\"buttons\":[1,2],\"action\":\(a)}]}"))
    add("app setup button: \(label)", file(config: "{\"appProfiles\":[{\"bundleID\":\"a\",\"buttons\":{\"3\":\(a)}}]}"))
}
for (label, b) in [("one button", "[1]"), ("no buttons", "[]"), ("same button twice", "[2,2]"), ("unsorted", "[3,1,2]"),
                   ("button 999", "[1,999]"), ("negative", "[-1,2]"), ("100,000 buttons", "[" + (0..<100_000).map { String($0 % 40) }.joined(separator: ",") + "]"),
                   ("buttons not numbers", "[\"a\",\"b\"]")] {
    add("combo \(label)", file(config: "{\"chords\":[{\"id\":\"\(UUID().uuidString)\",\"buttons\":\(b),\"action\":\(actionJSON(.leftClick))}]}"))
}
add("combo with a bad id", file(config: "{\"chords\":[{\"id\":\"../../x\",\"buttons\":[1,2],\"action\":\(actionJSON(.leftClick))}]}"))
add("combo without an id", file(config: "{\"chords\":[{\"buttons\":[1,2],\"action\":\(actionJSON(.leftClick))}]}"))
add("80,000 combos", file(config: "{\"chords\":[" + Array(repeating: "{\"id\":\"\(UUID().uuidString)\",\"buttons\":[1,2],\"action\":{\"back\":{}}}", count: 80_000).joined(separator: ",") + "]}"))
add("100,000 app setups, one id", file(config: "{\"appProfiles\":[" + Array(repeating: #"{"bundleID":"a"}"#, count: 100_000).joined(separator: ",") + "]}"))
add("100,000 app setups", file(config: "{\"appProfiles\":[" + (0..<100_000).map { "{\"bundleID\":\"b\($0)\"}" }.joined(separator: ",") + "]}"))
add("100,000 buttons", file(config: "{\"buttons\":{" + (0..<100_000).map { "\"\($0)\":{\"back\":{}}" }.joined(separator: ",") + "}}"))
add("100,000 display speeds", file(config: "{\"displaySpeeds\":{\"enabled\":true,\"speeds\":{" + (0..<100_000).map { "\"d\($0)\":\($0 % 90)" }.joined(separator: ",") + "}}}"))
add("100,000 display names", file(config: "{\"displaySpeeds\":{\"names\":{" + (0..<100_000).map { "\"d\($0)\":\"n\"" }.joined(separator: ",") + "}}}"))
for n in oddNames {
    let s = J.str(n).text
    add("app setup id \(n.debugDescription.prefix(20))", file(config: "{\"appProfiles\":[{\"bundleID\":\(s),\"name\":\(s)}]}"))
    add("display key \(n.debugDescription.prefix(20))", file(config: "{\"displaySpeeds\":{\"enabled\":true,\"speeds\":{\(s):3},\"names\":{\(s):\(s)}}}"))
    add("export name \(n.debugDescription.prefix(20))", file(config: "{}", extra: ",\"exportedFrom\":\(s),\"writtenBy\":\(s)"))
}
for n in weirdNumbers {
    add("app setup speed \(n)", file(config: "{\"appProfiles\":[{\"bundleID\":\"a\",\"trackingSpeed\":\(n)}]}"))
    add("app setup scroll \(n)", file(config: "{\"appProfiles\":[{\"bundleID\":\"a\",\"scroll\":{\"flyDistance\":\(n),\"scrollDistance\":\(n)}}]}"))
    add("display speed \(n)", file(config: "{\"displaySpeeds\":{\"enabled\":true,\"speeds\":{\"d\":\(n)}}}"))
    add("exportedAt \(n)", file(config: "{}", extra: ",\"exportedAt\":\(n)"))
}
for (label, g) in [("pause with no modifiers", #"{"pause":{"keyCode":0,"modifiers":0,"keyName":"A"}}"#),
                   ("precision shift only", #"{"precision":{"keyCode":0,"modifiers":131072,"keyName":"A"}}"#),
                   ("every bit", #"{"dragLock":{"keyCode":0,"modifiers":18446744073709551615,"keyName":"A"}}"#),
                   ("caps lock + fn only", #"{"ballScroll":{"keyCode":0,"modifiers":8781824,"keyName":"A"}}"#),
                   ("all null", #"{"pause":null,"precision":null,"ballScroll":null,"dragLock":null}"#),
                   ("wrong types", #"{"pause":7,"precision":"x","ballScroll":[],"dragLock":{}}"#)] {
    add("global shortcuts: \(label)", file(config: "{\"globalShortcuts\":\(g)}"))
}
add("10 MB key name (over the size cap)", file(config: "{\"globalShortcuts\":{\"pause\":{\"keyCode\":5,\"modifiers\":1048576,\"keyName\":\"\(big)\"}}}"))
add("3.9 MB app name", file(config: "{\"appProfiles\":[{\"bundleID\":\"a\",\"name\":\"\(big.prefix(3_900_000))\"}]}"))
add("3.9 MB bundle id", file(config: "{\"appProfiles\":[{\"bundleID\":\"\(big.prefix(3_900_000))\"}]}"))
add("100,000 [", String(repeating: "[", count: 100_000))
add("100,000 [ ]", String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000))
add("100,000 nested objects", String(repeating: "{\"a\":", count: 100_000) + "1" + String(repeating: "}", count: 100_000))
add("deep nesting inside config", file(config: "{\"chords\":" + String(repeating: "[", count: 50_000) + String(repeating: "]", count: 50_000) + "}"))
add("deep nesting in an unknown key", file(config: "{\"zzz\":" + String(repeating: "[", count: 50_000) + String(repeating: "]", count: 50_000) + "}"))
add("deep nesting 600", file(config: "{\"zzz\":" + String(repeating: "[", count: 600) + String(repeating: "]", count: 600) + "}"))
add("deep nesting 400", file(config: "{\"zzz\":" + String(repeating: "[", count: 400) + String(repeating: "]", count: 400) + "}"))
// Every node of a full config, replaced by each odd value.
var treeCases: [(String, Data)] = []
// The quick run uses the values most likely to break something; --deep all of them.
let treeValues = deep ? weirdNumbers : ["\"4\"", "[]", "null", "1e308", "-1e308", "1e400", "-1", "9223372036854775808"]
for path in richFile.paths() where !path.isEmpty {
    for n in treeValues {
        treeCases.append(("\(path.map(\.description).joined(separator: ".")) = \(n)", richFile.replacing(path[...], with: .raw(n))!.data))
    }
    treeCases.append(("\(path.map(\.description).joined(separator: ".")) removed", richFile.replacing(path[...], with: nil)!.data))
}

// MARK: - 1. Ordinary settings never change

beginSection()
baseline = snapshot()
for (name, c) in normalConfigs {
    worker.run("identity: \(name)") {
        check(c.clamped() == c, "\(name): clamping changes it")
        check(limitsProblem(c) == nil, "\(name): out of limits: \(limitsProblem(c) ?? "")")
        let back = try? BackupStore.decode(fileData(c)).validatedConfig()
        check(back == c, "\(name): saving and reading back changes it")
        let sync = try? JSONDecoder().decode(GlideSettingsFile.self, from: JSONEncoder().encode(GlideSettingsFile(config: c)))
        check(sync?.config == c, "\(name): the sync encoding changes it")
        // An older Glideball's copy (no writtenBy) merged with this Mac's own settings is this Mac's settings.
        check(c.keepingNewerFeatures(from: c).config == c, "\(name): merging with itself changes it")
        // Settings versioning: 2 only when something newer is used, and clamping never changes that.
        check(GlideSettingsFile(config: c).version == (c.usesNewerFeatures ? 2 : 1), "\(name): file version \(GlideSettingsFile(config: c).version)")
        check(c.clamped().requiredFileVersion == c.requiredFileVersion, "\(name): clamping changes its file version")
    }
}
worker.run("versioning: defaults are version 1, gestures version 2") {
    check(GlideSettingsFile(config: GlideConfig()).version == 1, "defaults written as version \(GlideSettingsFile(config: GlideConfig()).version)")
    check(GlideSettingsFile(config: richConfig()).version == 2, "gestures written as version \(GlideSettingsFile(config: richConfig()).version)")
    var tuned = GlideConfig()
    tuned.gestureDistance = .long; tuned.gestureSteadyHands = true   // an older Glideball just ignores these
    check(GlideSettingsFile(config: tuned).version == 1, "gesture tuning alone written as version 2")
}
endSection("normal settings unchanged by clamping", "\(normalConfigs.count) configs")

// MARK: - 2. Import (ImportFile.read, what AppModel.previewImport calls)

let importFolder = appFolder.appendingPathComponent("imports", isDirectory: true)
try! fm.createDirectory(at: importFolder, withIntermediateDirectories: true)
var importIndex = 0

/// The settings a chosen file would give, as AppModel does it: a settings file is
/// shown (already clamped) and Apply takes `validatedConfig()` → `sanitizedForImport()`
/// with this Mac's pause switch; a shared setup goes to the share preview, whose Apply
/// is `applied(to:)` with this Mac's pause switch and primary button. Nil: refused.
func imported(_ url: URL, into current: GlideConfig) -> GlideConfig? {
    switch try? ImportFile.read(url) {
    case .settings(let file)?:
        guard var incoming = try? file.validatedConfig() else { return nil }
        if withoutIDs(file.config) != withoutIDs(incoming.sanitizedForImport()) {
            fail("import: the preview isn't what Apply would do: \(firstDifference(withoutIDs(file.config), withoutIDs(incoming.sanitizedForImport())))")
        }
        incoming = incoming.sanitizedForImport()
        incoming.enabled = current.enabled
        return incoming
    case .share(let share)?:
        return sharedApplied(share, to: current)
    case nil:
        return nil
    }
}

/// `c` with every combo's id the same (an import gives combos fresh ids).
func withoutIDs(_ c: GlideConfig) -> GlideConfig {
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    var c = c
    for i in c.chords.indices { c.chords[i].id = zero }
    for p in c.appProfiles.indices { if var ch = c.appProfiles[p].chords { for i in ch.indices { ch[i].id = zero }; c.appProfiles[p].chords = ch } }
    return c
}

/// The first top-level setting where `a` and `b` differ (for failure messages).
func firstDifference(_ a: GlideConfig, _ b: GlideConfig) -> String {
    let ma = Mirror(reflecting: a).children, mb = Array(Mirror(reflecting: b).children)
    for (i, x) in ma.enumerated() where String(describing: x.value) != String(describing: mb[i].value) {
        return "\(x.label ?? "?"): \(String(describing: x.value).prefix(300)) vs \(String(describing: mb[i].value).prefix(300))"
    }
    return "(no visible difference)"
}

/// AppModel.applyIncoming for a share.
func sharedApplied(_ share: SharedSetup, to current: GlideConfig) -> GlideConfig {
    var updated = share.applied(to: current)
    updated.enabled = current.enabled
    updated.buttons[0] = current.buttons[0]
    return updated
}

/// Anything imported: inside the limits, already clamped, and the primary button as it was.
func assertImported(_ c: GlideConfig, from current: GlideConfig, _ name: String) {
    assertInLimits(c, name)
    if c.buttons[0] != current.buttons[0] { fail("\(name): the primary button changed to \(String(describing: c.buttons[0]))") }
}

/// The importer: AppModel shows a preview only for a file `ImportFile.read` accepts.
func importCase(_ name: String, _ data: Data, expect: Bool? = nil) {
    importIndex += 1
    let url = importFolder.appendingPathComponent("\(importIndex).glide-settings")
    try! data.write(to: url)
    worker.run("import: \(name)") {
        let current = richConfig()
        var settings = current
        if let incoming = imported(url, into: current) {
            settings = incoming
            if expect == false { fail("import: \(name): accepted, should be refused") }
            assertImported(settings, from: current, "import: \(name)")
        } else {
            if expect == true { fail("import: \(name): refused, should be accepted") }
            check(settings == current, "import: \(name): a refused file changed settings")
        }
    }
    try? fm.removeItem(at: url)
}

beginSection()
var acceptedCount = 0
for (name, c) in normalConfigs { importCase("normal \(name)", fileData(c), expect: true) }
importCase("older file with numeric dates", try! JSONEncoder().encode(GlideSettingsFile(config: richConfig())), expect: true)
for (name, data) in hostile {
    var expect: Bool?
    if name.hasPrefix("version ") {
        expect = ["version 1", "version 2", "version 1.0"].contains(name) ? true : false
        if name == "version 1.5" || name == "version 1e400" { expect = false }
    }
    if name.contains("over the size cap") { expect = false }
    if ["empty file", "null", "array", "just {", "truncated at 1"].contains(name) { expect = false }
    importCase(name, data, expect: expect)
}
for (name, data) in treeCases {
    let current = richConfig()
    worker.run("import tree: \(name)") {
        if let f = try? GlideSettingsFile.decode(data), let c = try? f.validatedConfig() {
            acceptedCount += 1
            assertInLimits(c, "import tree: \(name)")
        } else {
            _ = current
        }
    }
}
// Files that aren't files.
let fifo = outside.appendingPathComponent("pipe")
mkfifo(fifo.path, 0o600)
let validOutside = outside.appendingPathComponent("someone else.glide-settings")
var foreign = GlideConfig()
foreign.trackingSpeed = 77
try! fileData(foreign).write(to: validOutside)
let outsideDir = outside.appendingPathComponent("folder", isDirectory: true)
try! fm.createDirectory(at: outsideDir, withIntermediateDirectories: true)
try! Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
baseline = snapshot()
func link(_ at: URL, _ to: String) { try? fm.removeItem(at: at); try! fm.createSymbolicLink(atPath: at.path, withDestinationPath: to) }
for (label, target) in [("a pipe (regression: used to block forever)", fifo.path), ("/dev/zero (regression: endless read)", "/dev/zero"),
                        ("/dev/random", "/dev/random"), ("/etc/passwd", "/etc/passwd"), ("a folder", outsideDir.path),
                        ("nothing", outside.appendingPathComponent("missing").path)] {
    let url = importFolder.appendingPathComponent("link.glide-settings")
    link(url, target)
    worker.run("import: a link to \(label)") {
        check(imported(url, into: GlideConfig()) == nil, "import: a link to \(label) was accepted")
    }
}
let pipeImport = importFolder.appendingPathComponent("pipe.glide-settings")
mkfifo(pipeImport.path, 0o600)
worker.run("import: a pipe itself (regression)") {
    check(imported(pipeImport, into: GlideConfig()) == nil, "import: a pipe was accepted")
}
try? fm.removeItem(at: pipeImport)
// An alias someone chose on purpose to a real settings file still imports.
link(importFolder.appendingPathComponent("alias.glide-settings"), validOutside.path)
worker.run("import: a link to a real settings file") {
    let c = imported(importFolder.appendingPathComponent("alias.glide-settings"), into: GlideConfig())
    check(c?.trackingSpeed == 77, "import: a link to a real settings file was refused")
}
let huge = importFolder.appendingPathComponent("huge.glide-settings")
fm.createFile(atPath: huge.path, contents: nil)
if let h = try? FileHandle(forWritingTo: huge) { try? h.truncate(atOffset: 2_000_000_000); try? h.close() }   // sparse 2 GB
worker.run("import: a 2 GB file (regression: read whole into memory)") {
    check(imported(huge, into: GlideConfig()) == nil, "import: a 2 GB file was accepted")
}
try? fm.removeItem(at: huge)
endSection("import", "\(treeCases.count) of them tree mutations, \(acceptedCount) accepted")

// MARK: - 2b. Shared setups (files and glideball://import links) and KensingtonWorks

beginSection()
var shareFiles: [(String, Data)] = []
var shareLinks: [(String, String)] = []
for (name, c) in normalConfigs {
    for kind in ShareKind.allCases {
        let look: ShareLook? = kind == .look || kind == .everything ? ShareLook(theme: "custom", custom: ["FF0000", "00FF00", "0000FF"]) : nil
        guard let share = SharedSetup.make(kind, from: c, look: look, appSetup: c.appProfiles.first?.bundleID, writtenBy: "2.11") else { continue }
        // Versioning: a share (like a settings file) is version 2 only when it carries something newer.
        if share.version != share.requiredVersion { fail("share \(kind.rawValue) of \(name): version \(share.version), needs \(share.requiredVersion)") }
        if let data = try? share.fileData() { shareFiles.append(("\(kind.rawValue) of \(name)", data)) }
        if share.link() != nil, let d = share.payload { shareLinks.append(("\(kind.rawValue) of \(name)", d)) }
    }
    // Checklist shares: every part, each part alone, and a few mixes, with names (odd ones too), sounds and a look.
    let parts: [SharePart] = SharePart.fixed + c.appProfiles.prefix(3).map { .app($0.bundleID) }
    let names = [nil, "Levi", "  \u{202E}Zoë 🎱\u{0007}  ", "<script>alert(1)</script>", String(repeating: "名", count: 300), "\u{0}\u{200B}"]
    let sounds = ShareSounds(on: false, volume: 0.3, kinds: ["ticks": false, "notAKind": true])
    var mixes: [[SharePart]] = [parts] + parts.map { [$0] }
    for i in 0..<6 { mixes.append(parts.enumerated().filter { ($0.offset + i) % 3 != 0 }.map(\.element)) }
    for (i, mix) in mixes.enumerated() {
        let n = names[i % names.count]
        guard let share = SharedSetup.make(mix, from: c, look: ShareLook(theme: "custom", custom: ["FF0000", "00FF00", "0000FF"]),
                                           sounds: sounds, name: n, writtenBy: "2.11") else { continue }
        if let from = share.from, from.count > SharedSetup.maxFromLength || from.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }) {
            fail("checklist share of \(name): the name wasn't cleaned: \(from.debugDescription)")
        }
        let label = "parts \(mix.map(\.id).joined(separator: "+").prefix(80)) of \(name)"
        if let data = try? share.fileData() { shareFiles.append((label, data)) }
        if share.link() != nil, let d = share.payload { shareLinks.append((label, d)) }
    }
}
for (name, data) in shareFiles { importCase("shared file: \(name)", data, expect: true) }
func linkCase(_ name: String, _ payload: String, expect: Bool? = nil) {
    worker.run("link: \(name)") {
        let current = richConfig()
        guard let share = try? SharedSetup.decode(linkPayload: payload) else {
            if expect == true { fail("link: \(name): refused, should be accepted") }
            return
        }
        if expect == false { fail("link: \(name): accepted, should be refused") }
        assertImported(sharedApplied(share, to: current), from: current, "link: \(name)")
        assertImported(sharedApplied(share, to: GlideConfig()), from: GlideConfig(), "link: \(name) (onto defaults)")
        // Parts left out in the preview: whatever's still ticked is just as safe, and nothing ticked changes nothing.
        for part in share.parts {
            assertImported(share.applied(to: current, parts: [part]), from: current, "link: \(name), only \(part.id)")
        }
        if share.applied(to: current, parts: []) != current.clamped() { fail("link: \(name): applying no parts changed something") }
        if let from = share.from, from.count > SharedSetup.maxFromLength { fail("link: \(name): a \(from.count)-character name got through") }
        if let s = share.appliedSounds(), !(0...1).contains(s.volume) || s.kinds.keys.contains(where: { !ShareSounds.kindIDs.contains($0) }) {
            fail("link: \(name): sounds outside the limits: \(s)")
        }
    }
}
for (name, d) in shareLinks { linkCase(name, d, expect: true) }
// Hostile shares: every value of every share file swapped for something odd, and
// the same JSON as a link's payload.
var shareTrees = 0, shareAccepted = 0
for (name, data) in shareFiles.filter({ $0.0.hasSuffix("of rich (gestures, app setups, display speeds)") || $0.0.hasSuffix("of defaults") }) {
    let tree = J(data: data)
    for (i, path) in tree.paths().enumerated() where !path.isEmpty && (deep || i % 2 == 0) {
        for v in treeValues {
            guard let t = tree.replacing(path[...], with: .raw(v)) else { continue }
            shareTrees += 1
            let bad = t.data
            importCase("shared file \(name), \(path) = \(v)", bad)
            if shareTrees % 7 == 0, let packed = SharedSetup.deflate(bad) { linkCase("\(name), \(path) = \(v)", SharedSetup.base64url(packed)) }
        }
    }
}
// Links that aren't: garbage, huge, deflate bombs, a settings file as a payload.
let zeros = Data(count: 4_000_000)
for (label, d) in [("empty", ""), ("not base64", "!!!!"), ("2 KB of A", String(repeating: "A", count: 2_100)),
                   ("a 4 MB deflate bomb", SharedSetup.deflate(zeros).map(SharedSetup.base64url) ?? ""),
                   ("a settings file", SharedSetup.deflate(fileData(richConfig())).map(SharedSetup.base64url) ?? ""),
                   ("deep nesting", SharedSetup.deflate(Data((String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)).utf8)).map(SharedSetup.base64url) ?? "")] {
    linkCase(label, d, expect: false)
}
// KensingtonWorks: its real file shapes (scripts/import-sim/fixtures) and every value swapped,
// through parse → make → applied, as previewKensingtonWorks and Apply do it.
let kwFixtures = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "scripts/import-sim/fixtures"), includingPropertiesForKeys: nil)) ?? []
var kwCases = 0
func kwCase(_ name: String, _ data: Data) {
    kwCases += 1
    worker.run("KensingtonWorks: \(name)") {
        for current in [richConfig(), GlideConfig()] {
            guard case .success(let settings) = KensingtonWorks.parse(data), let imp = KensingtonWorksImport.make(from: settings) else { return }
            var updated = imp.applied(to: current)
            updated.enabled = current.enabled
            updated.buttons[0] = current.buttons[0]
            assertImported(updated, from: current, "KensingtonWorks: \(name)")
        }
    }
}
for url in kwFixtures where url.pathExtension == "json" {
    guard let data = try? Data(contentsOf: url) else { fail("can't read \(url.lastPathComponent)"); continue }
    kwCase(url.lastPathComponent, data)
    let tree = J(data: data)
    for (i, path) in tree.paths().enumerated() where !path.isEmpty && (deep || i % 3 == 0) {
        for v in ["\"4\"", "null", "1e308", "-1", "9223372036854775808", "\"\(String(repeating: "k", count: 400))\""] {
            if let t = tree.replacing(path[...], with: .raw(v)) { kwCase("\(url.lastPathComponent) \(path) = \(v)", t.data) }
        }
    }
}
if kwFixtures.isEmpty { fail("no KensingtonWorks fixtures in scripts/import-sim/fixtures") }
// KensingtonWorks' file itself is read only, never through a pipe or forever.
let kwFolder = appFolder.appendingPathComponent("kw", isDirectory: true)
try! fm.createDirectory(at: kwFolder, withIntermediateDirectories: true)
let kwPipe = kwFolder.appendingPathComponent("TbwSettings.json")
mkfifo(kwPipe.path, 0o600)
worker.run("KensingtonWorks: its file is a pipe") {
    if case .success = KensingtonWorks.read(kwPipe) { fail("KensingtonWorks: a pipe was read") }
}
try? fm.removeItem(at: kwPipe)
for (label, target) in [("a pipe", fifo.path), ("/dev/zero", "/dev/zero"), ("a folder", outsideDir.path)] {
    link(kwPipe, target)
    worker.run("KensingtonWorks: its file is a link to \(label)") {
        if case .success = KensingtonWorks.read(kwPipe) { fail("KensingtonWorks: a link to \(label) was read") }
    }
}
try? fm.removeItem(at: kwPipe)
endSection("shared setups and KensingtonWorks", "\(shareFiles.count) shares, \(shareLinks.count) links, \(shareTrees) hostile shares, \(kwCases) KensingtonWorks files")

// MARK: - 3. Backups: listing, restore, pruning

let backupFolder = appFolder.appendingPathComponent("Backups", isDirectory: true)
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "UTC")!
var clock = cal.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 12))!

/// AppModel.restoreBackup: a backup that doesn't load changes nothing.
func restore(_ store: BackupStore, _ backup: BackupStore.Backup, into current: GlideConfig) -> GlideConfig {
    guard var restored = store.load(backup) else { return current }
    restored.enabled = current.enabled
    store.checkpoint(current, kind: .beforeRestore)
    return restored
}

func backupContentCase(_ name: String, _ data: Data) {
    try? fm.removeItem(at: backupFolder)
    try! fm.createDirectory(at: backupFolder, withIntermediateDirectories: true)
    try! data.write(to: backupFolder.appendingPathComponent("2026-05-31 09.00.00.glide-settings"))
    worker.run("backup: \(name)") {
        let store = BackupStore(folder: backupFolder, defaults: MemoryDefaults(), calendar: cal, now: { clock })
        guard let b = store.backups.first else { return fail("backup: \(name): not listed") }
        let current = richConfig()
        let after = restore(store, b, into: current)
        if store.load(b) == nil { check(after == current, "backup: \(name): an unreadable backup changed settings") }
        else { assertInLimits(after, "backup: \(name)") }
        // The next daily backup still works and holds today's settings.
        let today = GlideConfig()
        store.snapshotIfDue(today)
        check(store.backups.contains { $0.kind == .daily && cal.isDate($0.date, inSameDayAs: clock) && store.load($0) == today },
              "backup: \(name): after it, today's backup doesn't hold today's settings")
    }
}

beginSection()
for (name, c) in normalConfigs { backupContentCase("normal \(name)", fileData(c)) }
for (name, data) in hostile { backupContentCase(name, data) }
for (name, data) in treeCases.enumerated().filter({ deep || $0.offset % 25 == 0 }).map(\.element) { backupContentCase("tree \(name)", data) }

// A folder full of junk, links and odd names, next to real backups.
try? fm.removeItem(at: backupFolder)
try! fm.createDirectory(at: backupFolder, withIntermediateDirectories: true)
func put(_ name: String, _ data: Data = fileData(GlideConfig())) { try! data.write(to: backupFolder.appendingPathComponent(name)) }
let real = ["2026-01-01 00.00.00", "2026-01-15 08.00.00 before import", "2026-05-20 09.00.00", "2026-05-31 09.00.00"]
for (i, n) in real.enumerated() {
    var c = GlideConfig(); c.trackingSpeed = Double(i + 2)
    put(n + ".glide-settings", fileData(c))
}
for n in ["2026-13-45 99.99.99", "0000-00-00 00.00.00", "2026-01-02 00.00.00 hacked", "2026-01-02 00.00.00\nbefore import",
          "2026-01-03 00.00.00 " + String(repeating: "x", count: 200), "x", "", "2026-01-04 00.00.00..", "../2026-01-05 00.00.00"]
    where !n.contains("/") {
    put(n + ".glide-settings", Data("junk".utf8))
}
put("9999-12-31 23.59.59.glide-settings", Data("future junk".utf8))
put("2026-01-06 00.00.00.GLIDE-SETTINGS")
put("2026-01-06 00.00.00.glide-settings.icloud")
put(".2026-01-06 00.00.00.glide-settings")
put("2026-04-01 00.00.00.glide-settings", Data(count: 5_000_000))   // over the size cap
put("2026-04-02 00.00.00.glide-settings", Data())
for i in 0..<500 { put(String(format: "junk %03d.txt", i), Data("x".utf8)) }
let dirBackup = backupFolder.appendingPathComponent("2026-01-07 00.00.00.glide-settings", isDirectory: true)
try! fm.createDirectory(at: dirBackup, withIntermediateDirectories: true)
try! Data("keep".utf8).write(to: dirBackup.appendingPathComponent("inside"))
let links: [(String, String)] = [("2026-01-08 00.00.00", validOutside.path), ("2026-05-30 00.00.00", validOutside.path),
                                 ("2026-01-09 00.00.00", "/dev/zero"), ("2026-01-10 00.00.00", fifo.path),
                                 ("2026-01-11 00.00.00", "/etc/passwd"), ("2026-01-12 00.00.00", outsideDir.path),
                                 ("2026-01-13 00.00.00", outside.appendingPathComponent("missing").path),
                                 ("2026-05-29 00.00.00 before restore", "../../outside/someone else.glide-settings")]
for (n, target) in links { link(backupFolder.appendingPathComponent(n + ".glide-settings"), target) }
mkfifo(backupFolder.appendingPathComponent("2026-05-28 00.00.00.glide-settings").path, 0o600)

worker.run("backup folder full of junk, links and pipes (regression: links listed and followed)", budget: 3) {
    let store = BackupStore(folder: backupFolder, defaults: MemoryDefaults(), calendar: cal, now: { clock })
    let names = Set(store.backups.map { $0.url.deletingPathExtension().lastPathComponent })
    for (n, _) in links { check(!names.contains(n), "backups: a link (\(n)) is listed") }
    check(!names.contains("2026-01-07 00.00.00"), "backups: a folder is listed")
    check(!names.contains("2026-05-28 00.00.00"), "backups: a pipe is listed")
    for n in real { check(names.contains(n), "backups: real backup \(n) missing") }
    var current = richConfig()
    for b in store.backups {
        let before = current
        current = restore(store, b, into: current)
        if current.trackingSpeed == 77 { fail("backups: restored settings from a file outside the folder") }
        if current != before { assertInLimits(current, "backups: restore \(b.url.lastPathComponent)") }
    }
    store.snapshotIfDue(GlideConfig())
    store.checkpoint(GlideConfig(), kind: .manual)
    clock = cal.date(byAdding: .year, value: 2, to: clock)!   // everything ages out: prune hard
    store.snapshotIfDue(richOnce)
    clock = cal.date(byAdding: .year, value: -2, to: clock)!
    check(fm.fileExists(atPath: dirBackup.appendingPathComponent("inside").path), "backups: pruning deleted a folder")
    for (n, _) in links {
        var st = stat()
        check(lstat(backupFolder.appendingPathComponent(n + ".glide-settings").path, &st) == 0, "backups: pruning removed the link \(n)")
    }
    check(store.backups.contains { store.load($0) == richOnce.withEnabled },
          "backups: the newest backup isn't today's settings: \(store.backups.map { "\($0.url.lastPathComponent) \(store.load($0)?.trackingSpeed ?? -1)" }) \(store.lastError ?? "")")
}
endSection("backups", "listing, restore and pruning")

extension GlideConfig { var withEnabled: GlideConfig { var c = self; c.enabled = true; return c } }

/// The harness's own look at a file: only a plain one (a pipe or /dev/zero would hang it).
func plainFile(_ url: URL) -> Data? {
    var st = stat()
    guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
    return try? Data(contentsOf: url)
}

// MARK: - 4. Sync with other Macs (the real SettingsSync on the main run loop)

/// The shared settings file another Mac would write, around raw settings JSON.
func shared(_ settings: String, updatedAt: String = "800000000", deviceID: String = "\"OTHER-MAC\"", name: String = "\"Other Mac\"") -> Data {
    Data("{\"settings\":\(settings),\"updatedAt\":\(updatedAt),\"deviceID\":\(deviceID),\"deviceName\":\(name)}".utf8)
}
func syncSettings(_ c: GlideConfig, writtenBy: String? = "2.10") -> String {
    var f = J(data: try! JSONEncoder().encode(GlideSettingsFile(config: c)))
    f["writtenBy"] = writtenBy.map(J.str)
    return f.text
}

enum SyncExpect { case adopt, refuse, replace, any }
var syncIndex = 0

/// One Mac turning sync on with `local`, against a sync folder `prepare` filled.
func syncCase(_ name: String, local: GlideConfig = GlideConfig(), remote: Data?, expect: SyncExpect,
              defaults: MemoryDefaults = MemoryDefaults(), heartbeat: Bool = true,
              prepare: (URL) -> Void = { _ in }, after: (URL, SettingsSync) -> Void = { _, _ in }) {
    sectionCases += 1
    setCase("sync: \(name)")
    syncIndex += 1
    let folder = appFolder.appendingPathComponent("iCloud \(syncIndex)/Glide", isDirectory: true)
    try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let settingsURL = folder.appendingPathComponent("settings.glide-settings")
    if let remote { try! remote.write(to: settingsURL) }
    prepare(folder)
    let before = plainFile(settingsURL)
    var got: GlideConfig?
    let sync = SettingsSync(onRemoteConfig: { got = $0 }, folder: folder, defaults: defaults)
    let start = Date()
    sync.setEnabled(true, current: local)
    func settled() -> Bool {
        switch sync.status {
        case .upToDate: !heartbeat || sync.devices.contains { $0.isThisMac }
        case .error, .unavailable: true
        default: false
        }
    }
    while !settled() && Date().timeIntervalSince(start) < 3 { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    let took = Date().timeIntervalSince(start)
    if !settled() { fail("sync: \(name): didn't settle in 3 s (status \(sync.status))") }
    else if took > 2 { fail("sync: \(name): took \(String(format: "%.1f", took)) s") }
    if let got {
        assertInLimits(got, "sync: \(name)")
        check(got.enabled == local.enabled, "sync: \(name): the pause switch came from the other Mac")
    }
    let afterData = plainFile(settingsURL)
    switch expect {
    case .adopt: check(got != nil, "sync: \(name): not adopted (status \(sync.status))")
    case .refuse:
        check(got == nil, "sync: \(name): adopted settings it should have refused")
        check(afterData == before, "sync: \(name): overwrote a file it should have left alone")
    case .replace:
        check(got == nil, "sync: \(name): adopted a broken file")
        let mine = afterData.flatMap { try? JSONDecoder().decode(SharedFileProbe.self, from: $0) }
        check(mine?.settings.config == local.withEnabled, "sync: \(name): didn't replace a broken file with this Mac's settings")
    case .any:
        if got == nil, case .error = sync.status { check(afterData == before, "sync: \(name): overwrote a file after an error") }
    }
    for d in sync.devices { check(d.name.utf8.count <= ConfigLimits.maxNameLength, "sync: \(name): device name of \(d.name.utf8.count) bytes") }
    after(folder, sync)
    sync.setEnabled(false, current: local)
}

struct SharedFileProbe: Decodable { let settings: GlideSettingsFile }

beginSection()
var other = richConfig()
other.trackingSpeed = 9
syncCase("a normal newer file from another Mac", remote: shared(syncSettings(other)), expect: .adopt)
syncCase("nothing there yet", remote: nil, expect: .replace)
syncCase("an empty file", remote: Data(), expect: .replace)
syncCase("not JSON", remote: Data("garbage".utf8), expect: .replace)
syncCase("truncated", remote: shared(syncSettings(other)).prefix(100), expect: .replace)
syncCase("invalid UTF-8", remote: Data([0xFF, 0xFE, 0x00, 0x7B]), expect: .replace)
syncCase("BOM + a normal file", remote: Data([0xEF, 0xBB, 0xBF]) + shared(syncSettings(other)), expect: .any)
for v in ["3", "0", "-1", "9223372036854775807", "-9223372036854775808", "\"1\"", "null", "1.5"] {
    syncCase("settings version \(v) (left alone)", remote: shared("{\"version\":\(v),\"config\":{}}"), expect: .refuse)
}
syncCase("settings version 2", remote: shared("{\"version\":2,\"config\":{\"trackingSpeed\":12},\"writtenBy\":\"2.11\"}"), expect: .adopt)
syncCase("JSON of the wrong shape", remote: Data("{\"hello\":[1,2,3]}".utf8), expect: .refuse)
syncCase("JSON array", remote: Data("[1,2,3]".utf8), expect: .refuse)
for n in ["1e308", "-1e308", "\"yesterday\"", "null", "-0", "9223372036854775807"] {
    syncCase("updatedAt \(n)", remote: shared(syncSettings(other), updatedAt: n), expect: .any)
}
for n in oddNames.prefix(8) {
    syncCase("device id \(n.debugDescription.prefix(16))", remote: shared(syncSettings(other), deviceID: J.str(n).text, name: J.str(n).text), expect: .adopt)
}
syncCase("1 MB device name", remote: shared(syncSettings(other), name: J.str(String(big.prefix(1_000_000))).text), expect: .adopt)
// Through sync too (a run of the real class per file, so the quick run takes a sample).
for (i, (name, data)) in hostile.enumerated() where deep || i % 15 == 0 || name.contains("deep") || name.hasPrefix("100,000") {
    syncCase("settings: \(name)", remote: shared(String(decoding: data, as: UTF8.self)), expect: .any)
}
// An older Glideball (no writtenBy) wrote back what it could; this Mac's newer
// features come back. Regression: the merge could hold more combos than allowed.
var fullOfCombos = GlideConfig()
fullOfCombos.chords = (0..<ConfigLimits.maxChords).map { Chord(buttons: [1 + $0 % 3, 4 + $0 / 3], action: .gesture(.standard)) }
var olderMacs = GlideConfig()
olderMacs.chords = (0..<ConfigLimits.maxChords).map { Chord(buttons: [5 + $0 % 3, 9 + $0 / 3], action: .back) }
syncCase("older Mac's file merged with 64 gesture combos (regression)", local: fullOfCombos,
         remote: shared(syncSettings(olderMacs, writtenBy: nil)), expect: .adopt)
syncCase("older Mac's file, this Mac has gestures", local: richConfig(),
         remote: shared(syncSettings(GlideConfig(), writtenBy: nil)), expect: .adopt)

// Files that aren't files. Regression: these were followed (adopting a file from
// anywhere on the disk) or read forever.
for (label, target) in [("a real settings file elsewhere", validOutside.path), ("/dev/zero", "/dev/zero"),
                        ("a pipe", fifo.path), ("a folder", outsideDir.path)] {
    syncCase("settings file is a link to \(label) (regression)", remote: nil, expect: .refuse, prepare: { folder in
        link(folder.appendingPathComponent("settings.glide-settings"), target)
    })
}
syncCase("settings file is a pipe (regression)", remote: nil, expect: .any, prepare: { folder in
    mkfifo(folder.appendingPathComponent("settings.glide-settings").path, 0o600)
})
syncCase("100,000 [ (regression: crashed the sync queue)", remote: Data(String(repeating: "[", count: 100_000).utf8), expect: .replace)
syncCase("100,000 nested objects (regression: crashed the sync queue)",
         remote: Data((String(repeating: "{\"a\":", count: 100_000) + "1" + String(repeating: "}", count: 100_000)).utf8), expect: .replace)
syncCase("gestures 150 deep (regression: crashed the sync queue)",
         remote: shared("{\"version\":1,\"config\":{\"buttons\":{\"2\":\(nestedGesture(150))}}}"), expect: .replace)
syncCase("gestures 10 deep", remote: shared("{\"version\":1,\"config\":{\"buttons\":{\"2\":\(nestedGesture(10))}}}"), expect: .adopt)
syncCase("settings file is 5 MB",remote: shared(syncSettings(other)) + Data(repeating: 0x20, count: 5_000_000), expect: .refuse)
syncCase("devices folder is a link elsewhere (regression: heartbeat written outside)", remote: shared(syncSettings(other)),
         expect: .adopt, heartbeat: false, prepare: { folder in
    link(folder.appendingPathComponent("devices"), outsideDir.path)
})
let pwned = MemoryDefaults()
pwned.set("../../../../outside/pwned", forKey: "GlideDeviceID")
syncCase("a device id of ../../x in UserDefaults (regression)", remote: shared(syncSettings(other)), expect: .adopt, defaults: pwned,
         after: { folder, _ in
    let names = (try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent("devices").path)) ?? []
    check(names.count == 1 && UUID(uuidString: String(names[0].dropLast(5))) != nil, "sync: heartbeat named \(names)")
})
syncCase("devices folder full of junk", remote: shared(syncSettings(other)), expect: .adopt, prepare: { folder in
    let devices = folder.appendingPathComponent("devices", isDirectory: true)
    try! fm.createDirectory(at: devices, withIntermediateDirectories: true)
    func beat(_ file: String, _ json: String) { try! Data(json.utf8).write(to: devices.appendingPathComponent(file)) }
    beat("good.json", #"{"name":"Studio","lastSeen":800000000,"appVersion":"2.10"}"#)
    beat("future.json", #"{"name":"Future","lastSeen":1e308}"#)
    beat("past.json", #"{"name":"Past","lastSeen":-1e308}"#)
    beat("huge name.json", "{\"name\":\"\(big.prefix(60_000))\",\"lastSeen\":1}")
    beat("too big.json", "{\"name\":\"\(big.prefix(200_000))\",\"lastSeen\":1}")
    beat("combining.json", "{\"name\":\"a\(String(repeating: "\u{301}", count: 5000))\",\"lastSeen\":1}")
    beat("junk.json", "not json")
    beat("empty.json", "")
    beat("wrong.json", #"{"name":7,"lastSeen":"x"}"#)
    beat(".json", #"{"name":"dot","lastSeen":1}"#)
    beat("..json", #"{"name":"dotdot","lastSeen":1}"#)
    beat("new\nline.json", #"{"name":"nl","lastSeen":1}"#)
    beat(".ghost.json.icloud", "stub")
    try! fm.createDirectory(at: devices.appendingPathComponent("folder.json"), withIntermediateDirectories: true)
    link(devices.appendingPathComponent("zero.json"), "/dev/zero")
    link(devices.appendingPathComponent("pipe.json"), fifo.path)
    link(devices.appendingPathComponent("passwd.json"), "/etc/passwd")
    mkfifo(devices.appendingPathComponent("fifo.json").path, 0o600)
}, after: { _, sync in
    check(sync.devices.contains { $0.name == "Studio" }, "sync: a real heartbeat among junk wasn't listed")
    check(!sync.devices.contains { $0.name == "Future" || $0.name == "Past" }, "sync: a heartbeat from year 10^300 was listed")
})
syncCase("5,000 heartbeats", remote: shared(syncSettings(other)), expect: .adopt, prepare: { folder in
    let devices = folder.appendingPathComponent("devices", isDirectory: true)
    try! fm.createDirectory(at: devices, withIntermediateDirectories: true)
    let beat = Data(#"{"name":"Mac","lastSeen":800000000}"#.utf8)
    for i in 0..<5000 { try! beat.write(to: devices.appendingPathComponent("\(UUID().uuidString)-\(i).json")) }
}, after: { _, sync in check(sync.devices.count <= SettingsSync.maxDevices + 1, "sync: \(sync.devices.count) devices listed") })
endSection("sync")

// MARK: - 5. Daily totals, the milestone ledger, the low-battery state

beginSection()
let goodDay = SavedDayTotals(["clicks": 1234, "ball": 5.5, "scroll": 2.0] as [String: Any])
worker.run("totals: a normal day reads as before") {
    check(goodDay == SavedDayTotals(clicks: 1234, ballCounts: 5.5, scrollPoints: 2), "totals: a normal day reads differently: \(String(describing: goodDay))")
    check(SavedDayTotals(["clicks": 3, "ball": 7, "scroll": 1.5] as [String: Any])?.ballCounts == 7, "totals: whole-number counts lost")
    check(SavedDayTotals("nope") == nil && SavedDayTotals(nil) == nil, "totals: a non-dictionary read as a day")
}
let oddValues: [Any] = [Int.max, Int.min, -5, Double.nan, Double.infinity, -Double.infinity, 1e300, -1e300, "12", [1], true,
                        UInt64.max, Double(Int.max), 0.5, NSNull()]
for v in oddValues {
    worker.run("totals: \(v) everywhere (regression: overflow crash)") {
        let day = SavedDayTotals(["clicks": v, "ball": v, "scroll": v] as [String: Any])!
        check(day.clicks >= 0 && day.clicks <= SavedDayTotals.maxClicks, "totals: clicks \(day.clicks)")
        check(day.ballCounts.isFinite && day.ballCounts >= 0 && day.scrollPoints.isFinite && day.scrollPoints >= 0, "totals: distances \(day)")
        // Ten years of such days, summed the way DelightCenter does.
        let sum = Array(repeating: day.tally, count: 3650).reduce(Tally(), +)
        for m in Metric.allCases {
            _ = m.format(sum.value(m))
            _ = Landmarks.compare(sum.value(m), metric: m)
        }
        _ = sum + Tally(clicks: .max) + Tally(clicks: .max)
    }
}
for v in [1e300, -1e300, Double.nan, Double.infinity, -Double.infinity, 9.3e18, -0.0, 0.4] {
    worker.run("formatting \(v) (regression: Int(...) crash)") {
        for m in Metric.allCases { _ = m.format(v); _ = Landmarks.compare(v, metric: m) }
        for k in RecordKind.allCases { _ = k.format(v) }
        _ = Tally.distance(v)
        _ = Tally.shortDistance(v)
    }
}
worker.run("formatting: whole clicks look as before") {
    check(Metric.clicks.format(1234) == 1234.formatted(), "formatting: clicks read \(Metric.clicks.format(1234))")
    check(Landmarks.compare(50 * 42_195, metric: .ball) == Landmarks.compare(50 * 42_195 + 1, metric: .ball), "formatting: landmark text changed")
}
let ledgers = [#"{}"#, #"{"records":{"spin":1e308,"flick":-1e308,"roll":0}}"#, #"{"earned":{"x":1e308},"started":-1e308}"#,
               #"{"checklist":["teleport"]}"#, #"{"explored":["teleport", 7, null]}"#, #"{"records":{"spin":"fast"}}"#,
               #"{"celebratedOn":{"spin":"../../x"},"knownBadges":["a","a"]}"#, String(repeating: "[", count: 100_000), "",
               "{\"records\":{" + (0..<100_000).map { "\"r\($0)\":\($0)" }.joined(separator: ",") + "}}"]
for (i, l) in ledgers.enumerated() {
    worker.run("ledger \(i)") {
        guard let ledger = try? JSONDecoder().decode(DelightLedger.self, from: Data(l.utf8)) else { return }
        for k in RecordKind.allCases { _ = k.format(ledger.record(k)) }
        for m in Milestone.all { _ = ledger.progress(m, lifetime: Tally(clicks: 5, ballMeters: 1e300, scrollMeters: 3)) }
    }
}
for a in ["9223372036854775807", "-9223372036854775808", "15", "5", "-1", "1e308", "\"x\"", "null", "[]"] {
    worker.run("low battery state announced=\(a) (regression: overflow crash)") {
        var alerts = (try? JSONDecoder().decode(LowBatteryAlerts.self, from: Data("{\"announced\":\(a)}".utf8))) ?? LowBatteryAlerts()
        for p in [100, 50, 14, 4, 0, 100, 3] { _ = alerts.update(percent: p) }
    }
}
worker.run("low battery state: saved thresholds still read") {
    let a = try? JSONDecoder().decode(LowBatteryAlerts.self, from: Data(#"{"announced":15}"#.utf8))
    check(a?.announced == 15, "low battery: a saved 15% notice was forgotten")
    check((try? JSONDecoder().decode(LowBatteryAlerts.self, from: JSONEncoder().encode(LowBatteryAlerts()))) == LowBatteryAlerts(),
          "low battery: the empty state doesn't round-trip")
}
for s in [String(big.prefix(1_000_000)), "GB-" + String(repeating: "AAAA-", count: 100_000), "GB-(.*)+$", ""] {
    worker.run("install id of \(s.count) characters") { check(!RandomID.isValid(s), "random id: junk accepted") }
}
endSection("daily totals, ledger, low-battery state")

// MARK: - 6. Crash reports

let crashFolder = appFolder.appendingPathComponent("DiagnosticReports", isDirectory: true)
try! fm.createDirectory(at: crashFolder, withIntermediateDirectories: true)
let home = fm.homeDirectoryForCurrentUser.path
func ips(header: String = #"{"bug_type":"309","app_version":"2.10","os_version":"macOS 26.1 (25B78)"}"#, body: String) -> Data {
    Data((header + "\n" + body).utf8)
}
func frameBody(symbol: String, extra: String = "") -> String {
    #"{"faultingThread":0,"threads":[{"frames":[{"imageIndex":0,"imageOffset":12,"symbol":"# + J.str(symbol).text
        + #"}]}],"usedImages":[{"name":"Glide"}],"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"#
        + #""termination":{"indicator":"Trace/BPT trap: 5"},"asi":{"libswiftCore":["Fatal error: x"]}"# + extra + "}"
}
var crashCases: [(String, Data)] = [
    ("normal", ips(body: frameBody(symbol: "Engine.tick()"))),
    ("paths and names", ips(body: frameBody(symbol: "\(home)/Code/x.swift /Users/jane/a /Volumes/My Disk/x jane@example.com \(NSUserName())"))),
    ("invisible characters splitting a path", ips(body: frameBody(symbol: "/Us\u{200B}ers/ja\u{202E}ne/x \(home.replacingOccurrences(of: "/", with: "/\u{0}"))"))),
    ("7 MB symbol, no spaces", ips(body: frameBody(symbol: String(big.prefix(7_000_000))))),
    ("7 MB of @", ips(body: frameBody(symbol: String(repeating: "a@", count: 3_500_000)))),
    ("7 MB of /Users/", ips(body: frameBody(symbol: String(repeating: "/Users/x", count: 800_000)))),
    ("7 MB of /Volumes/", ips(body: frameBody(symbol: String(repeating: "/Volumes/", count: 750_000)))),
    ("100,000 frames", ips(body: #"{"faultingThread":0,"threads":[{"frames":["# + Array(repeating: #"{"imageIndex":0,"imageOffset":1}"#, count: 100_000).joined(separator: ",") + #"]}],"usedImages":[{"name":"x"}]}"#)),
    ("odd numbers", ips(body: #"{"faultingThread":9223372036854775807,"threads":[{"triggered":true,"frames":[{"imageIndex":-5,"imageOffset":-9223372036854775808},{"imageIndex":1e300,"imageOffset":1e300},{"imageIndex":"0","imageOffset":null}]}],"usedImages":[{"name":7},{"name":null}]}"#)),
    ("faulting thread -1", ips(body: #"{"faultingThread":-1,"threads":[{"frames":[{"imageIndex":0}]}]}"#)),
    ("wrong types everywhere", ips(body: #"{"faultingThread":"x","threads":"y","usedImages":{},"exception":[],"termination":7,"asi":{"a":"b","c":[1,2]},"cpuType":[]}"#)),
    ("no newline", Data(#"{"bug_type":"309"}"#.utf8)),
    ("header only", ips(body: "")),
    ("not JSON", ips(header: "hello", body: "world")),
    ("a hang report", ips(header: #"{"bug_type":"288"}"#, body: frameBody(symbol: "x"))),
    ("invalid UTF-8", Data([0x7B, 0xFF, 0x0A, 0x7B, 0xC3, 0x28, 0x7D])),
    ("deep nesting", ips(body: String(repeating: "[", count: 100_000))),
    ("deep nesting in the header", ips(header: String(repeating: "{\"a\":", count: 100_000), body: "{}")),
    ("9 MB (over the cap)", ips(body: frameBody(symbol: String(big.prefix(9_000_000))))),
    ("a hostile os version", ips(header: "{\"bug_type\":\"309\",\"os_version\":\"\(String(repeating: "1.", count: 100_000))\",\"app_version\":\"\(String(big.prefix(100_000)))\"}", body: frameBody(symbol: "x"))),
]
beginSection()
for (i, (name, data)) in crashCases.enumerated() {
    let url = crashFolder.appendingPathComponent("glide-file-fuzz-\(i).ips")
    try! data.write(to: url)
    worker.run("crash report: \(name)") {
        guard let r = CrashReports.read(url, date: Date(), installID: "GB-TEST") else { return }
        let all = [r.version, r.build, r.os, r.arch, r.exception, r.signal, r.termination, r.reason, r.ownImage]
            + r.frames.flatMap { [$0.image, $0.symbol ?? ""] }
        for s in all {
            check(!s.contains(home) && !s.lowercased().contains("/users/jane") && !s.contains("jane@example.com"),
                  "crash report: \(name): something personal left in \(s.prefix(80))")
            check(NSUserName().count < 3 || !s.localizedCaseInsensitiveContains(NSUserName()), "crash report: \(name): the user name left in")
            check(s.count <= 600, "crash report: \(name): a field of \(s.count) characters")
        }
        check(r.frames.count <= 40, "crash report: \(name): \(r.frames.count) frames")
    }
}
for (label, target) in [("/dev/zero", "/dev/zero"), ("a pipe", fifo.path), ("a folder", outsideDir.path)] {
    let url = crashFolder.appendingPathComponent("link.ips")
    link(url, target)
    worker.run("crash report: a link to \(label) (regression: endless read)") {
        check(CrashReports.read(url, date: Date(), installID: "GB-TEST") == nil, "crash report: read through a link")
    }
}
worker.run("crash report: the faster email pattern takes out exactly what the old one did") {
    let old = #"[^\s@'"<>()]+@[^\s@'"<>()]+\.[A-Za-z]{2,}"#
    let new = #"(?<![^\s@'"<>()])[^\s@'"<>()]++@[^\s@'"<>()]+\.[A-Za-z]{2,}"#
    var gen = SystemRandomNumberGenerator()
    let alphabet = Array("ab@@..co m'\"<>()\n\tZ-_é")
    for _ in 0..<3000 {
        let s = String((0..<Int.random(in: 0...24, using: &gen)).map { _ in alphabet.randomElement(using: &gen)! })
        let a = s.replacingOccurrences(of: old, with: "(email)", options: [.regularExpression, .caseInsensitive])
        let b = s.replacingOccurrences(of: new, with: "(email)", options: [.regularExpression, .caseInsensitive])
        if a != b { return fail("crash report: email patterns differ on \(s.debugDescription): \(a.debugDescription) vs \(b.debugDescription)") }
    }
}
endSection("crash reports")

// MARK: - 7. Random mutations of valid files

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
let seeds = normalConfigs.map { J(data: fileData($0.1)) } + [J(data: try! JSONEncoder().encode(GlideSettingsFile(config: richConfig())))]
let shareSeeds = shareFiles.map { J(data: $0.1) }
let rawValues = weirdNumbers + ["\"\"", "\"\(String(repeating: "z", count: 300))\"", "{\"gesture\":{\"_0\":{}}}", actionJSON(.gesture(.media)),
                                "[1,2,3]", "-0.0", "1e-5", "33", "31", "-2", "4294967296", "18446744073709551616", nestedGesture(20)]

func randomValue() -> J {
    switch Int.random(in: 0..<6, using: &rng) {
    case 0: return .raw(rawValues.randomElement(using: &rng)!)
    case 1: return .num([Double.random(in: -1e6...1e6, using: &rng), Double(Int.random(in: -40...40, using: &rng)), 1e308, -1e308, 5e-324].randomElement(using: &rng)!)
    case 2: return .str(oddNames.randomElement(using: &rng)!)
    case 3: return .bool(Bool.random(using: &rng))
    case 4: return .null
    default: return .arr((0..<Int.random(in: 0...3, using: &rng)).map { _ in .num(Double(Int.random(in: -2...40, using: &rng))) })
    }
}

func mutate(_ base: J) -> Data {
    var tree = base
    for _ in 0..<Int.random(in: 1...4, using: &rng) {
        let paths = tree.paths()
        let path = paths.randomElement(using: &rng)!
        switch Int.random(in: 0..<7, using: &rng) {
        case 0, 1: tree = tree.replacing(path[...], with: randomValue()) ?? tree
        case 2: tree = tree.replacing(path[...], with: nil) ?? tree
        case 3:   // repeat an array's element many times
            if case .arr(let a)? = tree.at(path[...]), let x = a.first {
                tree = tree.replacing(path[...], with: .arr(Array(repeating: x, count: Int.random(in: 2...300, using: &rng)))) ?? tree
            }
        case 4:   // wrap in arrays
            if let node = tree.at(path[...]) {
                var n = node
                for _ in 0..<Int.random(in: 1...700, using: &rng) { n = .arr([n]) }
                tree = tree.replacing(path[...], with: n) ?? tree
            }
        case 5:   // graft another node here
            if let other = tree.at(paths.randomElement(using: &rng)![...]) { tree = tree.replacing(path[...], with: other) ?? tree }
        default:  // an unknown key
            if case .obj(var d)? = tree.at(path[...]) {
                d["zz\(Int.random(in: 0...9, using: &rng))"] = randomValue()
                tree = tree.replacing(path[...], with: .obj(d)) ?? tree
            }
        }
    }
    var data = tree.data
    if Int.random(in: 0..<5, using: &rng) == 0, !data.isEmpty {   // byte damage
        for _ in 0..<Int.random(in: 1...8, using: &rng) {
            let i = Int.random(in: 0..<data.count, using: &rng)
            switch Int.random(in: 0..<3, using: &rng) {
            case 0: data[i] = UInt8.random(in: 0...255, using: &rng)
            case 1: data = data.prefix(i)
            default: data.insert(contentsOf: [UInt8](repeating: UInt8.random(in: 0...255, using: &rng), count: Int.random(in: 1...4, using: &rng)), at: i)
            }
            if data.isEmpty { break }
        }
    }
    return data
}

beginSection()
let fuzzEnd = Date().addingTimeInterval(deep ? 180 : 1)
var mutations = 0, accepted = 0, syncRuns = 0
let local = richConfig()
while Date() < fuzzEnd {
    mutations += 1
    let base = seeds.randomElement(using: &rng)!
    let data = mutate(base)
    let n = mutations
    if n % 4 == 0 {   // a shared setup, through ImportFile and the share preview's Apply
        let share = mutate(shareSeeds.randomElement(using: &rng)!)
        worker.run("share mutation \(n) (seed \(seed))") {
            if case .share(let s)? = try? ImportFile.parse(share) {
                accepted += 1
                assertImported(sharedApplied(s, to: local), from: local, "share mutation \(n) (seed \(seed))")
            }
        }
    }
    worker.run("mutation \(n) (seed \(seed))") {
        guard let f = try? GlideSettingsFile.decode(data), let c = try? f.validatedConfig() else { return }
        accepted += 1
        assertInLimits(c, "mutation \(n) (seed \(seed))")
        let merged = c.keepingNewerFeatures(from: local).config
        if let p = limitsProblem(merged) { fail("mutation \(n) (seed \(seed)): merged with this Mac's out of limits: \(p)") }
        let mergedBack = local.keepingNewerFeatures(from: c).config
        if let p = limitsProblem(mergedBack) { fail("mutation \(n) (seed \(seed)): this Mac's merged with it out of limits: \(p)") }
    }
    if n % 25 == 0 { backupContentCase("mutation \(n) (seed \(seed))", data) }
    if deep && n % 150 == 0 {
        syncRuns += 1
        let wrapped = shared(String(decoding: data, as: UTF8.self))
        syncCase("mutation \(n) (seed \(seed))", local: local, remote: wrapped, expect: .any)
    }
}
endSection("random mutations", "seed \(seed), \(mutations) files, \(accepted) accepted\(deep ? ", \(syncRuns) through sync" : "")")

print(failures == 0 ? "ALL GOOD" : "\(failures) FAILURES (seed \(seed))")
try? fm.removeItem(at: root)
exit(failures == 0 ? 0 : 1)
