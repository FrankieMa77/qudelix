import XCTest
@testable import QudelixBar

final class DemoLinkTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("demo-link-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActiveSlotFile.directoryOverride = directory
        EqHistoryFile.directoryOverride = directory
    }

    override func tearDown() {
        ActiveSlotFile.directoryOverride = nil
        EqHistoryFile.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    @MainActor
    func testTheDemoDeviceAnswersLikeAFiveK() async {
        let model = AppModel(makeLinks: { [DemoLink()] },
                             acquireLock: { QxInstanceLock.acquire(at: nil) },
                             probeDevice: { AppDeviceProbe(present: true) },
                             clock: ManualClock())
        model.start()
        let deadline = Date().addingTimeInterval(4)
        while !model.state.connection.isConnected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let status = model.state.status
        XCTAssertEqual(status?.linkKind, .usb)
        XCTAssertEqual(status?.firmware, "3.2.7")
        XCTAssertEqual(status?.batteryPercent, 76)
        XCTAssertEqual(status?.charging, false)
        XCTAssertEqual(status?.eqType, "PEQ")
        XCTAssertEqual(status?.eqGroupLabel, "b20 (20-band)")
        XCTAssertEqual(status?.eqBandsLabel, "20-band")
        XCTAssertEqual(status?.activeSlotLabel, "Slot 6 \u{00B7} Harman target")
        XCTAssertEqual(status?.activePresetIndex, 5)
        XCTAssertEqual(status?.activePresetName, "Harman target")
        XCTAssertEqual(status?.eqEnabled, true)
        XCTAssertEqual(status?.sampleRate, "48 kHz")
        model.setVolume(db: -9)
        model.setMute(true)
        model.setDacFilter(index: 6)
        await model.waitForIdle()
        XCTAssertEqual(model.state.status?.volumeDb ?? 0, -9, accuracy: 0.02)
        XCTAssertEqual(model.state.status?.dacFilterName, "Hybrid fast roll-off")
        XCTAssertEqual(DemoLink.bands.count, 20)
        await model.shutdown()
    }
}

final class BatteryLabelTests: XCTestCase {
    private func label(percent: Int?, charging: Bool, charger: Bool) -> String {
        var snapshot = QxStatusSnapshot()
        snapshot.batteryPercent = percent
        snapshot.charging = charging
        snapshot.chargerConnected = charger
        return snapshot.batteryLabel
    }

    func testTheBatteryRowNamesTheChargerState() {
        XCTAssertEqual(label(percent: 76, charging: false, charger: false), "76%")
        XCTAssertEqual(label(percent: 76, charging: true, charger: true), "76% \u{2014} plugged in, charging")
        XCTAssertEqual(label(percent: 100, charging: false, charger: true),
                       "100% \u{2014} plugged in, not charging")
        XCTAssertEqual(label(percent: nil, charging: true, charger: true), "Unknown")
    }

    @MainActor
    func testTheDemoDeviceReportsEachPowerState() async {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("demo-power-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActiveSlotFile.directoryOverride = directory
        EqHistoryFile.directoryOverride = directory
        defer {
            ActiveSlotFile.directoryOverride = nil
            EqHistoryFile.directoryOverride = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let expected: [(DemoLink.Power, String)] = [
            (.battery, "76%"),
            (.charging, "76% \u{2014} plugged in, charging"),
            (.idle, "76% \u{2014} plugged in, not charging"),
        ]
        for (power, text) in expected {
            let model = AppModel(makeLinks: { [DemoLink(power: power)] },
                                 acquireLock: { QxInstanceLock.acquire(at: nil) },
                                 probeDevice: { AppDeviceProbe(present: true) },
                                 clock: ManualClock())
            model.start()
            let deadline = Date().addingTimeInterval(4)
            while model.state.status == nil, Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(model.state.status?.batteryLabel, text)
            await model.shutdown()
        }
    }
}
