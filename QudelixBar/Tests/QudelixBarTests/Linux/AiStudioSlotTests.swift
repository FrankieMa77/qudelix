import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import QudelixBar

final class AiStudioSlotTests: XCTestCase {
    private var directory: URL!
    private var clock: ManualClock!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ai-slot-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActiveSlotFile.directoryOverride = directory
        EqHistoryFile.directoryOverride = directory
        clock = ManualClock()
    }

    override func tearDown() {
        ActiveSlotFile.directoryOverride = nil
        EqHistoryFile.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    private func chat(_ text: String) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: ["choices": [["message": ["content": text]]]])) ?? Data()
    }

    private let dossierText = "{\"signature\": \"Neutral\", \"bass\": \"Lean\", \"mids\": \"Even\", "
        + "\"treble\": \"Peak\", \"soundstage\": \"Wide\", \"knownIssues\": [], "
        + "\"confidence\": \"high\"}"

    private func draftText() -> String {
        let freqs = QxEqGroup.user.defaultFreqs
        let rows = (0..<10).map { index in
            "{\"freq\": \(freqs[index]), \"gainDb\": \(Double(index % 5) - 2), "
                + "\"q\": 1.0, \"kind\": \"peak\"}"
        }.joined(separator: ", ")
        return "{\"name\": \"Airy 650\", \"rationale\": \"Lifts the presence dip.\", "
            + "\"bands\": [\(rows)]}"
    }

    private func environment(_ transport: AITransport) -> LibraryEnvironment {
        var runtime = AIRuntime()
        runtime.keychain = AIKeychain(directory: directory.appendingPathComponent("keys"),
                                      environment: [:])
        runtime.transport = transport
        let research = directory.appendingPathComponent("research-\(UUID().uuidString)",
                                                         isDirectory: true)
        try? FileManager.default.createDirectory(at: research, withIntermediateDirectories: true)
        runtime.researchDirectory = research
        runtime.measurement = { _ in nil }
        runtime.readKey = { nil }
        runtime.keychain.save(key: "k", provider: AIProvider.mistral.rawValue)
        return LibraryEnvironment(libraryFile: directory.appendingPathComponent("presets.json"),
                                  autoEqTransport: CountingCatalogue(), ai: runtime,
                                  searchDelay: 0.4)
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
    private func open(_ device: EqTestDevice?) async -> AppModel {
        let lock = directory.appendingPathComponent("qudelix.lock")
        let links: [QxLink] = device.map { [$0.link] } ?? []
        let model = AppModel(makeLinks: { links },
                             acquireLock: { QxInstanceLock.acquire(at: lock) },
                             probeDevice: { AppDeviceProbe(present: device != nil) },
                             clock: clock, retryInterval: 2, connectTimeout: 2)
        model.libraryEnvironment = environment(ScriptedAITransport([chat(dossierText), chat(draftText())]))
        guard device != nil else { return model }
        model.start()
        await until("connected") {
            model.state.connection.isConnected && model.eq.state.ready
                && model.presets.state.slots.count == PresetSlotsModel.slotCount
        }
        await model.presets.waitForIdle()
        device?.link.clearSends()
        return model
    }

    @MainActor
    private func draft(_ model: AppModel) async {
        let ai = model.library.ai
        ai.setHeadphone("Sennheiser HD 650")
        ai.setKind("bass")
        XCTAssertTrue(ai.generate())
        await ai.waitForIdle()
        XCTAssertNotNil(ai.state.draft)
    }

    private func device() -> EqTestDevice {
        EqTestDevice(group: .user, bands: EqTestSupport.shaped(), preGain: -1, slot: 2,
                     names: [0: "Flat", 2: "Warm"])
    }

    @MainActor
    func testKindsAreGroupedLikeTheMacWithCharacterFirst() async {
        let model = await open(nil)
        let groups = model.library.ai.state.kindGroups
        XCTAssertEqual(groups.map(\.title), ["Character", "Targets"])
        XCTAssertEqual(groups[0].kinds.map(\.id), AIPresetKind.character.map(\.rawValue))
        XCTAssertEqual(groups[1].kinds.map(\.id), AIPresetKind.targets.map(\.rawValue))
        XCTAssertEqual(groups.flatMap(\.kinds).count, AIPresetKind.allCases.count)
        XCTAssertEqual(model.library.ai.state.kindLabel, AIPresetKind.correction.label)
        model.library.ai.setKind("vShape")
        XCTAssertEqual(model.library.ai.state.kindLabel, AIPresetKind.vShape.label)
    }

    @MainActor
    func testWriteToSlotIsOfferedOnlyWithADraftAndAConnectedDevice() async {
        let offline = await open(nil)
        await draft(offline)
        XCTAssertFalse(offline.library.ai.state.canWriteSlot)
        offline.library.ai.chooseSlot(1)
        XCTAssertNil(offline.library.ai.state.slotChoice)

        let device = device()
        let model = await open(device)
        XCTAssertFalse(model.library.ai.state.canWriteSlot)
        await draft(model)
        let ai = model.library.ai
        XCTAssertTrue(ai.state.canWriteSlot)
        XCTAssertEqual(ai.state.slots.count, PresetSlotsModel.slotCount)
        XCTAssertEqual(ai.state.slots[2].label, "Warm")
        ai.discardDraft()
        XCTAssertFalse(ai.state.canWriteSlot)
        await model.shutdown()
    }

    @MainActor
    func testChoosingAFilledSlotShowsTheMacOverwriteTextAndAnEmptyOneTheEmptyText() async {
        let model = await open(device())
        await draft(model)
        let ai = model.library.ai
        ai.chooseSlot(2)
        XCTAssertEqual(ai.state.slotChoice?.message,
                       "Slot 3, \u{201C}Warm\u{201D}, holds a preset on the device. "
                       + "Writing replaces it, and the device keeps no copy.")
        XCTAssertEqual(ai.state.slotChoice?.confirmLabel, "Overwrite slot 3")
        ai.chooseSlot(1)
        XCTAssertEqual(ai.state.slotChoice?.message,
                       "Slot 2 is empty. Writing puts this preset there.")
        ai.cancelSlotChoice()
        XCTAssertNil(ai.state.slotChoice)
        ai.chooseSlot(99)
        XCTAssertNil(ai.state.slotChoice)
        await model.shutdown()
    }

    @MainActor
    func testWritingToASlotAppliesTheDraftThenSavesThatSlotAndNamesIt() async {
        let device = device()
        let model = await open(device)
        await draft(model)
        let ai = model.library.ai
        ai.chooseSlot(1)
        XCTAssertTrue(ai.writeToSlot())
        XCTAssertNil(ai.state.slotChoice)
        await model.eq.waitForIdle()
        await model.presets.waitForIdle()
        let sent = device.link.sentCommands
        XCTAssertEqual(device.link.payloads(for: .setEqBandParam).count, 10)
        XCTAssertEqual(device.link.payloads(for: .saveEqPreset).count, 1)
        XCTAssertEqual(device.link.payloads(for: .saveEqPreset).first?.contains(1), true)
        let applied = sent.firstIndex(of: .setEqBandParam)
        let saved = sent.firstIndex(of: .saveEqPreset)
        XCTAssertNotNil(applied)
        XCTAssertNotNil(saved)
        if let applied, let saved { XCTAssertLessThan(applied, saved) }
        XCTAssertEqual(model.eq.state.undoLabel, "apply Airy 650")
        await model.shutdown()
    }

    @MainActor
    func testWritingWithoutAChosenSlotDoesNothing() async {
        let device = device()
        let model = await open(device)
        await draft(model)
        XCTAssertFalse(model.library.ai.writeToSlot())
        await model.eq.waitForIdle()
        XCTAssertTrue(device.link.sentCommands.isEmpty)
        await model.shutdown()
    }

    @MainActor
    func testTheUnsavedCurveWarningFollowsTheActiveSlot() async {
        let device = device()
        let model = await open(device)
        await draft(model)
        let ai = model.library.ai
        XCTAssertEqual(AiStudioModel.unsavedCurveWarning,
                       "Your current EQ is a custom setting that isn\u{2019}t saved to a "
                       + "slot \u{2014} applying this will replace it.")
        XCTAssertFalse(ai.state.unsavedCurve)
        let offline = await open(nil)
        XCTAssertTrue(offline.library.ai.state.unsavedCurve)
        await model.shutdown()
    }

    @MainActor
    func testResearchWordingMatchesTheMac() async {
        XCTAssertEqual(AiStudioModel.researchAgainLabel, "Research again")
        XCTAssertEqual(AiStudioModel.researchPending,
                       "Will research this model again on the next generate.")
        XCTAssertEqual(AiStudioModel.researchFirst, "Will research this model on first generate.")
        XCTAssertEqual(AiStudioModel.researchFallbackNote,
                       "Research didn\u{2019}t come back \u{2014} designed from general knowledge instead.")
        let model = await open(nil)
        let ai = model.library.ai
        await draft(model)
        XCTAssertFalse(ai.state.researchFallback)
        let info = ai.state.researchInfo ?? ""
        let pattern = "^Researched \\d{1,2}/\\d{1,2}/\\d{2} \u{00B7} high confidence$"
        XCTAssertNotNil(info.range(of: pattern, options: .regularExpression), info)
    }
}
