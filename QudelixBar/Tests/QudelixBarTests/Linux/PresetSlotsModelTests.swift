import XCTest
@testable import QudelixBar

final class PresetSlotsModelTests: XCTestCase {
    private var directory: URL!
    private var lockURL: URL!
    private var clock: ManualClock!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("preset-model-\(UUID().uuidString)", isDirectory: true)
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

    private func device(slot: Int = 2) -> EqTestDevice {
        let device = EqTestDevice(group: .b20, bands: EqTestSupport.shaped(.b20), preGain: -2,
                                  slot: slot, names: [0: "Flat", 2: "Warm", 5: "Vocal"])
        var other = EqTestSupport.shaped(.b20)
        for index in other.indices { other[index].gain = 2 }
        device.slots[5] = (-1, other)
        device.slots[2] = (-2, EqTestSupport.shaped(.b20))
        return device
    }

    @MainActor
    func testTwentySlotsAreListedWithNamesAndTheActiveMarker() async {
        let model = await open(device(slot: 2))
        let state = model.presets.state
        XCTAssertEqual(state.slots.count, 20)
        XCTAssertEqual(state.slots.map(\.number), Array(1...20))
        XCTAssertEqual(state.slots[0].label, "Flat")
        XCTAssertEqual(state.slots[2].label, "Warm")
        XCTAssertEqual(state.slots[1].label, "Preset 2")
        XCTAssertEqual(state.slots[19].label, "Preset 20")
        XCTAssertEqual(state.activeIndex, 2)
        XCTAssertEqual(state.slots.filter(\.isActive).map(\.index), [2])
        XCTAssertEqual(model.state.status?.activePresetIndex, 2)
        await model.shutdown()
    }

    @MainActor
    func testNamesAreFetchedTheWayPresetListDoes() async {
        let link = device()
        let model = AppModel(makeLinks: { [link.link] },
                             acquireLock: { QxInstanceLock.acquire(at: self.lockURL) },
                             probeDevice: { AppDeviceProbe(present: true) },
                             clock: clock, retryInterval: 2, connectTimeout: 2)
        model.start()
        await until("names") { model.presets.state.slots.count == 20 && model.presets.state.slots[5].name == "Vocal" }
        await model.presets.waitForIdle()
        let asked = link.link.payloads(for: .reqEqPresetName).map { Int($0[1]) }
        XCTAssertTrue(Set(asked).isSuperset(of: [0, 2, 5]))
        XCTAssertTrue(asked.allSatisfy { [0, 2, 5].contains($0) })
        XCTAssertTrue(link.link.payloads(for: .reqEqPresetName).allSatisfy { $0[0] == QxEqGroup.b20.rawValue })
        await model.shutdown()
    }

    @MainActor
    func testLoadingASlotSendsTheCommandReadsTheCurveAndRecordsTheActiveSlot() async {
        let device = device(slot: 2)
        let model = await open(device)
        model.presets.load(slot: 5)
        await model.presets.waitForIdle()
        XCTAssertEqual(device.link.sentCommands.prefix(2), [.loadEqPreset, .reqEqPreset])
        XCTAssertEqual(device.link.payloads(for: .loadEqPreset), [[5]])
        XCTAssertEqual(model.eq.state.bands.map(\.gain), [Double](repeating: 2, count: 20))
        XCTAssertEqual(model.eq.state.preGain, -1, accuracy: 0.001)
        XCTAssertEqual(model.presets.state.activeIndex, 5)
        XCTAssertEqual(model.state.status?.activePresetIndex, 5)
        XCTAssertEqual(model.presets.state.slots.filter(\.isActive).map(\.index), [5])
        XCTAssertFalse(model.hasPendingSave)
        let recorded = ActiveSlotFile.slot(
            matching: QxUserEqPreset(preGain: -1, preGainCh1: -1, crossfeedLevel: 0,
                                     bands: model.eq.state.bands.map(\.raw)),
            group: .b20, identity: model.state.status?.deviceIdentity)
        XCTAssertEqual(recorded, 5)
        await model.shutdown()
        XCTAssertFalse(device.link.sentCommands.contains(.saveAll))
    }

    @MainActor
    func testALoadIsOneUndoCheckpointNamedAfterTheSlot() async {
        let device = device(slot: 2)
        let model = await open(device)
        let before = model.eq.state.bands
        model.presets.load(slot: 5)
        await model.presets.waitForIdle()
        XCTAssertEqual(model.eq.state.undoLabel, "load Vocal")
        XCTAssertEqual(EqHistoryFile.load().entries.map(\.label), ["load Vocal"])
        XCTAssertEqual(EqHistoryFile.load().entries[0].snapshot.activePreset, 2)
        model.eq.undo()
        await model.eq.waitForIdle()
        XCTAssertEqual(model.eq.state.bands, before)
        XCTAssertEqual(device.bands.map(\.gain), before.map(\.gain))
        await model.shutdown()
    }

    @MainActor
    func testTheActiveMarkerSurvivesAnEditAndFollowsTheDevice() async {
        let device = device(slot: 2)
        let model = await open(device)
        model.eq.setBand(0, EqBand(filter: .peak, freq: 31, gain: 5, q: 1))
        await model.eq.waitForIdle()
        await model.waitForIdle()
        XCTAssertEqual(model.presets.state.activeIndex, 2)
        XCTAssertEqual(model.state.status?.activePresetIndex, 2)
        device.notifyPreset(slot: 0)
        await until("slot 1 active") { model.presets.state.activeIndex == 0 }
        await model.shutdown()
    }

