import XCTest
@testable import QudelixBar

final class SlotConfirmationTests: XCTestCase {
    private var directory: URL!
    private var lockURL: URL!
    private var clock: ManualClock!
    private var notices: [AppNotice] = []
    private var savedTimeout: TimeInterval = 0
    private var savedPause: TimeInterval = 0

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("slot-confirm-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActiveSlotFile.directoryOverride = directory
        EqHistoryFile.directoryOverride = directory
        lockURL = directory.appendingPathComponent("qudelix.lock")
        clock = ManualClock()
        notices = []
        savedTimeout = PresetSlotsModel.confirmTimeout
        savedPause = PresetSlotsModel.confirmRetryPause
        PresetSlotsModel.confirmTimeout = 1.5
        PresetSlotsModel.confirmRetryPause = 0.05
    }

    override func tearDown() {
        PresetSlotsModel.confirmTimeout = savedTimeout
        PresetSlotsModel.confirmRetryPause = savedPause
        ActiveSlotFile.directoryOverride = nil
        EqHistoryFile.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    @MainActor
    private func until(_ what: String, timeout: TimeInterval = 6, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    private func open(_ device: EqTestDevice) async -> AppModel {
        let url = lockURL
        let model = AppModel(makeLinks: { [device.link] },
                             acquireLock: { QxInstanceLock.acquire(at: url) },
                             probeDevice: { AppDeviceProbe(present: true) },
                             clock: clock, retryInterval: 2, connectTimeout: 2)
        model.addNoticeObserver { [weak self] in self?.notices.append($0) }
        model.start()
        await until("connected") {
            model.state.connection.isConnected && model.eq.state.ready
                && model.presets.state.slots.count == 20
        }
        await model.eq.waitForIdle()
        await model.presets.waitForIdle()
        device.link.clearSends()
        return model
    }

    private func device() -> EqTestDevice {
        let device = EqTestDevice(group: .b20, bands: EqTestSupport.shaped(.b20), preGain: -2,
                                  slot: 2, names: [0: "Flat", 2: "Warm", 5: "Vocal"])
        device.slots[2] = (-2, EqTestSupport.shaped(.b20))
        var other = EqTestSupport.shaped(.b20)
        for index in other.indices { other[index].gain = 2 }
        device.slots[5] = (-1, other)
        return device
    }

    private func messages(_ kind: AppNoticeKind) -> [String] {
        notices.filter { $0.kind == kind }.map(\.message)
    }

    @MainActor
    func testASaveThatTheDeviceKeptIsConfirmedAfterTheReadBack() async {
        let device = device()
        let model = await open(device)
        model.eq.setBand(1, EqBand(filter: .peak, freq: 44, gain: 6, q: 1))
        await model.eq.waitForIdle()
        model.presets.save(slot: 7)
        await model.presets.waitForIdle()
        XCTAssertEqual(messages(.success), ["Saved to slot 8."])
        XCTAssertTrue(messages(.failure).isEmpty)
        XCTAssertEqual(device.slots[7]?.bands[1].gain ?? 0, 6, accuracy: 0.001)
        XCTAssertTrue(device.link.sentCommands.contains(.loadEqPreset))
        XCTAssertEqual(model.eq.state.bands[1].gain, 6, accuracy: 0.001)
        XCTAssertEqual(device.bands[1].gain, 6, accuracy: 0.001)
        await model.shutdown()
    }

    @MainActor
    func testASaveTheDeviceDroppedIsReportedAndTheLiveCurveIsPutBack() async {
        let device = device()
        let model = await open(device)
        model.eq.setBand(1, EqBand(filter: .peak, freq: 44, gain: 6, q: 1))
        await model.eq.waitForIdle()
        device.dropsSaves = true
        let began = Date()
        model.presets.save(slot: 5)
        await model.presets.waitForIdle()
        XCTAssertLessThan(Date().timeIntervalSince(began), PresetSlotsModel.confirmTimeout + 2)
        XCTAssertEqual(messages(.failure), [PresetSlotsModel.saveUnconfirmed])
        XCTAssertTrue(messages(.success).isEmpty)
        XCTAssertEqual(device.slots[5]?.bands[1].gain ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(device.bands[1].gain, 6, accuracy: 0.001)
        XCTAssertEqual(model.eq.state.bands[1].gain, 6, accuracy: 0.001)
        await model.shutdown()
    }

    @MainActor
    func testARenameIsConfirmedOnlyAfterTheNameReadsBack() async {
        let device = device()
        let model = await open(device)
        model.presets.rename(slot: 9, to: "  Night listening ")
        await model.presets.waitForIdle()
        XCTAssertEqual(messages(.success), ["Renamed slot 10."])
        XCTAssertEqual(device.link.payloads(for: .reqEqPresetName), [[QxEqGroup.b20.rawValue, 9]])
        XCTAssertEqual(model.presets.state.slots[9].name, "Night listening")
        await model.shutdown()
    }

    @MainActor
    func testARenameTheDeviceNeverAppliedGivesTheErrorAndKeepsTheOldName() async {
        let device = device()
        device.dropsNames = true
        let model = await open(device)
        model.presets.rename(slot: 5, to: "Bright")
        await model.presets.waitForIdle()
        XCTAssertEqual(messages(.failure), [PresetSlotsModel.renameUnconfirmed])
        XCTAssertTrue(messages(.success).isEmpty)
        XCTAssertEqual(model.presets.state.slots[5].name, "Vocal")
        await model.shutdown()
    }

    @MainActor
    func testARenameThatTheDeviceAppliesLateIsStillConfirmedWithinTheWindow() async {
        let device = device()
        device.dropsNames = true
        let model = await open(device)
        model.presets.rename(slot: 5, to: "Bright")
        await until("first read") { !device.link.payloads(for: .reqEqPresetName).isEmpty }
        XCTAssertTrue(messages(.success).isEmpty)
        device.commitLateNames()
        await model.presets.waitForIdle()
        XCTAssertEqual(messages(.success), ["Renamed slot 6."])
        XCTAssertTrue(messages(.failure).isEmpty)
        XCTAssertEqual(model.presets.state.slots[5].name, "Bright")
        await model.shutdown()
    }

    @MainActor
    func testADeviceThatStopsAnsweringNamesStillGetsTheErrorWithinTheWindow() async {
        let device = device()
        let model = await open(device)
        device.silentNames = true
        let began = Date()
        model.presets.rename(slot: 5, to: "Bright")
        await until("the error") { !self.messages(.failure).isEmpty }
        XCTAssertLessThan(Date().timeIntervalSince(began), PresetSlotsModel.confirmTimeout + 2)
        XCTAssertEqual(messages(.failure), [PresetSlotsModel.renameUnconfirmed])
        XCTAssertTrue(messages(.success).isEmpty)
        await model.shutdown()
    }

    @MainActor
    func testClearingANameIsConfirmedWhenTheSlotReadsBackWithoutOne() async {
        let device = device()
        let model = await open(device)
        model.presets.rename(slot: 0, to: "")
        await model.presets.waitForIdle()
        XCTAssertEqual(messages(.success), ["Cleared the name of slot 1."])
        XCTAssertEqual(model.presets.state.slots[0].label, "Preset 1")
        await model.shutdown()
    }
}
