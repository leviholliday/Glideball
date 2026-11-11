import Foundation

/// Which pointing devices Glide works with.
///
/// Everyone gets the Kensington Expert Mouse. Anyone who turns on Other Kensington trackballs also
/// get Kensington's other pointing devices (SlimBlade, Orbit, Expert Wireless…),
/// which Glide hasn't been tuned on yet. Everything else — other brands, the
/// trackpad — is never touched. The engine (which events to rewrite) and the
/// pointer tuner (which HID services to configure) share this one rule.
struct DeviceIdentity: Equatable {
    var vendorID: Int?
    var productID: Int?
    var name: String?

    static let kensingtonVendorID = 0x047D
    static let expertMouseProductID = 0x1020

    enum Kind: Equatable {
        case expertMouse          // always supported
        case otherKensington      // supported when "Other Kensington trackballs" is on
        case other                // never touched
    }

    var kind: Kind {
        guard vendorID == Self.kensingtonVendorID else { return .other }
        if productID == Self.expertMouseProductID || (name?.localizedCaseInsensitiveContains("Expert Mouse") ?? false) {
            return .expertMouse
        }
        return .otherKensington
    }

    func isSupported(beta: Bool) -> Bool {
        switch kind {
        case .expertMouse: true
        case .otherKensington: beta
        case .other: false
        }
    }

    /// A readable name: "Kensington SlimBlade Trackball", or a fallback.
    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return vendorID == Self.kensingtonVendorID && !trimmed.localizedCaseInsensitiveContains("Kensington")
                ? "Kensington \(trimmed)" : trimmed
        }
        return kind == .expertMouse ? "Kensington Expert Mouse" : "Kensington trackball"
    }
}

/// The old per-Mac "Beta program" switch, which covered both of the switches below. It's no
/// longer written, but still read: anyone who had it on starts with both new switches on.
enum BetaProgram {
    static let defaultsKey = "GlideBetaProgram"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// A switch's saved value, or the old Beta program value until the person sets it.
    fileprivate static func value(forKey key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? isEnabled
    }
}

/// The per-Mac "Other Kensington trackballs" switch. Deliberately not part of `GlideConfig`, so
/// it never syncs: it's a choice made on each Mac.
enum OtherTrackballs {
    static let defaultsKey = "GlideOtherTrackballs"
    static var isEnabled: Bool { BetaProgram.value(forKey: defaultsKey) }
}

/// The per-Mac "Early updates" switch (prerelease versions). Not synced either.
enum EarlyUpdates {
    static let defaultsKey = "GlideEarlyUpdates"
    static var isEnabled: Bool { BetaProgram.value(forKey: defaultsKey) }
}
