import AppKit
import ObjectiveC

/// `--render-ui` and `--self-test` run Glideball's real code with nothing live,
/// so they're safe while the installed Glideball is running and owns the trackball.
///
/// In either mode:
///   - no `Engine.start()`: no event tap, no IOHIDManager, no input thread, no
///     `PointerTuner` writes (AppModel's init returns before them; Engine's
///     `perform` does nothing on an engine that was never started);
///   - `UserDefaults.standard` is an in-memory store (`MemoryDefaults`, swapped in
///     before anything reads it), so the real settings are never read or written;
///   - backups, the iCloud Drive sync folder and the scroll log live in a temp
///     folder that's deleted at exit; sync, backups' timers and update checks
///     aren't started;
///   - every URLSession.shared request is answered here (`SandboxURLProtocol`),
///     never by the network; ShareData and Send Feedback refuse to send;
///   - no global hot keys, no menu-bar icon, no sounds or haptics, no login-item
///     changes, no AppRename, no windows on screen (the activation policy is
///     `.prohibited`, and nothing is ordered front).
///
/// Every guard in the app is a `Sandbox.isActive` check, so `grep Sandbox.isActive`
/// lists them. The modes refuse to run as the real app (bundle ID
/// `com.leviholliday.glide`): run them from a copy made by
/// `scripts/render-ui.sh` / `scripts/self-test.sh`, or the bare binary.
enum Sandbox {
    enum Mode { case renderUI, selfTest }

    static let mode: Mode? = {
        let args = CommandLine.arguments
        if args.contains("--render-ui") { return .renderUI }
        if args.contains("--self-test") { return .selfTest }
        return nil
    }()

    static var isActive: Bool { mode != nil }

    static let realBundleID = "com.leviholliday.glide"

    /// The in-memory settings both modes use instead of the real ones.
    static let defaults = MemoryDefaults()

    /// A fresh temp folder for anything that must be written; removed at exit.
    static let folder: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlideballSandbox-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Where `BackupStore` and `SettingsSync` keep their files here; nil in the real app.
    static var backupsFolder: URL? { isActive ? folder.appendingPathComponent("Backups", isDirectory: true) : nil }
    static var syncFolder: URL? {
        isActive ? folder.appendingPathComponent("Mobile Documents/com~apple~CloudDocs/Glide", isDirectory: true) : nil
    }

    /// Call first thing in main.swift. Does nothing in the real app.
    static func enter() {
        guard isActive else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        if Bundle.main.bundleIdentifier == realBundleID {
            print("""
            error: --render-ui and --self-test don't run as the real Glideball (\(realBundleID)).
                   Use scripts/render-ui.sh or scripts/self-test.sh, which run a copy with its own bundle ID.
            """)
            exit(2)
        }
        swapStandardDefaults()
        Diagnostics.folder = folder.appendingPathComponent("Logs", isDirectory: true)
        atexit { try? FileManager.default.removeItem(at: Sandbox.folder) }
        URLProtocol.registerClass(SandboxURLProtocol.self)
        guard networkIsLocal() else {
            print("error: URLSession.shared requests aren't being answered locally; stopping before anything could reach the network")
            exit(2)
        }
    }

    /// Proves that a URLSession.shared request is answered by `SandboxURLProtocol`,
    /// using a name that can't exist (`.invalid`) in case it isn't.
    private static func networkIsLocal() -> Bool {
        let probe = URL(string: "https://sandbox-probe.invalid/")!
        SandboxURLProtocol.responder = { $0.url == probe ? .init(status: 204) : nil }
        defer { SandboxURLProtocol.responder = nil }
        let answered = DispatchSemaphore(value: 0)
        var status = 0
        URLSession.shared.dataTask(with: probe) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
            answered.signal()
        }.resume()
        guard answered.wait(timeout: .now() + 5) == .success else { return false }
        return status == 204
    }

    /// From here on `UserDefaults.standard` (ours, SwiftUI's and AppKit's) is `defaults`.
    private static func swapStandardDefaults() {
        guard let method = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults")) else {
            print("error: couldn't redirect UserDefaults.standard; stopping before anything touches the real settings")
            exit(2)
        }
        let memory = defaults
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in memory }
        method_setImplementation(method, imp_implementationWithBlock(block))
        guard UserDefaults.standard === memory else {
            print("error: UserDefaults.standard is still the real one; stopping")
            exit(2)
        }
    }

    /// Spins the main run loop (timers, async blocks, SwiftUI updates) for a while.
    static func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

