import Foundation
@preconcurrency import UserNotifications

/// Standard system notifications for the 5K's battery: low, very low, and
/// charging. Each fires once per episode — latched, with hysteresis on the
/// re-arm so a battery reading that jitters around a threshold can't nag.
@MainActor
final class BatteryAlerts: NSObject {
    static let lowThreshold = 20
    static let veryLowThreshold = 10

    /// Shortest gap between two alerts of the same kind. Every latch below is
    /// armed by something the device reports, and a device that oscillates —
    /// a charging bit that flickers on and off, a percentage parked on a
    /// threshold — can re-arm one indefinitely. Banners carry sound, so an
    /// indefinite loop of them is not a cosmetic problem. This is the backstop
    /// under all of it: whatever the readings do, one banner per kind per
    /// interval is the most that can escape.
    static let minimumInterval: TimeInterval = 300

    /// Consecutive not-charging readings needed before the charging edge
    /// re-arms. "Charging" is believed the moment it is reported — a charger
    /// really was just plugged in, and that is worth saying at once — but
    /// "stopped charging" is where a flickering bit shows up, and it is the
    /// direction that costs a notification when it is wrong.
    static let dischargeConfirmations = 3

    /// What a reading warrants, if anything. Kept apart from delivery so the
    /// decision — thresholds, latches, rate limit — can be exercised without
    /// a notification centre, which needs a real app bundle behind it.
    enum Alert: Equatable {
        case charging(percent: Int)
        case low(percent: Int)
        case veryLow(percent: Int)

        var title: String {
            switch self {
            case .charging: return "Qudelix 5K charging"
            case .low: return "Qudelix 5K battery low"
            case .veryLow: return "Qudelix 5K battery very low"
            }
        }

        var body: String {
            switch self {
            case .charging(let pct): return "Battery at \(pct)%."
            case .low(let pct): return "\(pct)% left."
            case .veryLow(let pct):
                return "\(pct)% left — it will shut down soon. Plug it in."
            }
        }
    }

    private var notifiedLow = false
    private var notifiedVeryLow = false
    /// The settled view of the charging bit, not the last one reported. nil
    /// until the first reading, so connecting to an already-charging device
    /// doesn't announce "charging" as if it just started.
    private var wasCharging: Bool?
    /// Readings in a row that said not charging, counted only while the
    /// settled view still says charging — see `dischargeConfirmations`.
    private var notChargingRun = 0
    private var lastChargingAlert: Date?
    private var lastLowAlert: Date?
    private var lastVeryLowAlert: Date?
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
        notChargingRun = 0
    }

    /// Feed every battery/charging update through here; cheap when nothing
    /// changed. Latches survive brief disconnects on purpose — a Bluetooth
    /// blip must not re-announce the same low battery.
    /// `deviceSaysLow` is the 5K's own low-battery flag. It is treated as an
    /// additional trigger rather than a replacement for the percentage: the two
    /// can disagree, and whichever fires first is the one worth acting on. It
    /// cannot make the alert quieter — only earlier.
    func update(batteryPercent: Int?, charging: Bool, deviceSaysLow: Bool = false) {
        guard let alert = step(batteryPercent: batteryPercent, charging: charging,
                               deviceSaysLow: deviceSaysLow) else { return }
        post(title: alert.title, body: alert.body)
    }

    /// The decision `update` acts on, and the whole of the state machine.
    /// `now` is a parameter rather than a call to `Date()` inside so the rate
    /// limit can be moved through in a test without waiting out five minutes
    /// of real time.
    func step(batteryPercent: Int?, charging: Bool, deviceSaysLow: Bool = false,
              now: Date = Date()) -> Alert? {
        guard let pct = batteryPercent else { return nil }

        if charging {
            notChargingRun = 0
        } else if wasCharging == true {
            notChargingRun += 1
            // Not enough evidence yet that charging really stopped. Hold the
            // settled view where it is and say nothing: re-arming here is what
            // let a flickering bit produce a charge announcement and a low
            // warning on every cycle, forever.
            guard notChargingRun >= Self.dischargeConfirmations else { return nil }
        }

        if charging {
            let announce = wasCharging == false && allow(&lastChargingAlert, now)
            // Charging genuinely underway ends the low episode, so the two
            // latches re-arm for the next discharge.
            notifiedLow = false
            notifiedVeryLow = false
            wasCharging = true
            return announce ? .charging(percent: pct) : nil
        }
        wasCharging = false

        // Re-arm above the threshold, not at it: 5 points of hysteresis.
        if pct > Self.lowThreshold + 5, !deviceSaysLow { notifiedLow = false }
        if pct > Self.veryLowThreshold + 5 { notifiedVeryLow = false }

        // The device's own flag counts as reaching the low threshold, whatever
        // the percentage says.
        let low = deviceSaysLow || pct <= Self.lowThreshold

        // A latch is set only once the alert is actually going out. An alert
        // the rate limit swallowed is postponed, not cancelled — the next
        // reading offers it again — which matters most for the very-low
        // warning, the one alert nothing else in the app will repeat.
        if pct <= Self.veryLowThreshold, !notifiedVeryLow {
            guard allow(&lastVeryLowAlert, now) else { return nil }
            notifiedVeryLow = true
            notifiedLow = true
            return .veryLow(percent: pct)
        }
        if low, !notifiedLow {
            guard allow(&lastLowAlert, now) else { return nil }
            notifiedLow = true
            return .low(percent: pct)
        }
        return nil
    }

    /// Whether this kind of alert may fire now, recording the time when it
    /// may. Not called until every other condition has already said yes, so
    /// the clock only ever advances on an alert that is really sent.
    private func allow(_ last: inout Date?, _ now: Date) -> Bool {
        if let last, now.timeIntervalSince(last) < Self.minimumInterval { return false }
        last = now
        return true
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
