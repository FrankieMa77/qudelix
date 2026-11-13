import XCTest
@testable import QudelixBar

@MainActor
final class OutputRoutingTests: XCTestCase {
    private var directory: URL!
    private var backend: FakeAudioBackend!
    private var clock: ManualClock!
    private var hops: HopQueue!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        backend = FakeAudioBackend()
        backend.sinks = [StageRig.fiveK, StageRig.speakers]
        backend.defaultSinkName = "qx_5k"
        backend.configuredDefaultSinkName = "qx_5k"
        clock = ManualClock()
        hops = HopQueue()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var memoryURL: URL { directory.appendingPathComponent("routing.json") }

    private func makeRouting() -> OutputRouting {
        OutputRouting(backend: backend, clock: clock, hop: hops.hop, memoryURL: memoryURL)
    }

    private func writeMemory(target: String, previous: String?) throws {
        let data = try JSONEncoder().encode(RoutingMemory(target: target, previousConfigured: previous))
        try data.write(to: memoryURL)
    }

    func testRealOutputIsTheDefaultSinkAndNeverTheStageSink() {
        backend.sinks.append(AudioSink(id: 9, name: LinuxAudioNames.stageSinkName, description: "Qudelix Stage"))
        let routing = makeRouting()
        routing.start()
        XCTAssertEqual(routing.realOutput?.name, "qx_5k")
        XCTAssertEqual(routing.sinks.map(\.name), ["qx_5k", "alsa_speakers"])
        XCTAssertTrue(routing.stageSinkPresent)
    }

    func testFiveKOverUsbIsToldApartFromBluetooth() {
        backend.sinks = [StageRig.fiveK, StageRig.headset, StageRig.speakers]
        let routing = makeRouting()
        routing.start()
        XCTAssertTrue(routing.outputIsQudelix)
        XCTAssertTrue(routing.outputIsQudelixUsb)
        backend.defaultSinkName = "bluez_output.AA"
        routing.refresh()
        XCTAssertTrue(routing.outputIsQudelix)
        XCTAssertFalse(routing.outputIsQudelixUsb)
        XCTAssertEqual(routing.realOutput?.transport, .bluetooth)
        backend.defaultSinkName = "alsa_speakers"
        routing.refresh()
        XCTAssertFalse(routing.outputIsQudelix)
    }

    func testQudelixSinkPrefersTheUsbOne() {
        backend.sinks = [StageRig.headset, StageRig.speakers, StageRig.fiveK]
        let routing = makeRouting()
        routing.start()
        XCTAssertEqual(routing.qudelixSink?.name, "qx_5k")
        backend.sinks = [StageRig.headset, StageRig.speakers]
        routing.refresh()
        XCTAssertEqual(routing.qudelixSink?.name, "bluez_output.AA")
    }

    func testChangeEventsAreHoppedBeforeTheyReachTheModel() {
        let routing = makeRouting()
        routing.start()
        var notifications = 0
        routing.addObserver { notifications += 1 }
        backend.defaultSinkName = "alsa_speakers"
        backend.changeHandler?()
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(routing.realOutput?.name, "qx_5k")
        XCTAssertEqual(hops.pending, 1)
        hops.drain()
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(routing.realOutput?.name, "alsa_speakers")
    }

    func testObserversHearNothingWhenNothingChanged() {
        let routing = makeRouting()
        routing.start()
        var notifications = 0
        routing.addObserver { notifications += 1 }
        routing.refresh()
        routing.refresh()
        XCTAssertEqual(notifications, 0)
    }

    func testAStaleStageDefaultFromACrashIsRestoredToTheRememberedSink() throws {
        backend.defaultSinkName = LinuxAudioNames.stageSinkName
        backend.configuredDefaultSinkName = LinuxAudioNames.stageSinkName
        try writeMemory(target: "qx_5k", previous: "alsa_speakers")
        let routing = makeRouting()
        routing.start()
        XCTAssertEqual(backend.setDefaultCalls, ["alsa_speakers"])
        XCTAssertEqual(routing.realOutput?.name, "qx_5k")
        hops.drain()
        XCTAssertEqual(backend.configuredDefaultSinkName, "alsa_speakers")
        routing.refresh()
        XCTAssertFalse(FileManager.default.fileExists(atPath: memoryURL.path))
    }

