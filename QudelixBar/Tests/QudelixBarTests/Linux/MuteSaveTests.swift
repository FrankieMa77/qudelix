import XCTest
@testable import QudelixBar

final class MuteSaveTests: XCTestCase {
    private var directory: URL!
    private var lockURL: URL!
    private var clock: ManualClock!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mute-save-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActiveSlotFile.directoryOverride = directory
        EqHistoryFile.directoryOverride = directory
        lockURL = directory.appendingPathComponent("qudelix.lock")
        clock = ManualClock()
    }

    override func tearDown() {
        ActiveSlotFile.directoryOverride = nil
        EqHistoryFile.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    @MainActor
    private func until(_ what: String = "condition", timeout: TimeInterval = 4,
                       _ condition: @MainActor () -> Bool) async {
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
        model.start()
        await until("connected") {
            model.state.connection.isConnected && model.eq.state.ready
                && model.presets.state.slots.count == 20
        }
        await model.presets.waitForIdle()
        device.link.clearSends()
        return model
    }

    @MainActor
    private func settle(_ model: AppModel) async {
        await model.eq.waitForIdle()
        await model.waitForIdle()
    }

    @MainActor
    private func quiet(_ model: AppModel, _ device: EqTestDevice, seconds: TimeInterval) async {
        clock.advance(seconds)
        try? await Task.sleep(nanoseconds: 120_000_000)
        await settle(model)
    }

    private func saveAlls(_ device: EqTestDevice) -> Int {
        device.link.sentCommands.filter { $0 == .saveAll }.count
    }

    private func newDevice() -> EqTestDevice {
        EqTestDevice(group: .b20, bands: EqTestSupport.shaped(.b20), preGain: -2, slot: 2,
                     names: [2: "Warm"])
    }

    @MainActor
    private func edit(_ model: AppModel, gain: Double = 3) async {
        model.eq.setBand(0, EqBand(filter: .peak, freq: 31, gain: gain, q: 1))
        await settle(model)
    }

    @MainActor
    func testUndoAndRedoArmTheSave() async {
        let device = newDevice()
        let model = await open(device)
        await edit(model)
        await model.flushSave()
        XCTAssertFalse(model.hasPendingSave)
        model.eq.undo()
        await settle(model)
        XCTAssertTrue(model.hasPendingSave)
        await quiet(model, device, seconds: 5.1)
        await until("saveAll after undo") { saveAlls(device) == 2 }
        model.eq.redo()
        await settle(model)
        XCTAssertTrue(model.hasPendingSave)
        await quiet(model, device, seconds: 5.1)
        await until("saveAll after redo") { saveAlls(device) == 3 }
        await model.shutdown()
    }

    @MainActor
    func testTheSaveIsParkedWhileABandIsMutedAndFiresFiveSecondsAfterTheLastUnmute() async {
        let device = newDevice()
        let model = await open(device)
        await edit(model)
        model.eq.setBandMuted(2, true)
        model.eq.setBandMuted(4, true)
        await settle(model)
        await quiet(model, device, seconds: 30)
        XCTAssertEqual(saveAlls(device), 0)
        XCTAssertTrue(model.hasPendingSave)
        model.eq.setBandMuted(2, false)
        await settle(model)
        await quiet(model, device, seconds: 30)
        XCTAssertEqual(saveAlls(device), 0)
        model.eq.setBandMuted(4, false)
        await settle(model)
        await quiet(model, device, seconds: 4.5)
        XCTAssertEqual(saveAlls(device), 0)
        await quiet(model, device, seconds: 0.6)
        await until("saveAll") { saveAlls(device) == 1 }
        await quiet(model, device, seconds: 30)
        XCTAssertEqual(saveAlls(device), 1)
        await model.shutdown()
    }

    @MainActor
    func testAnEditWhileMutedAndUndoWhileMutedStayParked() async {
        let device = newDevice()
        let model = await open(device)
        model.eq.setBandMuted(2, true)
        await edit(model)
        model.eq.undo()
        await settle(model)
        await quiet(model, device, seconds: 30)
        XCTAssertEqual(saveAlls(device), 0)
        model.eq.setBandMuted(2, false)
        await settle(model)
        await quiet(model, device, seconds: 5.1)
        await until("saveAll") { saveAlls(device) == 1 }
        await model.shutdown()
    }

    @MainActor
    func testAFilterChangeThatDropsTheLastMuteReleasesTheSave() async {
        let device = newDevice()
        let model = await open(device)
        await edit(model)
        model.eq.setBandMuted(2, true)
        await settle(model)
        model.eq.setBand(2, EqBand(filter: .peak, freq: 125, gain: 4, q: 1))
        await settle(model)
        await quiet(model, device, seconds: 5.1)
        await until("saveAll") { saveAlls(device) == 1 }
        await model.shutdown()
    }

    @MainActor
    func testASlotSaveWhileMutedWritesTheRealShapeSavesThenMutesAgain() async {
        let device = newDevice()
        let model = await open(device)
        model.eq.setBandMuted(2, true)
        await settle(model)
        device.link.clearSends()
        model.presets.save(slot: 5)
        await model.presets.waitForIdle()
        await settle(model)
        let commands = device.link.sentCommands.filter { $0 == .setEqBandParam || $0 == .saveEqPreset }
        XCTAssertEqual(commands, [.setEqBandParam, .saveEqPreset, .setEqBandParam])
        let payloads = device.link.payloads(for: .setEqBandParam)
        XCTAssertNotEqual(payloads[0], payloads[1])
        XCTAssertEqual(device.bands[2].filter, .bypass)
        XCTAssertTrue(model.eq.state.isMuted(2))
        await model.shutdown()
    }

    @MainActor
    func testTheQuitFlushWritesRealShapesSavesAllAndLeavesTheRealCurve() async {
        let device = newDevice()
        let model = await open(device)
        await edit(model)
        model.eq.setBandMuted(2, true)
        await settle(model)
        device.link.clearSends()
        await model.shutdown()
        let commands = device.link.sentCommands.filter { $0 == .setEqBandParam || $0 == .saveAll }
        XCTAssertEqual(commands, [.setEqBandParam, .saveAll])
        XCTAssertNotEqual(device.bands[2].filter, .bypass)
    }

    @MainActor
    func testTheQuitFlushSendsNothingWithoutAPendingSave() async {
        let device = newDevice()
        let model = await open(device)
        model.eq.setBandMuted(2, true)
        await settle(model)
        device.link.clearSends()
        await model.shutdown()
        XCTAssertFalse(device.link.sentCommands.contains(.saveAll))
        XCTAssertEqual(device.link.sentCommands.filter { $0 == .setEqBandParam }.count, 0)
    }
}
