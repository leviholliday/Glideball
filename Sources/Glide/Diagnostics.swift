import Foundation
import QuartzCore

/// A rolling, timestamped log of scroll input and output, written to
/// ~/Library/Logs/Glide/scroll.log. Used only on the engine's input thread;
/// flushed from the engine's maintenance timer so logging never blocks input.
final class Diagnostics {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Glide")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scroll.log")
    }()

    private var lines: [String] = []
    private var dirty = false
    private let start = CACurrentMediaTime()
    private let maxLines = 6000

    /// The previous launch's log, kept so a report sent after a relaunch or
    /// crash still has something in it.
    static var previousURL: URL { url.deletingLastPathComponent().appendingPathComponent("scroll-previous.log") }

    init() {
        let fm = FileManager.default
        if ((try? Self.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 {
            try? fm.removeItem(at: Self.previousURL)
            try? fm.moveItem(at: Self.url, to: Self.previousURL)
        }
        try? Data().write(to: Self.url)
    }

    /// This launch's log if it has anything, otherwise the previous launch's.
    static var latestNonEmpty: URL? {
        [url, previousURL].first { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 }
    }

    func record(_ message: @autoclosure () -> String) {
        let t = (CACurrentMediaTime() - start) * 1000
        lines.append(String(format: "%10.1f  ", t) + message())
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        dirty = true
    }

    func flush() {
        guard dirty else { return }
        dirty = false
        try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: Self.url, options: .atomic)
    }
}
