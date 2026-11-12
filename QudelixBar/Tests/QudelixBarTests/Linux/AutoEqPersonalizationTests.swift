import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import QudelixBar

final class RecordingCatalogue: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String] = []
    private let inner = DemoCatalogueTransport()

    var equalizeBodies: [String] { lock.withLock { bodies } }

    func send(_ request: URLRequest, limit: Int) async throws -> Data {
        if request.url?.path == "/equalize", let body = request.httpBody {
            lock.withLock { bodies.append(String(decoding: body, as: UTF8.self)) }
        }
        return try await inner.send(request, limit: limit)
    }
}

final class PublishedFixtures: @unchecked Sendable {
    private let lock = NSLock()
    private var indexCalls = 0
    private var presetPaths: [String] = []

    static let index = """
        - [Sennheiser HD 600](./oratory1990/over-ear/Sennheiser%20HD%20600)
        - [Sennheiser HD 650](./oratory1990/over-ear/Sennheiser%20HD%20650)
        - [Sennheiser HD 650](./crinacle/over-ear/Sennheiser%20HD%20650)
        - [Moondrop Aria](./crinacle/in-ear/Moondrop%20Aria)
        """

    static let preset = "Preamp: -5.5 dB\n"
        + "Filter 1: ON LSC Fc 105 Hz Gain 4.0 dB Q 0.70\n"
        + "Filter 2: ON PK Fc 1000 Hz Gain -2.0 dB Q 1.40\n"
        + "Filter 3: ON HSC Fc 10000 Hz Gain -3.0 dB Q 0.70\n"

    var indexCount: Int { lock.withLock { indexCalls } }
    var presets: [String] { lock.withLock { presetPaths } }

    func apply(to environment: inout LibraryEnvironment) {
        environment.publishedIndex = { [self] _, _ in
            lock.withLock { indexCalls += 1 }
            return Data(Self.index.utf8)
        }
        environment.publishedPreset = { [self] entry in
            lock.withLock { presetPaths.append(entry.path) }
            guard let file = ParametricEQFile.parse(Self.preset) else { throw URLError(.cannotParseResponse) }
            return file
        }
    }
}

final class AutoEqPersonalizationTests: XCTestCase {
    private var directory: URL!
    private var lockURL: URL!
    private var clock: ManualClock!
    private var catalogue: RecordingCatalogue!
    private var published: PublishedFixtures!
    private var held: [AppModel] = []

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("autoeq-personal-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActiveSlotFile.directoryOverride = directory
        EqHistoryFile.directoryOverride = directory
        lockURL = directory.appendingPathComponent("qudelix.lock")
        clock = ManualClock()
        catalogue = RecordingCatalogue()
        published = PublishedFixtures()
    }

    override func tearDown() async throws {
        for model in held {
            await model.eq.waitForIdle()
            await model.waitForIdle()
        }
        ActiveSlotFile.directoryOverride = nil
        EqHistoryFile.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        held = []
        try await super.tearDown()
    }

    private func environment() -> LibraryEnvironment {
        var runtime = AIRuntime()
        runtime.keychain = AIKeychain(directory: directory.appendingPathComponent("keys"), environment: [:])
        runtime.researchDirectory = directory.appendingPathComponent("research")
        runtime.measurement = { _ in nil }
        runtime.readKey = { nil }
        var env = LibraryEnvironment(libraryFile: directory.appendingPathComponent("presets.json"),
                                     autoEqTransport: catalogue, ai: runtime, searchDelay: 0.4)
        published.apply(to: &env)
        return env
    }

    @MainActor
    private func open(_ device: EqTestDevice?) async -> AppModel {
        let url = lockURL
        let links: [QxLink] = device.map { [$0.link] } ?? []
        let model = AppModel(makeLinks: { links },
                             acquireLock: { QxInstanceLock.acquire(at: url) },
                             probeDevice: { AppDeviceProbe(present: device != nil) },
                             clock: clock, retryInterval: 2, connectTimeout: 2)
        model.libraryEnvironment = environment()
        held.append(model)
        guard let device else { return model }
        model.start()
        await until("connected") { model.state.connection.isConnected && model.eq.state.ready }
        await model.eq.waitForIdle()
        device.link.clearSends()
        return model
    }

