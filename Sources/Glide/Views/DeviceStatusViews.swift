import SwiftUI

// How the trackball is connected and, for wireless models that say, its battery.
// Never a guess: no battery glyph at all when the level is unknown or the
// trackball is wired (DeviceBattery.swift explains what macOS reports).

extension DeviceConnection {
    /// "Bluetooth", "USB", "Receiver".
    var title: String {
        switch self {
        case .usb: String(localized: "USB", comment: "How the trackball is connected: a USB cable")
        case .bluetooth: String(localized: "Bluetooth", comment: "How the trackball is connected")
        case .receiver: String(localized: "Receiver", comment: "How the trackball is connected: Kensington’s 2.4 GHz USB receiver")
        }
    }

    var symbol: String {
        switch self {
        case .usb: "cable.connector"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .receiver: "antenna.radiowaves.left.and.right"
        }
    }
}

enum BatteryLevel {
    /// Status colors only: amber at 15% and below, red at 5% and below, otherwise quiet.
    static func color(_ percent: Int) -> Color? {
        if percent <= 5 { return Theme.bad }
        if percent <= 15 { return Color(nsColor: .systemOrange) }   // amber: systemYellow is too faint on light
        return nil
    }

    static func symbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

/// A small battery with its percentage, colored only when it's low.
struct BatteryGlyph: View {
    let percent: Int
    var size: CGFloat = 11

    var body: some View {
        let tint = BatteryLevel.color(percent)
        HStack(spacing: 3) {
            Image(systemName: BatteryLevel.symbol(percent))
                .font(.system(size: size + 1, weight: .regular))
                .symbolRenderingMode(.hierarchical)
            Text(verbatim: (Double(percent) / 100).wholePercent)
                .font(.system(size: size, weight: tint == nil ? .regular : .semibold).monospacedDigit())
        }
        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Battery \((Double(percent) / 100).wholePercent)", comment: "Spoken: the trackball's battery level"))
    }
}

/// "Bluetooth · 62%": how it's connected, then its battery, each only when known.
/// Empty when neither is.
struct ConnectionDetail: View {
    let connection: DeviceConnection?
    let battery: Int?
    var size: CGFloat = 11
    /// Show the connection's symbol too (Overview).
    var symbol = false

    var body: some View {
        HStack(spacing: 5) {
            if let connection {
                if symbol {
                    Image(systemName: connection.symbol).font(.system(size: size))
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: connection.title)
                    .font(.system(size: size))
                    .foregroundStyle(.secondary)
            }
            if let battery, connection?.isWireless != false {
                if connection != nil { Text(verbatim: "·").font(.system(size: size)).foregroundStyle(.tertiary) }
                BatteryGlyph(percent: battery, size: size)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    var isEmpty: Bool { connection == nil && (battery == nil || connection?.isWireless == false) }
}

extension AppModel {
    /// The battery as the UI may show it: only for a connected wireless trackball that reports one.
    var shownBattery: Int? {
        guard status.deviceConnected, status.connection?.isWireless != false else { return nil }
        return status.batteryPercent
    }

    var shownConnection: DeviceConnection? { status.deviceConnected ? status.connection : nil }
}
