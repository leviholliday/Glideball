import AppKit

// The few things UpdateChecker.swift needs from parts of the app the fuzzer doesn't build.
enum EarlyUpdates {
    static var isEnabled: Bool { false }
}

enum AppRename {
    static func installPath(for url: URL) -> URL { url }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func quitNow() {}
}
