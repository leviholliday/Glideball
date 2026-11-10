import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem

/// Sets pointer and scroll speed on the supported Kensington's own HID service,
/// so macOS keeps moving the cursor (and, in Native mode, scrolling) itself —
/// no lag — while other mice keep their settings.
final class PointerTuner {
    struct Settings: Equatable {
        var trackingSpeed: Double     // macOS tracking curve (System Settings tops out at 3)
        var scrollSpeed: Double?      // macOS wheel acceleration; nil = leave alone
        var betaProgram = false       // also tune Kensington's other pointing devices (see DeviceIdentity)
    }

    private var applied: (settings: Settings, services: [UInt64])?
    private var client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    /// Every service Glide has written to, so one that stops being supported
    /// (the Beta program switched off) is handed back to macOS's own speeds.
    private var tuned = Set<UInt64>()
    /// Each service's own values from just before Glide's first write to it
    /// (raw 16.16 fixed point, so -1 = acceleration off comes back exactly).
    private struct Original { var tracking: Int?; var scroll: Int?; var wroteScroll = false }
    private var original: [UInt64: Original] = [:]

    /// Call when the trackball (re)connects: a long-lived client keeps a stale
    /// service list, so settings would silently stop applying after a replug
    /// or sleep. Recreated only then — never on a timer.
    func devicesChanged() {
        client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        applied = nil
    }