    @MainActor
    private func until(_ what: String, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(4)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func field(_ body: String, _ key: String) -> Double? {
        let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        return (object?[key] as? NSNumber)?.doubleValue
    }

    @MainActor
    private func search(_ autoEq: AutoEqSearchModel, _ text: String) async {
        autoEq.setQuery(text)
        autoEq.searchNow()
        await autoEq.waitForIdle()
    }

    @MainActor
    func testTheDefaultsAreTheMacsAndTheRangesComeFromCorrectionOptions() async {
        let autoEq = await open(nil).library.autoEq
        XCTAssertEqual(autoEq.state.mode, .fit)
        XCTAssertEqual(autoEq.state.bass, 0)
        XCTAssertEqual(autoEq.state.tilt, 0)
        XCTAssertEqual(autoEq.state.bassText, "+0.0 dB")
        XCTAssertEqual(autoEq.state.tiltText, "+0.00 dB/oct")
        XCTAssertFalse(autoEq.state.canReset)
        XCTAssertEqual(AutoEqSearchModel.bassRange, -6...6)
        XCTAssertEqual(AutoEqSearchModel.tiltRange, -1...1)
        XCTAssertEqual(AutoEqSearchModel.bassStep, 0.5)
        XCTAssertEqual(AutoEqSearchModel.tiltStep, 0.05)
        XCTAssertEqual(AutoEqMode.fit.label, "Fit to my device")
        XCTAssertEqual(AutoEqMode.published.label, "Published preset")
        XCTAssertEqual(autoEq.state.fitHint,
                       "Fitted to the 10-band mode \u{2014} asked for a curve this device can hold as-is.")
    }

    @MainActor
    func testBassAndTiltSnapClampAndLightUpReset() async {
        let autoEq = await open(nil).library.autoEq
        autoEq.setBass(2.3)
        XCTAssertEqual(autoEq.state.bass, 2.5)
        autoEq.setBass(99)
        XCTAssertEqual(autoEq.state.bass, 6)
        autoEq.setTilt(-0.52)
        XCTAssertEqual(autoEq.state.tilt, -0.5)
        autoEq.setTilt(-7)
        XCTAssertEqual(autoEq.state.tilt, -1)
        XCTAssertEqual(autoEq.state.bassText, "+6.0 dB")
        XCTAssertEqual(autoEq.state.tiltText, "\u{2212}1.00 dB/oct")
        XCTAssertTrue(autoEq.state.canReset)
        autoEq.resetPersonalization()
        XCTAssertEqual(autoEq.state.bass, 0)
        XCTAssertEqual(autoEq.state.tilt, 0)
        XCTAssertNil(autoEq.state.error)
        XCTAssertEqual(autoEq.state.target, AutoEqSearchModel.recommendedTarget)
        XCTAssertFalse(autoEq.state.canReset)
    }

    @MainActor
    func testAPickedTargetCountsAsPersonalizationAndResetClearsIt() async {
        let device = EqTestDevice()
        let autoEq = await open(device).library.autoEq
        await search(autoEq, "HD 600")
        autoEq.select(autoEq.state.results.first?.id)
        await autoEq.waitForIdle()
        autoEq.setTarget("Diffuse field over-ear")
        XCTAssertTrue(autoEq.state.canReset)
        await autoEq.waitForIdle()
        autoEq.resetPersonalization()
        XCTAssertEqual(autoEq.state.target, AutoEqSearchModel.recommendedTarget)
        XCTAssertFalse(autoEq.state.canReset)
    }

    @MainActor
    func testBassAndTiltReachTheOptimizerAfterTheDebounceAndRefitTheSelection() async {
        let device = EqTestDevice()
        let autoEq = await open(device).library.autoEq
        await search(autoEq, "HD 600")
        autoEq.select(autoEq.state.results.first?.id)
        await autoEq.waitForIdle()
        XCTAssertEqual(catalogue.equalizeBodies.count, 1)
        XCTAssertNil(field(catalogue.equalizeBodies[0], "bass_boost_gain"))
        XCTAssertNil(field(catalogue.equalizeBodies[0], "tilt"))
        autoEq.setBass(3)
        autoEq.setTilt(-0.25)
        XCTAssertEqual(catalogue.equalizeBodies.count, 1)
        clock.advance(0.5)
        XCTAssertTrue(autoEq.state.fitting)
        await autoEq.waitForIdle()
        XCTAssertEqual(catalogue.equalizeBodies.count, 2)
        XCTAssertEqual(field(catalogue.equalizeBodies[1], "bass_boost_gain"), 3)
        XCTAssertEqual(field(catalogue.equalizeBodies[1], "tilt"), -0.25)
        XCTAssertNotNil(autoEq.state.preview)
    }

    @MainActor
    func testPublishedModeLoadsTheIndexAndFetchesThePresetThroughTheSeams() async {
        let device = EqTestDevice()
        let model = await open(device)
        let autoEq = model.library.autoEq
        autoEq.setMode(.published)
        XCTAssertEqual(autoEq.state.mode, .published)
        await search(autoEq, "HD 650")
        XCTAssertEqual(published.indexCount, 1)
        XCTAssertTrue(catalogue.equalizeBodies.isEmpty)
        XCTAssertEqual(autoEq.state.results.map(\.title), ["Sennheiser HD 650", "Sennheiser HD 650"])
        autoEq.select(autoEq.state.results.first?.id)
        await autoEq.waitForIdle()
        XCTAssertEqual(published.presets.count, 1)
        XCTAssertTrue(published.presets[0].hasSuffix("Sennheiser%20HD%20650"))
        XCTAssertEqual(autoEq.state.preview?.preGain ?? 0, -5.5, accuracy: 0.001)
        XCTAssertEqual(autoEq.state.preview?.bands.count, 3)
        XCTAssertTrue(autoEq.state.provenance?.hasSuffix("published preset") == true)
        XCTAssertTrue(autoEq.apply())
        XCTAssertTrue(autoEq.state.summary?.contains("Applied 3 bands") == true)
    }

    @MainActor
    func testPublishedModeWarnsThatPersonalizationAndTheLimitAreNotHonoured() async {
        let device = EqTestDevice()
        let autoEq = await open(device).library.autoEq
        autoEq.useCutoff { 12.0 }
        autoEq.setLimitToCutoff(true)
        autoEq.setBass(2)
        autoEq.setMode(.published)
        await search(autoEq, "HD 600")
        autoEq.select(autoEq.state.results.first?.id)
        await autoEq.waitForIdle()
        let warnings = autoEq.state.warnings.joined(separator: "\n")
        XCTAssertTrue(warnings.contains("12.0 kHz limit was not applied"))
        XCTAssertTrue(warnings.contains("+2.0 dB bass"))
    }

    @MainActor
    func testSwitchingModeKeepsTheQueryAndSearchesTheOtherCatalogue() async {
        let device = EqTestDevice()
        let autoEq = await open(device).library.autoEq
        await search(autoEq, "Aria")
        XCTAssertEqual(autoEq.state.results.map(\.title), ["Moondrop Aria"])
        XCTAssertNil(autoEq.state.status)
        autoEq.setMode(.published)
        XCTAssertEqual(autoEq.state.query, "Aria")
        await autoEq.waitForIdle()
        XCTAssertEqual(autoEq.state.results.map(\.title), ["Moondrop Aria"])
        XCTAssertTrue(autoEq.state.results[0].detail.contains("crinacle"))
        autoEq.setQuery("")
        XCTAssertEqual(autoEq.state.status, "4 presets available. Start typing to search.")
        autoEq.setMode(.fit)
        XCTAssertEqual(autoEq.state.status, "6 headphones available. Start typing to search.")
    }

    @MainActor
    func testTheCutoffOfferAppearsOnlyWhenACutoffIsKnownAndIsLimitedToTheMacRange() async {
        let autoEq = await open(nil).library.autoEq
        XCTAssertNil(autoEq.state.cutoffHz)
        XCTAssertNil(autoEq.state.cutoffLabel)
        autoEq.useCutoff { 16.0 }
        XCTAssertEqual(autoEq.state.cutoffHz, 16000)
        XCTAssertEqual(autoEq.state.cutoffLabel,
                       "Limit correction to 16.0 kHz \u{2014} what's playing now stops there")
        autoEq.useCutoff { 4.0 }
        XCTAssertNil(autoEq.state.cutoffHz)
        autoEq.useCutoff { 20.0 }
        XCTAssertNil(autoEq.state.cutoffHz)
        autoEq.useCutoff { .infinity }
        XCTAssertNil(autoEq.state.cutoffHz)
        autoEq.useCutoff { 15.5 }
        autoEq.useCutoff(nil)
        XCTAssertNil(autoEq.state.cutoffHz)
        XCTAssertFalse(autoEq.state.limitToCutoff)
    }

    @MainActor
    func testTheLimitChangesWhatIsAskedOfTheOptimizer() async {
        let device = EqTestDevice()
        let autoEq = await open(device).library.autoEq
        autoEq.useCutoff { 15.0 }
        await search(autoEq, "HD 600")
        autoEq.select(autoEq.state.results.first?.id)
        await autoEq.waitForIdle()
        let plain = catalogue.equalizeBodies[0]
        autoEq.setLimitToCutoff(true)
        clock.advance(0.5)
        await autoEq.waitForIdle()
        XCTAssertEqual(catalogue.equalizeBodies.count, 2)
        XCTAssertNotEqual(catalogue.equalizeBodies[1], plain)
        autoEq.useCutoff(nil)
        clock.advance(0.5)
        XCTAssertTrue(autoEq.state.fitting)
        await autoEq.waitForIdle()
        XCTAssertNotNil(autoEq.state.preview)
    }

    @MainActor
    func testTheQueryAndResultsSurviveForTheSession() async {
        let device = EqTestDevice()
        let autoEq = await open(device).library.autoEq
        await search(autoEq, "HD 6")
        let results = autoEq.state.results
        XCTAssertFalse(results.isEmpty)
        var late: AutoEqState?
        autoEq.addObserver { late = $0 }
        XCTAssertEqual(late?.query, "HD 6")
        XCTAssertEqual(late?.results, results)
        autoEq.setMode(.published)
        autoEq.setMode(.fit)
        await autoEq.waitForIdle()
        XCTAssertEqual(autoEq.state.query, "HD 6")
        XCTAssertEqual(autoEq.state.results.map(\.title), results.map(\.title))
    }

    @MainActor
    func testAppliedCorrectionLandsAReferenceSoTheFitButtonReadsReFit() async {
        let device = EqTestDevice()
        let model = await open(device)
        var landed: [ReferenceCurve] = []
        model.eqHost.onReferenceLanded = { curve, _ in landed.append(curve) }
        let autoEq = model.library.autoEq
        autoEq.setBass(1.5)
        await search(autoEq, "HD 600")
        autoEq.select(autoEq.state.results.first?.id)
        await autoEq.waitForIdle()
        XCTAssertTrue(autoEq.apply())
        XCTAssertEqual(landed.count, 1)
        XCTAssertEqual(landed.first?.headphone, "Sennheiser HD 600")
        XCTAssertEqual(landed.first?.source, "AutoEq optimizer")
        XCTAssertEqual(landed.first?.bassBoostDb, 1.5)
    }
}