/// UserDefaults that live only in memory: nothing is read from or written to
/// disk. Every typed getter and setter (`bool(forKey:)`, `set(_: Double, …)`…)
/// goes through `object(forKey:)` / `set(_:forKey:)`, which these override.
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]
    private let lock = NSLock()

    init() {
        // A suite name that's never written to: every write is overridden below.
        super.init(suiteName: "com.leviholliday.glide.sandbox.memory")!
    }

    override func object(forKey key: String) -> Any? {
        lock.withLock { values[key] ?? registered[key] }
    }

    override func set(_ value: Any?, forKey key: String) {
        lock.withLock { values[key] = value }
    }

    override func removeObject(forKey key: String) {
        lock.withLock { values[key] = nil }
    }

    override func register(defaults registrationDictionary: [String: Any]) {
        lock.withLock { registered.merge(registrationDictionary) { _, new in new } }
    }

    override func dictionaryRepresentation() -> [String: Any] {
        lock.withLock { registered.merging(values) { _, new in new } }
    }

    override func persistentDomain(forName domainName: String) -> [String: Any]? {
        lock.withLock { values }
    }

    override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {
        lock.withLock { values = domain }
    }

    override func removePersistentDomain(forName domainName: String) {
        lock.withLock { values = [:] }
    }

    override func synchronize() -> Bool { true }
}

/// Answers every http(s) request made through URLSession.shared — today that's
/// only the update check and the update download — so nothing reaches the
/// network. `responder` decides the answer; by default, "not connected".
final class SandboxURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var body = Data()
        /// Sends this many bytes, then never finishes (a download in progress).
        var stallAfter: Int?
        /// Waits this long before answering (a check in progress).
        var delay: Double = 0
    }

    /// nil = fail as if offline.
    nonisolated(unsafe) static var responder: ((URLRequest) -> Reply?)?
    /// Every URL asked for, for the self-test.
    nonisolated(unsafe) static var requested: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool {
        ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var stopped = false
    private var reply = Reply()
    /// The thread URLSession started this load on: every client call must happen there.
    private var thread: Thread?
    nonisolated(unsafe) private static var stalledLoads: [SandboxURLProtocol] = []
    private static let lock = NSLock()

    override func startLoading() {
        let request = self.request
        if let url = request.url, url.host != "sandbox-probe.invalid" { Self.lock.withLock { Self.requested.append(url) } }
        guard let reply = Self.responder?(request), request.url != nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        self.reply = reply
        thread = Thread.current
        if reply.delay > 0 {
            perform(#selector(sendReply), with: nil, afterDelay: reply.delay,
                    inModes: [.default, .common])
        } else {
            sendReply()
        }
    }

    @objc private func sendReply() {
        guard !stopped, let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(reply.body.count)",
                                                      "Content-Type": "application/octet-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let stall = reply.stallAfter {
            client?.urlProtocol(self, didLoad: reply.body.prefix(stall))
            Self.lock.withLock { Self.stalledLoads.append(self) }
            return   // finishes only when `failStalled()` cuts it off
        }
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Cuts off every download left hanging by `Reply.stallAfter`, as a lost connection would.
    static func failStalled() {
        let loads = lock.withLock { () -> [SandboxURLProtocol] in
            defer { stalledLoads = [] }
            return stalledLoads
        }
        for load in loads {
            guard let thread = load.thread else { continue }
            load.perform(#selector(failLoad), on: thread, with: nil, waitUntilDone: false)
        }
    }

    @objc private func failLoad() {
        guard !stopped else { return }
        client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost, userInfo: [
            NSLocalizedDescriptionKey: "The network connection was lost."]))
    }

    override func stopLoading() { stopped = true }
}
