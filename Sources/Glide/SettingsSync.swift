import AppKit
import CoreServices
import Observation

enum SyncStatus: Equatable {
    case off
    case unavailable(String)
    case syncing
    case upToDate(Date)
    case error(String)
}

/// A Mac that has synced Glide's settings.
struct SyncDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let lastSeen: Date
    let isThisMac: Bool
}

/// Keeps Glide's settings the same on all of the user's Macs.
///
/// Glide is signed locally and has no iCloud entitlements, so rather than CloudKit
/// it shares plain files through the user's iCloud Drive folder:
///
///     ~/Library/Mobile Documents/com~apple~CloudDocs/Glide/
///         settings.glide-settings    the settings, plus which Mac wrote them and when
///         devices/<deviceID>.json    one heartbeat per Mac, for the device list
///
/// The newest edit wins. The pause switch (`enabled`) stays per-Mac.
/// Call from the main thread; file I/O runs on a background queue because
/// iCloud may need to download a file before it can be read.
@Observable
final class SettingsSync {
    private(set) var isEnabled: Bool
    private(set) var status: SyncStatus
    /// Macs that have synced, newest first.
    private(set) var devices: [SyncDevice] = []

    /// The iCloud Drive folder exists and Glide can write to it.
    var iCloudDriveAvailable: Bool {
        let root = folder.deletingLastPathComponent().path
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: root)
    }

    static let unavailableMessage = String(localized: "Turn on iCloud Drive in System Settings → Apple Account → iCloud",
                                           comment: "Use the names System Settings shows in this language")

    private enum Keys {
        static let enabled = "GlideSyncEnabled"
        static let deviceID = "GlideDeviceID"
        static let lastStamp = "GlideSyncLastStamp"
        static let pendingChangeAt = "GlideSyncPendingChangeAt"
    }

    private let onRemoteConfig: (GlideConfig) -> Void
    private let folder: URL
    private let defaults: UserDefaults
    private let deviceID: String
    private let deviceName = Host.current().localizedName ?? "Mac"
    private let io = DispatchQueue(label: "com.leviholliday.glide.sync")

    /// This Mac's settings, as last reported by the app.
    @ObservationIgnored private var local: GlideConfig?
    /// The shared file version this Mac last wrote or adopted.
    @ObservationIgnored private var lastStamp: Stamp? {
        didSet { defaults.set(lastStamp.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.lastStamp) }
    }
    /// When this Mac's settings were last edited, until that edit is synced.
    @ObservationIgnored private var pendingChangeAt: Date? {
        didSet { defaults.set(pendingChangeAt, forKey: Keys.pendingChangeAt) }
    }
    @ObservationIgnored private var lastSyncedAt: Date?
    @ObservationIgnored private var lastHeartbeat: Date?
    @ObservationIgnored private var uploadWork: DispatchWorkItem?
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var poller: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// `onRemoteConfig` runs on the main thread with another Mac's settings, this Mac's
    /// `enabled` kept. `folder` and `defaults` are for tests.
    init(onRemoteConfig: @escaping (GlideConfig) -> Void, folder: URL? = nil, defaults: UserDefaults = .standard) {
        self.onRemoteConfig = onRemoteConfig
        self.folder = folder ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Glide", isDirectory: true)
        self.defaults = defaults
        let id = defaults.string(forKey: Keys.deviceID) ?? UUID().uuidString
        defaults.set(id, forKey: Keys.deviceID)
        deviceID = id
        let enabled = defaults.bool(forKey: Keys.enabled)
        isEnabled = enabled
        status = enabled ? .syncing : .off   // the app's first syncNow takes it from here
        lastStamp = defaults.data(forKey: Keys.lastStamp).flatMap { try? JSONDecoder().decode(Stamp.self, from: $0) }
        pendingChangeAt = defaults.object(forKey: Keys.pendingChangeAt) as? Date

        observers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { [weak self] _ in self?.check() },
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
                // Give the network a moment to come back.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.check() }
            },
        ]
        if isEnabled { startWatching() }
    }

    deinit {
        stopWatching()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: Public API

    /// Turning sync on adopts a newer copy from iCloud Drive if there is one, else uploads `current`.
    func setEnabled(_ on: Bool, current: GlideConfig) {
        guard on != isEnabled else {
            syncNow(current: current)
            return
        }
        local = current
        isEnabled = on
        defaults.set(on, forKey: Keys.enabled)
        if on {
            startWatching()
            check(userInitiated: true)
        } else {
            stopWatching()
            uploadWork?.cancel()
            status = .off
            devices = []
        }
    }

    /// Call on every settings change made on this Mac. Uploads once edits pause for a second.
    func localConfigChanged(_ config: GlideConfig) {
        let previous = local
        local = config
        // Pausing Glide is per-Mac, so it isn't an edit to sync.
        if let previous, Self.syncable(previous) == Self.syncable(config) { return }
        pendingChangeAt = Date()
        guard isEnabled else { return }
        uploadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.upload() }
        uploadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Checks iCloud Drive right away, adopting another Mac's newer settings or uploading ours.
    func syncNow(current: GlideConfig) {
        local = current
        check(userInitiated: true)
    }

    // MARK: Syncing

    /// Reads the shared file and reconciles it with this Mac's settings.
    private func check(userInitiated: Bool = false) {
        guard isEnabled, local != nil else { return }
        guard iCloudDriveAvailable else { return setStatus(.unavailable(Self.unavailableMessage)) }
        if userInitiated { setStatus(.syncing) }
        io.async { [self] in
            let remote = readRemote()
            let devices = readDevices()
            DispatchQueue.main.async { [self] in
                guard isEnabled else { return }
                setDevices(devices)
                reconcile(remote, userInitiated: userInitiated)
            }
        }
    }

    private func reconcile(_ remote: RemoteState, userInitiated: Bool) {
        guard isEnabled, let local else { return }
        switch remote {
        case .missing, .corrupt:
            upload()
        case .downloading:
            setStatus(.syncing)   // the folder watcher or the next poll picks it up
        case .failed(let message):
            setStatus(.error(message))
        case .found(let file):
            // Last writer wins: another Mac's write beats an older unsynced edit here.
            // A stamp we've seen before is our own write, or one we already adopted.
            let remoteIsNewer = pendingChangeAt.map { file.updatedAt > $0 } ?? true
            if file.stamp != lastStamp && remoteIsNewer {
                adopt(file, local: local)
            } else if pendingChangeAt != nil {
                upload()
            } else {
                markSynced(didSync: userInitiated)
            }
        }
    }

    private func adopt(_ file: SharedFile, local: GlideConfig) {
        uploadWork?.cancel()
        pendingChangeAt = nil
        lastStamp = file.stamp
        if Self.syncable(file.settings.config) != Self.syncable(local) {
            var config = file.settings.config
            config.enabled = local.enabled   // the pause switch stays per-Mac
            self.local = config
            onRemoteConfig(config)
        }
        markSynced(didSync: true)
    }

    /// Writes this Mac's settings to iCloud Drive, unless another Mac's newer edit got there first.
    private func upload() {
        uploadWork?.cancel()
        guard isEnabled, let local else { return }
        guard iCloudDriveAvailable else { return setStatus(.unavailable(Self.unavailableMessage)) }
        let changedAt = pendingChangeAt
        let file = SharedFile(settings: GlideSettingsFile(config: Self.syncable(local)),
                              updatedAt: changedAt ?? Date(), deviceID: deviceID, deviceName: deviceName)
        let known = lastStamp
        setStatus(.syncing)
        io.async { [self] in
            let current = readRemote()
            switch current {
            case .missing, .corrupt:
                break
            case .found(let other) where other.stamp == known || other.deviceID == deviceID
                                      || other.updatedAt <= file.updatedAt:
                break
            default:
                // Another Mac's newer edit, a copy still downloading, or a file we mustn't overwrite.
                DispatchQueue.main.async { [self] in reconcile(current, userInitiated: true) }
                return
            }
            do {
                try Self.write(Self.encoder.encode(file), to: settingsURL)
            } catch {
                DispatchQueue.main.async { [self] in
                    setStatus(.error(String(localized: "Couldn’t save settings to iCloud Drive: \(error.localizedDescription)")))
                }
                return
            }
            DispatchQueue.main.async { [self] in
                lastStamp = file.stamp
                if pendingChangeAt == changedAt { pendingChangeAt = nil }
                if isEnabled { markSynced(didSync: true) }
            }
        }
    }

    private func markSynced(didSync: Bool) {
        let now = Date()
        if didSync || lastSyncedAt == nil { lastSyncedAt = now }
        setStatus(.upToDate(lastSyncedAt ?? now))
        // Each sync refreshes this Mac's heartbeat; otherwise at most every 10 minutes.
        let heartbeatDue = lastHeartbeat.map { now.timeIntervalSince($0) > 600 } ?? true
        guard didSync || heartbeatDue else { return }
        lastHeartbeat = now
        io.async { [self] in
            try? writeHeartbeat()
            let devices = readDevices()
            DispatchQueue.main.async { [self] in if isEnabled { setDevices(devices) } }
        }
    }

    private func setStatus(_ new: SyncStatus) { if status != new { status = new } }
    private func setDevices(_ new: [SyncDevice]) { if devices != new { devices = new } }

    /// The part of a config that syncs: everything but the per-Mac pause switch.
    private static func syncable(_ config: GlideConfig) -> GlideConfig {
        var config = config
        config.enabled = true
        return config
    }

    // MARK: Watching for other Macs' changes

    private func startWatching() {
        guard stream == nil else { return }
        // FSEvents notices iCloud Drive updating the folder; polling backs it up.
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<SettingsSync>.fromOpaque(info).takeUnretainedValue().check()
        }, &context, [folder.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, 0)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
        poller = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.check() }
    }

    private func stopWatching() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        poller?.invalidate()
        poller = nil
    }

    // MARK: Files (on the io queue)

    private var settingsURL: URL { folder.appendingPathComponent("settings.glide-settings") }
    private var devicesURL: URL { folder.appendingPathComponent("devices", isDirectory: true) }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    private func readRemote() -> RemoteState {
        let data: Data
        do {
            switch try Self.read(settingsURL) {
            case .missing: return .missing
            case .downloading: return .downloading
            case .data(let contents): data = contents
            }
        } catch {
            return .failed(String(localized: "Couldn’t read settings from iCloud Drive: \(error.localizedDescription)"))
        }
        do {
            let file = try Self.decoder.decode(SharedFile.self, from: data)
            _ = try file.settings.validatedConfig()
            return .found(file)
        } catch {
            guard (try? JSONSerialization.jsonObject(with: data)) != nil else { return .corrupt }
            // JSON we can't understand most likely came from a newer Glide: leave it be.
            return .failed(String(localized: "Settings in iCloud Drive were saved by a newer version of Glide. Update Glide on this Mac to keep syncing."))
        }
    }

    private func readDevices() -> [SyncDevice] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: devicesURL.path)) ?? []
        // Include not-yet-downloaded ".<id>.json.icloud" stubs; reading asks iCloud for them.
        let files = Set(names.map { name in
            name.hasPrefix(".") && name.hasSuffix(".icloud") ? String(name.dropFirst().dropLast(7)) : name
        })
        return files.filter { $0.hasSuffix(".json") }.compactMap { name -> SyncDevice? in
            let url = devicesURL.appendingPathComponent(name)
            guard case .data(let data)? = try? Self.read(url),
                  let beat = try? Self.decoder.decode(Heartbeat.self, from: data) else { return nil }
            let id = url.deletingPathExtension().lastPathComponent
            return SyncDevice(id: id, name: beat.name, lastSeen: beat.lastSeen, isThisMac: id == deviceID)
        }
        .sorted { $0.lastSeen > $1.lastSeen }
    }

    private func writeHeartbeat() throws {
        let beat = Heartbeat(name: deviceName, lastSeen: Date())
        try Self.write(Self.encoder.encode(beat), to: devicesURL.appendingPathComponent("\(deviceID).json"))
    }

    /// Reads a file another Mac may have written. If iCloud hasn't downloaded it yet,
    /// asks for it and returns `.downloading`; the folder watcher or next poll reads it.
    private static func read(_ url: URL) throws -> FileRead {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            // Older iCloud Drive keeps undownloaded files as hidden ".<name>.icloud" stubs.
            let stub = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
            guard fileManager.fileExists(atPath: stub.path) else { return .missing }
            try? fileManager.startDownloadingUbiquitousItem(at: url)
            return .downloading
        }
        // Current iCloud Drive keeps them as "dataless" files, which the coordinated read downloads.
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if values?.ubiquitousItemDownloadingStatus == .notDownloaded {
            try? fileManager.startDownloadingUbiquitousItem(at: url)
        }
        var data: Data?
        var readError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { url in
            do { data = try Data(contentsOf: url) } catch { readError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let readError { throw readError }
        return data.map { .data($0) } ?? .missing
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var writeError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }
}

private extension SettingsSync {
    /// Identifies one write of the shared settings file.
    struct Stamp: Codable, Equatable {
        let deviceID: String
        let updatedAt: Date
    }

    /// `settings.glide-settings`: the portable settings file, plus which Mac wrote it and when.
    struct SharedFile: Codable {
        let settings: GlideSettingsFile
        let updatedAt: Date
        let deviceID: String
        let deviceName: String

        var stamp: Stamp { Stamp(deviceID: deviceID, updatedAt: updatedAt) }
    }

    /// `devices/<deviceID>.json`
    struct Heartbeat: Codable {
        let name: String
        let lastSeen: Date
    }

    enum RemoteState {
        case missing            // nothing shared yet
        case downloading        // iCloud is still fetching it
        case corrupt            // not even JSON: safe to replace
        case failed(String)     // unreadable, or from a newer Glide: leave it alone
        case found(SharedFile)
    }

    enum FileRead {
        case missing
        case downloading
        case data(Data)
    }
}
