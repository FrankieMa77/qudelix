import XCTest
@testable import QudelixBar

final class FakeAudioBackendTests: XCTestCase {
    func testSinkTransportHints() {
        let usb = AudioSink(id: 1, name: "usb", description: "Qudelix-5K USB DAC", deviceApi: "alsa", deviceBus: "usb",
                            vendorId: "0x0a12", productId: "0x4007")
        let bluetooth = AudioSink(id: 2, name: "bluez_output.AA", description: "Headset", deviceApi: "bluez5")
        let other = AudioSink(id: 3, name: "pci", description: "Speakers", deviceApi: "alsa", deviceBus: "pci")
        XCTAssertEqual(usb.transport, .usb)
        XCTAssertTrue(usb.isQudelix5K)
        XCTAssertEqual(bluetooth.transport, .bluetooth)
        XCTAssertFalse(bluetooth.isQudelix5K)
        XCTAssertEqual(other.transport, .other)
        XCTAssertFalse(other.isStageSink)
        XCTAssertTrue(AudioSink(id: 4, name: LinuxAudioNames.stageSinkName, description: "").isStageSink)
    }

    func testDefaultSinkAndForceRateRoundTrip() {
        let backend = FakeAudioBackend()
        var changes = 0
        backend.changeHandler = { changes += 1 }
        XCTAssertTrue(backend.setDefaultSink(named: "a"))
        XCTAssertEqual(backend.defaultSinkName, "a")
        XCTAssertTrue(backend.setForceRate(44100))
        XCTAssertEqual(backend.forceRate, 44100)
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(backend.setDefaultCalls, ["a"])
    }

    func testStreamsStopOnShutdown() throws {
        let backend = FakeAudioBackend()
        let handle = try backend.startInsert(target: "a") { input, output, frames, channels, _ in
            output.update(from: input, count: frames * channels)
        }
        XCTAssertTrue(handle.isStreaming)
        backend.shutdown()
        XCTAssertFalse(handle.isStreaming)
        XCTAssertTrue(backend.isShutDown)
    }

    func testStreamFailureThrows() {
        let backend = FakeAudioBackend()
        backend.failStreams = true
        XCTAssertThrowsError(try backend.startTone(sink: "a") { _, _, _, _ in })
    }
}
