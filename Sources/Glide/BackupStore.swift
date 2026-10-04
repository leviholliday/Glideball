import AppKit
import Observation

/// Automatic, tiny, self-pruning backups of Glide's settings.
///
/// Each backup is an ordinary `.glide-settings` file (compact JSON, ~2 KB) in
///
///     ~/Library/Application Support/Glide/Backups/
///
/// so it also opens in Glide with a double-click.
///
/// **When:** once a day — the first time Glide runs that day, before any change,
/// so a day's backup is how things were when the day began — plus a *checkpoint*
/// right before something replaces all your settings (an import, a restore) and
/// whenever you press Back Up Now. Nothing is written if the settings match the
/// newest backup, so a month without changes costs one file.
///
/// **How long** (see `prune`):
///   - every backup from the last 14 days (a week of dailies, kept another week);
///   - then the newest backup of each month;
///   - nothing older than a year — except the newest backup, which always stays
///     (with unchanged settings it's the only copy).
/// That caps the folder at roughly 30 files — well under 100 KB.
@Observable
final class BackupStore {
    enum Kind: String {
        case daily
        case beforeImport = "before import"
        case beforeRestore = "before restore"
        case manual = "saved by you"
    }

    struct Backup: Identifiable, Equatable {
        let url: URL
        let date: Date
        let kind: Kind
        let size: Int
        var id: URL { url }
    }

    /// Newest first.
    private(set) var backups: [Backup] = []
    private(set) var lastError: String?

