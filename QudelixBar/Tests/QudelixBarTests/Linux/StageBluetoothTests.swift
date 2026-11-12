import XCTest
@testable import QudelixBar

@MainActor
final class StageBluetoothTests: XCTestCase {
    private var rigs: [StageRig] = []
    private let btName = "bluez_output.AA"

    override func tearDown() async throws {
        for rig in rigs { rig.cleanUp() }
        rigs = []
        try await super.tearDown()
    }

    private func bluetoothSink(profile: String = "a2dp-sink") -> AudioSink {
        AudioSink(id: 3, name: btName, description: "Qudelix-5K", deviceApi: "bluez5",
                  bluezAddress: "AA", profile: profile)
    }

    private func makeBluetoothRig(profile: String = "a2dp-sink") throws -> StageRig {
        let rig = try StageRig(sinks: [bluetoothSink(profile: profile), StageRig.speakers],
                               defaultSink: btName) { backend in
            backend.volumes[self.btName] = AudioSinkVolume(volume: 1, channelVolume: 1, muted: false)
        }
        rigs.append(rig)
        return rig
    }

    private func makeUsbRig() throws -> StageRig {
        let rig = try StageRig { backend in
            backend.volumes["qx_5k"] = AudioSinkVolume(volume: 1, channelVolume: 1, muted: false)
        }
        rigs.append(rig)
        return rig
    }

    private func stall(_ rig: StageRig, ticks: Int) {
        for _ in 0..<ticks {
            rig.backend.inserts.last?.stream.underruns += 5
            rig.tick()
        }
    }

    func testABluetoothTargetAsksForTheBluetoothEngine() throws {
        let rig = try makeBluetoothRig()
        rig.enableStage()
        XCTAssertEqual(rig.backend.insertBluetooth, [true])
        let usb = try makeUsbRig()
        usb.enableStage()
        XCTAssertEqual(usb.backend.insertBluetooth, [false])
    }

    func testABluetoothTargetNeedsTenRisingTicks() throws {
        let rig = try makeBluetoothRig()
        rig.enableStage()
        stall(rig, ticks: 9)
        XCTAssertTrue(rig.model.state.running)
        stall(rig, ticks: 1)
        XCTAssertFalse(rig.model.state.running)
        XCTAssertEqual(rig.model.state.failure?.message, StageModel.bluetoothStallMessage)
    }

    func testAUsbTargetStillFailsAfterThreeTicksWithTheOldText() throws {
        let rig = try makeUsbRig()
        rig.enableStage()
        stall(rig, ticks: 3)
        XCTAssertFalse(rig.model.state.running)
        XCTAssertTrue(rig.model.state.failure?.message.contains("keep up") == true)
        rig.tick(60)
        XCTAssertFalse(rig.model.state.running)
    }

    func testABluetoothStallRetriesAfterFifteenSecondsThreeTimesThenBacksOff() throws {
        let rig = try makeBluetoothRig()
        rig.enableStage()
        for _ in 0..<3 {
            stall(rig, ticks: 10)
            XCTAssertFalse(rig.model.state.running)
            rig.tick(10)
            XCTAssertFalse(rig.model.state.running)
            rig.tick(8)
            XCTAssertTrue(rig.model.state.running)
        }
        stall(rig, ticks: 10)
        XCTAssertFalse(rig.model.state.running)
        rig.tick(100)
        XCTAssertFalse(rig.model.state.running)
        rig.tick(270)
        XCTAssertTrue(rig.model.state.running)
    }

    func testAHeadsetProfileSinkHoldsStageUntilTheProfileSwitchesBack() throws {
        let rig = try makeBluetoothRig(profile: "headset-head-unit")
        rig.enableStage()
        XCTAssertFalse(rig.model.state.running)
        XCTAssertTrue(rig.backend.inserts.isEmpty)
        XCTAssertEqual(rig.model.state.status, StageModel.headsetHoldStatus)
        rig.backend.sinks[0] = bluetoothSink()
        rig.backend.changeHandler?()
        rig.settle(0.5)
        XCTAssertTrue(rig.model.state.running)
    }

