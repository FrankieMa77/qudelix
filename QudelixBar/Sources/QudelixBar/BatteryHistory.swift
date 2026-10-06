import Foundation

struct BatterySample: Codable, Equatable {
    var time: Date
    var percent: Int?
    var charging: Bool

    var isGap: Bool { percent == nil }
}

struct BatteryHistory: Codable, Equatable {
    var samples: [BatterySample] = []

    static let heartbeat: TimeInterval = 10 * 60
    static let retention: TimeInterval = 7 * 24 * 3600
    static let maxSamples = 8000
    static let minimumDrainSpan: TimeInterval = 30 * 60
    static let flickerBand = 1
    static let gapTolerance: TimeInterval = 5 * 60
    static let thinAge: TimeInterval = 24 * 3600
    static let thinStep: TimeInterval = 5 * 60

    var isEmpty: Bool { samples.isEmpty }
    var readingCount: Int { samples.filter { !$0.isGap }.count }
    var firstReading: Date? { samples.first(where: { !$0.isGap })?.time }

    @discardableResult
    mutating func record(percent: Int, charging: Bool, at now: Date = Date()) -> Bool {
        let level = max(0, min(100, percent))
        let healed = healShortGap(level: level, charging: charging, at: now)
        if let last = samples.last, !last.isGap, last.charging == charging,
           now >= last.time, now.timeIntervalSince(last.time) < Self.heartbeat {
            if last.percent == level { return healed }
            if returnsToPriorLevel(level, after: last) {
                samples.removeLast()
                return true
            }
        }
        samples.append(BatterySample(time: now, percent: level, charging: charging))
        prune(now: now)
        return true
    }

    private mutating func healShortGap(level: Int, charging: Bool, at now: Date) -> Bool {
        guard samples.count >= 2, let gap = samples.last, gap.isGap,
              now >= gap.time, now.timeIntervalSince(gap.time) < Self.gapTolerance else {
            return false
        }
        let before = samples[samples.count - 2]
        guard let was = before.percent, before.charging == charging,
              abs(was - level) <= Self.flickerBand else { return false }
        samples.removeLast()
        return true
    }

    private func returnsToPriorLevel(_ level: Int, after last: BatterySample) -> Bool {
        guard samples.count >= 2, let lastLevel = last.percent else { return false }
        let before = samples[samples.count - 2]
        guard let was = before.percent, before.charging == last.charging,
              was == level, abs(lastLevel - level) <= Self.flickerBand else { return false }
        return true
    }

