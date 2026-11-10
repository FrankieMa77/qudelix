import Foundation
import QudelixAudio
import QudelixBar
import XCTest

final class PipeWireBackendTests: XCTestCase {
    private var backend: PipeWireAudioBackend!
    private var originalConfigured: String?
    private var originalForceRate = 0

    override func setUpWithError() throws {
        try Harness.require()
        backend = try PipeWireAudioBackend()
        originalConfigured = backend.configuredDefaultSinkName
        originalForceRate = backend.forceRate
    }

    override func tearDown() {
        if let backend {
            _ = backend.setForceRate(originalForceRate)
            _ = backend.setDefaultSink(named: originalConfigured)
            backend.shutdown()
        }
        backend = nil
        super.tearDown()
    }

    func testSinkListingCarriesHints() throws {
        let sinks = backend.sinks
        let fiveK = try XCTUnwrap(sinks.first { $0.name == Harness.fiveK })
        let other = try XCTUnwrap(sinks.first { $0.name == Harness.other })
        XCTAssertEqual(fiveK.description, "Qudelix 5K Test")
        XCTAssertEqual(fiveK.transport, .usb)
        XCTAssertTrue(fiveK.isQudelix5K)
        XCTAssertEqual(other.transport, .other)
        XCTAssertFalse(other.isQudelix5K)
        XCTAssertGreaterThan(fiveK.id, 0)
    }

    func testDefaultSinkReadSetAndRestore() throws {
        XCTAssertTrue(waitFor { self.backend.defaultSinkName != nil })
        XCTAssertTrue(backend.setDefaultSink(named: Harness.other))
        XCTAssertTrue(waitFor { self.backend.configuredDefaultSinkName == Harness.other })
        XCTAssertTrue(waitFor { self.backend.defaultSinkName == Harness.other })
        XCTAssertTrue(backend.setDefaultSink(named: Harness.fiveK))
        XCTAssertTrue(waitFor { self.backend.defaultSinkName == Harness.fiveK })
        XCTAssertTrue(backend.setDefaultSink(named: originalConfigured))
        XCTAssertTrue(waitFor { self.backend.configuredDefaultSinkName == self.originalConfigured })
        XCTAssertTrue(waitFor { self.backend.defaultSinkName != nil })
    }

    func testChangeHandlerFiresOnDefaultChange() throws {
        let lock = NSLock()
        var fired = 0
        backend.changeHandler = {
            lock.lock()
            fired += 1
            lock.unlock()
        }
        XCTAssertTrue(backend.setDefaultSink(named: Harness.other))
        XCTAssertTrue(waitFor {
            lock.lock()
            defer { lock.unlock() }
            return fired > 0
        })
    }

    func testSinkVolumeAndMuteRead() throws {
        let sink = try XCTUnwrap(backend.sinks.first { $0.name == Harness.fiveK })
        XCTAssertTrue(waitFor { self.backend.sinkVolume(named: Harness.fiveK) != nil })
        let id = String(sink.id)
        XCTAssertEqual(runTool(["pw-cli", "s", id, "Props", "{ mute: true, channelVolumes: [ 0.125, 0.125 ] }"]).status, 0)
        XCTAssertTrue(waitFor {
            guard let volume = self.backend.sinkVolume(named: Harness.fiveK) else { return false }
            return volume.muted && abs(volume.channelVolume - 0.125) < 0.001
        })
        XCTAssertEqual(runTool(["pw-cli", "s", id, "Props", "{ mute: false, channelVolumes: [ 1.0, 1.0 ] }"]).status, 0)
        XCTAssertTrue(waitFor {
            guard let volume = self.backend.sinkVolume(named: Harness.fiveK) else { return false }
            return !volume.muted && abs(volume.channelVolume - 1.0) < 0.001
        })
    }

    func testMonitorCapturesTonePlayedIntoNullSink() throws {
        let recorder = Recorder()
        let monitor = try backend.startMonitor(sink: Harness.fiveK, block: recorder.block)
        defer { monitor.stop() }
        XCTAssertTrue(waitFor { monitor.isStreaming })
        let wav = try writeSineWav(frequency: 1000, amplitude: 0.25, seconds: 2.5)
        defer { try? FileManager.default.removeItem(at: wav) }
        XCTAssertTrue(playWav(wav, target: Harness.fiveK))
        XCTAssertTrue(waitFor { recorder.frameCount > Harness.sampleRate * 2 })
        let snapshot = recorder.snapshot
        XCTAssertEqual(snapshot.rates, [Harness.sampleRate])
        XCTAssertEqual(snapshot.channels, [2])
        XCTAssertEqual(monitor.format, AudioStreamFormat(rate: Harness.sampleRate, channels: 2))
        let fit = try XCTUnwrap(fitTone(snapshot.left, frequency: 1000))
        XCTAssertEqual(fit.amplitude, 0.25, accuracy: 0.25 * 0.03)
        XCTAssertLessThan(fit.residualRatio, 0.02)
        let wrong = try XCTUnwrap(fitTone(snapshot.left, frequency: 1300))
        XCTAssertGreaterThan(wrong.residualRatio, 0.5)
        let right = try XCTUnwrap(fitTone(snapshot.right, frequency: 1000))
        XCTAssertEqual(right.amplitude, fit.amplitude, accuracy: 0.01)
        print("monitor amplitude=\(fit.amplitude) residual=\(fit.residualRatio) rate=\(String(describing: monitor.format))")
    }