    /// Per-Mac; on unless turned off on the Sync tab.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled, let current = currentConfig?() { snapshotIfDue(current) }
        }
    }

    var totalBytes: Int { backups.reduce(0) { $0 + $1.size } }

    static let enabledKey = "GlideAutoBackups"
    static let dailyWindowDays = 14
    static let keepDays = 365
    /// Checkpoints kept per day (the newest ones); dailies are one per day anyway.
    static let checkpointsPerDay = 5

    /// Supplies the live settings for timer-driven snapshots.
    @ObservationIgnored var currentConfig: (() -> GlideConfig)?

    private let folder: URL
    private let defaults: UserDefaults
    private let calendar: Calendar
    private let now: () -> Date
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    /// `folder`, `defaults`, `calendar` and `now` are for tests.
    init(folder: URL? = nil, defaults: UserDefaults = .standard,
         calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.folder = folder ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glide/Backups", isDirectory: true)
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        backups = scan()
    }

    deinit {
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    /// Takes today's backup if it's due, and checks again every half hour and on
    /// wake so a Mac that's never restarted still gets one each day.
    func start(current: GlideConfig) {
        snapshotIfDue(current)
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            guard let self, let config = self.currentConfig?() else { return }
            self.snapshotIfDue(config)
        }
        timer?.tolerance = 60
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let config = self.currentConfig?() else { return }
            self.snapshotIfDue(config)
        }
    }

    // MARK: Writing

    /// Call with the settings as they were *before* a change, so the first edit
    /// of a day can't sneak into that day's backup.
    func willChange(from old: GlideConfig) {
        snapshotIfDue(old)
    }

    /// Today's daily backup, unless today is already covered — by a backup taken
    /// today, or because the settings still match the newest backup.
    func snapshotIfDue(_ config: GlideConfig) {
        guard isEnabled else { return }
        let today = calendar.startOfDay(for: now())
        guard coveredDay != today else { return }   // cheap: called on every settings change
        if backups.contains(where: { $0.kind == .daily && calendar.isDate($0.date, inSameDayAs: today) })
            || !write(config, kind: .daily) {
            prune()   // a new day ages everything, even when nothing is written
        }
        if lastError == nil { coveredDay = today }
    }

    /// A checkpoint before something replaces every setting, or on request.
    /// Written even with automatic backups off, so a restore can always be undone.
    @discardableResult
    func checkpoint(_ config: GlideConfig, kind: Kind) -> Bool {
        write(config, kind: kind, force: kind == .manual)
    }

    /// The day whose start-of-day settings are already safe on disk.
    @ObservationIgnored private var coveredDay: Date?
    /// The newest backup's settings, so most writes needn't read the disk.
    @ObservationIgnored private var newestConfig: (url: URL, config: GlideConfig)?

    /// Writes a backup unless the newest one already holds these settings
    /// (`force`, for Back Up Now, writes anyway so the button always does something).
    @discardableResult
    private func write(_ config: GlideConfig, kind: Kind, force: Bool = false) -> Bool {
        var config = config
        config.enabled = true   // the pause switch isn't a setting worth restoring
        if !force, let newest = backups.first {
            let saved = newestConfig?.url == newest.url ? newestConfig?.config : load(newest)
            if saved == config { return false }
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var url = folder.appendingPathComponent(Self.fileName(for: now(), kind: kind))
            if FileManager.default.fileExists(atPath: url.path) {   // two in the same second
                url = folder.appendingPathComponent(Self.fileName(for: now().addingTimeInterval(1), kind: kind))
            }
            try Self.encode(config).write(to: url, options: .atomic)
            newestConfig = (url, config)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            NSLog("Glide: backup failed: \(error)")
            return false
        }
        prune()
        return true
    }

    // MARK: Reading

    func load(_ backup: Backup) -> GlideConfig? {
        if let cached = loaded[backup.url] { return cached }
        guard let data = try? Data(contentsOf: backup.url),
              let file = try? Self.decode(data),
              var config = try? file.validatedConfig() else { return nil }
        config.enabled = true
        loaded[backup.url] = config   // backups never change once written
        return config
    }

    @ObservationIgnored private var loaded: [URL: GlideConfig] = [:]

    func reload() { backups = scan() }

    func revealInFinder(_ backup: Backup? = nil) {
        if let backup {
            NSWorkspace.shared.activateFileViewerSelecting([backup.url])
        } else {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }

    private func scan() -> [Backup] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url -> Backup? in
            guard url.pathExtension == GlideSettingsFile.fileExtension,
                  let (date, kind) = Self.parse(url.deletingPathExtension().lastPathComponent) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Backup(url: url, date: date, kind: kind, size: size)
        }
        .sorted { $0.date > $1.date }
    }

    // MARK: Retention

    /// Applies the retention rules and refreshes `backups`.
    func prune() {
        let all = scan()
        for backup in Self.expired(all, now: now(), calendar: calendar) {
            try? FileManager.default.removeItem(at: backup.url)
        }
        backups = scan()
    }

    /// The backups the retention rules no longer keep. Pure, for testing.
    static func expired(_ backups: [Backup], now: Date, calendar: Calendar) -> [Backup] {
        let sorted = backups.sorted { $0.date > $1.date }
        guard let newest = sorted.first else { return [] }
        let today = calendar.startOfDay(for: now)
        var keep: Set<URL> = [newest.url]
        var checkpointsByDay: [Date: Int] = [:]
        var monthsSeen: Set<DateComponents> = []

        for backup in sorted {   // newest first, so "first seen" = newest of its group
            let day = calendar.startOfDay(for: backup.date)
            let age = max(calendar.dateComponents([.day], from: day, to: today).day ?? 0, 0)
            if age < dailyWindowDays {
                if backup.kind == .daily {
                    keep.insert(backup.url)
                } else {
                    let n = checkpointsByDay[day, default: 0]
                    if n < checkpointsPerDay { keep.insert(backup.url) }
                    checkpointsByDay[day] = n + 1
                }
            } else if age <= keepDays {
                let month = calendar.dateComponents([.year, .month], from: backup.date)
                if monthsSeen.insert(month).inserted { keep.insert(backup.url) }
            }
        }
        return sorted.filter { !keep.contains($0.url) }
    }

    // MARK: Files

    static func encode(_ config: GlideConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]   // compact: no indentation
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(GlideSettingsFile(config: config))
    }

    static func decode(_ data: Data) throws -> GlideSettingsFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GlideSettingsFile.self, from: data)
    }

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    /// "2026-10-04 09.12.30" or "2026-10-04 09.12.30 before import".
    static func fileName(for date: Date, kind: Kind) -> String {
        let stamp = stampFormat.string(from: date)
        let name = kind == .daily ? stamp : "\(stamp) \(kind.rawValue)"
        return "\(name).\(GlideSettingsFile.fileExtension)"
    }

    static func parse(_ name: String) -> (Date, Kind)? {
        guard name.count >= 19, let date = stampFormat.date(from: String(name.prefix(19))) else { return nil }
        let rest = name.dropFirst(19).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { return (date, .daily) }
        guard let kind = Kind(rawValue: rest) else { return nil }
        return (date, kind)
    }
}
