import AppKit
import SwiftUI
import XCTest
@testable import QudelixBar

@MainActor
final class BatteryHistoryViewTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("battery-view-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDurationSurvivesIntervalsNoInt64CanHold() {
        let ceiling = BatteryHistoryBody.duration(BatteryHistoryBody.maxDurationSeconds)
        XCTAssertEqual(BatteryHistoryBody.duration(1e300), ceiling)
        XCTAssertEqual(BatteryHistoryBody.duration(.greatestFiniteMagnitude), ceiling)
        XCTAssertEqual(BatteryHistoryBody.duration(.infinity), ceiling)
    }

    func testDurationReadsNonsenseAsTheShortestSpan() {
        XCTAssertEqual(BatteryHistoryBody.duration(.nan), "1 min")
        XCTAssertEqual(BatteryHistoryBody.duration(-1e300), "1 min")
        XCTAssertEqual(BatteryHistoryBody.duration(-.infinity), "1 min")
        XCTAssertEqual(BatteryHistoryBody.duration(-5), "1 min")
    }

    func testDurationStillFormatsOrdinarySpans() {
        XCTAssertEqual(BatteryHistoryBody.duration(3 * 3600 + 12 * 60), "3 h 12 min")
        XCTAssertEqual(BatteryHistoryBody.duration(2 * 86400 + 5 * 3600), "2 d 5 h")
    }

    func testTheAccessibilityLabelReadsAPlotThatWasAlreadyBuilt() {
        var history = BatteryHistory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        history.record(percent: 64, charging: false, at: now.addingTimeInterval(-600))
        let plot = history.plot(window: .day, now: now)
        XCTAssertEqual(BatteryHistoryBody.chartAccessibility(plot: plot, window: .day),
                       "Battery graph over the last 24 h, now 64 percent")
        XCTAssertEqual(BatteryHistoryBody.chartAccessibility(plot: BatteryHistory.Plot(), window: .week),
                       "Battery graph, nothing recorded in the last 7 d")
    }

    func testAnOutOfRangeLatestPointIsClampedBeforeItBecomesAnInteger() {
        var plot = BatteryHistory.Plot()
        plot.lines = [[.init(x: 0, y: 0), .init(x: 1, y: 1e300)]]
        plot.latest = .init(x: 1, y: 1e300)
        XCTAssertEqual(BatteryHistoryBody.chartAccessibility(plot: plot, window: .day),
                       "Battery graph over the last 24 h, now 100 percent")
        plot.latest = .init(x: 1, y: .nan)
        XCTAssertEqual(BatteryHistoryBody.chartAccessibility(plot: plot, window: .day),
                       "Battery graph over the last 24 h, now 0 percent")
    }

    func testAHandEditedFileWithImpossibleTimesDoesNotCrashTheDrawer() throws {
        let file = directory.appendingPathComponent("battery-history.json")
        let json = """
        {"samples":[
          {"time":-1e300,"percent":50,"charging":false},
          {"time":1e300,"percent":40,"charging":false}
        ]}
        """
        try json.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(BatteryLog(fileURL: file).history.samples.count, 0,
                       "the loader refuses these times before they get anywhere near a view")
        let log = BatteryLog.inMemory(BatteryHistory(samples: [
            BatterySample(time: Date(timeIntervalSince1970: -1e300), percent: 50, charging: false),
            BatterySample(time: Date(timeIntervalSince1970: 1e300), percent: 40, charging: false),
        ]))
        XCTAssertEqual(log.history.samples.count, 2)

        let controller = QudelixController()
        controller.connection = .connected(name: "Qudelix-5K")
        controller.batteryPercent = 40
        controller.charging = false
        controller.chargerConnected = false

        let suiteName = "battery-view-test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        for window in BatteryHistory.Window.allCases {
            suite.set(window.rawValue, forKey: "batteryHistoryWindow")
            let root = BatteryHistoryBody(log: log)
                .environmentObject(controller)
                .defaultAppStorage(suite)
                .frame(width: 372)
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: 372, height: 300)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 100)
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
            }
        }
    }

    func testAPausedScheduleHasNoFurtherTicks() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = Array(BatteryTickSchedule(live: false).entries(from: start, mode: .normal).prefix(5))
        XCTAssertEqual(entries, [start])
    }

    func testALiveScheduleTicksOncePerMinute() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = Array(BatteryTickSchedule(live: true).entries(from: start, mode: .normal).prefix(4))
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[0], start)
        for pair in zip(entries, entries.dropFirst()) {
            XCTAssertEqual(pair.1.timeIntervalSince(pair.0), 60, accuracy: 0.001)
        }
    }
}
