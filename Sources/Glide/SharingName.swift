import Foundation
import Observation

/// The name someone may put on what they share ("Levi’s Glideball setup"). Optional,
/// asked for in the Welcome Tour and changed in Settings › General › Sharing.
///
/// Where it lives and where it never goes:
///  - In this Mac's UserDefaults only (three keys below). It isn't part of
///    `GlideConfig`, so it's never synced to other Macs, never in a backup and
///    never in an exported settings file.
///  - It's never in the opt-in stats (`ShareData.Stats` has no field for it) or a
///    crash report (`CrashReports.scrub` takes it out, like the account name).
///    The self-test checks both.
///  - It goes on a share picture (setup, overview, badge, weekly recap) only with
///    `onPictures`, and inside a link or file's payload (`from`) only with
///    `inLinks`. Both are off while there's no name, and turn on with the first one.
enum SharingName {
    static let nameKey = "GlideSharingName"
    static let picturesKey = "GlideSharingNameOnPictures"
    static let linksKey = "GlideSharingNameInLinks"
    /// The same limit a share's `from` has (`SharedSetup.maxFromLength`).
    static let maxLength = SharedSetup.maxFromLength

    /// Typed text made safe to keep: no control or invisible characters, trimmed, at most 40 characters.
    static func clean(_ text: String) -> String { ImportText.clean(text, max: maxLength) }

    static func name(_ d: UserDefaults = .standard) -> String {
        clean(d.string(forKey: nameKey) ?? "")
    }

    /// Saves a name. The first name turns both switches on (unless they were set by hand);
    /// an empty one is removed.
    static func setName(_ text: String, _ d: UserDefaults = .standard) {
        let name = clean(text)
        if name.isEmpty { d.removeObject(forKey: nameKey) } else { d.set(name, forKey: nameKey) }
    }

    /// The switch as set, or (never set) on exactly when there's a name.
    static func onPictures(_ d: UserDefaults = .standard) -> Bool {
        !name(d).isEmpty && (d.object(forKey: picturesKey) as? Bool ?? true)
    }

    static func inLinks(_ d: UserDefaults = .standard) -> Bool {
        !name(d).isEmpty && (d.object(forKey: linksKey) as? Bool ?? true)
    }

    static func setOnPictures(_ on: Bool, _ d: UserDefaults = .standard) { d.set(on, forKey: picturesKey) }
    static func setInLinks(_ on: Bool, _ d: UserDefaults = .standard) { d.set(on, forKey: linksKey) }

    /// What a picture shows, or nil.
    static var forPictures: String? { onPictures() ? name() : nil }
    /// What a link or file carries, or nil.
    static var forLinks: String? { inLinks() ? name() : nil }
}

/// The same, for SwiftUI: the tour's field and Settings' rows read and write through it.
@Observable
final class SharingNameStore {
    static let shared = SharingNameStore()

    /// What's in the text field (saved cleaned, as you type).
    var text: String {
        didSet {
            guard text != oldValue else { return }
            if text.count > SharingName.maxLength { text = String(text.prefix(SharingName.maxLength)); return }
            SharingName.setName(text)
            refresh()
        }
    }
    private(set) var onPictures: Bool
    private(set) var inLinks: Bool

    private init() {
        text = SharingName.name()
        onPictures = SharingName.onPictures()
        inLinks = SharingName.inLinks()
    }

    var hasName: Bool { !SharingName.name().isEmpty }

    func setOnPictures(_ on: Bool) { SharingName.setOnPictures(on); refresh() }
    func setInLinks(_ on: Bool) { SharingName.setInLinks(on); refresh() }

    /// After UserDefaults changed underneath (renders swap the store in and out).
    func reload() {
        text = SharingName.name()
        refresh()
    }

    private func refresh() {
        onPictures = SharingName.onPictures()
        inLinks = SharingName.inLinks()
    }
}
