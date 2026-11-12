import Foundation

/// Glideball's crashes, from macOS's own crash reports, for people who chose
/// to send them (see `ShareData`).
///
/// Why not MetricKit or a crash handler of our own: whenever any app crashes,
/// macOS's ReportCrash writes an .ips report to ~/Library/Logs/DiagnosticReports,
/// signed or not, App Store or not, with the stack already symbolicated where
/// the binary has symbols. Glideball isn't sandboxed, so it can read its own on
/// the next launch. MetricKit's crash diagnostics arrive on Apple's schedule
/// (up to a day later) and nothing promises them for a self-signed app outside
/// the App Store; a signal handler can't safely do much more than write a
/// marker, and would sit next to the engine's own SIGTERM handling.
///
/// Only a small part of a report is sent: the kind of crash, how the process
/// ended, the message Swift or the system left (if any), and the stack of the
/// thread that crashed (library names, function names and offsets). Paths,
/// the user's name, the Mac's identifiers and the rest of the report stay here.
enum CrashReports {
    struct Report: Encodable {
        var installId: String
        var crashedAt: String
        var version: String
        var build: String
        var os: String
        var arch: String
        var exception: String
        var signal: String
        var termination: String
        var reason: String
        var ownImage: String
        var frames: [Frame]

        struct Frame: Encodable {
            var image: String
            var symbol: String?
            var offset: Int
        }
    }

    static var folders: [URL] {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        return [logs, logs.appendingPathComponent("Retired")]
    }

    /// The executable's name ("Glide"), which is what macOS names the reports after.
    static var executableName: String { Bundle.main.executableURL?.lastPathComponent ?? "Glide" }

    /// Glideball's crash reports written after `since`, oldest first, with when each was written.
    static func find(after since: Date) -> [(url: URL, date: Date)] {
        let fm = FileManager.default
        let prefix = executableName + "-"
        var found: [(URL, Date)] = []
        for folder in folders {
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where name.hasPrefix(prefix) && name.hasSuffix(".ips") {
                let url = folder.appendingPathComponent(name)
                guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      date > since else { continue }
                found.append((url, date))
            }
        }
        return found.sorted { $0.1 < $1.1 }
    }

    /// The part of one .ips report that's sent, or nil if it isn't a crash of
    /// this app (a hang, another app with the same name, something unreadable).
    static func read(_ url: URL, date: Date, installID: String) -> Report? {
        guard let data = try? SafeRead.data(url, limit: 8_000_000),
              let text = String(data: data, encoding: .utf8),
              let newline = text.firstIndex(of: "\n"),
              let header = json(String(text[..<newline])),
              let body = json(String(text[text.index(after: newline)...])) else { return nil }
        // 309 is a crash; anything else (hangs, resource reports) isn't sent.
        guard header["bug_type"] as? String == "309" else { return nil }
        if let id = header["bundleID"] as? String, id != Bundle.main.bundleIdentifier { return nil }

        let exception = body["exception"] as? [String: Any] ?? [:]
        let termination = body["termination"] as? [String: Any] ?? [:]
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { image in
            clean(image["name"] as? String ?? "", allowed: imageCharacters, max: 64)
        }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int ?? threads.firstIndex { ($0["triggered"] as? Bool) == true } ?? 0
        let rawFrames = threads.indices.contains(faulting) ? threads[faulting]["frames"] as? [[String: Any]] ?? [] : []
        let frames: [Report.Frame] = rawFrames.prefix(40).map { f in
            let index = f["imageIndex"] as? Int ?? -1
            let image = images.indices.contains(index) && !images[index].isEmpty ? images[index] : "unknown"
            let symbol = (f["symbol"] as? String).map { scrub($0, max: 200) }
            return .init(image: image, symbol: symbol?.isEmpty == false ? symbol : nil, offset: max(0, f["imageOffset"] as? Int ?? 0))
        }
        guard !frames.isEmpty else { return nil }

        // What Swift or the system left behind ("Fatal error: Index out of range").
        let asi = body["asi"] as? [String: Any] ?? [:]
        let messages = asi.values.flatMap { $0 as? [String] ?? [] }
        let app = ShareData.appInfo
        let os = (header["os_version"] as? String).flatMap(osNumber) ?? ShareData.osVersion
        let cpu = (body["cpuType"] as? String ?? "").uppercased()

        return Report(
            installId: installID,
            crashedAt: ISO8601DateFormatter().string(from: date),
            version: clean(header["app_version"] as? String ?? "", allowed: versionCharacters, max: 32).nonEmpty ?? app["version"] ?? "",
            build: clean(header["build_version"] as? String ?? "", allowed: .decimalDigits, max: 10).nonEmpty ?? app["build"] ?? "",
            os: os,
            arch: cpu.contains("X86") ? "x86_64" : cpu.contains("ARM") ? "arm64" : ShareData.arch,
            exception: clean(exception["type"] as? String ?? "", allowed: exceptionCharacters, max: 40).nonEmpty ?? "UNKNOWN",
            signal: clean(exception["signal"] as? String ?? "", allowed: exceptionCharacters, max: 16),
            termination: scrub(termination["indicator"] as? String ?? "", max: 120),
            reason: scrub(messages.prefix(3).joined(separator: " · "), max: 600),
            ownImage: clean(executableName, allowed: imageCharacters, max: 64),
            frames: frames)
    }

