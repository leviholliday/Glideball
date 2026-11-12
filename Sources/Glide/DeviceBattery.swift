import Foundation
import IOKit
import IOKit.hid

// Battery level and connection type for Kensington's wireless trackballs.
//
// What macOS exposes (researched 2026-11-11; untested on wireless hardware, since
// only the wired Expert Mouse was at hand, so everything here is read-only and
// says "unknown" rather than guess):
//  - Bluetooth LE devices with the standard Battery Service: macOS puts a
//    `BatteryPercent` property in the I/O Registry (on the device or on the
//    `AppleDeviceManagementHIDEventService` under it). Apple's own devices always
//    do; many third-party mice don't. Kensington doesn't document whether the
//    Expert Mouse Wireless or SlimBlade Pro do.
//  - HID devices may report battery as an input element: Generic Device Controls
//    / Battery Strength (0x06/0x20), or Battery System / Absolute or Relative State
//    of Charge (0x85/0x65, 0x66). Glideball reads it if it arrives.
//  - The 2.4 GHz dongles show up as ordinary USB devices; their battery reports
//    (if any) are vendor-specific, so a dongle's battery is usually unknown.
// The transport comes from the HID device's `Transport` property ("USB",
// "Bluetooth", "Bluetooth Low Energy"); a dongle is a USB device whose name says
// it's wireless (Kensington's receivers are named for the trackball they pair with).
//
// `DeviceConnection.classify` and `LowBatteryAlerts` are pure: scripts/device-sim checks them.

enum DeviceConnection: String, Equatable, CaseIterable {
    case usb, bluetooth, receiver

    static let wiredExpertMouseProductID = 0x1020

    static func classify(transport: String?, name: String?, productID: Int?) -> DeviceConnection? {
        guard let t = transport?.lowercased(), !t.isEmpty else { return nil }
        if t.contains("bluetooth") { return .bluetooth }
        guard t == "usb" else { return nil }
        if productID == wiredExpertMouseProductID { return .usb }
        let n = (name ?? "").lowercased()
        if ["wireless", "receiver", "dongle", "nano", "2.4"].contains(where: n.contains) { return .receiver }
        return .usb
    }

    /// Battery-powered, so a battery level could exist.
    var isWireless: Bool { self != .usb }
}

enum DeviceBattery {
    /// HID usages that carry a battery level.
    static func isBatteryUsage(page: Int, usage: Int) -> Bool {
        (page == 0x06 && usage == 0x20) || (page == 0x85 && (usage == 0x65 || usage == 0x66))
    }

    /// A HID battery value as a percentage, using the element's logical range.
    static func percent(value: Int, logicalMin: Int, logicalMax: Int) -> Int? {
        guard logicalMax > logicalMin, value >= logicalMin, value <= logicalMax else { return nil }
        return Int((Double(value - logicalMin) * 100 / Double(logicalMax - logicalMin)).rounded())
    }

    /// `BatteryPercent` on the device's registry entry, below it, or above it. Read-only.
    static func registryPercent(_ device: IOHIDDevice) -> Int? {
        let service = IOHIDDeviceGetService(device)
        guard service != 0 else { return nil }
        for options in [IOOptionBits(kIORegistryIterateRecursively),
                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)] {
            if let n = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "BatteryPercent" as CFString,
                                                       kCFAllocatorDefault, options) as? NSNumber {
                let p = n.intValue
                if (0...100).contains(p) { return p }
            }
        }
        return nil
    }

    static func transport(_ device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
    }
}

/// Low-battery notices at 15% and 5%, each once per discharge. A level back
/// above a threshold by `rearm` points (a charge) makes that notice due again.
struct LowBatteryAlerts: Codable, Equatable {
    static let thresholds = [15, 5]
    static let rearm = 5

    /// The lowest threshold already announced in this discharge.
    var announced: Int?

    /// A new reading. Returns the threshold to announce now, if any (only the
    /// lowest one crossed: from 30% straight to 4% is one notice, not two).
    mutating func update(percent: Int?) -> Int? {
        guard let percent, (0...100).contains(percent) else { return nil }
        if let a = announced, percent >= a + Self.rearm {
            // Charged past it: re-arm every notice the level is now clearly above.
            announced = Self.thresholds.filter { percent < $0 + Self.rearm }.min()
        }
        guard let crossed = Self.thresholds.filter({ percent <= $0 }).min() else { return nil }
        if let a = announced, a <= crossed { return nil }
        announced = crossed
        return crossed
    }
}
