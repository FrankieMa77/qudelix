import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import QudelixBar

final class CountingCatalogue: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private let inner = DemoCatalogueTransport()
    var failEntries = false
    var delay: TimeInterval = 0

    var requests: [String] { lock.withLock { paths } }

    func send(_ request: URLRequest, limit: Int) async throws -> Data {
        lock.withLock { paths.append(request.url?.path ?? "") }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if failEntries, request.url?.path == "/entries" { throw URLError(.notConnectedToInternet) }
        return try await inner.send(request, limit: limit)
    }
}

final class SlowAITransport: AITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent = 0
    let replies: [Data]
    let delay: TimeInterval

    init(_ replies: [Data], delay: TimeInterval) {
        self.replies = replies
        self.delay = delay
    }

    var count: Int { lock.withLock { sent } }

    func send(_ request: URLRequest, host: String, limit: Int) async throws -> Data {
        let index = lock.withLock { () -> Int in
            sent += 1
            return sent - 1
        }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return replies[min(index, replies.count - 1)]
    }
}

final class FailingAITransport: AITransport, @unchecked Sendable {
    let error: Error
    init(_ error: Error) { self.error = error }
    func send(_ request: URLRequest, host: String, limit: Int) async throws -> Data { throw error }
}

final class LibraryModelTests: XCTestCase {
    private var directory: URL!
    private var lockURL: URL!
    private var clock: ManualClock!
    private var catalogue: CountingCatalogue!
    private var researchDirectory: URL!
    private var keyDirectory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("library-model-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActiveSlotFile.directoryOverride = directory
        EqHistoryFile.directoryOverride = directory
        lockURL = directory.appendingPathComponent("qudelix.lock")
        researchDirectory = directory.appendingPathComponent("research", isDirectory: true)
        keyDirectory = directory.appendingPathComponent("keys", isDirectory: true)
        try? FileManager.default.createDirectory(at: researchDirectory,
                                                 withIntermediateDirectories: true)
        clock = ManualClock()
        catalogue = CountingCatalogue()
    }

    override func tearDown() {
        ActiveSlotFile.directoryOverride = nil
        EqHistoryFile.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        catalogue = nil
        super.tearDown()
    }

    private var libraryFile: URL { directory.appendingPathComponent("presets.json") }

