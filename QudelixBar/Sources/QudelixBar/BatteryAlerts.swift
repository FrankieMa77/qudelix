import Foundation
@preconcurrency import UserNotifications

/// Standard system notifications for the 5K's battery: low, very low, and
/// charging. Each fires once per episode — latched, with hysteresis on the
/// re-arm so a battery reading that jitters around a threshold can't nag.
@MainActor
final class BatteryAlerts: NSObject {
    static let lowThreshold = 20
    static let veryLowThreshold = 10

    private var notifiedLow = false
    private var notifiedVeryLow = false
    /// nil until the first reading, so connecting to an already-charging
    /// device doesn't announce "charging" as if it just started.
    private var wasCharging: Bool?
    private var configured = false

    /// Notifications need a real app bundle; the bare debug binary (the UI
    /// render harness) has none, and UNUserNotificationCenter aborts the
    /// process rather than erroring when asked without one.
    private static let canNotify = Bundle.main.bundleIdentifier != nil
        && Bundle.main.bundleURL.pathExtension == "app"

    /// Call when a connection episode ends. The low/very-low latches
    /// deliberately survive (a Bluetooth blip must not re-announce the same
    /// low battery), but the charging-edge sentinel must not compare across
    /// the gap: the device may well have been put on a charger while away,
    /// and announcing that hours later as "started charging" is wrong.
    func connectionReset() {
        wasCharging = nil
    }

    /// Feed every battery/charging update through here; cheap when nothing
    /// changed. Latches survive brief disconnects on purpose — a Bluetooth
    /// blip must not re-announce the same low battery.
    func update(batteryPercent: Int?, charging: Bool) {
        guard let pct = batteryPercent else { return }

        if charging {
            if wasCharging == false {
                post(title: "Qudelix 5K charging",
                     body: "Battery at \(pct)%.")
            }
            notifiedLow = false
            notifiedVeryLow = false
            wasCharging = true
            return
        }

        // Re-arm above the threshold, not at it: 5 points of hysteresis.
        if pct > Self.lowThreshold + 5 { notifiedLow = false }
        if pct > Self.veryLowThreshold + 5 { notifiedVeryLow = false }

        if pct <= Self.veryLowThreshold, !notifiedVeryLow {
            notifiedVeryLow = true
            notifiedLow = true
            post(title: "Qudelix 5K battery very low",
                 body: "\(pct)% left — it will shut down soon. Plug it in.")
        } else if pct <= Self.lowThreshold, !notifiedLow {
            notifiedLow = true
            post(title: "Qudelix 5K battery low",
                 body: "\(pct)% left.")
        }
        wasCharging = false
    }

    private func post(title: String, body: String) {
        guard Self.canNotify else { return }
        let center = UNUserNotificationCenter.current()
        if !configured {
            configured = true
            center.delegate = self
        }
        let fire = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                             content: content, trigger: nil))
        }
        // Authorization is requested at the first alert, not at launch — the
        // permission dialog then appears attached to something the user can
        // see the point of. Denied means center.add silently no-ops, which
        // is the user's decision working as intended.
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { fire() }
                }
            } else {
                fire()
            }
        }
    }
}

extension BatteryAlerts: UNUserNotificationCenterDelegate {
    /// A menu bar app can count as "active" while the popover is open;
    /// battery alerts should still show rather than being swallowed.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
