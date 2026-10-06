import CoreAudio
import XCTest
@testable import QudelixBar

final class MicrophoneStreamUsageTests: XCTestCase {
    func testAnOutputWithNoInputStreamsHasNothingToClose() {
        XCTAssertEqual(StageEngine.inputClosePlan(deviceInputStreams: 0,
                                                  engineInputStreams: 1),
                       .nothingToClose)
        XCTAssertEqual(StageEngine.inputClosePlan(deviceInputStreams: 0,
                                                  engineInputStreams: 4),
                       .nothingToClose)
    }

    func testADuplexOutputHasItsLeadingStreamsSwitchedOffAndTheTapsLeftOn() {
        XCTAssertEqual(StageEngine.inputClosePlan(deviceInputStreams: 1,
                                                  engineInputStreams: 2),
                       .close(usage: [0, 1]))
        XCTAssertEqual(StageEngine.inputClosePlan(deviceInputStreams: 2,
                                                  engineInputStreams: 5),
                       .close(usage: [0, 0, 1, 1, 1]))
    }

    func testTapStreamsNotYetListedStillClosesEveryMicrophoneStream() {
        XCTAssertEqual(StageEngine.inputClosePlan(deviceInputStreams: 2,
                                                  engineInputStreams: 2),
                       .close(usage: [0, 0]))
    }

    func testAnEngineDeviceWithFewerStreamsThanTheOutputCannotBeMapped() {
        XCTAssertEqual(StageEngine.inputClosePlan(deviceInputStreams: 3,
                                                  engineInputStreams: 1),
                       .unmappable)
        XCTAssertEqual(StageEngine.inputClosePlan(deviceInputStreams: 1,
                                                  engineInputStreams: 0),
                       .unmappable)
    }

    func testTheNumberOfEnabledStreamsAfterTheSwitchIsExactlyTheTapCount() {
        for device in 1...3 {
            for taps in 1...4 {
                guard case .close(let usage) = StageEngine.inputClosePlan(
                    deviceInputStreams: device, engineInputStreams: device + taps)
                else { return XCTFail("a duplex output must be closed") }
                XCTAssertEqual(usage.count, device + taps)
                XCTAssertEqual(usage.filter { $0 != 0 }.count, taps)
                XCTAssertTrue(usage.prefix(device).allSatisfy { $0 == 0 },
                              "the output's own streams come first and are the ones closed")
            }
        }
    }

    func testAReadBackThatDisagreesIsNotHonouredAndAnUnreadableOneIs() {
        XCTAssertTrue(StageEngine.usageHonoured(requested: [0, 1], readBack: [0, 1]))
        XCTAssertTrue(StageEngine.usageHonoured(requested: [0, 1], readBack: [0, 7]),
                      "any non-zero value means on")
        XCTAssertFalse(StageEngine.usageHonoured(requested: [0, 1], readBack: [1, 1]))
        XCTAssertFalse(StageEngine.usageHonoured(requested: [0, 1], readBack: [0]))
        XCTAssertTrue(StageEngine.usageHonoured(requested: [0, 1], readBack: nil))
    }

    func testTheRefusalNamesTheMicrophoneAndPromisesNotToOpenOne() {
        let refusal = StageEngine.microphoneRefusal("the system refused the stream setting")
        XCTAssertTrue(refusal.message.contains("microphone"))
        XCTAssertTrue(refusal.message.contains("won't start"))
        XCTAssertFalse(refusal.summary.isEmpty)
    }

    func testThePropertyPayloadMatchesTheHeadersStructLayout() {
        let marker = UnsafeMutableRawPointer(bitPattern: 0x1234_5678)
        let bytes = AudioOutputs.streamUsageBytes(ioProc: marker, usage: [0, 1, 1])

        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>
            .offset(of: \.mStreamIsOn)!
        XCTAssertEqual(bytes.count, flagsOffset + 3 * MemoryLayout<UInt32>.size)

        bytes.withUnsafeBytes { raw in
            let header = raw.loadUnaligned(as: AudioHardwareIOProcStreamUsage.self)
            XCTAssertEqual(header.mIOProc, marker)
            XCTAssertEqual(header.mNumberStreams, 3)
            XCTAssertEqual(raw.loadUnaligned(fromByteOffset: flagsOffset, as: UInt32.self), 0)
            XCTAssertEqual(raw.loadUnaligned(fromByteOffset: flagsOffset + 4, as: UInt32.self), 1)
            XCTAssertEqual(raw.loadUnaligned(fromByteOffset: flagsOffset + 8, as: UInt32.self), 1)
        }
    }

    func testAPayloadReadsBackAsTheFlagsItWasBuiltFrom() {
        let usage: [UInt32] = [0, 0, 1, 1]
        let bytes = AudioOutputs.streamUsageBytes(ioProc: nil, usage: usage)
        XCTAssertEqual(AudioOutputs.parseStreamUsage(bytes), usage)
    }

    func testAMalformedPayloadIsRejectedRatherThanOverRead() {
        XCTAssertNil(AudioOutputs.parseStreamUsage([]))
        XCTAssertNil(AudioOutputs.parseStreamUsage([UInt8](repeating: 0, count: 4)))
        var lying = AudioOutputs.streamUsageBytes(ioProc: nil, usage: [1])
        let countOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>
            .offset(of: \.mNumberStreams)!
        lying.withUnsafeMutableBytes {
            $0.storeBytes(of: UInt32(1000), toByteOffset: countOffset, as: UInt32.self)
        }
        XCTAssertNil(AudioOutputs.parseStreamUsage(lying),
                     "a count larger than the bytes present must not be trusted")
        lying.withUnsafeMutableBytes {
            $0.storeBytes(of: UInt32.max, toByteOffset: countOffset, as: UInt32.self)
        }
        XCTAssertNil(AudioOutputs.parseStreamUsage(lying))
    }
}
