import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem

/// Sets pointer and scroll speed on the Kensington's own HID service, so macOS
/// keeps moving the cursor (and, in Native mode, scrolling) itself — no lag —
/// while other mice keep their settings.
final class PointerTuner {
    static let vendorID = 0x047D

    struct Settings: Equatable {
        var trackingSpeed: Double     // macOS tracking curve (System Settings tops out at 3)
        var scrollSpeed: Double?      // macOS wheel acceleration; nil = leave alone
    }

    private var applied: (settings: Settings, services: [UInt64])?
    private var client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)

    /// Call when the trackball (re)connects: a long-lived client keeps a stale
    /// service list, so settings would silently stop applying after a replug
    /// or sleep. Recreated only then — never on a timer.
    func devicesChanged() {
        client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        applied = nil
    }

    /// Registry IDs of the Kensington's HID services, read straight from the
    /// I/O Registry (no HID-server traffic). They change when the device or its
    /// driver restarts — which doesn't always look like a disconnect.
    static func liveServiceIDs() -> Set<UInt64> {
        var iterator: io_iterator_t = 0
        let match = IOServiceMatching("IOHIDEventService") as NSMutableDictionary
        match[kIOHIDVendorIDKey] = vendorID
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var ids = Set<UInt64>()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            // Pointers only (Generic Desktop mouse/pointer) — the same set `apply` configures.
            let page = IORegistryEntryCreateCFProperty(service, kIOHIDPrimaryUsagePageKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
            let usage = IORegistryEntryCreateCFProperty(service, kIOHIDPrimaryUsageKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
            guard page == kHIDPage_GenericDesktop, usage == kHIDUsage_GD_Mouse || usage == kHIDUsage_GD_Pointer else { continue }
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS { ids.insert(id) }
        }
        return ids
    }

    /// Applies to every Kensington pointer. Cheap when nothing changed.
    func apply(_ settings: Settings) {
        // Our client's list is stale if the registry has services it doesn't know.
        if let applied, !Self.liveServiceIDs().isSubset(of: Set(applied.services)) {
            devicesChanged()
        }
        let services = kensingtonPointers()
        let ids = services.map(\.id)
        if let applied, applied.settings == settings, applied.services == ids,
           services.allSatisfy({ currentAcceleration($0.service) == fixed(settings.trackingSpeed) }) {
            return
        }
        for (_, service) in services {
            // Only the curve value — never the sensor resolution: writing
            // HIDPointerResolution crashed the system's HID server with this driver.
            IOHIDServiceClientSetProperty(service, accelerationKey(service) as CFString, fixed(settings.trackingSpeed) as CFNumber)
            if let scroll = settings.scrollSpeed {
                IOHIDServiceClientSetProperty(service, "HIDMouseScrollAcceleration" as CFString, fixed(scroll) as CFNumber)
            }
        }
        applied = (settings, ids)
    }

    private func fixed(_ v: Double) -> Int { Int(max(0, min(v, 100)) * 65536) }

    /// macOS reads the curve from whichever key `HIDPointerAccelerationType`
    /// names — "HIDMouseAcceleration" for mice.
    private func accelerationKey(_ s: IOHIDServiceClient) -> String {
        (IOHIDServiceClientCopyProperty(s, "HIDPointerAccelerationType" as CFString) as? String) ?? "HIDMouseAcceleration"
    }

    private func currentAcceleration(_ s: IOHIDServiceClient) -> Int? {
        IOHIDServiceClientCopyProperty(s, accelerationKey(s) as CFString) as? Int
    }

    private func kensingtonPointers() -> [(id: UInt64, service: IOHIDServiceClient)] {
        guard let services = IOHIDEventSystemClientCopyServices(client) as NSArray? else { return [] }
        return services.compactMap { obj -> (UInt64, IOHIDServiceClient)? in
            let s = obj as! IOHIDServiceClient
            let vid = IOHIDServiceClientCopyProperty(s, kIOHIDVendorIDKey as CFString) as? Int
            guard vid == Self.vendorID else { return nil }
            let isPointer = IOHIDServiceClientConformsTo(s, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0
                || IOHIDServiceClientConformsTo(s, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Pointer)) != 0
            guard isPointer else { return nil }
            let id = (IOHIDServiceClientGetRegistryID(s) as? NSNumber)?.uint64Value ?? 0
            return (id, s)
        }
    }
}