    func testACrashThatHadNoExplicitDefaultClearsTheConfiguredOne() throws {
        backend.defaultSinkName = LinuxAudioNames.stageSinkName
        backend.configuredDefaultSinkName = LinuxAudioNames.stageSinkName
        try writeMemory(target: "qx_5k", previous: nil)
        let routing = makeRouting()
        routing.start()
        XCTAssertEqual(backend.setDefaultCalls, [nil])
    }

    func testAStaleDefaultWithoutAnyMemoryIsCleared() {
        backend.defaultSinkName = LinuxAudioNames.stageSinkName
        backend.configuredDefaultSinkName = LinuxAudioNames.stageSinkName
        let routing = makeRouting()
        routing.start()
        XCTAssertEqual(backend.setDefaultCalls, [nil])
    }

    func testAMissingPreviousSinkIsWrittenBackByName() throws {
        backend.defaultSinkName = LinuxAudioNames.stageSinkName
        backend.configuredDefaultSinkName = LinuxAudioNames.stageSinkName
        try writeMemory(target: "qx_5k", previous: "unplugged_dac")
        let routing = makeRouting()
        routing.start()
        XCTAssertEqual(backend.setDefaultCalls, ["unplugged_dac"])
    }

    func testAStageSinkOwnedByAnotherClientIsNotTouched() throws {
        backend.sinks.append(AudioSink(id: 9, name: LinuxAudioNames.stageSinkName, description: "Qudelix Stage"))
        backend.defaultSinkName = LinuxAudioNames.stageSinkName
        backend.configuredDefaultSinkName = LinuxAudioNames.stageSinkName
        try writeMemory(target: "qx_5k", previous: "alsa_speakers")
        let routing = makeRouting()
        routing.start()
        XCTAssertEqual(backend.setDefaultCalls, [])
        XCTAssertEqual(routing.realOutput?.name, "qx_5k")
    }

    func testRestoreIsNotRepeatedInsideTheRetryWindow() throws {
        backend.defaultSinkName = LinuxAudioNames.stageSinkName
        backend.configuredDefaultSinkName = LinuxAudioNames.stageSinkName
        backend.acceptDefaultChange = false
        try writeMemory(target: "qx_5k", previous: "alsa_speakers")
        let routing = makeRouting()
        routing.start()
        routing.refresh()
        routing.refresh()
        XCTAssertEqual(backend.setDefaultCalls.count, 1)
        clock.advance(OutputRouting.restoreRetry + 0.5)
        routing.refresh()
        XCTAssertEqual(backend.setDefaultCalls.count, 2)
    }

    func testNothingIsRestoredBeforeAnySinkAppears() {
        backend.sinks = []
        backend.defaultSinkName = LinuxAudioNames.stageSinkName
        backend.configuredDefaultSinkName = LinuxAudioNames.stageSinkName
        let routing = makeRouting()
        routing.start()
        XCTAssertEqual(backend.setDefaultCalls, [])
    }

    func testInsertRoundTripRemembersAndRestoresTheDefault() throws {
        let routing = makeRouting()
        routing.start()
        routing.prepareInsert(target: "qx_5k")
        let saved = try JSONDecoder().decode(RoutingMemory.self, from: Data(contentsOf: memoryURL))
        XCTAssertEqual(saved, RoutingMemory(target: "qx_5k", previousConfigured: "qx_5k",
                                            stageGain: 1, stageMuted: false))
        backend.sinks.append(AudioSink(id: 9, name: LinuxAudioNames.stageSinkName, description: "Qudelix Stage"))
        routing.refresh()
        XCTAssertTrue(routing.activateStage())
        XCTAssertEqual(backend.defaultSinkName, LinuxAudioNames.stageSinkName)
        hops.drain()
        XCTAssertTrue(routing.isStageDefault)
        XCTAssertEqual(routing.realOutput?.name, "qx_5k")
        routing.endInsert()
        XCTAssertEqual(backend.setDefaultCalls.last, "qx_5k")
        backend.sinks.removeAll { $0.isStageSink }
        hops.drain()
        routing.refresh()
        XCTAssertFalse(routing.isStageDefault)
        XCTAssertFalse(FileManager.default.fileExists(atPath: memoryURL.path))
    }

