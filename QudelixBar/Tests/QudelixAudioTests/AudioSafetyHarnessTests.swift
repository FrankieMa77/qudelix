import Foundation
import QudelixAudio
@testable import QudelixBar
import XCTest

private final class SafetyHops: @unchecked Sendable {
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

private final class SafetyClock: AppClock {
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

private final class FrameSizes {
    private let lock = NSLock()
    private var seen: Set<Int> = []

    func add(_ frames: Int) {
        lock.lock()
        seen.insert(frames)
        lock.unlock()
    }

    var value: Set<Int> {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}

@MainActor
final class AudioSafetyHarnessTests: XCTestCase {
    private var backend: PipeWireAudioBackend!
    private var routing: OutputRouting!
    private var model: StageModel!
    private var hops: SafetyHops!
    private var clock: SafetyClock!
    private var directory: URL!
    private var originalConfigured: String?

    override func setUp() async throws {
        try Harness.require()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qx-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("impulses"),
                                                withIntermediateDirectories: true)
        backend = try PipeWireAudioBackend()
        originalConfigured = backend.configuredDefaultSinkName
        hops = SafetyHops()
        clock = SafetyClock()
        XCTAssertTrue(backend.setDefaultSink(named: Harness.fiveK))
        XCTAssertTrue(pump { self.backend.defaultSinkName == Harness.fiveK })
        XCTAssertTrue(pump { self.backend.sinkVolume(named: Harness.fiveK) != nil })
        setRealVolume(1, muted: false)
    }

    private func resetStageSinkState() {
        guard let backend,
              let probe = try? backend.startInsert(target: Harness.fiveK, render: { input, output, frames, channels, _ in
                  output.update(from: input, count: frames * channels)
              }) else { return }
        defer { probe.stop() }
        let stage = LinuxAudioNames.stageSinkName
        guard waitFor(8, { backend.sinkVolume(named: stage) != nil }),
              let volume = backend.sinkVolume(named: stage), volume.gain > 0 else { return }
        _ = backend.scaleSinkVolume(named: stage, by: min(1 / volume.gain, 16), muted: false)
        _ = waitFor { backend.sinkVolume(named: stage).map { abs($0.gain - 1) < 0.01 && !$0.muted } ?? false }
        Thread.sleep(forTimeInterval: 1.5)
    }

