import Foundation
import QudelixAudio
@testable import QudelixBar
import XCTest

private final class PumpedHops: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [() -> Void] = []

    var hop: OutputRouting.Hop {
        { [self] work in
            lock.lock()
            queue.append(work)
            lock.unlock()
        }
    }

    func drain() {
        while true {
            lock.lock()
            let next = queue.isEmpty ? nil : queue.removeFirst()
            lock.unlock()
            guard let next else { return }
            next()
        }
    }
}

private final class PumpedClock: AppClock {
    private final class Entry: AppTimer {
        let due: Date
        let work: @MainActor () -> Void
        var cancelled = false

        init(due: Date, work: @escaping @MainActor () -> Void) {
            self.due = due
            self.work = work
        }

        func cancel() { cancelled = true }
    }

    private var entries: [Entry] = []

    func now() -> Date { Date() }

    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> AppTimer {
        let entry = Entry(due: Date().addingTimeInterval(seconds), work: work)
        entries.append(entry)
        return entry
    }

    @MainActor
    func runDue() {
        let now = Date()
        let due = entries.filter { !$0.cancelled && $0.due <= now }
        entries.removeAll { $0.cancelled || $0.due <= now }
        for entry in due { entry.work() }
    }
}

@MainActor
final class ModelHarnessTests: XCTestCase {
    private var backend: PipeWireAudioBackend!
    private var routing: OutputRouting!
    private var model: StageModel!
    private var hops: PumpedHops!
    private var clock: PumpedClock!
    private var directory: URL!
    private var originalConfigured: String?