    @discardableResult
    mutating func recordGap(at now: Date = Date()) -> Bool {
        guard let last = samples.last, !last.isGap else { return false }
        samples.append(BatterySample(time: now, percent: nil, charging: false))
        return true
    }

    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        if let firstKept = samples.firstIndex(where: { $0.time >= cutoff }) {
            if firstKept > 1 { samples.removeFirst(firstKept - 1) }
        } else if samples.count > 1 {
            samples.removeFirst(samples.count - 1)
        }
        thin(before: now.addingTimeInterval(-Self.thinAge))
        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
        }
    }

    private mutating func thin(before boundary: Date) {
        let end = min(samples.firstIndex(where: { $0.time >= boundary }) ?? samples.count,
                      samples.count - 1)
        guard end > 2 else { return }
        var kept: [BatterySample] = []
        kept.reserveCapacity(end)
        for sample in samples[..<end] {
            if let last = kept.last, !sample.isGap, !last.isGap,
               sample.charging == last.charging,
               sample.time.timeIntervalSince(last.time) < Self.thinStep {
                continue
            }
            kept.append(sample)
        }
        guard kept.count < end else { return }
        samples.replaceSubrange(0..<end, with: kept)
    }

    var currentRun: ArraySlice<BatterySample> {
        guard let last = samples.last, !last.isGap else { return [] }
        var start = samples.count - 1
        while start > 0 {
            let previous = samples[start - 1]
            if previous.isGap {
                let gapIndex = start - 1
                guard gapIndex >= 1, bridgesGap(at: gapIndex, resumingWith: samples[start]) else {
                    break
                }
                start = gapIndex - 1
                continue
            }
            if previous.charging != last.charging { break }
            start -= 1
        }
        return samples[start...]
    }

    private func bridgesGap(at index: Int, resumingWith next: BatterySample) -> Bool {
        let gap = samples[index]
        let before = samples[index - 1]
        guard let was = before.percent, let now = next.percent,
              before.charging == next.charging,
              next.time >= gap.time,
              next.time.timeIntervalSince(gap.time) < Self.gapTolerance else { return false }
        return next.charging ? now >= was - Self.flickerBand : now <= was + Self.flickerBand
    }

    var onBatterySince: Date? {
        let run = currentRun
        guard let first = run.first, !first.charging else { return nil }
        return first.time
    }

    var runStartsAtHistoryStart: Bool {
        guard let first = currentRun.first else { return false }
        return first.time == samples.first?.time
    }

    struct Drain: Equatable {
        var percentPerHour: Double
        var hoursLeft: Double?
    }

    func drain(now: Date = Date()) -> Drain? {
        let run = currentRun
        guard let first = run.first, let last = run.last, !last.charging else { return nil }
        let span = last.time.timeIntervalSince(first.time)
        guard span >= Self.minimumDrainSpan else { return nil }
        let levels = Set(run.compactMap(\.percent))
        guard levels.count >= 2 else { return nil }
        let points = run.compactMap { s -> (Double, Double)? in
            s.percent.map { (s.time.timeIntervalSince(first.time) / 3600, Double($0)) }
        }
        let n = Double(points.count)
        let meanX = points.map(\.0).reduce(0, +) / n
        let meanY = points.map(\.1).reduce(0, +) / n
        let sxx = points.map { ($0.0 - meanX) * ($0.0 - meanX) }.reduce(0, +)
        guard sxx > 0 else { return nil }
        let sxy = points.map { ($0.0 - meanX) * ($0.1 - meanY) }.reduce(0, +)
        let slope = sxy / sxx
        guard slope < 0 else { return nil }
        let rate = -slope
        let hoursLeft = last.percent.map { Double($0) / rate }
        return Drain(percentPerHour: rate, hoursLeft: hoursLeft)
    }

    enum Window: String, CaseIterable, Identifiable {
        case sixHours
        case day
        case week

        var id: String { rawValue }

        var seconds: TimeInterval {
            switch self {
            case .sixHours: return 6 * 3600
            case .day: return 24 * 3600
            case .week: return 7 * 24 * 3600
            }
        }

        var label: String {
            switch self {
            case .sixHours: return "6 h"
            case .day: return "24 h"
            case .week: return "7 d"
            }
        }

        var tickStep: DateComponents {
            switch self {
            case .sixHours: return DateComponents(hour: 1)
            case .day: return DateComponents(hour: 4)
            case .week: return DateComponents(day: 1)
            }
        }

        func ticks(now: Date, calendar: Calendar = .current) -> [Date] {
            let start = now.addingTimeInterval(-seconds)
            var result: [Date] = []
            switch self {
            case .sixHours, .day:
                guard var tick = calendar.dateInterval(of: .hour, for: start)?.end else {
                    return []
                }
                let every = tickStep.hour ?? 1
                while tick <= now, result.count < 64 {
                    if calendar.component(.hour, from: tick) % every == 0 { result.append(tick) }
                    guard let next = calendar.dateInterval(of: .hour, for: tick)?.end,
                          next > tick else { break }
                    tick = next
                }
            case .week:
                guard var tick = calendar.date(byAdding: .day, value: 1,
                                               to: calendar.startOfDay(for: start)) else {
                    return []
                }
                while tick <= now, result.count < 64 {
                    result.append(tick)
                    guard let next = calendar.date(byAdding: tickStep, to: tick) else { break }
                    tick = next
                }
            }
            return result
        }

        func tickLabel(_ date: Date, calendar: Calendar = .current) -> String {
            let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar,
                                         timeZone: calendar.timeZone)
            switch self {
            case .sixHours, .day:
                return date.formatted(style.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            case .week:
                return date.formatted(style.weekday(.abbreviated))
            }
        }
    }

    struct Plot: Equatable {
        struct Point: Equatable {
            var x: Double
            var y: Double
        }

        var lines: [[Point]] = []
        var chargingSpans: [ClosedRange<Double>] = []
        var latest: Point?

        var isEmpty: Bool { lines.isEmpty }
    }

    func plot(window: Window, now: Date = Date()) -> Plot {
        let start = now.addingTimeInterval(-window.seconds)
        func x(_ t: Date) -> Double { t.timeIntervalSince(start) / window.seconds }

        var plot = Plot()
        var line: [Plot.Point] = []
        var spans: [ClosedRange<Double>] = []

        func close() {
            if line.count >= 2 { plot.lines.append(line) }
            else if line.count == 1 { plot.lines.append([line[0], line[0]]) }
            line = []
        }

        for (index, sample) in samples.enumerated() {
            guard let percent = sample.percent else {
                close()
                continue
            }
            let next = index + 1 < samples.count ? samples[index + 1] : nil
            let endTime = next?.time ?? now
            if endTime < start { continue }
            let clippedStart = max(sample.time, start)
            if sample.time < start {
                if let next, let nextPercent = next.percent, next.time > sample.time {
                    let f = start.timeIntervalSince(sample.time) / next.time.timeIntervalSince(sample.time)
                    let y = Double(percent) + (Double(nextPercent) - Double(percent)) * f
                    line.append(Plot.Point(x: 0, y: y))
                } else {
                    line.append(Plot.Point(x: 0, y: Double(percent)))
                }
            } else {
                line.append(Plot.Point(x: min(1, x(sample.time)), y: Double(percent)))
            }
            if next == nil {
                let hold = Plot.Point(x: 1, y: Double(percent))
                plot.latest = hold
                line.append(hold)
            }
            if sample.charging {
                let lower = max(0, x(clippedStart))
                let upper = min(1, x(endTime))
                if upper > lower { spans.append(lower...upper) }
            }
        }
        close()

        var merged: [ClosedRange<Double>] = []
        for span in spans {
            if let last = merged.last, span.lowerBound <= last.upperBound + 0.0005 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        plot.chargingSpans = merged
        return plot
    }
}

