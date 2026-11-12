import CoreGraphics
import Foundation

// Per-display pointer speed: which display the pointer is on, cheaply.
//
// Foundation and CoreGraphics types only; scripts/device-sim drives `DisplayTracker`
// with scripted displays and pointer positions. The engine feeds it from the
// trackball's own HID reports (so it costs nothing while the ball is still: no
// timer, no polling), at most every `checkInterval`, and only while per-display
// speeds are on with more than one display connected.

/// The tracking speed the trackball should have right now. Precedence, highest first:
/// Precision (while on), the app setup's own speed (already in `config.trackingSpeed`,
/// with display speeds switched off by `GlideConfig.resolved(for:)`), the display's
/// speed, the main speed. `config` is the resolved setup the engine runs.
enum PointerSpeed {
    static func effective(_ config: GlideConfig, display: String?, precision: Bool) -> Double {
        if precision { return config.precisionSpeed }
        return config.displaySpeeds.speed(for: display) ?? config.trackingSpeed
    }
}

/// A connected display, as the engine needs it.
struct DisplayRegion: Equatable {
    /// Stable across reconnects and restarts (see `DisplayKey`).
    var key: String
    /// Global display coordinates (origin top-left of the main display), as `CGDisplayBounds` and `CGEvent.location` use.
    var bounds: CGRect
}

/// A connected display, as the UI shows it.
struct DisplayInfo: Identifiable, Equatable {
    var key: String
    var name: String
    var isMain: Bool
    /// Where it sits in the arrangement (global display coordinates), for the Pointer tab's little map.
    var frame: CGRect = .zero
    var id: String { key }
}

/// Stable display identity: vendor, model and serial number from the display's
/// EDID when it has a serial; otherwise the UUID macOS itself keeps for that display
/// (ColorSync's `CGDisplayCreateUUIDFromDisplayID`), so two identical monitors
/// without serials still get their own speeds.
enum DisplayKey {
    static func make(vendor: UInt32, model: UInt32, serial: UInt32, uuid: String?) -> String {
        if serial != 0 { return "\(vendor)-\(model)-\(serial)" }
        if let uuid, !uuid.isEmpty { return "uuid-\(uuid)" }
        return "\(vendor)-\(model)-0"
    }
}

struct DisplayTracker {
    /// The shortest gap between two "which display is the pointer on" checks.
    static let checkInterval = 0.05

    private(set) var regions: [DisplayRegion] = []
    /// The display the pointer was last seen on (nil before the first look, or when it's on none).
    private(set) var current: String?
    private var currentBounds: CGRect?
    private var lastCheck = -Double.infinity
    /// How many full lookups (not just a bounds test) have been done, for the sim.
    private(set) var lookups = 0

    /// Only worth watching when there's more than one display to be on.
    var needsWatching: Bool { regions.count > 1 }

    /// New display list (one appeared, went away or moved). Returns true if
    /// the current display changed. With one display, that's the one.
    @discardableResult
    mutating func setRegions(_ new: [DisplayRegion], pointer: CGPoint?) -> Bool {
        regions = new
        let before = current
        current = nil
        currentBounds = nil
        lastCheck = -Double.infinity
        if new.count == 1 {
            current = new[0].key
            currentBounds = new[0].bounds
        } else if let pointer, locate(pointer) {
            // found it
        } else if let before, let still = new.first(where: { $0.key == before }) {
            current = still.key   // pointer unknown: stay on the display it was on, if that's still here
            currentBounds = still.bounds
        }
        return current != before
    }

    /// Whether enough time has passed for another check (and remembers that one happened).
    mutating func due(now: Double) -> Bool {
        guard now - lastCheck >= Self.checkInterval else { return false }
        lastCheck = now
        return true
    }

    /// The pointer is at `point`. Returns true if it's on a different display now.
    /// Inside the current display's bounds is a rectangle test; only a crossing
    /// walks the list.
    mutating func update(point: CGPoint) -> Bool {
        if let b = currentBounds, b.contains(point) { return false }
        let before = current
        if !locate(point) {
            // Between displays (an edge, or a display just removed): keep the last one.
            return false
        }
        return current != before
    }

    private mutating func locate(_ point: CGPoint) -> Bool {
        lookups += 1
        guard let r = regions.first(where: { $0.bounds.contains(point) }) else { return false }
        current = r.key
        currentBounds = r.bounds
        return true
    }
}
