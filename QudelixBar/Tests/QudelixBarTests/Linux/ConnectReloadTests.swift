import XCTest
@testable import QudelixBar

final class ConnectReloadTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("connect-reload-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActiveSlotFile.directoryOverride = directory
        EqHistoryFile.directoryOverride = directory
    }

    override func tearDown() {
        ActiveSlotFile.directoryOverride = nil
        EqHistoryFile.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @MainActor
    private func connect(_ device: EqTestDevice) async -> AppModel {
        let url = directory.appendingPathComponent("qudelix.lock")
        let model = AppModel(makeLinks: { [device.link] },
                             acquireLock: { QxInstanceLock.acquire(at: url) },
                             probeDevice: { AppDeviceProbe(present: true) },
                             clock: ManualClock(), retryInterval: 2, connectTimeout: 2)
        model.start()
        let deadline = Date().addingTimeInterval(6)
        while !(model.state.connection.isConnected && model.eq.state.ready && model.presets.state.ready) {
            if Date() > deadline { XCTFail("timed out waiting for the connection"); break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await model.eq.waitForIdle()
        await model.presets.waitForIdle()
        try? await Task.sleep(nanoseconds: 150_000_000)
        await model.eq.waitForIdle()
        return model
    }

    @MainActor
    func testConnectingReadsTheEqPresetOnlyForTheHandshakeAndTheOpeningReadWhenNothingMoved() async {
        let device = EqTestDevice(group: .b20, bands: EqTestSupport.shaped(.b20), preGain: -2,
                                  slot: 2, names: [2: "Warm"])
        let model = await connect(device)
        XCTAssertEqual(device.link.payloads(for: .reqEqPreset).count, 2)
        await model.shutdown()
    }

    @MainActor
    func testConnectingToADeviceWithNoActiveSlotAddsNoReloadRead() async {
        let device = EqTestDevice(group: .user, preGain: -2, slot: 255)
        let model = await connect(device)
        XCTAssertEqual(device.link.payloads(for: .reqEqPreset).count, 2)
        await model.shutdown()
    }

    @MainActor
    func testASlotChangeAfterConnectingStillReloads() async {
        let device = EqTestDevice(group: .b20, bands: EqTestSupport.shaped(.b20), preGain: -2,
                                  slot: 2, names: [2: "Warm", 5: "Vocal"])
        device.slots[5] = (-1, EqTestSupport.shaped(.b20))
        let model = await connect(device)
        let before = device.link.payloads(for: .reqEqPreset).count
        device.notifyPreset(slot: 5)
        let deadline = Date().addingTimeInterval(4)
        while device.link.payloads(for: .reqEqPreset).count == before, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(device.link.payloads(for: .reqEqPreset).count, before)
        await model.shutdown()
    }
}