    override func tearDown() async throws {
        model?.shutdown()
        resetStageSinkState()
        if let backend {
            setRealVolume(1, muted: false)
            _ = backend.setForceRate(0)
            _ = backend.setDefaultSink(named: originalConfigured)
            backend.shutdown()
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        model = nil
        routing = nil
        backend = nil
    }

    private func makeModel(markerURL: URL? = nil) {
        routing = OutputRouting(backend: backend, clock: clock, hop: hops.hop,
                                memoryURL: directory.appendingPathComponent("routing.json"))
        model = StageModel(backend: backend, routing: routing, clock: clock,
                           settingsURL: directory.appendingPathComponent("stage.json"),
                           impulseDirectory: { [directory] in directory!.appendingPathComponent("impulses") },
                           forceMarkerURL: markerURL)
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

    private func sinkId(_ name: String) -> String? {
        backend.sinks.first { $0.name == name }.map { String($0.id) }
    }

    private func setProps(_ name: String, gain: Float, muted: Bool) {
        guard let id = sinkId(name) else { return XCTFail("no sink \(name)") }
        let props = "{ mute: \(muted), channelVolumes: [ \(gain), \(gain) ] }"
        XCTAssertEqual(runTool(["pw-cli", "s", id, "Props", props]).status, 0)
        XCTAssertTrue(waitFor {
            guard let volume = self.backend.sinkVolume(named: name) else { return false }
            return volume.muted == muted && abs(volume.channelVolume - gain) < 0.001
        })
    }

    private func setRealVolume(_ gain: Float, muted: Bool) {
        setProps(Harness.fiveK, gain: gain, muted: muted)
    }

    private func enableStage() {
        model.start()
        XCTAssertTrue(pump { self.model.state.outputKey == Harness.fiveK })
        var settings = StageSettings()
        settings.enabled = true
        model.setStage(settings, editedFor: model.outputKey)
        XCTAssertTrue(pump { self.model.state.routed }, "status: \(model.state.status)")
    }

    private func disableStage() {
        model.setStage(StageSettings(), editedFor: model.outputKey)
        XCTAssertTrue(pump { self.backend.configuredDefaultSinkName == Harness.fiveK })
        XCTAssertTrue(pump { !self.backend.sinks.contains { $0.isStageSink } })
    }

    func testScaleSinkVolumeWritesTheChannelVolumesAndTheMute() throws {
        XCTAssertTrue(backend.scaleSinkVolume(named: Harness.fiveK, by: 0.5, muted: nil))
        XCTAssertTrue(waitFor {
            guard let volume = self.backend.sinkVolume(named: Harness.fiveK) else { return false }
            return abs(volume.gain - 0.5) < 0.001 && !volume.muted
        })
        XCTAssertTrue(backend.scaleSinkVolume(named: Harness.fiveK, by: 0.5, muted: true))
        XCTAssertTrue(waitFor {
            guard let volume = self.backend.sinkVolume(named: Harness.fiveK) else { return false }
            return abs(volume.gain - 0.25) < 0.001 && volume.muted
        })
        XCTAssertFalse(backend.scaleSinkVolume(named: "qx_no_such_sink", by: 0.5, muted: nil))
    }

    func testTheRealSinkNeverEndsLouderThanWhatWasHeardThroughStage() throws {
        makeModel()
        enableStage()
        XCTAssertTrue(pump { self.backend.sinkVolume(named: LinuxAudioNames.stageSinkName) != nil })
        setProps(LinuxAudioNames.stageSinkName, gain: 0.2, muted: false)
        XCTAssertTrue(pump { abs((self.routing.rememberedStageGain ?? 1) - 0.2) < 0.001 })
        disableStage()
        XCTAssertTrue(waitFor {
            guard let volume = self.backend.sinkVolume(named: Harness.fiveK) else { return false }
            return abs(volume.gain - 0.2) < 0.01 && !volume.muted
        }, "real sink: \(String(describing: backend.sinkVolume(named: Harness.fiveK)))")
    }

    func testAMutedStageSinkMutesTheRealSinkWhenStageEnds() throws {
        makeModel()
        enableStage()
        setProps(LinuxAudioNames.stageSinkName, gain: 1, muted: true)
        disableStage()
        XCTAssertTrue(waitFor { self.backend.sinkVolume(named: Harness.fiveK)?.muted == true })
    }

    func testAStaleStagedStateIsHandedOverBeforeTheDefaultIsRestored() throws {
        let memory = RoutingMemory(target: Harness.fiveK, previousConfigured: Harness.fiveK,
                                   stageGain: 0.2, stageMuted: false)
        try JSONEncoder().encode(memory).write(to: directory.appendingPathComponent("routing.json"))
        XCTAssertTrue(backend.setDefaultSink(named: LinuxAudioNames.stageSinkName))
        XCTAssertTrue(pump { self.backend.configuredDefaultSinkName == LinuxAudioNames.stageSinkName })
        makeModel()
        model.start()
        XCTAssertTrue(pump { self.backend.configuredDefaultSinkName == Harness.fiveK })
        XCTAssertTrue(waitFor {
            guard let volume = self.backend.sinkVolume(named: Harness.fiveK) else { return false }
            return abs(volume.gain - 0.2) < 0.01
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("routing.json").path))
    }

    func testAForceRateLeftBehindByAnEarlierRunIsClearedAtStart() throws {
        let marker = directory.appendingPathComponent("force-rate.json")
        try Data("{\"rate\":44100}".utf8).write(to: marker)
        XCTAssertTrue(backend.setForceRate(44100))
        makeModel(markerURL: marker)
        model.start()
        XCTAssertTrue(pump { self.backend.forceRate == 0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testTheStageLegsAgreeOnTheRateAndAskForAWholeQuantum() throws {
        let sizes = FrameSizes()
        let insert = try backend.startInsert(target: Harness.fiveK) { input, output, frames, channels, _ in
            sizes.add(frames)
            output.update(from: input, count: frames * channels)
        }
        defer { insert.stop() }
        XCTAssertTrue(waitFor { insert.isReady })
        XCTAssertTrue(waitFor { insert.playbackLegState == .streaming })
        XCTAssertEqual(insert.format?.rate, Harness.sampleRate)
        let wav = try writeSineWav(frequency: 1000, amplitude: 0.25, seconds: 2)
        defer { try? FileManager.default.removeItem(at: wav) }
        XCTAssertTrue(playWav(wav, target: LinuxAudioNames.stageSinkName))
        XCTAssertTrue(waitFor { insert.sinkLegState == .streaming || !sizes.value.isEmpty })
        XCTAssertFalse(sizes.value.isEmpty)
        XCTAssertEqual(insert.sinkLegFormat?.rate, insert.format?.rate)
        XCTAssertEqual(sizes.value.filter { $0 % 512 != 0 }, [], "callback sizes: \(sizes.value)")
    }
}