    func testEndingAnInsertThatNeverSwitchedLeavesTheDefaultAlone() {
        let routing = makeRouting()
        routing.start()
        routing.prepareInsert(target: "qx_5k")
        routing.endInsert()
        XCTAssertEqual(backend.setDefaultCalls, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: memoryURL.path))
    }

    func testEndingAnInsertWhoseSwitchWasStillInFlightStillRestores() {
        backend.deferDefaultChange = true
        let routing = makeRouting()
        routing.start()
        routing.prepareInsert(target: "qx_5k")
        XCTAssertTrue(routing.activateStage())
        routing.endInsert()
        XCTAssertEqual(backend.setDefaultCalls, [LinuxAudioNames.stageSinkName, "qx_5k"])
    }

    func testAUserChoiceMadeWhileStagedIsNotOverwrittenOnStop() {
        let routing = makeRouting()
        routing.start()
        routing.prepareInsert(target: "qx_5k")
        backend.sinks.append(AudioSink(id: 9, name: LinuxAudioNames.stageSinkName, description: "Qudelix Stage"))
        routing.refresh()
        routing.activateStage()
        routing.refresh()
        XCTAssertTrue(routing.isStageDefault)
        backend.defaultSinkName = "alsa_speakers"
        backend.configuredDefaultSinkName = "alsa_speakers"
        routing.refresh()
        let before = backend.setDefaultCalls.count
        routing.endInsert()
        XCTAssertEqual(backend.setDefaultCalls.count, before)
        XCTAssertEqual(backend.configuredDefaultSinkName, "alsa_speakers")
    }

    func testStageDefaultWithoutAKnownTargetHasNoRealOutput() {
        backend.sinks.append(AudioSink(id: 9, name: LinuxAudioNames.stageSinkName, description: "Qudelix Stage"))
        backend.defaultSinkName = LinuxAudioNames.stageSinkName
        let routing = makeRouting()
        routing.start()
        XCTAssertNil(routing.realOutput)
    }

    func testSinkVolumeInDecibels() {
        let routing = makeRouting()
        routing.start()
        backend.volumes["qx_5k"] = AudioSinkVolume(volume: 1, channelVolume: 0.1, muted: false)
        XCTAssertEqual(try XCTUnwrap(routing.sinkVolumeDb(named: "qx_5k")), -20, accuracy: 0.001)
        backend.volumes["qx_5k"] = AudioSinkVolume(volume: 0.5, channelVolume: 0.5, muted: false)
        XCTAssertEqual(try XCTUnwrap(routing.sinkVolumeDb(named: "qx_5k")), -12.041, accuracy: 0.01)
        backend.volumes["qx_5k"] = AudioSinkVolume(volume: 1, channelVolume: 0.5, muted: true)
        XCTAssertNil(routing.sinkVolumeDb(named: "qx_5k"))
        backend.volumes["qx_5k"] = AudioSinkVolume(volume: 1, channelVolume: 0, muted: false)
        XCTAssertNil(routing.sinkVolumeDb(named: "qx_5k"))
        XCTAssertNil(routing.sinkVolumeDb(named: "missing"))
    }

    func testShutdownReleasesTheHandlerAndRestores() {
        let routing = makeRouting()
        routing.start()
        routing.prepareInsert(target: "qx_5k")
        backend.sinks.append(AudioSink(id: 9, name: LinuxAudioNames.stageSinkName, description: "Qudelix Stage"))
        routing.refresh()
        routing.activateStage()
        routing.shutdown()
        XCTAssertNil(backend.changeHandler)
        XCTAssertEqual(backend.setDefaultCalls.last, "qx_5k")
    }
}

@MainActor
final class FiveKAddressLookupTests: XCTestCase {
    private var directory: URL!
    private var backend: FakeAudioBackend!
    private var hops: HopQueue!
    private var lookups = 0
    private var found: Set<String> = []
    private var lookupThreads: [Bool] = []

