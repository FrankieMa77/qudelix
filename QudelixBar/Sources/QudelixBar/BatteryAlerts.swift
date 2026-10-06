import Foundation

@MainActor
final class BatteryAlerts {
    nonisolated static let lowThreshold = 20
    static let veryLowThreshold = 10

    static let minimumInterval: TimeInterval = 300

    static let dischargeConfirmations = 3

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

        var notificationID: String {
            switch self {
            case .charging: return Notifier.identifier("qudelix-battery-charging")
            case .low: return Notifier.identifier("qudelix-battery-low")
            case .veryLow: return Notifier.identifier("qudelix-battery-very-low")
            }
        }
    }

    private var notifiedLow = false
    private var notifiedVeryLow = false
    private var wasCharging: Bool?
    private var notChargingRun = 0
    private var lastChargingAlert: Date?
    private var lastLowAlert: Date?
    private var lastVeryLowAlert: Date?

    func connectionReset() {
        wasCharging = nil
        notChargingRun = 0
    }

    func update(batteryPercent: Int?, charging: Bool, deviceSaysLow: Bool = false) {
        guard let alert = step(batteryPercent: batteryPercent, charging: charging,
                               deviceSaysLow: deviceSaysLow) else { return }
        Notifier.shared.post(id: alert.notificationID, title: alert.title,
                             body: alert.body)
    }

    func step(batteryPercent: Int?, charging: Bool, deviceSaysLow: Bool = false,
              now: Date = Date()) -> Alert? {
        guard let pct = batteryPercent else { return nil }

        if charging {
            notChargingRun = 0
        } else if wasCharging == true {
            notChargingRun += 1
            guard notChargingRun >= Self.dischargeConfirmations else { return nil }
        }

        if charging {
            let announce = wasCharging == false && allow(&lastChargingAlert, now)
            notifiedLow = false
            notifiedVeryLow = false
            wasCharging = true
            return announce ? .charging(percent: pct) : nil
        }
        wasCharging = false

        if pct > Self.lowThreshold + 5, !deviceSaysLow { notifiedLow = false }
        if pct > Self.veryLowThreshold + 5 { notifiedVeryLow = false }

        let low = deviceSaysLow || pct <= Self.lowThreshold

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

    private func allow(_ last: inout Date?, _ now: Date) -> Bool {
        if let last, now.timeIntervalSince(last) < Self.minimumInterval { return false }
        last = now
        return true
    }
}