enum BatteryHistoryFile {
    static var url: URL {
        StageStateFile.directory.appendingPathComponent("battery-history.json")
    }

    private static let maxBytes = 2_000_000

    static let earliestPlausible = Date(timeIntervalSince1970: 1_577_836_800)
    static let futureTolerance: TimeInterval = 24 * 3600

    private struct StoredHistory: Decodable {
        var samples: [FailableDecodable<BatterySample>]
    }

    static func load(from fileURL: URL = url, now: Date = Date()) -> BatteryHistory {
        guard let data = SafeFile.read(fileURL, cap: maxBytes) else { return BatteryHistory() }
        guard let stored = try? decoder.decode(StoredHistory.self, from: data) else {
            park(data, beside: fileURL)
            return BatteryHistory()
        }
        let decoded = stored.samples.compactMap(\.value)
        let kept = plausible(decoded, now: now)
        if kept.count != stored.samples.count { park(data, beside: fileURL) }
        return BatteryHistory(samples: kept)
    }

    static func plausible(_ samples: [BatterySample], now: Date = Date()) -> [BatterySample] {
        let latest = now.addingTimeInterval(futureTolerance)
        return samples.filter { sample in
            guard sample.time.timeIntervalSince1970.isFinite,
                  sample.time >= earliestPlausible, sample.time <= latest else { return false }
            guard let percent = sample.percent else { return true }
            return (0...100).contains(percent)
        }
    }

    private static func park(_ data: Data, beside fileURL: URL) {
        ParkedCopy.park(data, beside: fileURL)
    }

    static func encoded(_ history: BatteryHistory) -> Data? {
        try? encoder.encode(history)
    }

    @discardableResult
    static func save(_ history: BatteryHistory, to fileURL: URL = url) -> Bool {
        guard let data = encoded(history) else { return false }
        return SafeFile.writeAtomic(data, to: fileURL)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        d.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return d
    }
}

@MainActor
final class BatteryLog: ObservableObject {
    @Published private(set) var history: BatteryHistory

    private let fileURL: URL?
    private var saveWork: DispatchWorkItem?
    private var dirty = false
    private var writeFailureLogged = false
    private(set) var saveCount = 0
    private(set) var bytesWritten = 0
    static let saveDelay: TimeInterval = 300
    var saveInterval: TimeInterval = BatteryLog.saveDelay
    var schedule: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    init(fileURL: URL? = BatteryHistoryFile.url) {
        self.fileURL = fileURL
        history = fileURL.map { BatteryHistoryFile.load(from: $0) } ?? BatteryHistory()
    }

    static func inMemory(_ history: BatteryHistory = BatteryHistory()) -> BatteryLog {
        let log = BatteryLog(fileURL: nil)
        log.history = history
        return log
    }

    func record(percent: Int, charging: Bool, at now: Date = Date()) {
        var next = history
        guard next.record(percent: percent, charging: charging, at: now) else { return }
        history = next
        scheduleSave()
    }

    func recordGap(at now: Date = Date()) {
        var next = history
        guard next.recordGap(at: now) else { return }
        history = next
        scheduleSave()
    }

    func appWillTerminate(at now: Date = Date()) {
        recordGap(at: now)
        saveNow()
    }

    private func scheduleSave() {
        dirty = true
        guard fileURL != nil, saveWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        schedule(saveInterval, work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard let fileURL, dirty else { return }
        guard let data = BatteryHistoryFile.encoded(history),
              SafeFile.writeAtomic(data, to: fileURL) else {
            if !writeFailureLogged {
                writeFailureLogged = true
                DebugLog.shared.log("battery history could not be written; will retry")
            }
            scheduleSave()
            return
        }
        dirty = false
        writeFailureLogged = false
        saveCount += 1
        bytesWritten += data.count
    }
}
