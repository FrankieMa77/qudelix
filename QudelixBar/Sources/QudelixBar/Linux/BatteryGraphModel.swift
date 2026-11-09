import Foundation

package enum BatteryGraphWindow: String, CaseIterable {
    case sixHours
    case day
    case week

    package var label: String { source.label }

    var source: BatteryHistory.Window {
        switch self {
        case .sixHours: return .sixHours
        case .day: return .day
        case .week: return .week
        }
    }
}

package struct BatteryGraphPoint: Equatable {
    package var x: Double
    package var y: Double
}

package struct BatteryGraphTick: Equatable {
    package var x: Double
    package var label: String
}

package struct BatteryGraphState: Equatable {
    package static let lowThreshold = BatteryAlerts.lowThreshold

    package var window: BatteryGraphWindow = .day
    package var lines: [[BatteryGraphPoint]] = []
    package var chargingSpans: [ClosedRange<Double>] = []
    package var latest: BatteryGraphPoint?
    package var ticks: [BatteryGraphTick] = []
    package var headline = ""
    package var footnote = ""
    package var accessibility = ""

    package var isEmpty: Bool { lines.isEmpty }

    package init() {}
}

struct BatteryReading: Equatable {
    var percent: Int
    var charging: Bool
    var chargerConnected: Bool
}

enum BatteryGraphBuilder {
    static let maxDurationSeconds: TimeInterval = 1e9

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone.current
        return calendar
    }()

    static func state(history: BatteryHistory, window: BatteryGraphWindow, reading: BatteryReading?,
                      now: Date, calendar: Calendar = BatteryGraphBuilder.calendar) -> BatteryGraphState {
        let plot = history.plot(window: window.source, now: now)
        var state = BatteryGraphState()
        state.window = window
        state.lines = plot.lines.map { $0.map { BatteryGraphPoint(x: $0.x, y: $0.y) } }
        state.chargingSpans = plot.chargingSpans
        state.latest = plot.latest.map { BatteryGraphPoint(x: $0.x, y: $0.y) }
        state.ticks = window.source.ticks(now: now, calendar: calendar).map {
            BatteryGraphTick(x: 1 - now.timeIntervalSince($0) / window.source.seconds,
                             label: tickLabel($0, window: window, calendar: calendar))
        }
        state.headline = headline(history: history, reading: reading, now: now)
        state.footnote = footnote(history: history, calendar: calendar)
        state.accessibility = accessibility(plot: plot, window: window)
        return state
    }

    static func tickLabel(_ date: Date, window: BatteryGraphWindow, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = window == .week ? "EEE" : "h a"
        return formatter.string(from: date)
    }

    static func headline(history: BatteryHistory, reading: BatteryReading?, now: Date) -> String {
        guard let reading else {
            return "The 5K is not connected — the graph shows what was recorded while it was."
        }
        var parts = ["\(reading.percent)%"]
        if reading.charging {
            parts.append("charging")
        } else if reading.chargerConnected {
            parts.append("plugged in, not charging")
        } else {
            if let since = history.onBatterySince {
                let prefix = history.runStartsAtHistoryStart ? "on battery for at least " : "on battery for "
                parts.append(prefix + duration(now.timeIntervalSince(since)))
            } else {
                parts.append("on battery")
            }
            if let drain = history.drain(now: now) {
                parts.append(String(format: "draining %.1f%%/h", drain.percentPerHour))
                if let left = drain.hoursLeft, left.isFinite, left < 24 * 14 {
                    parts.append("about " + duration(left * 3600) + " left")
                }
            } else if history.currentRun.count >= 1 {
                parts.append("measuring the drain rate")
            }
        }
        return parts.joined(separator: " · ")
    }

    static func footnote(history: BatteryHistory, calendar: Calendar) -> String {
        guard let first = history.firstReading else {
            return "Nothing recorded yet. A reading is kept every time the level changes and at least every ten minutes while the 5K is connected, for seven days."
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d, h:mm a"
        let count = history.readingCount
        return "Recording since \(formatter.string(from: first)) · \(count) reading\(count == 1 ? "" : "s") · kept for seven days. Shaded bands mark charging; breaks mark time away."
    }

    static func accessibility(plot: BatteryHistory.Plot, window: BatteryGraphWindow) -> String {
        if plot.isEmpty { return "Battery graph, nothing recorded in the last \(window.label)" }
        var text = "Battery graph over the last \(window.label)"
        if let latest = plot.latest {
            let percent = latest.y.isNaN ? 0 : min(max(latest.y, 0), 100)
            text += ", now \(Int(percent.rounded())) percent"
        }
        return text
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let bounded = seconds.isNaN ? 0 : min(max(seconds, 0), maxDurationSeconds)
        let total = Int(bounded.rounded())
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return hours > 0 ? "\(days) d \(hours) h" : "\(days) d" }
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h" }
        return "\(max(1, minutes)) min"
    }
}

