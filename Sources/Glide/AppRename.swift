import AppKit
import ServiceManagement

/// Glide was renamed Glideball in 2.8. The bundle ID, settings, permissions and
/// folders didn't change — only the app's name on disk, which this moves.
enum AppRename {
    static let oldName = "Glide.app"
    static let newName = "Glideball.app"

    /// Where an app at `url` should live: next to it, named Glideball.app.
    static func installPath(for url: URL) -> URL {
        url.lastPathComponent == oldName
            ? url.deletingLastPathComponent().appendingPathComponent(newName)
            : url
    }

    /// Run first thing at launch. If this copy is still called Glide.app (an update
    /// from 2.7 or earlier, which installs under the old name), rename it and
    /// relaunch from the new place. Returns true when it's relaunching.
    static func moveIfNeeded() -> Bool {
        let here = Bundle.main.bundleURL
        let target = installPath(for: here)
        guard target != here, !FileManager.default.fileExists(atPath: target.path) else { return false }
        let wasLoginItem = SMAppService.mainApp.status == .enabled
        do {
            try FileManager.default.moveItem(at: here, to: target)
        } catch {
            NSLog("Glideball: couldn't rename \(here.path): \(error)")   // e.g. no write access; keep running as is
            return false
        }
        if wasLoginItem { UserDefaults.standard.set(true, forKey: "GlideReRegisterLoginItem") }
        let pid = ProcessInfo.processInfo.processIdentifier
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"\(target.path)\""]
        guard (try? helper.run()) != nil else { return false }
        return true
    }

    /// After a rename, point Open at Login at the new location.
    static func finishLoginItem() {
        guard UserDefaults.standard.bool(forKey: "GlideReRegisterLoginItem") else { return }
        UserDefaults.standard.removeObject(forKey: "GlideReRegisterLoginItem")
        try? SMAppService.mainApp.unregister()
        try? SMAppService.mainApp.register()
    }
}
