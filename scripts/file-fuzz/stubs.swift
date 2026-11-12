import Foundation

// The few things the compiled files need from parts of the app the fuzzer
// doesn't build (ShareData pulls in AppModel and the whole UI).
enum ShareData {
    static var appInfo: [String: String] { ["version": "2.10", "build": "1"] }
    static var osVersion: String { "26.0" }
    static var arch: String { "arm64" }
}
