import XCTest
@testable import QudelixBar

final class HopQueue {
    private var queue: [() -> Void] = []

    var hop: OutputRouting.Hop {
        { [self] work in queue.append(work) }
    }

    var pending: Int { queue.count }

    func drain() {
        var rounds = 0
        while !queue.isEmpty, rounds < 200 {
            let work = queue.removeFirst()
            work()
            rounds += 1
        }
    }
}

@MainActor
final class FakeReporter: AudioDeviceReporting {
    var reportedVolumeDb: Double?
    var reportedActiveCall: Bool?
    var reportedInputSource: String?
    private(set) var statusRequests = 0

    func requestDeviceStatus() {
        statusRequests += 1
    }
}

@MainActor
final class StageRig {
    nonisolated static let fiveK = AudioSink(id: 1, name: "qx_5k", description: "Qudelix-5K USB DAC",
                                 deviceApi: "alsa", deviceBus: "usb",
                                 vendorId: "0x0a12", productId: "0x4007")
    nonisolated static let speakers = AudioSink(id: 2, name: "alsa_speakers", description: "Speakers",
                                    deviceApi: "alsa", deviceBus: "pci")
    nonisolated static let headset = AudioSink(id: 3, name: "bluez_output.AA", description: "Qudelix-5K",
                                   deviceApi: "bluez5", bluezAddress: "AA")

    let backend = FakeAudioBackend()
    let clock = ManualClock()
    let hops = HopQueue()
    let reporter = FakeReporter()
    let directory: URL
    let routing: OutputRouting
    let model: StageModel

    var settingsURL: URL { directory.appendingPathComponent("stage.json") }
    var memoryURL: URL { directory.appendingPathComponent("routing.json") }
    var impulseDirectory: URL { directory.appendingPathComponent("impulses") }

    init(directory: URL? = nil,
         sinks: [AudioSink] = [StageRig.fiveK, StageRig.speakers],
         defaultSink: String? = "qx_5k",
         configured: String?? = nil,
         detect: Bool = false,
         start: Bool = true,
         prepare: (FakeAudioBackend) -> Void = { _ in }) throws {
        let dir = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("stage-rig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("impulses"),
                                                withIntermediateDirectories: true)
        self.directory = dir
        backend.sinks = sinks
        backend.defaultSinkName = defaultSink
        backend.configuredDefaultSinkName = configured ?? defaultSink
        prepare(backend)
        let settings = dir.appendingPathComponent("stage.json")
        if !FileManager.default.fileExists(atPath: settings.path) {
            var seed = PersistedStageState()
            seed.detectQuality = detect
            StageStateFile.save(seed, to: settings)
        }
        routing = OutputRouting(backend: backend, clock: clock, hop: hops.hop,
                                memoryURL: dir.appendingPathComponent("routing.json"))
        model = StageModel(backend: backend, routing: routing, clock: clock,
                           settingsURL: settings,
                           impulseDirectory: { dir.appendingPathComponent("impulses") })
        model.reporter = reporter
        if start { model.start() }
    }

    func cleanUp() {
        model.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    func settle(_ seconds: Double = 0.5) {
        hops.drain()
        var elapsed = 0.0
        while elapsed < seconds {
            clock.advance(0.1)
            hops.drain()
            elapsed += 0.1
        }
    }

    func tick(_ count: Int = 1) {
        for _ in 0..<count {
            clock.advance(1)
            hops.drain()
        }
    }

    var key: String? { model.outputKey }

    func enableStage(_ preset: StageSettings = .music) {
        var settings = preset
        settings.enabled = true
        model.setStage(settings, editedFor: key)
        settle(0.5)
    }

    func changeDefault(to name: String) {
        backend.defaultSinkName = name
        backend.configuredDefaultSinkName = name
        backend.changeHandler?()
        settle(0.3)
    }

    func feedMonitor(_ mono: [Float], rate: Int = 48000, scale: Float = 1) {
        guard let monitor = backend.monitors.last(where: { !$0.stream.stopped }) else { return }
        var interleaved = [Float](repeating: 0, count: mono.count * 2)
        for (i, v) in mono.enumerated() {
            interleaved[i * 2] = v * scale
            interleaved[i * 2 + 1] = v * scale
        }
        interleaved.withUnsafeBufferPointer { monitor.block($0.baseAddress!, mono.count, 2, rate) }
    }

    func feedInsert(left: [Float], right: [Float], rate: Int = 48000) -> [Float] {
        guard let insert = backend.inserts.last(where: { !$0.stream.stopped }) else { return [] }
        var input = [Float](repeating: 0, count: left.count * 2)
        for i in 0..<left.count {
            input[i * 2] = left[i]
            input[i * 2 + 1] = right[i]
        }
        var output = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                insert.render(source.baseAddress!, target.baseAddress!, left.count, 2, rate)
            }
        }
        return output
    }

    static func sine(_ frequency: Double, amplitude: Float, frames: Int, rate: Double = 48000,
                     start: Int = 0) -> [Float] {
        (0..<frames).map { i in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(start + i) / rate))
        }
    }
}