@MainActor
package final class BatteryGraphModel {
    private unowned let host: AppModel
    private let log: BatteryLog
    private var observers: [Int: (BatteryGraphState) -> Void] = [:]
    private var nextObserverID = 0

    private var stored = BatteryGraphState()
    private var stale = true

    package private(set) var window: BatteryGraphWindow = .day

    package var state: BatteryGraphState {
        if stale {
            stored = compute()
            stale = false
        }
        return stored
    }

    init(host: AppModel, log: BatteryLog) {
        self.host = host
        self.log = log
    }

    @discardableResult
    package func addObserver(_ observer: @escaping (BatteryGraphState) -> Void) -> Int {
        nextObserverID += 1
        observers[nextObserverID] = observer
        observer(state)
        return nextObserverID
    }

    package func removeObserver(_ id: Int) {
        observers[id] = nil
    }

    package func setWindow(_ next: BatteryGraphWindow) {
        guard next != window else { return }
        window = next
        refresh()
    }

    package func refresh() {
        guard !observers.isEmpty else {
            stale = true
            return
        }
        let next = compute()
        stale = false
        guard next != stored else { return }
        stored = next
        for observer in observers.values { observer(next) }
    }

    private func compute() -> BatteryGraphState {
        let status = host.state.status
        let reading = status?.batteryPercent.map {
            BatteryReading(percent: $0, charging: status?.charging ?? false,
                           chargerConnected: status?.chargerConnected ?? false)
        }
        return BatteryGraphBuilder.state(history: log.history, window: window, reading: reading,
                                         now: host.clock.now())
    }
}

package enum BatteryStore {
    case memory
    case demo
    case file(URL)
    case system

    @MainActor
    func makeLog(now: Date) -> BatteryLog {
        switch self {
        case .memory: return BatteryLog.inMemory()
        case .demo: return BatteryLog.inMemory(DemoBattery.history(now: now))
        case .file(let url): return BatteryLog(fileURL: url)
        case .system: return BatteryLog()
        }
    }
}

enum DemoBattery {
    static func history(now: Date) -> BatteryHistory {
        var history = BatteryHistory()
        let step: TimeInterval = 15 * 60
        func hours(_ value: Double) -> Date { now.addingTimeInterval(-value * 3600) }
        func segment(from startHours: Double, to endHours: Double, from startLevel: Double,
                     to endLevel: Double, charging: Bool) {
            var offset = startHours
            while offset >= endHours {
                let fraction = (startHours - offset) / max(startHours - endHours, 0.001)
                let wobble = sin(offset * 3.1) * 0.4
                let level = startLevel + (endLevel - startLevel) * fraction + wobble
                history.record(percent: Int(level.rounded()), charging: charging, at: hours(offset))
                offset -= step / 3600
            }
        }
        segment(from: 27, to: 20.5, from: 88, to: 63, charging: false)
        history.recordGap(at: hours(20))
        segment(from: 19, to: 16, from: 55, to: 100, charging: true)
        segment(from: 15.75, to: 0.25, from: 100, to: 77, charging: false)
        return history
    }
}