    private func chat(_ text: String) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: ["choices": [["message": ["content": text]]]])) ?? Data()
    }

    private let dossierText = "{\"signature\": \"Neutral with a lifted top\", "
        + "\"bass\": \"Lean below 60 Hz\", \"mids\": \"Even\", \"treble\": \"A peak at 6 kHz\", "
        + "\"soundstage\": \"Wide\", \"knownIssues\": [{\"where\": \"3-5 kHz\", "
        + "\"issue\": \"peak\"}], \"confidence\": \"high\"}"

    private func draftText(count: Int = 10, name: String = "Airy 650") -> String {
        let freqs = QxEqGroup.user.defaultFreqs
        let rows = (0..<count).map { index in
            "{\"freq\": \(freqs[index % 10] + (index >= 10 ? index : 0)), "
                + "\"gainDb\": \(Double(index % 5) - 2), \"q\": 1.0, \"kind\": \"peak\"}"
        }.joined(separator: ", ")
        return "{\"name\": \"\(name)\", \"rationale\": \"Lifts the presence dip.\", "
            + "\"bands\": [\(rows)]}"
    }

    private func environment(ai transport: AITransport? = nil,
                             key: String? = nil) -> LibraryEnvironment {
        var runtime = AIRuntime()
        runtime.keychain = AIKeychain(directory: keyDirectory, environment: [:])
        runtime.transport = transport ?? ScriptedAITransport()
        runtime.researchDirectory = researchDirectory
        runtime.measurement = { _ in nil }
        runtime.readKey = { nil }
        if let key { runtime.keychain.save(key: key, provider: AIProvider.mistral.rawValue) }
        return LibraryEnvironment(libraryFile: libraryFile, autoEqTransport: catalogue,
                                  ai: runtime, searchDelay: 0.4)
    }

    @MainActor
    private func makeModel(_ device: EqTestDevice?, _ env: LibraryEnvironment) -> AppModel {
        let url = lockURL
        let links: [QxLink] = device.map { [$0.link] } ?? []
        let model = AppModel(makeLinks: { links },
                             acquireLock: { QxInstanceLock.acquire(at: url) },
                             probeDevice: { AppDeviceProbe(present: device != nil) },
                             clock: clock, retryInterval: 2, connectTimeout: 2)
        model.libraryEnvironment = env
        return model
    }

    @MainActor
    private func until(_ what: String = "condition", timeout: TimeInterval = 4,
                       _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    private func open(_ device: EqTestDevice, _ env: LibraryEnvironment) async -> AppModel {
        let model = makeModel(device, env)
        model.start()
        await until("connected") { model.state.connection.isConnected && model.eq.state.ready }
        device.link.clearSends()
        return model
    }

    @MainActor
    private func settle(_ model: AppModel) async {
        await model.eq.waitForIdle()
        await model.waitForIdle()
    }

    private func preset(_ name: String, group: QxEqGroup = .user, gain: Double = 1.5,
                        source: String? = nil) -> LibraryPreset {
        LibraryPreset(name: name, scope: .global, group: group,
                      bands: group.defaultFreqs.map {
                          QxEqBandValue(filter: .peak, freq: $0, gain: gain, q: 1.2)
                      },
                      preGain: -2, sourceName: source)
    }

    private func seed(_ presets: [LibraryPreset]) {
        PresetLibraryFile.save(PresetLibraryDocument(presets: presets), to: libraryFile)
    }

    private func stored() -> [LibraryPreset] {
        PresetLibraryFile.load(from: libraryFile)?.presets ?? []
    }

    @MainActor
    func testTheListIsSortedByNameAndFiltersOnTypedText() async {
        seed([preset("Warm"), preset("bass 10"), preset("Bass 2"), preset("Vocal")])
        let model = makeModel(nil, environment())
        let saved = model.library.saved
        XCTAssertEqual(saved.state.presets.map(\.name), ["Bass 2", "bass 10", "Vocal", "Warm"])
        XCTAssertEqual(saved.state.total, 4)
        saved.setFilter("  BASS ")
        XCTAssertEqual(saved.state.presets.map(\.name), ["Bass 2", "bass 10"])
        XCTAssertEqual(saved.state.total, 4)
        saved.setFilter("zzz")
        XCTAssertTrue(saved.state.presets.isEmpty)
        saved.setFilter("")
        XCTAssertEqual(saved.state.presets.count, 4)
    }

    @MainActor
    func testSelectingAPresetPreviewsItsCurveAndPreGain() async {
        let shaped = preset("Warm", gain: 4, source: "Sennheiser HD 650")
        seed([shaped])
        let model = makeModel(nil, environment())
        let saved = model.library.saved
        XCTAssertNil(saved.state.preview)
        saved.select(shaped.id)
        let preview = saved.state.preview
        XCTAssertEqual(preview?.title, "Warm")
        XCTAssertEqual(preview?.bands.count, 10)
        XCTAssertEqual(preview?.preGain, -2)
        XCTAssertTrue(preview?.subtitle.contains("10-band") == true)
        XCTAssertTrue(preview?.subtitle.contains("Sennheiser HD 650") == true)
        XCTAssertEqual(preview?.response.count, 220)
        XCTAssertTrue((preview?.response.max() ?? 0) > 1)
    }

    @MainActor
    func testSavingTheLiveEqKeepsItUnderANameAndSurvivesAReload() async {
        let bands = EqTestSupport.shaped()
        let device = EqTestDevice(bands: bands, preGain: -3.5)
        let model = await open(device, environment())
        let saved = model.library.saved
        XCTAssertNil(saved.state.saveRefusal)
        XCTAssertTrue(saved.saveCurrent(name: "  My curve  "))
        XCTAssertEqual(saved.state.presets.map(\.name), ["My curve"])
        XCTAssertNotNil(saved.state.selected)
        XCTAssertTrue(saved.state.notice?.contains("Saved") == true)
        let file = stored()
        XCTAssertEqual(file.count, 1)
        XCTAssertEqual(file[0].bands, bands.map(PresetLibraryFile.clamped))
        XCTAssertEqual(file[0].preGain, -3.5, accuracy: 0.001)
        XCTAssertEqual(file[0].group, .user)
        XCTAssertTrue(device.link.sentCommands.isEmpty)
        XCTAssertTrue(saved.saveCurrent(name: "My curve"))
        XCTAssertEqual(saved.state.presets.map(\.name), ["My curve", "My curve 2"])
        let reloaded = makeModel(nil, environment())
        XCTAssertEqual(reloaded.library.saved.state.presets.map(\.name),
                       ["My curve", "My curve 2"])
        await model.shutdown()
    }

    @MainActor
    func testSavingNeedsTheDeviceAndSaysSo() async {
        let model = makeModel(nil, environment())
        let saved = model.library.saved
        XCTAssertNotNil(saved.state.saveRefusal)
        XCTAssertFalse(saved.saveCurrent(name: "Nope"))
        XCTAssertTrue(saved.state.presets.isEmpty)
        XCTAssertTrue(stored().isEmpty)
        XCTAssertTrue(saved.state.notice?.contains("isn't connected") == true)
    }

    @MainActor
    func testRenameKeepsTheOthersAndPersistsAndNeverTakesAnotherNameTwice() async {
        let first = preset("One")
        let second = preset("Two")
        seed([first, second])
        let model = makeModel(nil, environment())
        let saved = model.library.saved
        saved.rename(first.id, to: "  Deep bass ")
        XCTAssertEqual(saved.state.presets.map(\.name), ["Deep bass", "Two"])
        XCTAssertEqual(Set(stored().map(\.name)), ["Deep bass", "Two"])
        saved.rename(second.id, to: "Deep bass")
        XCTAssertEqual(Set(stored().map(\.name)), ["Deep bass", "Deep bass 2"])
        saved.rename(second.id, to: "   ")
        XCTAssertEqual(Set(stored().map(\.name)), ["Deep bass", "Deep bass 2"])
    }

    @MainActor
    func testAnExternalDeleteIsNotUndoneByTheNextEdit() async {
        let one = preset("One"), two = preset("Two"), three = preset("Three")
        seed([one, two, three])
        let model = makeModel(nil, environment())
        let saved = model.library.saved
        saved.rename(one.id, to: "Uno")
        seed([one, three])
        saved.rename(three.id, to: "Tres")
        XCTAssertEqual(Set(stored().map(\.name)), ["One", "Tres"])
        XCTAssertEqual(saved.state.presets.map(\.name), ["One", "Tres"])
        XCTAssertNil(saved.name(of: two.id))
    }

    @MainActor
    func testAnExternalSaveSurvivesTheNextEditAndShowsOnRefresh() async {
        let one = preset("One")
        seed([one])
        let model = makeModel(nil, environment())
        let saved = model.library.saved
        let added = preset("Added outside")
        seed([one, added])
        XCTAssertEqual(saved.state.presets.count, 1)
        saved.refreshFromDisk()
        XCTAssertEqual(saved.state.presets.map(\.name), ["Added outside", "One"])
        let extra = preset("Second outside")
        seed([one, added, extra])
        saved.rename(one.id, to: "Renamed")
        XCTAssertEqual(Set(stored().map(\.name)), ["Renamed", "Added outside", "Second outside"])
    }

    @MainActor
    func testTheLibraryBecomesWritableAgainWhenABadExternalFileIsFixed() async {
        let one = preset("One"), two = preset("Two")
        seed([one, two])
        let model = makeModel(nil, environment())
        let saved = model.library.saved
        saved.rename(one.id, to: "Uno")
        XCTAssertEqual(Set(stored().map(\.name)), ["Uno", "Two"])
        try? Data("not a library".utf8).write(to: libraryFile, options: .atomic)
        saved.refreshFromDisk()
        saved.rename(two.id, to: "Dos")
        XCTAssertEqual(saved.state.presets.map(\.name).sorted(), ["Dos", "Uno"])
        XCTAssertNil(PresetLibraryFile.load(from: libraryFile))
        seed([one, two])
        saved.refreshFromDisk()
        XCTAssertEqual(saved.state.presets.map(\.name).sorted(), ["One", "Two"])
        saved.rename(two.id, to: "Tres")
        XCTAssertEqual(Set(stored().map(\.name)), ["One", "Tres"])
        XCTAssertNil(saved.state.notice)
    }

    @MainActor
    func testAnUnchangedFileIsNotReloaded() async {
        seed([preset("One")])
        let model = makeModel(nil, environment())
        let saved = model.library.saved
        var published = 0
        saved.addObserver { _ in published += 1 }
        let before = published
        saved.refreshFromDisk()
        saved.refreshFromDisk()
        XCTAssertEqual(published, before)
    }

    @MainActor
    func testDeleteRemovesThePresetFromTheFileAndClearsItsSelection() async {
        let first = preset("One")
        let second = preset("Two")
        seed([first, second])
        let model = makeModel(nil, environment())
        let saved = model.library.saved
        saved.select(first.id)
        XCTAssertEqual(SavedPresetsModel.deleteTitle("One"), "Delete \u{201C}One\u{201D}?")
        XCTAssertEqual(saved.name(of: first.id), "One")
        saved.delete(first.id)
        XCTAssertEqual(stored().map(\.name), ["Two"])
        XCTAssertEqual(saved.state.presets.map(\.name), ["Two"])
        XCTAssertNil(saved.state.selected)
        XCTAssertNil(saved.state.preview)
        saved.delete(first.id)
        XCTAssertEqual(stored().count, 1)
    }

    @MainActor
    func testApplyingASavedPresetWritesItAsOneCheckpointAndArmsTheSave() async {
        let wanted = preset("Warm", gain: 3, source: "Somewhere")
        seed([wanted])
        let device = EqTestDevice(bands: EqTestSupport.shaped(), preGain: -1)
        let model = await open(device, environment())
        let saved = model.library.saved
        XCTAssertNil(saved.refusal(forApplying: wanted.id))
        XCTAssertTrue(saved.apply(wanted.id))
        await settle(model)

        XCTAssertEqual(device.link.sentCommands.first, .setEqType)
        XCTAssertEqual(device.link.payloads(for: .setEqType), [[0, 1]])
        XCTAssertEqual(device.link.payloads(for: .setEqPreGain),
                       [[0, 1, 0, 0xFF, 0xEC], [0, 2, 0, 0xFF, 0xEC]])
        let writes = device.link.payloads(for: .setEqBandParam)
        XCTAssertEqual(writes.count, 10)
        XCTAssertEqual(writes, wanted.bands.enumerated().compactMap {
            QxPacket.bandParamPayload(group: .user, band: $0.offset,
                                      QxSession.clamped($0.element))
        })
        XCTAssertFalse(device.link.sentCommands.contains(.saveAll))
        XCTAssertFalse(device.link.sentCommands.contains(.setEqEnable))
        XCTAssertEqual(model.eq.state.bands.map(\.freq), wanted.bands.map(\.freq))
        XCTAssertEqual(model.eq.state.bands.map(\.gain), wanted.bands.map(\.gain))
        XCTAssertEqual(model.eq.state.preGain, -2, accuracy: 0.001)
        XCTAssertTrue(model.eq.state.canUndo)
        XCTAssertEqual(model.eq.state.undoLabel, "apply Warm")
        XCTAssertTrue(model.hasPendingSave)
        XCTAssertTrue(saved.state.notice?.hasPrefix("Applied 10 band(s)") == true)

        clock.advance(5.1)
        await until("saveAll") { device.link.sentCommands.contains(.saveAll) }
        XCTAssertEqual(device.link.sentCommands.filter { $0 == .saveAll }.count, 1)

        model.eq.undo()
        await settle(model)
        XCTAssertEqual(model.eq.state.bands, EqTestSupport.shaped().map(EqBand.init))
        XCTAssertEqual(model.eq.state.preGain, -1, accuracy: 0.001)
        XCTAssertFalse(model.eq.state.canUndo)
        await model.shutdown()
    }

    @MainActor
    func testApplyingWithEqOffSwitchesItOnFirstLikeTheMacImport() async {
        let wanted = preset("Warm")
        seed([wanted])
        let device = EqTestDevice()
        device.enabled = false
        let model = await open(device, environment())
        XCTAssertTrue(model.library.saved.apply(wanted.id))
        await settle(model)
        XCTAssertEqual(device.link.sentCommands.first, .setEqEnable)
        XCTAssertEqual(device.link.payloads(for: .setEqEnable), [[0, 1]])
        XCTAssertTrue(model.eq.state.enabled)
        await model.shutdown()
    }

    @MainActor
    func testApplyingIsRefusedWhenDisconnectedAndNothingIsSent() async {
        let wanted = preset("Warm")
        seed([wanted])
        let model = makeModel(nil, environment())
        let saved = model.library.saved
        saved.select(wanted.id)
        XCTAssertEqual(saved.state.applyRefusal, "Connect the 5K to apply.")
        XCTAssertFalse(saved.apply(wanted.id))
        XCTAssertNil(model.session)
        XCTAssertFalse(model.hasPendingSave)
        XCTAssertFalse(model.eq.state.canUndo)
    }

    @MainActor
    func testApplyingIsRefusedForTheOtherBankWithTheMacReason() async {
        let twenty = preset("Wide", group: .b20)
        seed([twenty])
        let device = EqTestDevice()
        let model = await open(device, environment())
        let saved = model.library.saved
        saved.select(twenty.id)
        XCTAssertTrue(saved.state.applyRefusal?.contains("20-band") == true)
        XCTAssertTrue(saved.state.applyRefusal?.contains("10-band mode") == true)
        XCTAssertFalse(saved.apply(twenty.id))
        await settle(model)
        XCTAssertTrue(device.link.sentCommands.isEmpty)
        XCTAssertFalse(model.hasPendingSave)
        XCTAssertTrue(saved.state.notice?.contains("not stretched to fit") == true)
        await model.shutdown()
    }

    @MainActor
    func testPassiveReasonsDoNotReadAsAFailedAttempt() async {
        let model = makeModel(nil, environment())
        XCTAssertEqual(model.eq.writeRefusal(attempted: false), "Connect the 5K to apply.")
        XCTAssertEqual(model.eq.writeRefusal(attempted: true), "Connect the 5K first \u{2014} nothing was applied.")
        XCTAssertEqual(model.library.saved.state.saveRefusal, "Connect the 5K to save its current EQ.")
        for text in [model.eq.writeRefusal(attempted: false), model.library.saved.state.saveRefusal] {
            XCTAssertFalse(text?.contains("nothing was") ?? true)
        }
    }

    @MainActor
    func testAnUnsupportedDeviceRefusesWithTheMacWording() async {
        let model = makeModel(nil, environment())
        XCTAssertEqual(model.eq.writeRefusal,
                       "Connect the 5K first \u{2014} nothing was applied.")
    }

    @MainActor
    func testNothingTouchesTheNetworkWhileBrowsingTypingOrOpeningThePage() async {
        seed([preset("Warm")])
        let env = environment(ai: ScriptedAITransport())
        let model = makeModel(nil, env)
        let library = model.library
        library.saved.setFilter("w")
        library.autoEq.setQuery("HD 6")
        library.ai.setHeadphone("HD 650")
        library.ai.setProvider("openai")
        library.ai.setKind("bass")
        library.ai.setNote("less sibilance")
        library.ai.setModel("custom-model")
        clock.advance(0.3)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(catalogue.requests.isEmpty)
        XCTAssertEqual((env.ai.transport as? ScriptedAITransport)?.callCount, 0)
        XCTAssertTrue(library.autoEq.state.results.isEmpty)
    }

    @MainActor
    func testAutoEqSearchWaitsForTheDebounceThenLoadsTheCatalogueOnce() async {
        let model = makeModel(nil, environment())
        let autoEq = model.library.autoEq
        autoEq.setQuery("HD 6")
        autoEq.setQuery("HD 65")
        clock.advance(0.39)
        XCTAssertTrue(catalogue.requests.isEmpty)
        clock.advance(0.02)
        XCTAssertEqual(autoEq.state.catalogue, .loading)
        await autoEq.waitForIdle()
        XCTAssertEqual(catalogue.requests.filter { $0 == "/entries" }.count, 1)
        guard case .ready(let count) = autoEq.state.catalogue else {
            return XCTFail("catalogue should be ready")
        }
        XCTAssertEqual(count, 6)
        XCTAssertEqual(autoEq.state.results.map(\.title),
                       ["Sennheiser HD 650", "Sennheiser HD 650"])
        XCTAssertEqual(Set(autoEq.state.results.map(\.detail)),
                       ["oratory1990 \u{00B7} GRAS 43AG", "crinacle \u{00B7} 711"])
        autoEq.setQuery("Aria")
        autoEq.searchNow()
        XCTAssertEqual(autoEq.state.results.map(\.title), ["Moondrop Aria"])
        XCTAssertEqual(catalogue.requests.filter { $0 == "/entries" }.count, 1)
    }

    @MainActor
    func testEnterSearchesAtOnceAndTheListIsCappedLikeTheMac() async {
        let model = makeModel(nil, environment())
        let autoEq = model.library.autoEq
        autoEq.setQuery("e")
        autoEq.searchNow()
        await autoEq.waitForIdle()
        XCTAssertEqual(catalogue.requests.first, "/entries")
        XCTAssertLessThanOrEqual(autoEq.state.results.count, AutoEqService.displayLimit)
        XCTAssertEqual(autoEq.state.results.count + autoEq.state.hiddenCount,
                       autoEq.state.results.count + max(0, autoEq.state.hiddenCount))
        autoEq.setQuery("")
        XCTAssertTrue(autoEq.state.results.isEmpty)
        XCTAssertEqual(autoEq.state.status, "6 headphones available. Start typing to search.")
    }

    @MainActor
    func testSelectingAResultFitsAPreviewToTheDeviceAndNamesTheTarget() async {
        let device = EqTestDevice()
        let model = await open(device, environment())
        let autoEq = model.library.autoEq
        autoEq.setQuery("HD 600")
        autoEq.searchNow()
        await autoEq.waitForIdle()
        let result = autoEq.state.results.first { $0.title == "Sennheiser HD 600" }
        XCTAssertNotNil(result)
        autoEq.select(result?.id)
        XCTAssertTrue(autoEq.state.fitting)
        await autoEq.waitForIdle()
        XCTAssertFalse(autoEq.state.fitting)
        XCTAssertNil(autoEq.state.error)
        let preview = autoEq.state.preview
        XCTAssertEqual(preview?.bands.count, 8)
        XCTAssertEqual(preview?.preGain ?? 0, -4.6, accuracy: 0.001)
        XCTAssertTrue(autoEq.state.provenance?.contains("Sennheiser HD 600") == true)
        XCTAssertTrue(autoEq.state.provenance?.contains("oratory1990") == true)
        XCTAssertTrue(autoEq.state.provenance?.contains("Harman over-ear 2018") == true)
        XCTAssertTrue(autoEq.state.provenance?.contains("10 bands") == true)
        XCTAssertEqual(autoEq.state.targets.first, AutoEqSearchModel.recommendedTarget)
        XCTAssertTrue(autoEq.state.targets.contains("Diffuse field over-ear"))
        XCTAssertNil(autoEq.state.applyRefusal)
        XCTAssertTrue(device.link.sentCommands.isEmpty)
        autoEq.setTarget("Diffuse field over-ear")
        await autoEq.waitForIdle()
        XCTAssertTrue(autoEq.state.provenance?.contains("Diffuse field over-ear (your choice)") == true)
        XCTAssertEqual(catalogue.requests.filter { $0 == "/equalize" }.count, 2)
        await model.shutdown()
    }

    @MainActor
    func testApplyingAnAutoEqCorrectionIsOneCheckpointNamedImportAndArmsTheSave() async {
        let device = EqTestDevice(bands: EqTestSupport.shaped(), preGain: -1)
        let model = await open(device, environment())
        let autoEq = model.library.autoEq
        autoEq.setQuery("HD 600")
        autoEq.searchNow()
        await autoEq.waitForIdle()
        autoEq.select(autoEq.state.results.first?.id)
        await autoEq.waitForIdle()
        XCTAssertTrue(autoEq.apply())
        await settle(model)
        XCTAssertEqual(device.link.payloads(for: .setEqType), [[0, 1]])
        XCTAssertEqual(device.link.payloads(for: .setEqPreGain),
                       [[0, 1, 0, 0xFF, 0xD2], [0, 2, 0, 0xFF, 0xD2]])
        let writes = device.link.payloads(for: .setEqBandParam)
        XCTAssertEqual(writes.count, 10)
        XCTAssertEqual(Array(writes[0].prefix(4)), [0, 1, 0, 3])
        XCTAssertEqual(model.eq.state.bands[0].filter, .lowShelf)
        XCTAssertEqual(model.eq.state.bands[8].filter, .bypass)
        XCTAssertEqual(model.eq.state.bands[9].filter, .bypass)
        XCTAssertEqual(model.eq.state.undoLabel, "import")
        XCTAssertTrue(model.hasPendingSave)
        XCTAssertTrue(autoEq.state.summary?.contains("Applied 8 band(s)") == true)
        XCTAssertTrue(autoEq.state.summary?.contains("Sennheiser HD 600") == true)
        let curve = model.eq.liveCurve()
        XCTAssertEqual(curve?.sourceName, "Sennheiser HD 600")
        model.eq.undo()
        await settle(model)
        XCTAssertEqual(model.eq.state.bands, EqTestSupport.shaped().map(EqBand.init))
        await model.shutdown()
    }

    @MainActor
    func testAnAutoEqResultCanBeKeptInTheLibraryWithoutTouchingTheDevice() async {
        let device = EqTestDevice()
        let model = await open(device, environment())
        let autoEq = model.library.autoEq
        autoEq.setQuery("Aria")
        autoEq.searchNow()
        await autoEq.waitForIdle()
        autoEq.select(autoEq.state.results.first?.id)
        await autoEq.waitForIdle()
        XCTAssertTrue(autoEq.saveToLibrary())
        XCTAssertEqual(stored().map(\.name), ["Moondrop Aria"])
        XCTAssertEqual(stored()[0].sourceName, "Moondrop Aria")
        XCTAssertEqual(stored()[0].bands.count, 8)
        XCTAssertEqual(stored()[0].group, .user)
        XCTAssertEqual(model.library.saved.state.presets.map(\.name), ["Moondrop Aria"])
        XCTAssertTrue(device.link.sentCommands.isEmpty)
        XCTAssertFalse(model.hasPendingSave)
        await model.shutdown()
    }

    @MainActor
    func testAutoEqWorksOffLineOfTheDeviceButRefusesToApplyAndSaysWhy() async {
        let model = makeModel(nil, environment())
        let autoEq = model.library.autoEq
        autoEq.setQuery("HD 650")
        autoEq.searchNow()
        await autoEq.waitForIdle()
        autoEq.select(autoEq.state.results.first?.id)
        await autoEq.waitForIdle()
        XCTAssertNotNil(autoEq.state.preview)
        XCTAssertEqual(autoEq.state.applyRefusal,
                       "Connect the 5K to apply.")
        XCTAssertFalse(autoEq.apply())
        XCTAssertNil(model.session)
        XCTAssertFalse(model.eq.state.canUndo)
        XCTAssertTrue(autoEq.saveToLibrary())
        XCTAssertEqual(stored().count, 1)
    }

    @MainActor
    func testAFailedCatalogueIsReportedAndTheNextSearchTriesAgain() async {
        catalogue.failEntries = true
        let model = makeModel(nil, environment())
        let autoEq = model.library.autoEq
        autoEq.setQuery("HD 6")
        autoEq.searchNow()
        await autoEq.waitForIdle()
        guard case .failed = autoEq.state.catalogue else {
            return XCTFail("should have failed")
        }
        XCTAssertTrue(autoEq.state.error?.hasPrefix("Couldn\u{2019}t load the AutoEq catalog") == true)
        catalogue.failEntries = false
        autoEq.searchNow()
        await autoEq.waitForIdle()
        XCTAssertNil(autoEq.state.error)
        XCTAssertFalse(autoEq.state.results.isEmpty)
    }

    @MainActor
    func testCancelStopsAFitInFlightAndKeepsTheResultsList() async {
        let model = makeModel(nil, environment())
        let autoEq = model.library.autoEq
        autoEq.setQuery("HD 600")
        autoEq.searchNow()
        await autoEq.waitForIdle()
        catalogue.delay = 0.4
        autoEq.select(autoEq.state.results.first?.id)
        XCTAssertTrue(autoEq.state.fitting)
        autoEq.cancel()
        XCTAssertFalse(autoEq.state.fitting)
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertNil(autoEq.state.preview)
        XCTAssertFalse(autoEq.state.results.isEmpty)
    }

    @MainActor
    func testTheKeyFileIsWrittenOnlyByAnExplicitSaveWithMode0600AndNeverEchoed() async throws {
        let secret = "sk-test-0123456789-ABCDEF"
        let model = makeModel(nil, environment())
        let ai = model.library.ai
        ai.setHeadphone("HD 650")
        ai.setKind("bass")
        XCTAssertFalse(ai.generate())
        XCTAssertFalse(ai.research())
        ai.setProvider("openai")
        ai.setProvider("mistral")
        ai.forgetKey()
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyDirectory.path))
        XCTAssertEqual(ai.state.keyStatus, .none)

        XCTAssertFalse(ai.saveKey("   "))
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyDirectory.path))
        XCTAssertTrue(ai.saveKey(secret))
        let url = keyDirectory.appendingPathComponent("ai-key-mistral")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: keyDirectory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: keyDirectory.path),
                       ["ai-key-mistral"])
        XCTAssertEqual(ai.state.keyStatus, .saved)
        XCTAssertFalse(String(describing: ai.state).contains(secret))
        XCTAssertFalse(String(describing: ai.state).contains("0123456789"))
        let others = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for name in others where name != "keys" {
            let path = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
            if !isDirectory.boolValue {
                let text = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
                XCTAssertFalse(text.contains(secret), name)
            }
        }
        ai.forgetKey()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(ai.state.keyStatus, .none)
    }

    @MainActor
    func testAKeyFromTheEnvironmentIsReportedAsSuchAndAnOpenFileIsRefused() async throws {
        var runtime = AIRuntime()
        runtime.keychain = AIKeychain(directory: keyDirectory,
                                      environment: ["QUDELIX_AI_KEY_MISTRAL": "from-env"])
        runtime.researchDirectory = researchDirectory
        runtime.measurement = { _ in nil }
        runtime.transport = ScriptedAITransport()
        let env = LibraryEnvironment(libraryFile: libraryFile, autoEqTransport: catalogue,
                                     ai: runtime)
        let model = makeModel(nil, env)
        XCTAssertEqual(model.library.ai.state.keyStatus, .environment)

        let open = AIKeychain(directory: keyDirectory, environment: [:])
        XCTAssertTrue(open.save(key: "abc", provider: "openai"))
        let url = keyDirectory.appendingPathComponent("ai-key-openai")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let ai = model.library.ai
        ai.setProvider("openai")
        XCTAssertEqual(ai.state.keyStatus, .unsafeMode)
        ai.setHeadphone("HD 650")
        ai.setKind("bass")
        XCTAssertFalse(ai.generate())
        XCTAssertTrue(ai.state.error?.contains("can be read by other users") == true)
        XCTAssertFalse(ai.state.error?.contains("abc") == true)
    }

    @MainActor
    func testGenerateResearchesThenDesignsReportsPhasesAndShowsADraftPreview() async throws {
        let transport = ScriptedAITransport([chat(dossierText), chat(draftText())])
        let model = makeModel(nil, environment(ai: transport, key: "sk-live-secret"))
        let ai = model.library.ai
        var phases: [AiPhase] = []
        ai.addObserver { if phases.last != $0.phase { phases.append($0.phase) } }
        ai.setHeadphone("Sennheiser HD 650")
        ai.setKind("bass")
        ai.setNote("less sibilance")
        ai.setModel(" custom-model ")
        XCTAssertTrue(ai.state.canGenerate)
        XCTAssertTrue(ai.generate())
        XCTAssertTrue(ai.state.busy)
        XCTAssertFalse(ai.generate())
        await ai.waitForIdle()
        XCTAssertEqual(phases, [.idle, .researching, .designing, .idle])
        XCTAssertNil(ai.state.error)
        XCTAssertEqual(transport.callCount, 2)
        let hosts = Set(transport.requests.compactMap { $0.url?.host })
        XCTAssertEqual(hosts, ["api.mistral.ai"])
        let design = String(data: transport.requests[1].httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(design.contains("less sibilance"))
        XCTAssertTrue(design.contains("\"model\":\"custom-model\""))
        XCTAssertFalse(design.contains("sk-live-secret"))
        let draft = try XCTUnwrap(ai.state.draft)
        XCTAssertEqual(draft.name, "Airy 650")
        XCTAssertEqual(draft.preview.bands.count, 10)
        XCTAssertEqual(draft.rationale, "Lifts the presence dip.")
        XCTAssertTrue(draft.notes.contains {
            $0.hasPrefix("No measurement found for this model")
        })
        XCTAssertTrue(draft.notes.contains { $0.hasPrefix("Pre-gain ") })
        XCTAssertTrue(draft.preview.subtitle.contains("Sennheiser HD 650"))
        XCTAssertFalse(draft.preview.subtitle.contains("custom-model"))
        XCTAssertTrue(ai.state.researchInfo?.hasPrefix("Researched ") == true)
        XCTAssertTrue(String(describing: ai.state).contains("Airy 650"))
        XCTAssertFalse(String(describing: ai.state).contains("sk-live-secret"))
    }

    @MainActor
    func testApplyingADraftIsOneCheckpointThroughTheEditorAndArmsTheSave() async throws {
        let transport = ScriptedAITransport([chat(dossierText), chat(draftText())])
        let device = EqTestDevice(bands: EqTestSupport.shaped(), preGain: -1)
        let model = await open(device, environment(ai: transport, key: "k"))
        let ai = model.library.ai
        ai.setHeadphone("Sennheiser HD 650")
        ai.setKind("bass")
        XCTAssertTrue(ai.generate())
        await ai.waitForIdle()
        XCTAssertNil(ai.state.applyRefusal)
        XCTAssertTrue(device.link.sentCommands.isEmpty)
        XCTAssertTrue(ai.apply())
        await settle(model)
        XCTAssertEqual(device.link.payloads(for: .setEqType), [[0, 1]])
        XCTAssertEqual(device.link.payloads(for: .setEqBandParam).count, 10)
        XCTAssertEqual(model.eq.state.undoLabel, "apply Airy 650")
        XCTAssertTrue(model.hasPendingSave)
        XCTAssertTrue(ai.state.summary?.hasPrefix("Applied 10 band(s)") == true)
        XCTAssertTrue(ai.saveDraftToLibrary())
        XCTAssertEqual(stored().map(\.name), ["Airy 650"])
        await model.shutdown()
    }

    @MainActor
    func testADraftCannotBeAppliedWhileDisconnected() async {
        let transport = ScriptedAITransport([chat(dossierText), chat(draftText())])
        let model = makeModel(nil, environment(ai: transport, key: "k"))
        let ai = model.library.ai
        ai.setHeadphone("Sennheiser HD 650")
        ai.setKind("bass")
        XCTAssertTrue(ai.generate())
        await ai.waitForIdle()
        XCTAssertEqual(ai.state.applyRefusal, "Connect the 5K to apply.")
        XCTAssertFalse(ai.apply())
        XCTAssertFalse(model.eq.state.canUndo)
        XCTAssertEqual(ai.state.summary, "Connect the 5K first \u{2014} nothing was applied.")
    }

    @MainActor
    func testGenerateNeedsAKeyForEveryKindButCorrectionAndNamesWhatIsMissing() async {
        let transport = ScriptedAITransport()
        let model = makeModel(nil, environment(ai: transport))
        let ai = model.library.ai
        XCTAssertEqual(ai.state.generateHint, "Name your headphones")
        ai.setHeadphone("HD 650")
        ai.setKind("warmth")
        XCTAssertEqual(ai.state.generateHint, "Save a key to start")
        XCTAssertFalse(ai.state.canGenerate)
        XCTAssertFalse(ai.generate())
        XCTAssertEqual(ai.state.error, "Save your Mistral API key first.")
        ai.setKind("correction")
        XCTAssertNil(ai.state.generateHint)
        XCTAssertEqual(transport.callCount, 0)
    }

    @MainActor
    func testACorrectionFromAStoredMeasurementNeedsNoKeyAndNoNetwork() async throws {
        let transport = ScriptedAITransport()
        var env = environment(ai: transport)
        env.ai.measurement = { _ in
            HeadphoneDossier.Measurement(
                title: "Sennheiser HD 650", preGain: -6,
                bands: [QxEqBandValue(filter: .lowShelf, freq: 105, gain: 6, q: 0.7),
                        QxEqBandValue(filter: .peak, freq: 400, gain: -2.5, q: 1.2),
                        QxEqBandValue(filter: .peak, freq: 3200, gain: 3, q: 1.4)])
        }
        let model = makeModel(nil, env)
        let ai = model.library.ai
        ai.setHeadphone("Sennheiser HD 650")
        XCTAssertTrue(ai.generate())
        await ai.waitForIdle()
        XCTAssertNil(ai.state.error)
        XCTAssertEqual(transport.callCount, 0)
        XCTAssertTrue(ai.state.draft?.notes.first?.hasPrefix("Grounded in a published") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyDirectory.path))
    }

    @MainActor
    func testProviderFailuresAreShownWithoutTheKeyAndLeaveNoDraft() async {
        let model = makeModel(nil, environment(ai: FailingAITransport(AIError.rejectedKey),
                                               key: "sk-bad-key"))
        let ai = model.library.ai
        ai.setHeadphone("HD 650")
        ai.setKind("bass")
        XCTAssertTrue(ai.generate())
        await ai.waitForIdle()
        XCTAssertEqual(ai.state.phase, .idle)
        XCTAssertNil(ai.state.draft)
        XCTAssertEqual(ai.state.error, "The key was rejected \u{2014} check it and its billing.")
        XCTAssertFalse(String(describing: ai.state).contains("sk-bad-key"))
        ai.clearError()
        XCTAssertNil(ai.state.error)
        XCTAssertTrue(ai.state.canGenerate)
    }

    @MainActor
    func testAnOfflineProviderIsReportedAsAnErrorNotAStuckSpinner() async {
        let model = makeModel(nil, environment(ai: FailingAITransport(URLError(.notConnectedToInternet)),
                                               key: "k"))
        let ai = model.library.ai
        ai.setHeadphone("HD 650")
        ai.setKind("bass")
        XCTAssertTrue(ai.generate())
        await ai.waitForIdle()
        XCTAssertEqual(ai.state.phase, .idle)
        XCTAssertNotNil(ai.state.error)
    }

    @MainActor
    func testCancelEndsTheRequestAtOnceAndADraftThatArrivesLaterIsDropped() async {
        let transport = SlowAITransport([chat(dossierText), chat(draftText())], delay: 0.25)
        let model = makeModel(nil, environment(ai: transport, key: "k"))
        let ai = model.library.ai
        ai.setHeadphone("HD 650")
        ai.setKind("bass")
        XCTAssertTrue(ai.generate())
        XCTAssertEqual(ai.state.phase, .researching)
        ai.cancel()
        XCTAssertEqual(ai.state.phase, .idle)
        XCTAssertFalse(ai.state.busy)
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertNil(ai.state.draft)
        XCTAssertNil(ai.state.error)
        XCTAssertLessThanOrEqual(transport.count, 1)
        XCTAssertTrue(ai.generate())
        await ai.waitForIdle()
        XCTAssertNotNil(ai.state.draft)
    }

    @MainActor
    func testResearchShowsWhatTheProviderKnowsAndThenAnswersFromTheCache() async throws {
        let transport = ScriptedAITransport([chat(dossierText)])
        let model = makeModel(nil, environment(ai: transport, key: "k"))
        let ai = model.library.ai
        ai.setHeadphone("Sennheiser HD 650")
        XCTAssertTrue(ai.research())
        XCTAssertEqual(ai.state.phase, .researching)
        await ai.waitForIdle()
        XCTAssertNil(ai.state.error)
        let facts = Dictionary(uniqueKeysWithValues: ai.state.dossier.map { ($0.label, $0.text) })
        XCTAssertEqual(facts["Signature"], "Neutral with a lifted top")
        XCTAssertEqual(facts["Confidence"], "high")
        XCTAssertEqual(facts["3-5 kHz"], "peak")
        XCTAssertEqual(transport.callCount, 1)
        XCTAssertTrue(ai.research())
        await ai.waitForIdle()
        XCTAssertEqual(transport.callCount, 1)
        XCTAssertTrue(ai.state.dossier.contains { $0.text.hasSuffix("(from the cache)") })
        ai.setRefreshResearch(true)
        XCTAssertTrue(ai.state.refreshResearch)
    }

    @MainActor
    func testPickingAProviderAModelOrAKindStaysLocalAndKeepsTheKeyPerProvider() async {
        let model = makeModel(nil, environment(key: "k"))
        let ai = model.library.ai
        XCTAssertEqual(ai.state.provider, "mistral")
        XCTAssertEqual(ai.state.keyStatus, .saved)
        ai.setProvider("anthropic")
        XCTAssertEqual(ai.state.provider, "anthropic")
        XCTAssertEqual(ai.state.providerHost, "api.anthropic.com")
        XCTAssertEqual(ai.state.keyStatus, .none)
        ai.setModel("my-model ")
        XCTAssertEqual(ai.state.model, "my-model ")
        ai.setProvider("mistral")
        XCTAssertEqual(ai.state.model, "")
        XCTAssertEqual(ai.state.defaultModel, AIProvider.mistral.defaultModel)
        ai.setProvider("nonsense")
        XCTAssertEqual(ai.state.provider, "mistral")
        XCTAssertEqual(ai.state.providers.map(\.id), AIProvider.allCases.map(\.rawValue))
        ai.setNote(String(repeating: "x", count: 500))
        XCTAssertEqual(ai.state.note.count, AiStudioModel.maxNoteLength)
        XCTAssertEqual(ai.state.kinds.count, AIPresetKind.allCases.count)
    }

    func testThePrivacyWordingNamesWhatIsAndIsNotSent() {
        XCTAssertTrue(AiStudioModel.privacyNote.hasPrefix("Nothing is sent until you press"))
        XCTAssertTrue(AiStudioModel.privacyNote.contains("Never your EQ curve"))
        XCTAssertTrue(AiStudioModel.billingCaption.contains("billed to you"))
    }
}