    func testTheRestoredDefaultKeepsTheNameOfAnAbsentSink() throws {
        let rig = try makeUsbRig()
        rig.enableStage()
        rig.backend.sinks.removeAll()
        rig.backend.volumes["qx_5k"] = nil
        rig.backend.changeHandler?()
        rig.settle(0.5)
        XCTAssertFalse(rig.model.state.running)
        XCTAssertEqual(rig.backend.setDefaultCalls.last, "qx_5k")
        XCTAssertEqual(rig.backend.configuredDefaultSinkName, "qx_5k")
    }

    private func quietStageVolume(_ rig: StageRig, gain: Float) {
        rig.backend.volumes[LinuxAudioNames.stageSinkName] = AudioSinkVolume(volume: 1, channelVolume: gain, muted: false)
        rig.backend.changeHandler?()
        rig.hops.drain()
    }

    private func returnFiveK(_ rig: StageRig) {
        rig.backend.sinks.insert(StageRig.fiveK, at: 0)
        rig.backend.volumes["qx_5k"] = AudioSinkVolume(volume: 1, channelVolume: 1, muted: false)
        rig.backend.changeHandler?()
        rig.settle(0.5)
    }

    func testTheStageVolumeWaitsForTheOutputToReturn() throws {
        let rig = try makeUsbRig()
        rig.enableStage()
        quietStageVolume(rig, gain: 0.25)
        rig.backend.sinks.removeAll()
        rig.backend.volumes["qx_5k"] = nil
        rig.backend.changeHandler?()
        rig.settle(0.5)
        let kept = try JSONDecoder().decode(RoutingMemory.self, from: Data(contentsOf: rig.memoryURL))
        XCTAssertNotEqual(kept.handedOver, true)
        XCTAssertEqual(kept.stageGain ?? 0, 0.25, accuracy: 0.0005)
        rig.backend.sinks = [StageRig.fiveK]
        rig.backend.volumes["qx_5k"] = AudioSinkVolume(volume: 1, channelVolume: 1, muted: false)
        rig.backend.changeHandler?()
        rig.settle(0.5)
        XCTAssertEqual(rig.backend.volumes["qx_5k"]?.gain ?? 0, 0.25, accuracy: 0.0005)
    }

    func testAPendingVolumeSurvivesStageRestartingOnAnotherOutput() throws {
        let rig = try makeUsbRig()
        rig.enableStage()
        quietStageVolume(rig, gain: 0.25)
        rig.backend.sinks.removeAll { $0.name == "qx_5k" }
        rig.backend.volumes["qx_5k"] = nil
        rig.backend.changeHandler?()
        rig.settle(0.5)
        XCTAssertEqual(rig.backend.inserts.last?.target, "alsa_speakers")
        let kept = try JSONDecoder().decode(RoutingMemory.self, from: Data(contentsOf: rig.memoryURL))
        XCTAssertEqual(kept.deferred?.first?.target, "qx_5k")
        returnFiveK(rig)
        XCTAssertEqual(rig.backend.volumes["qx_5k"]?.gain ?? 0, 0.25, accuracy: 0.0005)
        let after = try JSONDecoder().decode(RoutingMemory.self, from: Data(contentsOf: rig.memoryURL))
        XCTAssertNil(after.deferred)
    }

    func testAFailureBackoffEndsWhenTheOutputComesBackAfterAPowerCycle() throws {
        let rig = try makeUsbRig()
        rig.enableStage()
        stall(rig, ticks: 3)
        XCTAssertFalse(rig.model.state.running)
        rig.backend.sinks.removeAll { $0.name == "qx_5k" }
        rig.backend.changeHandler?()
        rig.settle(0.5)
        rig.backend.sinks.insert(StageRig.fiveK, at: 0)
        rig.backend.volumes["qx_5k"] = AudioSinkVolume(volume: 1, channelVolume: 1, muted: false)
        rig.backend.changeHandler?()
        rig.settle(1)
        XCTAssertTrue(rig.model.state.running)
    }
}