    /// Registry IDs of the supported Kensington HID services, read straight from
    /// the I/O Registry (no HID-server traffic). They change when the device or
    /// its driver restarts — which doesn't always look like a disconnect.
    static func liveServiceIDs(betaProgram: Bool) -> Set<UInt64> {
        var iterator: io_iterator_t = 0
        let match = IOServiceMatching("IOHIDEventService") as NSMutableDictionary
        match[kIOHIDVendorIDKey] = DeviceIdentity.kensingtonVendorID
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var ids = Set<UInt64>()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            // Pointers only (Generic Desktop mouse/pointer) — the same set `apply` configures.
            let page = registryValue(service, kIOHIDPrimaryUsagePageKey) as? Int
            let usage = registryValue(service, kIOHIDPrimaryUsageKey) as? Int
            guard page == kHIDPage_GenericDesktop, usage == kHIDUsage_GD_Mouse || usage == kHIDUsage_GD_Pointer else { continue }
            let identity = DeviceIdentity(vendorID: DeviceIdentity.kensingtonVendorID,
                                          productID: registryValue(service, kIOHIDProductIDKey) as? Int,
                                          name: registryValue(service, kIOHIDProductKey) as? String)
            guard identity.isSupported(beta: betaProgram) else { continue }
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS { ids.insert(id) }
        }
        return ids
    }

    /// A property of the service itself, or failing that of the device above it.
    private static func registryValue(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }

    /// Applies to every supported Kensington pointer. Cheap when nothing changed.
    func apply(_ settings: Settings) {
        // Our client's list is stale if the registry has services it doesn't know.
        if let applied, !Self.liveServiceIDs(betaProgram: settings.betaProgram).isSubset(of: Set(applied.services)) {
            devicesChanged()
        }
        let all = kensingtonPointers()
        let services = all.filter { $0.identity.isSupported(beta: settings.betaProgram) }
        let ids = services.map(\.id)
        if let applied, applied.settings == settings, applied.services == ids,
           services.allSatisfy({ currentAcceleration($0.service) == fixed(settings.trackingSpeed) }) {
            return
        }
        for p in services {
            var saved = original[p.id] ?? Original()
            if !tuned.contains(p.id) { saved.tracking = currentAcceleration(p.service) }
            if settings.scrollSpeed != nil && !saved.wroteScroll {
                saved.scroll = currentScrollAcceleration(p.service)
                saved.wroteScroll = true
            }
            original[p.id] = saved
            // Only the curve value — never the sensor resolution: writing
            // HIDPointerResolution crashed the system's HID server with this driver.
            IOHIDServiceClientSetProperty(p.service, accelerationKey(p.service) as CFString, fixed(settings.trackingSpeed) as CFNumber)
            if let scroll = settings.scrollSpeed {
                IOHIDServiceClientSetProperty(p.service, "HIDMouseScrollAcceleration" as CFString, fixed(scroll) as CFNumber)
            }
            tuned.insert(p.id)
        }
        // A device Glide tuned but no longer supports goes back to its own speeds.
        for p in all where tuned.contains(p.id) && !ids.contains(p.id) {
            restoreSpeeds(p.id, p.service)
            tuned.remove(p.id)
            original[p.id] = nil
        }
        applied = (settings, ids)
    }

    /// Hands every tuned trackball back to macOS (pause, quit). Does nothing
    /// when nothing is tuned, so the 2 s upkeep stays cheap while paused.
    func restoreAll() {
        guard !tuned.isEmpty else { return }
        for p in kensingtonPointers() where tuned.contains(p.id) { restoreSpeeds(p.id, p.service) }
        tuned.removeAll()
        original.removeAll()
        applied = nil
    }

    /// Puts back System Settings' speeds (the same curve keys `apply` writes — never
    /// the sensor resolution). Those are what "normal" means to the user, and they're
    /// the same whether Glide pauses or quits. The values captured before Glide's first
    /// write are only a fallback: right after an update they can be a speed an earlier
    /// Glide left behind, which made pause and quit hand back different speeds.
    private func restoreSpeeds(_ id: UInt64, _ s: IOHIDServiceClient) {
        func systemValue(_ key: String) -> Int? {
            // Unclamped: -1 (acceleration off) must stay -1.
            (CFPreferencesCopyAppValue(key as CFString, kCFPreferencesAnyApplication) as? NSNumber).map { Int($0.doubleValue * 65536) }
        }
        if let tracking = systemValue("com.apple.mouse.scaling") ?? original[id]?.tracking {
            IOHIDServiceClientSetProperty(s, accelerationKey(s) as CFString, tracking as CFNumber)
        }
        // Scrolling only if Glide changed it (Native mode).
        if original[id]?.wroteScroll ?? true, let scroll = systemValue("com.apple.scrollwheel.scaling") ?? original[id]?.scroll {
            IOHIDServiceClientSetProperty(s, "HIDMouseScrollAcceleration" as CFString, scroll as CFNumber)
        }
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

    private func currentScrollAcceleration(_ s: IOHIDServiceClient) -> Int? {
        IOHIDServiceClientCopyProperty(s, "HIDMouseScrollAcceleration" as CFString) as? Int
    }

    /// Every Kensington pointer service, supported or not.
    private func kensingtonPointers() -> [(id: UInt64, identity: DeviceIdentity, service: IOHIDServiceClient)] {
        guard let services = IOHIDEventSystemClientCopyServices(client) as NSArray? else { return [] }
        return services.compactMap { obj -> (UInt64, DeviceIdentity, IOHIDServiceClient)? in
            let s = obj as! IOHIDServiceClient
            let vid = IOHIDServiceClientCopyProperty(s, kIOHIDVendorIDKey as CFString) as? Int
            guard vid == DeviceIdentity.kensingtonVendorID else { return nil }
            let isPointer = IOHIDServiceClientConformsTo(s, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0
                || IOHIDServiceClientConformsTo(s, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Pointer)) != 0
            guard isPointer else { return nil }
            let identity = DeviceIdentity(vendorID: vid,
                                          productID: IOHIDServiceClientCopyProperty(s, kIOHIDProductIDKey as CFString) as? Int,
                                          name: IOHIDServiceClientCopyProperty(s, kIOHIDProductKey as CFString) as? String)
            let id = (IOHIDServiceClientGetRegistryID(s) as? NSNumber)?.uint64Value ?? 0
            return (id, identity, s)
        }
    }
}