    private static let renamed = AudioSink(id: 5, name: "bluez_output.AA_BB_CC_DD_EE_FF.1",
                                           description: "My Earbuds", deviceApi: "bluez5",
                                           bluezAddress: "AA:BB:CC:DD:EE:FF")
    private static let other = AudioSink(id: 6, name: "bluez_output.11_22_33_44_55_66.1",
                                         description: "Car Stereo", deviceApi: "bluez5",
                                         bluezAddress: "11:22:33:44:55:66")

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fivek-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        backend = FakeAudioBackend()
        hops = HopQueue()
        lookups = 0
        found = ["AA:BB:CC:DD:EE:FF"]
        lookupThreads = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeRouting(offload: @escaping OutputRouting.Hop = { $0() }) -> OutputRouting {
        OutputRouting(backend: backend, clock: ManualClock(), hop: hops.hop,
                      memoryURL: directory.appendingPathComponent("routing.json"),
                      fiveKLookup: { [unowned self] in
                          self.lookups += 1
                          self.lookupThreads.append(Thread.isMainThread)
                          return self.found
                      },
                      offload: offload)
    }

    func testARenamedFiveKIsRecognizedByItsAddress() {
        backend.sinks = [Self.renamed, Self.other]
        backend.defaultSinkName = Self.renamed.name
        let routing = makeRouting()
        routing.start()
        XCTAssertFalse(routing.outputIsQudelix)
        hops.drain()
        XCTAssertTrue(routing.outputIsQudelix)
        XCTAssertEqual(routing.qudelixSink?.name, Self.renamed.name)
        XCTAssertFalse(routing.sinks.first { $0.name == Self.other.name }?.isQudelix5K ?? true)
    }

    func testTheDescriptionStaysAsTheFallbackWhenBlueZKnowsNothing() {
        found = []
        backend.sinks = [StageRig.headset, Self.other]
        backend.defaultSinkName = StageRig.headset.name
        let routing = makeRouting()
        routing.start()
        hops.drain()
        XCTAssertTrue(routing.outputIsQudelix)
        XCTAssertFalse(routing.sinks.first { $0.name == Self.other.name }?.isQudelix5K ?? true)
    }

    func testOneListingServesEveryRefreshUntilTheBluetoothOutputsChange() {
        backend.sinks = [Self.renamed]
        backend.defaultSinkName = Self.renamed.name
        let routing = makeRouting()
        routing.start()
        hops.drain()
        for _ in 0..<5 {
            routing.refresh()
            hops.drain()
        }
        XCTAssertEqual(lookups, 1)
        backend.sinks = [Self.renamed, Self.other]
        routing.refresh()
        hops.drain()
        XCTAssertEqual(lookups, 2)
        routing.refresh()
        hops.drain()
        XCTAssertEqual(lookups, 2)
    }

    func testNothingIsListedWithoutABluetoothOutput() {
        backend.sinks = [StageRig.fiveK, StageRig.speakers]
        let routing = makeRouting()
        routing.start()
        hops.drain()
        XCTAssertEqual(lookups, 0)
    }

    func testAChangeDuringALookupIsPickedUpAfterIt() {
        backend.sinks = [Self.renamed]
        backend.defaultSinkName = Self.renamed.name
        var held: [() -> Void] = []
        let routing = makeRouting(offload: { held.append($0) })
        routing.start()
        backend.sinks = [Self.renamed, Self.other]
        routing.refresh()
        XCTAssertEqual(held.count, 1)
        held.removeFirst()()
        hops.drain()
        XCTAssertEqual(held.count, 1)
        held.removeFirst()()
        hops.drain()
        XCTAssertEqual(lookups, 2)
    }

    func testTheListingNeverRunsOnTheMainThread() async {
        backend.sinks = [Self.renamed]
        backend.defaultSinkName = Self.renamed.name
        let routing = makeRouting(offload: OutputRouting.backgroundHop)
        routing.start()
        let deadline = Date().addingTimeInterval(5)
        while !routing.outputIsQudelix, Date() < deadline {
            hops.drain()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(routing.outputIsQudelix)
        XCTAssertEqual(lookupThreads, [false])
    }
}
