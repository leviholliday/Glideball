import Foundation
import UserNotifications

/// The per-Mac "Low battery alerts" switch (off by default, never synced).
/// Notification permission is asked for only when it's turned on.
enum LowBatteryAlertSetting {
    static let defaultsKey = "GlideLowBatteryAlerts"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
}

/// Tells the user, once each at 15% and 5% per discharge, that a wireless
/// trackball needs charging. The thresholds and "once each" live in
/// `LowBatteryAlerts` (checked by scripts/device-sim); this only posts. Main thread.
final class LowBatteryNotifier {
    private static let stateKey = "GlideLowBatteryAlertState"
    private var alerts: LowBatteryAlerts

    init() {
        alerts = UserDefaults.standard.data(forKey: Self.stateKey)
            .flatMap { try? JSONDecoder().decode(LowBatteryAlerts.self, from: $0) } ?? LowBatteryAlerts()
    }

    /// Asks for permission to show notifications (the switch was just turned on).
    func requestPermission() {
        guard !Sandbox.isActive else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// A new battery reading for the trackball in use. Readings are always tracked,
    /// so turning the switch on later doesn't announce an old crossing.
    func update(percent: Int?, deviceName: String?, enabled: Bool) {
        let before = alerts
        let due = alerts.update(percent: percent)
        if alerts != before, let data = try? JSONEncoder().encode(alerts) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        }
        guard let due, let percent, enabled, !Sandbox.isActive else { return }
        let name = deviceName ?? String(localized: "Your trackball")
        let level = (Double(percent) / 100).wholePercent
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Trackball battery low")
        content.body = due <= 5
            ? String(localized: "\(name) is at \(level). Charge it now so it doesn’t switch off.", comment: "Notification; first %@ is the trackball's name, second a percentage")
            : String(localized: "\(name) is at \(level). Charge it soon.", comment: "Notification; first %@ is the trackball's name, second a percentage")
        content.sound = .default
        let request = UNNotificationRequest(identifier: "glide.battery.\(due)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