    override func setUp() async throws {
        try Harness.require()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qx-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("impulses"),
                                                withIntermediateDirectories: true)
        backend = try PipeWireAudioBackend()
        originalConfigured = backend.configuredDefaultSinkName
        hops = PumpedHops()
        clock = PumpedClock()
        routing = OutputRouting(backend: backend, clock: clock, hop: hops.hop,
                                memoryURL: directory.appendingPathComponent("routing.json"))
        model = StageModel(backend: backend, routing: routing, clock: clock,
                           settingsURL: directory.appendingPathComponent("stage.json"),
                           impulseDirectory: { [directory] in directory!.appendingPathComponent("impulses") })
        XCTAssertTrue(backend.setDefaultSink(named: Harness.fiveK))
        XCTAssertTrue(pump { self.backend.defaultSinkName == Harness.fiveK
            && self.backend.configuredDefaultSinkName == Harness.fiveK })
    }

    override func tearDown() async throws {
        model?.shutdown()
        if let backend {
            _ = backend.setForceRate(0)
            _ = backend.setDefaultSink(named: originalConfigured)
            backend.shutdown()
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        model = nil
        routing = nil
        backend = nil
    }

    private func pump(_ seconds: Double = 10, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            hops.drain()
            clock.runDue()
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        hops.drain()
        clock.runDue()
        return condition()
    }

    func testStageInsertChangesTheCapturedOutputAndStopsCleanly() throws {
        model.start()
        XCTAssertTrue(pump { self.model.state.outputKey == Harness.fiveK })

        var settings = StageSettings()
        settings.enabled = true
        settings.width = 100
        settings.crossfeed = 0
        settings.room = 0
        settings.dialogue = 0
        settings.distance = 0
        settings.balanceDb = 6
        model.setStage(settings, editedFor: model.outputKey)
        XCTAssertTrue(pump { self.model.state.routed }, "status: \(model.state.status)")
        XCTAssertEqual(model.state.settings.balanceDbValue, 3)
        XCTAssertEqual(backend.configuredDefaultSinkName, LinuxAudioNames.stageSinkName)
        XCTAssertEqual(routing.realOutput?.name, Harness.fiveK)
        XCTAssertTrue(backend.sinks.contains { $0.isStageSink })

        let recorder = Recorder()
        let monitor = try backend.startMonitor(sink: Harness.fiveK, block: recorder.block)
        defer { monitor.stop() }
        XCTAssertTrue(pump { monitor.isReady })

        let wav = try writeSineWav(frequency: 1000, amplitude: 0.25, seconds: 3.0)
        defer { try? FileManager.default.removeItem(at: wav) }
        recorder.reset()
        XCTAssertTrue(playWav(wav, target: LinuxAudioNames.stageSinkName))
        XCTAssertTrue(pump { recorder.frameCount > Harness.sampleRate * 2 })
        let snapshot = recorder.snapshot
        let windowFrames = Harness.sampleRate / 10
        let leftTone = try XCTUnwrap(fitToneWindows(snapshot.left, frequency: 1000, windowFrames: windowFrames))
        let rightTone = try XCTUnwrap(fitToneWindows(snapshot.right, frequency: 1000, windowFrames: windowFrames))
        XCTAssertGreaterThanOrEqual(leftTone.agreeingSeconds(windowFrames: windowFrames), 1.5,
                                    "left windows: \(leftTone.amplitudes)")
        XCTAssertGreaterThanOrEqual(rightTone.agreeingSeconds(windowFrames: windowFrames), 1.5,
                                    "right windows: \(rightTone.amplitudes)")
        let shaped = (left: leftTone.amplitude, right: rightTone.amplitude)
        let ratio = shaped.right / shaped.left
        print("stage balance 3 dB: left=\(shaped.left) right=\(shaped.right) ratio=\(ratio) windows=\(leftTone.windows) agreeing=\(leftTone.agreeing)/\(rightTone.agreeing)")
        XCTAssertEqual(ratio, 1.4125, accuracy: 0.06)
        XCTAssertEqual(shaped.left, 0.25 * 0.8414, accuracy: 0.01)

        model.setStage(StageSettings(), editedFor: model.outputKey)
        XCTAssertTrue(pump { self.backend.configuredDefaultSinkName == Harness.fiveK })
        XCTAssertTrue(pump { !self.backend.sinks.contains { $0.isStageSink } })
        XCTAssertEqual(backend.defaultSinkName, Harness.fiveK)
        XCTAssertNotEqual(model.state.mode, .insert)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("routing.json").path))
    }

    private func lowpassedNoise(cutoffHz: Double, rate: Double, rms: Float) -> [Float] {
        let length = 1 << 16
        let fft = PortableRealFFT(length: length)!
        var state: UInt64 = 11
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        let half = length / 2
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        for k in 1..<half {
            let hz = Double(k) * rate / Double(length)
            let magnitude = hz <= cutoffHz ? 1.0 : 1e-6
            let phase = 2 * Double.pi * next()
            re[k] = Float(magnitude * cos(phase))
            im[k] = Float(magnitude * sin(phase))
        }
        var time = [Float](repeating: 0, count: length)
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                time.withUnsafeMutableBufferPointer { t in
                    fft.inverse(real: r.baseAddress!, imag: i.baseAddress!, time: t.baseAddress!)
                }
            }
        }
        let power = time.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(length)
        let scale = power > 0 ? Float(Double(rms) / power.squareRoot()) : 0
        return time.map { $0 * scale }
    }

    private func writeNoiseWav(_ samples: [Float], repeats: Int) throws -> URL {
        let rate = Harness.sampleRate
        let frames = samples.count * repeats
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = frames * 4
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + payload))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append32(16)
        append16(1)
        append16(2)
        append32(UInt32(rate))
        append32(UInt32(rate * 4))
        append16(4)
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(payload))
        for _ in 0..<repeats {
            for sample in samples {
                let value = Int16((Double(sample) * 32767.0).rounded())
                append16(UInt16(bitPattern: value))
                append16(UInt16(bitPattern: value))
            }
        }
        let url = directory.appendingPathComponent("noise-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    func testLevelMonitorReportsTheLevelAndAQualityVerdictForPlayedAudio() throws {
        model.start()
        XCTAssertTrue(pump { self.model.state.outputKey == Harness.fiveK })
        XCTAssertTrue(pump { self.model.state.running && self.model.state.mode == .monitor })
        model.setLevelTracking(true)

        let noise = lowpassedNoise(cutoffHz: 16000, rate: Double(Harness.sampleRate), rms: 0.1)
        let wav = try writeNoiseWav(noise, repeats: 9)
        defer { try? FileManager.default.removeItem(at: wav) }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        player.arguments = ["pw-play", "--target", Harness.fiveK, wav.path]
        try player.run()
        defer { if player.isRunning { player.terminate() } }

        var sawLevel: Double?
        XCTAssertTrue(pump(20) {
            if let level = self.model.level.state.currentLevelDb, level > -40 { sawLevel = level }
            return self.model.level.state.quality != nil
        }, "level=\(String(describing: model.level.state.currentLevelDb)) status=\(model.state.status)")
        let level = try XCTUnwrap(sawLevel)
        print("level monitor: level=\(level) dB quality=\(String(describing: model.level.state.quality))")
        XCTAssertEqual(level, -20, accuracy: 2)
        let quality = try XCTUnwrap(model.level.state.quality)
        XCTAssertEqual(quality.kind, .lossy)
        XCTAssertEqual(try XCTUnwrap(quality.cutoffKHz), 16, accuracy: 1.5)
        XCTAssertNotNil(model.level.state.balance)
        XCTAssertFalse(model.level.state.exposureDays.isEmpty)
        XCTAssertEqual(model.state.runningRate, Double(Harness.sampleRate))
    }

    func testToneTestPlaybackReachesTheFiveKStandInAtTheExpectedLevel() async throws {
        model.start()
        XCTAssertTrue(pump { self.routing.realOutput?.name == Harness.fiveK })
        let app = AppModel.demo()
        app.start()
        for _ in 0..<400 where !app.state.connection.isConnected {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(app.state.connection.isConnected)
        let onFiveK = Recorder()
        let onOther = Recorder()
        let fiveKMonitor = try backend.startMonitor(sink: Harness.fiveK, block: onFiveK.block)
        let otherMonitor = try backend.startMonitor(sink: Harness.other, block: onOther.block)
        defer {
            fiveKMonitor.stop()
            otherMonitor.stop()
        }
        XCTAssertTrue(pump { fiveKMonitor.isReady && otherMonitor.isReady })
        let tones = ToneTestModel(host: app.eqHost, routing: routing, backend: backend, stage: model)
        XCTAssertNil(tones.blocker)
        tones.randomPause = { 0 }
        tones.randomCatch = { false }
        var captured: (left: [Float], right: [Float])?
        var quiet: [Float] = []
        tones.sleepMs = { ms in
            guard ms == 1250 else {
                try? await Task.sleep(nanoseconds: 5_000_000)
                return
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let loud = onFiveK.snapshot
            captured = (loud.left, loud.right)
            quiet = onOther.snapshot.left
        }
        tones.start()
        XCTAssertEqual(tones.phase, .running)
        XCTAssertTrue(model.toneHold)
        for _ in 0..<600 where captured == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        tones.stop()
        XCTAssertFalse(model.toneHold)
        let heard = try XCTUnwrap(captured)
        let expected = pow(10.0, ToneTestMath.clamp(-40) / 20)
        let peak = Double(heard.left.map { abs($0) }.max() ?? 0)
        let peakRight = Double(heard.right.map { abs($0) }.max() ?? 0)
        print("tone test: peak=\(peak) right=\(peakRight) expected=\(expected) other=\(quiet.map { abs($0) }.max() ?? 0)")
        XCTAssertEqual(peak, expected, accuracy: expected * 0.05)
        XCTAssertEqual(peakRight, peak, accuracy: expected * 0.01)
        XCTAssertLessThan(Double(quiet.map { abs($0) }.max() ?? 0), 1e-4)
        var crossings = 0
        var previous: Float = 0
        for sample in heard.left where abs(sample) > 0.002 {
            if (sample > 0) != (previous > 0) { crossings += 1 }
            previous = sample
        }
        XCTAssertTrue((1100...1500).contains(crossings), "zero crossings \(crossings)")
        await app.shutdown()
    }
}
