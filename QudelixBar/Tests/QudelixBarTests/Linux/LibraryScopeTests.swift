import XCTest
@testable import QudelixBar

final class LibraryScopeTests: XCTestCase {
    private var directory: URL!
    private var lockURL: URL!
    private var clock: ManualClock!
    private var held: [AppModel] = []

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("library-scope-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActiveSlotFile.directoryOverride = directory
        EqHistoryFile.directoryOverride = directory
        lockURL = directory.appendingPathComponent("qudelix.lock")
        clock = ManualClock()
    }

    override func tearDown() {
        ActiveSlotFile.directoryOverride = nil
        EqHistoryFile.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        held = []
        super.tearDown()
    }

    private var libraryFile: URL { directory.appendingPathComponent("presets.json") }

    private func environment() -> LibraryEnvironment {
        var runtime = AIRuntime()
        runtime.keychain = AIKeychain(directory: directory.appendingPathComponent("keys"), environment: [:])
        runtime.researchDirectory = directory.appendingPathComponent("research")
        runtime.measurement = { _ in nil }
        runtime.readKey = { nil }
        return LibraryEnvironment(libraryFile: libraryFile, autoEqTransport: CountingCatalogue(),
                                  ai: runtime, searchDelay: 0.4)
    }

    @MainActor
    private func makeModel(_ device: EqTestDevice?) -> AppModel {
        let url = lockURL
        let links: [QxLink] = device.map { [$0.link] } ?? []
        let model = AppModel(makeLinks: { links },
                             acquireLock: { QxInstanceLock.acquire(at: url) },
                             probeDevice: { AppDeviceProbe(present: device != nil) },
                             clock: clock, retryInterval: 2, connectTimeout: 2)
        model.libraryEnvironment = environment()
        held.append(model)
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

    @MainActor
    private func open(_ device: EqTestDevice) async -> AppModel {
        let model = makeModel(device)
        model.start()
        await until("connected") { model.state.connection.isConnected && model.eq.state.ready }
        await model.eq.waitForIdle()
        device.link.clearSends()
        return model
    }

    private func preset(_ name: String, scope: LibraryScope = .global) -> LibraryPreset {
        LibraryPreset(name: name, scope: scope, group: .user,
                      bands: QxEqGroup.user.defaultFreqs.map {
                          QxEqBandValue(filter: .peak, freq: $0, gain: 1.5, q: 1.2)
                      },
                      preGain: -2)
    }

    private func seed(_ presets: [LibraryPreset]) {
        PresetLibraryFile.save(PresetLibraryDocument(presets: presets), to: libraryFile)
    }

    private func stored() -> [LibraryPreset] {
        PresetLibraryFile.load(from: libraryFile)?.presets ?? []
    }

    private let speakers = LibraryOutputState.output(key: "alsa_output.speakers", name: "Speakers")
    private let apo = "Preamp: -3.0 dB\nFilter 1: ON PK Fc 100 Hz Gain 2.0 dB Q 1.00\n"
        + "Filter 2: ON PK Fc 1000 Hz Gain -1.5 dB Q 2.00\n"

    @MainActor
    func testWithoutAnAudioBackendEveryPresetIsListedAndScopeIsHidden() {
        seed([preset("Global"), preset("Mine", scope: .output(uid: "a", name: "A"))])
        let saved = makeModel(nil).library.saved
        XCTAssertFalse(saved.state.scopeShown)
        XCTAssertEqual(saved.state.presets.map(\.name), ["Global", "Mine"])
        XCTAssertTrue(saved.state.others.isEmpty)
        XCTAssertTrue(saved.state.presets.allSatisfy { !$0.canUseEverywhere && !$0.canUseOnlyHere })
    }

    @MainActor
    func testTheListShowsThisOutputAndGlobalPresetsAndFoldsTheRestAway() {
        seed([preset("Global"),
              preset("Here", scope: .output(uid: "alsa_output.speakers", name: "Speakers")),
              preset("Elsewhere", scope: .output(uid: "bluez_output.AA", name: "Qudelix-5K")),
              preset("Mac one", scope: .output(uid: "AppleUSBAudioEngine:1", name: "Desk"))])
        let saved = makeModel(nil).library.saved
        saved.useOutputs { self.speakers }
        XCTAssertTrue(saved.state.scopeShown)
        XCTAssertEqual(saved.state.outputName, "Speakers")
        XCTAssertEqual(saved.state.presets.map(\.name), ["Global", "Here"])
        XCTAssertEqual(saved.state.others.map(\.name), ["Elsewhere", "Mac one"])
        XCTAssertEqual(SavedPresetsModel.othersTitle(saved.state.others.count), "Other outputs (2)")
        XCTAssertEqual(saved.state.total, 4)
        saved.setFilter("else")
        XCTAssertTrue(saved.state.presets.isEmpty)
        XCTAssertEqual(saved.state.others.map(\.name), ["Elsewhere"])
    }

    @MainActor
    func testTheMenuOffersOnlyTheScopeChangesThatMeanSomething() {
        seed([preset("Global"),
              preset("Here", scope: .output(uid: "alsa_output.speakers", name: "Speakers")),
              preset("Elsewhere", scope: .output(uid: "x", name: "X"))])
        let saved = makeModel(nil).library.saved
        saved.useOutputs { self.speakers }
        let byName = Dictionary(uniqueKeysWithValues: (saved.state.presets + saved.state.others).map { ($0.name, $0) })
        XCTAssertEqual([byName["Global"]!.canUseEverywhere, byName["Global"]!.canUseOnlyHere], [false, true])
        XCTAssertEqual([byName["Here"]!.canUseEverywhere, byName["Here"]!.canUseOnlyHere], [true, false])
        XCTAssertEqual([byName["Elsewhere"]!.canUseEverywhere, byName["Elsewhere"]!.canUseOnlyHere], [true, true])
        saved.useOutputs { .noOutput }
        XCTAssertTrue(saved.state.scopeShown)
        XCTAssertFalse(saved.state.outputAvailable)
        XCTAssertEqual(saved.state.presets.map(\.name), ["Global"])
        XCTAssertTrue((saved.state.presets + saved.state.others).allSatisfy { !$0.canUseOnlyHere })
    }

    @MainActor
    func testUseOnlyHereAndUseEverywhereChangeAndPersistTheScope() {
        let global = preset("Global")
        seed([global])
        let saved = makeModel(nil).library.saved
        saved.useOutputs { self.speakers }
        saved.useOnlyHere(global.id)
        XCTAssertEqual(stored().first?.scope, .output(uid: "alsa_output.speakers", name: "Speakers"))
        XCTAssertEqual(saved.state.presets.first?.canUseEverywhere, true)
        saved.useOutputs { .output(key: "other", name: "Other") }
        XCTAssertTrue(saved.state.presets.isEmpty)
        XCTAssertEqual(saved.state.others.map(\.name), ["Global"])
        saved.useEverywhere(global.id)
        XCTAssertEqual(stored().first?.scope, .global)
        XCTAssertEqual(saved.state.presets.map(\.name), ["Global"])
        saved.useOutputs(nil)
        saved.useOnlyHere(global.id)
        XCTAssertEqual(stored().first?.scope, .global)
    }

    @MainActor
    func testSavingKeepsTheCurveGlobalOrBoundToTheOutputByTheChoice() async {
        let device = EqTestDevice(bands: EqTestSupport.shaped(), preGain: -3)
        let model = await open(device)
        let saved = model.library.saved
        saved.useOutputs { self.speakers }
        XCTAssertTrue(saved.saveCurrent(name: "Everywhere"))
        XCTAssertTrue(saved.saveCurrent(name: "Speakers only", onlyHere: true))
        XCTAssertEqual(stored().map(\.scope), [.global, .output(uid: "alsa_output.speakers", name: "Speakers")])
        saved.useOutputs { .noOutput }
        XCTAssertTrue(saved.saveCurrent(name: "No output", onlyHere: true))
        XCTAssertEqual(stored().last?.scope, .global)
        saved.useOutputs(nil)
        XCTAssertTrue(saved.saveCurrent(name: "No audio", onlyHere: true))
        XCTAssertEqual(stored().last?.scope, .global)
        XCTAssertTrue(device.link.sentCommands.isEmpty)
        await model.shutdown()
    }

    @MainActor
    func testTheModelFollowsTheRealOutputOfTheRouting() {
        let backend = FakeAudioBackend()
        backend.sinks = [StageRig.fiveK, StageRig.speakers]
        backend.defaultSinkName = "qx_5k"
        let routing = OutputRouting(backend: backend, clock: clock, hop: { $0() },
                                    memoryURL: directory.appendingPathComponent("routing.json"))
        routing.start()
        seed([preset("Global"), preset("USB", scope: .output(uid: "qx_5k", name: "Qudelix-5K USB DAC"))])
        let saved = makeModel(nil).library.saved
        saved.attach(routing: routing)
        XCTAssertEqual(saved.state.outputName, "Qudelix-5K USB DAC")
        XCTAssertEqual(saved.state.presets.map(\.name), ["Global", "USB"])
        backend.defaultSinkName = "alsa_speakers"
        routing.refresh()
        XCTAssertEqual(saved.state.outputName, "Speakers")
        XCTAssertEqual(saved.state.presets.map(\.name), ["Global"])
        XCTAssertEqual(saved.state.others.map(\.name), ["USB"])
        backend.connected = false
        routing.refresh()
        XCTAssertFalse(saved.state.scopeShown)
        XCTAssertEqual(saved.state.presets.map(\.name), ["Global", "USB"])
    }

    @MainActor
    func testImportedTextLandsInTheLibraryOnlyAndNothingGoesToTheDevice() async {
        let device = EqTestDevice(bands: EqTestSupport.shaped(), preGain: -3)
        let model = await open(device)
        let saved = model.library.saved
        saved.useOutputs { self.speakers }
        XCTAssertNil(saved.state.importRefusal)
        XCTAssertTrue(saved.importText(apo))
        XCTAssertEqual(saved.state.presets.map(\.name), [SavedPresetsModel.pasteName])
        XCTAssertTrue(saved.state.notice?.contains("nothing has been sent to the 5K") == true)
        XCTAssertEqual(stored().first?.scope, .output(uid: "alsa_output.speakers", name: "Speakers"))
        XCTAssertEqual(stored().first?.preGain ?? 0, -3, accuracy: 0.001)
        XCTAssertEqual(stored().first?.bands.first?.freq, 100)
        XCTAssertNotNil(saved.state.selected)
        XCTAssertTrue(device.link.sentCommands.isEmpty)
        XCTAssertTrue(saved.importText(apo))
        XCTAssertEqual(stored().count, 2)
        XCTAssertEqual(Set(stored().map(\.name)).count, 2)
        await model.shutdown()
    }

    @MainActor
    func testImportRefusesWithoutTheDeviceOrWithoutFiltersOrWithTooMuchText() async {
        let offline = makeModel(nil).library.saved
        XCTAssertEqual(offline.state.importRefusal, SavedPresetsModel.connectToImport)
        XCTAssertFalse(offline.importText(apo))
        XCTAssertTrue(offline.state.notice?.contains("Connect the 5K first") == true)
        XCTAssertTrue(stored().isEmpty)

        let device = EqTestDevice(bands: EqTestSupport.shaped(), preGain: 0)
        let model = await open(device)
        let saved = model.library.saved
        XCTAssertFalse(saved.importText("nothing useful here"))
        XCTAssertEqual(saved.state.notice, "No EQ filters found in what was pasted.")
        XCTAssertFalse(saved.importText(""))
        XCTAssertFalse(saved.importText(String(repeating: "x", count: 1_000_001)))
        XCTAssertTrue(saved.state.notice?.contains("too much text") == true)
        XCTAssertTrue(stored().isEmpty)
        XCTAssertTrue(device.link.sentCommands.isEmpty)
        await model.shutdown()
    }

    @MainActor
    func testImportingAFileNamesThePresetAfterTheFileAndReportsUnreadableOnes() async {
        let device = EqTestDevice(bands: EqTestSupport.shaped(), preGain: 0)
        let model = await open(device)
        let saved = model.library.saved
        let file = directory.appendingPathComponent("HD 650 ParametricEQ.txt")
        try? apo.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(saved.importFile(at: file))
        XCTAssertEqual(saved.state.presets.map(\.name), ["HD 650 ParametricEQ"])
        XCTAssertFalse(saved.importFile(at: directory.appendingPathComponent("missing.txt")))
        XCTAssertTrue(saved.state.notice?.contains("Couldn't read missing.txt") == true)
        XCTAssertEqual(stored().count, 1)
        XCTAssertTrue(device.link.sentCommands.isEmpty)
        await model.shutdown()
    }

    @MainActor
    func testExportWritesTheSameTextTheLiveEqExportUses() {
        let one = preset("A/B curve")
        seed([one])
        let saved = makeModel(nil).library.saved
        let expected = QudelixController.exportText(bands: one.bands, preGain: one.preGain)
        XCTAssertEqual(saved.exportText(of: one.id), expected)
        let file = directory.appendingPathComponent("out.txt")
        XCTAssertTrue(saved.exportFile(one.id, to: file))
        XCTAssertEqual(try? String(contentsOf: file, encoding: .utf8), expected)
        XCTAssertEqual(saved.state.notice, "Exported \u{201C}A/B curve\u{201D}.")
        XCTAssertFalse(saved.exportFile(one.id, to: directory.appendingPathComponent("no/such/dir/x.txt")))
        XCTAssertTrue(saved.state.notice?.contains("Couldn't save x.txt") == true)
        XCTAssertNil(saved.exportText(of: UUID()))
        XCTAssertEqual(SavedPresetsModel.exportFileName(one.name), "A-B curve.txt")
        XCTAssertEqual(SavedPresetsModel.exportFileName(""), "preset.txt")
    }

    @MainActor
    func testTheExportedTextImportsBackToTheSameCurve() async {
        let device = EqTestDevice(bands: EqTestSupport.shaped(), preGain: 0)
        let model = await open(device)
        let saved = model.library.saved
        XCTAssertTrue(saved.saveCurrent(name: "Round"))
        let id = saved.state.presets[0].id
        let text = saved.exportText(of: id) ?? ""
        XCTAssertTrue(saved.importText(text, name: "Again"))
        let rows = stored()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].bands.map(\.freq), rows[1].bands.map(\.freq))
        XCTAssertEqual(rows[0].bands.map(\.gain), rows[1].bands.map(\.gain))
        await model.shutdown()
    }

    @MainActor
    func testTheHeadphoneNameIsCleanedShownAndKeptAcrossARestart() {
        let saved = makeModel(nil).library.saved
        XCTAssertEqual(saved.state.headphoneName, "")
        saved.setHeadphoneName("  Sennheiser HD 650 ")
        XCTAssertEqual(saved.state.headphoneName, "Sennheiser HD 650")
        saved.flushPendingWrites()
        XCTAssertEqual(PresetLibraryFile.load(from: libraryFile)?.headphoneName, "Sennheiser HD 650")
        XCTAssertEqual(makeModel(nil).library.saved.state.headphoneName, "Sennheiser HD 650")
    }

    @MainActor
    func testTheEqPageExportsTheLiveCurveAndRefusesWithoutTheDevice() async {
        let offline = makeModel(nil)
        XCTAssertNil(offline.eq.exportText())
        let target = directory.appendingPathComponent("live.txt")
        XCTAssertFalse(offline.eq.exportFile(to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        let bands = EqTestSupport.shaped()
        let device = EqTestDevice(bands: bands, preGain: -3)
        let model = await open(device)
        let text = model.eq.exportText() ?? ""
        XCTAssertTrue(text.hasPrefix("Preamp: -3.0 dB\nFilter 1: ON PK Fc "))
        XCTAssertEqual(text.split(separator: "\n").count, 1 + bands.count)
        XCTAssertTrue(model.eq.exportFile(to: target))
        XCTAssertEqual(try? String(contentsOf: target, encoding: .utf8), text)
        XCTAssertFalse(model.eq.exportFile(to: directory.appendingPathComponent("no/such/x.txt")))
        XCTAssertTrue(device.link.sentCommands.isEmpty)
        XCTAssertEqual(EqEditorModel.exportFileName, "QudelixEQ.txt")
        await model.shutdown()
    }

    @MainActor
    func testTheLabelsMatchTheMacWording() {
        XCTAssertEqual(SavedPresetsModel.useEverywhereLabel, "Use with every output")
        XCTAssertEqual(SavedPresetsModel.useOnlyHereLabel("Speakers"), "Use only with Speakers")
        XCTAssertEqual(SavedPresetsModel.useOnlyHereLabel(""), "Use only with this output")
        XCTAssertEqual(SavedPresetsModel.thisOutputLabel(""), "This output")
        XCTAssertEqual(SavedPresetsModel.everyOutputLabel, "Every output")
    }
}
