import CoreAudio
import XCTest
@testable import QudelixBar

final class EngineDeviceIdentityTests: XCTestCase {
    private func output(_ id: AudioDeviceID, uid: String, name: String,
                        bluetooth: Bool = false) -> AudioOutput {
        AudioOutput(id: id, uid: uid, name: name, sampleRate: 48000,
                    isBluetooth: bluetooth)
    }

    func testTheEnginesOwnDeviceIsRecognisedByTheUidItWasGiven() {
        let uid = StageEngine.makeAggregateUID()
        XCTAssertTrue(uid.hasPrefix(StageEngine.aggregateUIDPrefix))
        XCTAssertTrue(StageEngine.isEngineDevice(uid: uid))
        XCTAssertNotEqual(uid, StageEngine.makeAggregateUID(),
                          "every start gets its own device")
    }

    func testARealDeviceIsNeverTakenForTheEngine() {
        XCTAssertFalse(StageEngine.isEngineDevice(uid: "AppleUSBAudioEngine:Qudelix:5K:1"))
        XCTAssertFalse(StageEngine.isEngineDevice(uid: "BuiltInSpeakerDevice"))
        XCTAssertFalse(StageEngine.isEngineDevice(uid: ""))
    }

    func testTheEnginesAggregateIsNeverTheQudelixOutput() {
        let engine = output(9, uid: StageEngine.makeAggregateUID(),
                            name: StageEngine.aggregateName)
        let speakers = output(1, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")
        XCTAssertNil(StageState.qudelixOutput(in: [speakers, engine]),
                     "with the 5K away the engine's own device must not stand in for it")
    }

    func testTheRealFiveKWinsWhereverTheEngineIsListed() {
        let engine = output(9, uid: StageEngine.makeAggregateUID(),
                            name: StageEngine.aggregateName)
        let usb = output(5, uid: "AppleUSBAudioEngine:Qudelix:5K:2", name: "Qudelix-5K USB DAC")
        XCTAssertEqual(StageState.qudelixOutput(in: [engine, usb])?.id, 5)
        XCTAssertEqual(StageState.qudelixOutput(in: [usb, engine])?.id, 5)
    }

    func testAnEmptyListHasNoQudelixOutput() {
        XCTAssertNil(StageState.qudelixOutput(in: []))
    }

    func testWithOnlyBluetoothRealTheUsbOutputStaysEmptyRatherThanTheEngine() {
        let engine = output(9, uid: StageEngine.makeAggregateUID(),
                            name: StageEngine.aggregateName)
        let ble = output(3, uid: "00-11-22:output", name: "Qudelix-5K", bluetooth: true)
        XCTAssertEqual(StageState.qudelixOutput(in: [engine, ble])?.id, 3)
        XCTAssertNil(StageState.qudelixUsbOutput(in: [engine, ble]),
                     "the rate row must not offer the engine's device as the USB DAC")
        let usb = output(5, uid: "AppleUSBAudioEngine:Qudelix:5K:2", name: "Qudelix-5K USB DAC")
        XCTAssertEqual(StageState.qudelixUsbOutput(in: [engine, usb])?.id, 5)
    }
}