    @MainActor
    func testSavingSendsTheLiveEqAfterAnyQueuedBandWrites() async {
        let device = device(slot: 2)
        let model = await open(device)
        model.eq.setBand(1, EqBand(filter: .peak, freq: 44, gain: 6, q: 1))
        model.presets.save(slot: 7)
        await model.presets.waitForIdle()
        let order = device.link.sentCommands
        XCTAssertEqual(order.first, .setEqBandParam)
        XCTAssertTrue(order.contains(.saveEqPreset))
        XCTAssertLessThan(order.firstIndex(of: .setEqBandParam)!, order.firstIndex(of: .saveEqPreset)!)
        XCTAssertEqual(device.link.payloads(for: .saveEqPreset), [[7]])
        XCTAssertEqual(device.slots[7]?.bands[1].gain ?? 0, 6, accuracy: 0.001)
        clock.advance(30)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(device.link.sentCommands.filter { $0 == .saveAll }.count, 1)
        await model.shutdown()
    }

    @MainActor
    func testOnlyNamedSlotsAskBeforeBeingOverwritten() async {
        let model = await open(device(slot: 2))
        XCTAssertTrue(model.presets.needsOverwriteConfirmation(slot: 2))
        XCTAssertTrue(model.presets.needsOverwriteConfirmation(slot: 0))
        XCTAssertFalse(model.presets.needsOverwriteConfirmation(slot: 9))
        XCTAssertEqual(PresetSlotsModel.overwriteMessage(slot: 2, name: "Warm"),
                       "Slot 3, \u{201C}Warm\u{201D}, holds a preset on the device. "
                       + "Writing replaces it, and the device keeps no copy.")
        await model.shutdown()
    }

    @MainActor
    func testRenamingWritesTheNameReadsItBackAndNeverSavesAll() async {
        let device = device(slot: 2)
        let model = await open(device)
        model.presets.rename(slot: 9, to: "  Night listening ")
        await model.presets.waitForIdle()
        let payload = device.link.payloads(for: .setEqPresetName)[0]
        XCTAssertEqual(Array(payload.prefix(3)), [QxEqGroup.b20.rawValue, 9, UInt8(3 + "Night listening".utf8.count)])
        XCTAssertEqual(String(bytes: payload.dropFirst(3), encoding: .utf8), "Night listening")
        XCTAssertEqual(model.presets.state.slots[9].name, "Night listening")
        XCTAssertTrue(device.link.payloads(for: .reqEqPresetName).isEmpty)
        clock.advance(0.5)
        await until("readback") { !device.link.payloads(for: .reqEqPresetName).isEmpty }
        XCTAssertEqual(device.link.payloads(for: .reqEqPresetName), [[QxEqGroup.b20.rawValue, 9]])
        await model.presets.waitForIdle()
        XCTAssertEqual(model.presets.state.slots[9].label, "Night listening")
        XCTAssertFalse(model.hasPendingSave)
        await model.shutdown()
        XCTAssertFalse(device.link.sentCommands.contains(.saveAll))
    }

    @MainActor
    func testAnEmptyNameClearsTheSlot() async {
        let device = device(slot: 2)
        let model = await open(device)
        model.presets.rename(slot: 0, to: "")
        await model.presets.waitForIdle()
        XCTAssertEqual(model.presets.state.slots[0].label, "Preset 1")
        XCTAssertNil(device.names[0])
        clock.advance(0.5)
        await until("readback") { !device.link.payloads(for: .reqEqPresetName).isEmpty }
        await model.presets.waitForIdle()
        XCTAssertEqual(model.presets.state.slots[0].label, "Preset 1")
        await model.shutdown()
    }

    @MainActor
    func testSlotsOutsideTheTwentyAreRefusedAndNothingIsSent() async {
        let device = device(slot: 2)
        let model = await open(device)
        model.presets.load(slot: 20)
        model.presets.load(slot: -1)
        model.presets.save(slot: 20)
        model.presets.rename(slot: 25, to: "x")
        await model.presets.waitForIdle()
        XCTAssertTrue(device.link.sentCommands.isEmpty)
        await model.shutdown()
    }

    @MainActor
    func testNothingHappensWithoutADevice() async {
        let model = AppModel.noDevice(clock: clock)
        model.start()
        await Task.yield()
        model.presets.load(slot: 1)
        model.presets.save(slot: 1)
        model.presets.rename(slot: 1, to: "x")
        XCTAssertFalse(model.presets.state.ready)
        XCTAssertTrue(model.presets.state.slots.isEmpty)
        XCTAssertTrue(EqHistoryFile.load().entries.isEmpty)
        await model.shutdown()
    }

    @MainActor
    func testOnlyAllowedCommandsAreSent() async {
        let device = device(slot: 2)
        let model = await open(device)
        model.presets.load(slot: 5)
        model.presets.save(slot: 3)
        model.presets.rename(slot: 3, to: "Mine")
        await model.presets.waitForIdle()
        clock.advance(1)
        await model.presets.waitForIdle()
        await model.shutdown()
        XCTAssertTrue(device.link.sentCommands.allSatisfy { QxSession.allowed.contains($0) })
    }
}
