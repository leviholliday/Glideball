import Foundation

/// Which pointing devices Glide works with.
///
/// Everyone gets the Kensington Expert Mouse. Members of the Beta program also
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
        case otherKensington      // supported in the Beta program
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

/// The per-Mac Beta program switch. Deliberately not part of `GlideConfig`, so
/// it never syncs: trying unfinished features is a choice made on each Mac.
enum BetaProgram {
    static let defaultsKey = "GlideBetaProgram"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
}