    private func runInsert(gain: Float) throws -> (fit: ToneFit, rendered: Int, underruns: UInt64) {
        let counter = Counter()
        let insert = try backend.startInsert(target: Harness.fiveK) { input, output, frames, channels, _ in
            let count = frames * channels
            for i in 0..<count { output[i] = input[i] * gain }
            counter.add(frames)
        }
        defer { insert.stop() }
        let recorder = Recorder()
        let monitor = try backend.startMonitor(sink: Harness.fiveK, block: recorder.block)
        defer { monitor.stop() }
        XCTAssertTrue(waitFor { insert.isReady && monitor.isReady })
        XCTAssertTrue(waitFor { self.backend.sinks.contains { $0.isStageSink } })
        let stage = try XCTUnwrap(backend.sinks.first { $0.isStageSink })
        XCTAssertEqual(stage.description, LinuxAudioNames.stageSinkDescription)
        let wav = try writeSineWav(frequency: 1000, amplitude: 0.25, seconds: 3.0)
        defer { try? FileManager.default.removeItem(at: wav) }
        recorder.reset()
        XCTAssertTrue(playWav(wav, target: LinuxAudioNames.stageSinkName))
        XCTAssertTrue(waitFor { recorder.frameCount > Harness.sampleRate * 2 })
        let fit = try XCTUnwrap(fitTone(recorder.snapshot.left, frequency: 1000))
        print("insert gain=\(gain) amplitude=\(fit.amplitude) residual=\(fit.residualRatio) underruns=\(insert.underruns) overruns=\(insert.overruns)")
        return (fit, counter.value, insert.underruns)
    }

    func testInsertPipelinePassesAudioToTargetSink() throws {
        let result = try runInsert(gain: 1)
        XCTAssertGreaterThan(result.rendered, Harness.sampleRate * 2)
        XCTAssertEqual(result.fit.amplitude, 0.25, accuracy: 0.25 * 0.03)
        XCTAssertLessThan(result.fit.residualRatio, 0.02)
    }

    func testInsertRenderIsInThePath() throws {
        let result = try runInsert(gain: 0.5)
        XCTAssertEqual(result.fit.amplitude, 0.125, accuracy: 0.125 * 0.03)
        XCTAssertLessThan(result.fit.residualRatio, 0.02)
    }

    func testTonePlaybackReachesTargetSink() throws {
        let recorder = Recorder()
        let monitor = try backend.startMonitor(sink: Harness.other, block: recorder.block)
        defer { monitor.stop() }
        let phase = TonePhase(frequency: 440, amplitude: 0.2)
        let tone = try backend.startTone(sink: Harness.other) { output, frames, channels, rate in
            phase.fill(output, frames: frames, channels: channels, rate: rate)
        }
        defer { tone.stop() }
        XCTAssertTrue(waitFor { tone.isStreaming && monitor.isReady })
        XCTAssertEqual(tone.format, AudioStreamFormat(rate: Harness.sampleRate, channels: 2))
        XCTAssertTrue(waitFor { recorder.frameCount > Harness.sampleRate * 2 })
        let fit = try XCTUnwrap(fitTone(recorder.snapshot.left, frequency: 440))
        XCTAssertEqual(fit.amplitude, 0.2, accuracy: 0.2 * 0.03)
        XCTAssertLessThan(fit.residualRatio, 0.02)
    }

    func testForceRateSetAndClear() throws {
        XCTAssertTrue(backend.setForceRate(44100))
        XCTAssertEqual(backend.forceRate, 44100)
        let shown = runTool(["pw-metadata", "-n", "settings", "0", "clock.force-rate"]).output
        XCTAssertTrue(shown.contains("44100"), shown)
        XCTAssertTrue(backend.setForceRate(0))
        XCTAssertEqual(backend.forceRate, 0)
        let cleared = runTool(["pw-metadata", "-n", "settings", "0", "clock.force-rate"]).output
        XCTAssertFalse(cleared.contains("44100"), cleared)
    }

    func testVirtualSinkDisappearsWhenBackendIsDestroyed() throws {
        let observer = try PipeWireAudioBackend()
        defer { observer.shutdown() }
        let owner = try PipeWireAudioBackend()
        let insert = try owner.startInsert(target: Harness.fiveK) { input, output, frames, channels, _ in
            output.update(from: input, count: frames * channels)
        }
        XCTAssertTrue(waitFor { insert.isReady })
        XCTAssertTrue(waitFor { observer.sinks.contains { $0.isStageSink } })
        owner.shutdown()
        XCTAssertFalse(insert.isReady)
        XCTAssertTrue(waitFor { !observer.sinks.contains { $0.isStageSink } })
        XCTAssertTrue(observer.sinks.contains { $0.name == Harness.fiveK })
    }

    func testMissingServerFailsCleanly() throws {
        let saved = ProcessInfo.processInfo.environment["PIPEWIRE_REMOTE"]
        setenv("PIPEWIRE_REMOTE", "qx-no-such-socket", 1)
        defer {
            if let saved { setenv("PIPEWIRE_REMOTE", saved, 1) } else { unsetenv("PIPEWIRE_REMOTE") }
        }
        XCTAssertThrowsError(try PipeWireAudioBackend())
    }
}

private final class Counter {
    private let lock = NSLock()
    private var total = 0

    func add(_ frames: Int) {
        lock.lock()
        total += frames
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }
}

private final class TonePhase {
    private let frequency: Double
    private let amplitude: Double
    private var index: Int = 0

    init(frequency: Double, amplitude: Double) {
        self.frequency = frequency
        self.amplitude = amplitude
    }

    func fill(_ output: UnsafeMutablePointer<Float>, frames: Int, channels: Int, rate: Int) {
        for i in 0..<frames {
            let value = Float(amplitude * sin(2.0 * Double.pi * frequency * Double(index) / Double(rate)))
            index += 1
            for c in 0..<channels { output[i * channels + c] = value }
        }
    }
}
