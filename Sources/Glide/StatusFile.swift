import Foundation

// status.json: the read side of glideball:// (URLs are one-way). Raycast or a
// script reads ~/Library/Application Support/Glide/status.json to show what
// Glideball is doing. It exists only while "Allow Raycast and scripts" is on;
// turning that off, or quitting, deletes it. Its fields are documented in
// docs/DEVELOPING.md; bump `schemaVersion` when one changes meaning or goes away
// (adding a field doesn't need a bump).
//
// Foundation only, so scripts/command-sim can check it.

/// Everything in status.json, and nothing else: no app names besides the
/// active setup's, no history, nothing typed.
struct GlideStatus: Codable, Equatable {
    static let currentSchema = 1

    struct Modes: Codable, Equatable {
        var precision = false
        var ballScroll = false
        var dragLock = false
    }

    struct AppSetup: Codable, Equatable {
        var name: String
        /// Chosen with glideball://app-setup, rather than because its app is in front.
        var pinned: Bool
    }

    struct Today: Codable, Equatable {
        var clicks = 0
        var ballMeters = 0.0
        var scrollMeters = 0.0
    }

    var schemaVersion = GlideStatus.currentSchema
    var appVersion = ""
    /// The running Glideball's process ID, so a reader can tell a file left by a crash.
    var pid: Int32 = 0
    var paused = false
    var trackballConnected = false
    /// The trackball Glideball is working with, if one's connected.
    var trackballs: [String] = []
    /// The main setup's (what glideball://scroll-mode and pointer-speed change).
    var scrollMode = ""
    var pointerSpeed = 0.0
    var modes = Modes()
    /// The app setup in effect right now, or null for the main setup.
    var activeAppSetup: AppSetup?
    var today = Today()
    /// ISO 8601, UTC.
    var updatedAt = ""

    /// Equal apart from when it was made: nothing to write.
    func sameState(as other: GlideStatus) -> Bool {
        var a = self, b = other
        a.updatedAt = ""
        b.updatedAt = ""
        return a == b
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Rounds distances so a tiny nudge of the ball isn't a new file.
    static func rounded(_ meters: Double) -> Double { (meters * 100).rounded() / 100 }

    static func timestamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

/// Writes status.json when asked, at most once every `minInterval` and only when
/// something changed, off the main thread (and never on the input thread).
/// Main thread, except the writing itself.
final class StatusFileWriter {
    let url: URL
    var minInterval = 1.0
    private let snapshot: () -> GlideStatus
    private let now: () -> Double
    private let queue = DispatchQueue(label: "com.leviholliday.glide.status-file", qos: .utility)
    private var lastWritten: GlideStatus?
    private var lastWriteTime = -Double.infinity
    private var scheduled = false
    private var active = true
    /// How many times the file was written (for scripts/command-sim).
    private(set) var writes = 0

    init(url: URL, now: @escaping () -> Double, snapshot: @escaping () -> GlideStatus) {
        self.url = url
        self.now = now
        self.snapshot = snapshot
    }

    /// Something may have changed: write soon, no sooner than `minInterval` after the last write.
    func setNeedsWrite() {
        guard active, !scheduled else { return }
        let wait = max(0, lastWriteTime + minInterval - now())
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.writeIfChanged()
        }
    }

    /// Writes now if the state differs from the file's. Returns whether it wrote.
    @discardableResult
    func writeIfChanged() -> Bool {
        guard active else { return false }
        var status = snapshot()
        if let lastWritten, status.sameState(as: lastWritten) { return false }
        status.updatedAt = GlideStatus.timestamp()
        guard let data = try? status.encoded() else { return false }
        lastWritten = status
        lastWriteTime = now()
        writes += 1
        let url = self.url
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)   // a temp file, then a rename: readers never see half a file
        }
        return true
    }

    /// Stops writing and deletes the file, after any write already on its way.
    /// `wait`: return only once it's gone (quitting).
    func stopAndRemove(wait: Bool = false) {
        active = false
        let url = self.url
        let remove = { try? FileManager.default.removeItem(at: url) }
        if wait { queue.sync { _ = remove() } } else { queue.async { _ = remove() } }
    }
}
