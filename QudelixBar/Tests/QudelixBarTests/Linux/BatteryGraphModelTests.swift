import XCTest
@testable import QudelixBar

final class BatteryGraphModelTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(_ history: BatteryHistory, window: BatteryGraphWindow = .day,
                       reading: BatteryReading? = nil) -> BatteryGraphState {
        BatteryGraphBuilder.state(history: history, window: window, reading: reading, now: now,
                                  calendar: calendar)
    }

    func testAnEmptyHistoryIsAnEmptyStateWithAnExplanation() {
        let result = state(BatteryHistory())
        XCTAssertTrue(result.isEmpty)
        XCTAssertNil(result.latest)
        XCTAssertTrue(result.footnote.hasPrefix("Nothing recorded yet."))
        XCTAssertEqual(result.headline, "The 5K is not connected — the graph shows what was recorded while it was.")
        XCTAssertEqual(result.accessibility, "Battery graph, nothing recorded in the last 24 h")
    }

    func testTheDemoHistoryShapesSegmentsChargingBandsAndTicks() {
        let history = DemoBattery.history(now: now)
        let result = state(history, reading: BatteryReading(percent: 77, charging: false, chargerConnected: false))
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertFalse(result.chargingSpans.isEmpty)
        XCTAssertEqual(result.latest?.x, 1)
        XCTAssertEqual(result.latest?.y ?? 0, 77, accuracy: 1.5)
        XCTAssertEqual(result.ticks.count, 6)
        XCTAssertTrue(result.ticks.allSatisfy { $0.x > 0 && $0.x <= 1 })
        for line in result.lines {
            XCTAssertTrue(line.allSatisfy { (0...1).contains($0.x) && (0...100).contains($0.y) })
        }
        let span = result.chargingSpans[0]
        XCTAssertTrue(span.lowerBound >= 0 && span.upperBound <= 1 && span.lowerBound < span.upperBound)
        XCTAssertTrue(result.headline.hasPrefix("77% · on battery for"))
        XCTAssertTrue(result.headline.contains("draining"))
        XCTAssertTrue(result.footnote.hasPrefix("Recording since"))
        XCTAssertTrue(result.accessibility.hasSuffix("now 77 percent"))
    }

    func testTheWindowChangesTheSpanAndTheTickLabels() {
        let history = DemoBattery.history(now: now)
        let six = state(history, window: .sixHours)
        let week = state(history, window: .week)
        XCTAssertEqual(six.ticks.count, 6)
        XCTAssertEqual(six.chargingSpans.count, 0)
        XCTAssertTrue(week.ticks.allSatisfy { ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].contains($0.label) })
        XCTAssertTrue(six.ticks.allSatisfy { $0.label.hasSuffix("AM") || $0.label.hasSuffix("PM") })
        XCTAssertEqual(week.window, .week)
    }

    func testTickLabelsUseTwelveHourUsFormat() {
        let at = Date(timeIntervalSince1970: 1_800_000_000 + 3600 * 3)
        let label = BatteryGraphBuilder.tickLabel(at, window: .day, calendar: calendar)
        XCTAssertTrue(["12 AM", "1 AM", "2 AM", "3 AM", "4 AM", "5 AM", "6 AM", "7 AM", "8 AM", "9 AM", "10 AM",
                       "11 AM", "12 PM", "1 PM", "2 PM", "3 PM", "4 PM", "5 PM", "6 PM", "7 PM", "8 PM", "9 PM",
                       "10 PM", "11 PM"].contains(label), label)
    }

    func testHeadlineCoversChargingPluggedAndMeasuring() {
        var history = BatteryHistory()
        history.record(percent: 60, charging: false, at: now.addingTimeInterval(-60))
        XCTAssertEqual(BatteryGraphBuilder.headline(
            history: history, reading: BatteryReading(percent: 60, charging: true, chargerConnected: true), now: now),
                       "60% · charging")
        XCTAssertEqual(BatteryGraphBuilder.headline(
            history: history, reading: BatteryReading(percent: 60, charging: false, chargerConnected: true), now: now),
                       "60% · plugged in, not charging")
        let measuring = BatteryGraphBuilder.headline(
            history: history, reading: BatteryReading(percent: 60, charging: false, chargerConnected: false), now: now)
        XCTAssertTrue(measuring.hasSuffix("measuring the drain rate"), measuring)
    }

    func testDurationsReadNaturally() {
        XCTAssertEqual(BatteryGraphBuilder.duration(10), "1 min")
        XCTAssertEqual(BatteryGraphBuilder.duration(45 * 60), "45 min")
        XCTAssertEqual(BatteryGraphBuilder.duration(3600), "1 h")
        XCTAssertEqual(BatteryGraphBuilder.duration(3600 * 2 + 600), "2 h 10 min")
        XCTAssertEqual(BatteryGraphBuilder.duration(86400 * 2), "2 d")
        XCTAssertEqual(BatteryGraphBuilder.duration(86400 + 7200), "1 d 2 h")
        XCTAssertEqual(BatteryGraphBuilder.duration(.nan), "1 min")
    }

    func testTheDemoSeedIsPlausibleAndKeepsItsInvariants() {
        let history = DemoBattery.history(now: now)
        XCTAssertGreaterThan(history.readingCount, 60)
        XCTAssertTrue(history.samples.contains { $0.isGap })
        XCTAssertTrue(history.samples.contains { $0.charging })
        XCTAssertTrue(history.samples.compactMap(\.percent).allSatisfy { (0...100).contains($0) })
        XCTAssertEqual(history.samples.last?.percent ?? 0, 77, accuracy: 1)
        XCTAssertEqual(history.samples, history.samples.sorted { $0.time < $1.time })
        XCTAssertLessThan(history.samples.last!.time, now)
    }

    @MainActor
    func testTheModelPublishesOnlyRealChanges() {
        let model = AppModel(makeLinks: { [] }, acquireLock: { nil },
                             probeDevice: { AppDeviceProbe(present: false) }, batteryStore: .demo,
                             clock: ManualClock())
        var seen: [BatteryGraphState] = []
        model.batteryGraph.addObserver { seen.append($0) }
        XCTAssertEqual(seen.count, 1)
        model.batteryGraph.refresh()
        XCTAssertEqual(seen.count, 1)
        model.batteryGraph.setWindow(.week)
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen.last?.window, .week)
        model.batteryGraph.setWindow(.week)
        XCTAssertEqual(seen.count, 2)
    }
}