    // MARK: Taking out what isn't needed

    private static func json(_ s: String) -> [String: Any]? {
        let data = Data(s.utf8)
        guard (try? SafeRead.checkDepth(data)) != nil else { return nil }   // deep nesting overflows the stack
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func osNumber(_ s: String) -> String? {
        // "macOS 26.3 (25D125)" → "26.3"
        guard let r = s.range(of: #"\d{1,3}(\.\d{1,3}){0,2}"#, options: .regularExpression) else { return nil }
        return String(s[r])
    }

    private static let imageCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+ -")
    private static let versionCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+-")
    private static let exceptionCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")

    /// Only the allowed characters (others become "_"), at most `max` of them.
    static func clean(_ s: String, allowed: CharacterSet, max: Int) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { allowed.contains($0) ? $0 : "_" })
            .prefix(max)).trimmingCharacters(in: .whitespaces)
    }

    /// Anything that could name the person or their files, taken out: their
    /// home folder and user name, other people's home folders, other
    /// volumes, and email addresses. The same rules as the server's own
    /// `scrub` (website/netlify/lib/usage.mjs), which runs again on arrival.
    static func scrub(_ s: String, max: Int) -> String {
        // Invisible characters first (control, zero-width, right-to-left marks),
        // so none can split a path or an address to slip it past what follows.
        // Then far more than can survive the cut to `max` below, but not megabytes: the
        // replacements take seconds on a few MB (scripts/file-fuzz). Replacements shorten
        // text 50 times over only for made-up input, never for a real report.
        var out = String(String.UnicodeScalarView(s.unicodeScalars.lazy.filter { !isInvisible($0) }.prefix(max * 50)))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if home.count > 1 { out = out.replacingOccurrences(of: home, with: "~", options: .caseInsensitive) }
        // macOS folders match in any case (/users/jane is /Users/jane), and a drive's
        // name can have spaces in it ("Jane's Passport"): all of it, up to the next folder.
        for (pattern, replacement) in [(#"/(Users|home)/[^/\s:")]+"#, "/$1/~"),
                                       (#"/Volumes/[^/\n]+"#, "/Volumes/~"),
                                       // An address only starts where a run of address characters
                                       // does (the lookbehind), and `++` never backtracks: the same
                                       // matches as `[^…]+@…`, but linear, where that took minutes on
                                       // a few MB without spaces (scripts/file-fuzz).
                                       (#"(?<![^\s@'"<>()])[^\s@'"<>()]++@[^\s@'"<>()]+\.[A-Za-z]{2,}"#, "(email)")] {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        for name in [NSUserName(), NSFullUserName()] where name.count >= 3 {
            out = out.replacingOccurrences(of: name, with: "(name)", options: .caseInsensitive)
        }
        // One line: line breaks and tabs become spaces.
        let flat = out.unicodeScalars.map { $0 == "\n" || $0 == "\t" ? " " : $0 }
        return String(String.UnicodeScalarView(flat).prefix(max)).trimmingCharacters(in: .whitespaces)
    }

    /// Control characters (but not line breaks and tabs) and invisible format
    /// characters: zero-width spaces and joiners, direction marks and overrides.
    static func isInvisible(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x09, 0x0A: return false
        case 0x00...0x1F, 0x7F...0x9F: return true
        default: return c.properties.generalCategory == .format
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
