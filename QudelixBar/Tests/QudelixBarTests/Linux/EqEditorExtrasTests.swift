import XCTest
@testable import QudelixBar

final class EqEditorExtrasTests: XCTestCase {
    private var directory: URL!
    private var clock: ManualClock!
    private var notices: [AppNotice] = []

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("eq-extras-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ActiveSlotFile.directoryOverride = directory
        EqHistoryFile.directoryOverride = directory
        clock = ManualClock()
        notices = []
    }

    override func tearDown() {
        ActiveSlotFile.directoryOverride = nil
        EqHistoryFile.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    @MainActor
    private func until(_ what: String = "condition", timeout: TimeInterval = 5,
                       _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    private func open(_ device: EqTestDevice) async -> AppModel {
        let url = directory.appendingPathComponent("qudelix.lock")
        let model = AppModel(makeLinks: { [device.link] },
                             acquireLock: { QxInstanceLock.acquire(at: url) },
                             probeDevice: { AppDeviceProbe(present: true) },
                             clock: clock, retryInterval: 2, connectTimeout: 2)
        model.addNoticeObserver { [weak self] notice in self?.notices.append(notice) }
        model.start()
        await until("connected") {
            model.state.connection.isConnected && model.eq.state.ready
                && model.presets.state.slots.count == PresetSlotsModel.slotCount
        }
        await model.eq.waitForIdle()
        device.link.clearSends()
        return model
    }

    @MainActor
    private func settle(_ model: AppModel) async {
        await model.eq.waitForIdle()
        await model.waitForIdle()
    }

    @MainActor
    func testTheBandCountCopyIsSingularForOneBand() {
        XCTAssertEqual(EqEditorModel.bandCount(1), "1 band")
        XCTAssertEqual(EqEditorModel.bandCount(0), "0 bands")
        XCTAssertEqual(EqEditorModel.bandCount(20), "20 bands")
    }

    private static let boosted = """
        Preamp: -6 dB
        Filter 1: ON PK Fc 60 Hz Gain 16 dB Q 1.0
        Filter 2: ON PK Fc 3000 Hz Gain -4 dB Q 2.0
        """

    @MainActor
    func testAnImportSetsTheSourceNameTheRequestedCurveAndTheDivergence() async {
        let device = EqTestDevice()
        let model = await open(device)
        XCTAssertNil(model.eq.state.requested)
        let result = model.eq.importText(Self.boosted, named: "HD 650")
        await settle(model)
        XCTAssertTrue(result.accepted)
        XCTAssertEqual(model.eq.state.sourceName, "HD 650")
        XCTAssertEqual(model.eq.state.requested?.count, 2)
        XCTAssertEqual(model.eq.state.requested?[0].gain ?? 0, 16, accuracy: 0.001)
        XCTAssertEqual(model.eq.state.bands[0].gain, 12, accuracy: 0.001)
        let divergence = model.eq.state.divergence()
        XCTAssertNotNil(divergence)
        XCTAssertGreaterThan(abs(divergence?.peak ?? 0), 1)
        XCTAssertEqual(notices.last?.kind, .success)
        XCTAssertTrue(notices.last?.message.hasPrefix("Applied 2 bands") ?? false)
        await model.shutdown()
    }

    @MainActor
    func testAFaithfulImportHasNoDivergence() async {
        let device = EqTestDevice()
        let model = await open(device)
        model.eq.importText("Preamp: -2 dB\nFilter 1: ON PK Fc 100 Hz Gain 3 dB Q 1.0\n", named: "mild")
        await settle(model)
        XCTAssertNotNil(model.eq.state.requested)
        XCTAssertNil(model.eq.state.divergence())
        XCTAssertTrue(model.eq.curveMatchesSource)
        model.eq.setBand(4, EqBand(filter: .peak, freq: 500, gain: 5, q: 1))
        XCTAssertFalse(model.eq.curveMatchesSource)
        await model.shutdown()
    }

    @MainActor
    func testUndoAndRedoRestoreTheRequestedCurveLikeTheMac() async {
        let device = EqTestDevice()
        let model = await open(device)
        model.eq.importText(Self.boosted, named: "HD 650")
        await settle(model)
        clock.advance(2)
        model.eq.flatten()
        await settle(model)
        XCTAssertNil(model.eq.state.requested)
        XCTAssertNil(model.eq.state.sourceName)
        model.eq.undo()
        await settle(model)
        XCTAssertNotNil(model.eq.state.requested)
        XCTAssertEqual(model.eq.state.sourceName, "HD 650")
        model.eq.undo()
        await settle(model)
        XCTAssertNil(model.eq.state.requested)
        model.eq.redo()
        await settle(model)
        XCTAssertNotNil(model.eq.state.requested)
        await model.shutdown()
    }

    @MainActor
    func testResetLayoutAndALoadedSlotClearTheRequestedCurve() async {
        let device = EqTestDevice(slot: 1, names: [1: "Warm"])
        device.slots[1] = (-2, EqTestSupport.shaped())
        let model = await open(device)
        model.eq.importText(Self.boosted, named: "HD 650")
        await settle(model)
        clock.advance(2)
        model.eq.resetLayout()
        await settle(model)
        XCTAssertNil(model.eq.state.requested)
        clock.advance(2)
        model.eq.importText(Self.boosted, named: "HD 650")
        await settle(model)
        XCTAssertNotNil(model.eq.state.requested)
        model.presets.load(slot: 1)
        await settle(model)
        XCTAssertNil(model.eq.state.requested)
        XCTAssertNil(model.eq.state.sourceName)
        await model.shutdown()
    }

    @MainActor
    func testAnImportIsRefusedDuringASessionAndLeavesNothingBehind() async {
        let device = EqTestDevice()
        let model = await open(device)
        model.eq.setSessionActive(true)
        let result = model.eq.importText(Self.boosted, named: "HD 650")
        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.summary, EqEditorModel.sessionRefusal)
        XCTAssertNil(model.eq.state.requested)
        XCTAssertEqual(notices.last?.kind, .failure)
        XCTAssertTrue(device.link.payloads(for: .setEqBandParam).isEmpty)
        await model.shutdown()
    }

    @MainActor
    func testFilesAreReadLikeTheCliAndBadOnesReportWhy() async throws {
        let device = EqTestDevice()
        let model = await open(device)
        let good = directory.appendingPathComponent("My Phones.txt")
        try Self.boosted.write(to: good, atomically: true, encoding: .utf8)
        let result = model.eq.importFile(at: good)
        await settle(model)
        XCTAssertTrue(result.accepted)
        XCTAssertEqual(model.eq.state.sourceName, "My Phones")

        let empty = directory.appendingPathComponent("notes.txt")
        try "nothing useful here".write(to: empty, atomically: true, encoding: .utf8)
        let none = model.eq.importFile(at: empty)
        XCTAssertFalse(none.accepted)
        XCTAssertEqual(none.summary, "No filters found in notes.txt.")

        let missing = model.eq.importFile(at: directory.appendingPathComponent("absent.txt"))
        XCTAssertFalse(missing.accepted)
        XCTAssertTrue(missing.summary.contains("absent.txt"))

        let utf16 = directory.appendingPathComponent("wide.txt")
        try Self.boosted.data(using: .utf16)!.write(to: utf16)
        XCTAssertTrue(model.eq.importFile(at: utf16).accepted)
        await model.shutdown()
    }

    @MainActor
    func testHeadroomAdviceAndTheSetButton() async {
        let device = EqTestDevice(preGain: 0)
        let model = await open(device)
        XCTAssertEqual(model.eq.state.headroom.text, "No band boost to offset.")
        XCTAssertNil(model.eq.state.headroom.buttonTitle)
        model.eq.setBand(3, EqBand(filter: .peak, freq: 250, gain: 6, q: 1))
        let advice = model.eq.state.headroom
        XCTAssertEqual(advice.peakBoost, 6, accuracy: 0.3)
        XCTAssertNotNil(advice.suggestion)
        XCTAssertTrue(advice.text.hasPrefix("Bands boost by up to"))
        XCTAssertTrue(advice.buttonTitle?.hasPrefix("Set -") ?? false)
        model.eq.applySuggestedPreGain()
        await settle(model)
        XCTAssertEqual(model.eq.state.preGain, advice.suggestion ?? 99, accuracy: 0.001)
        XCTAssertTrue(model.eq.state.headroom.text.hasSuffix("pre-gain covers it."))
        XCTAssertNil(model.eq.state.headroom.buttonTitle)
        await model.shutdown()
    }

    @MainActor
    func testTheSuggestedPreGainIsRefusedWhileFollowingOrInASession() async {
        let device = EqTestDevice(preGain: 0)
        let model = await open(device)
        model.eq.setBand(3, EqBand(filter: .peak, freq: 250, gain: 6, q: 1))
        await settle(model)
        model.eq.setFollowing(true)
        model.eq.applySuggestedPreGain()
        XCTAssertEqual(model.eq.state.preGain, 0, accuracy: 0.001)
        XCTAssertFalse(model.eq.state.canEdit)
        XCTAssertEqual(model.eq.state.readOnlyReason, EqEditorModel.followRefusal)
        model.eq.setFollowing(false)
        model.eq.setSessionActive(true)
        model.eq.applySuggestedPreGain()
        XCTAssertEqual(model.eq.state.preGain, 0, accuracy: 0.001)
        await model.shutdown()
    }

    @MainActor
    func testSwitchingToTwentyBandsFlushesEditsFirstThenSwitchesAndRereads() async {
        let device = EqTestDevice()
        let model = await open(device)
        model.eq.modeRetryDelays = [0.05, 0.05, 1]
        model.eq.importText(Self.boosted, named: "HD 650")
        await settle(model)
        model.eq.setBand(5, EqBand(filter: .peak, freq: 1000, gain: 4, q: 1))
        device.link.clearSends()
        model.eq.setEqMode(twentyBand: true)
        XCTAssertTrue(model.eq.state.modeChanging)
        await until("twenty bands") { model.eq.state.isTwentyBand && !model.eq.state.modeChanging }
        await settle(model)
        let sent = device.link.sentCommands
        let switchAt = sent.firstIndex(of: .setEqMode)
        XCTAssertNotNil(switchAt)
        XCTAssertEqual(device.link.payload(for: .setEqMode), [1])
        let lastBandBefore = sent.lastIndex(of: .setEqBandParam)
        XCTAssertNotNil(lastBandBefore)
        XCTAssertLessThan(sent.firstIndex(of: .setEqBandParam) ?? Int.max, switchAt ?? 0)
        XCTAssertEqual(model.eq.state.bandCount, 20)
        XCTAssertEqual(model.eq.state.groupLabel, QxFormat.groupLabel(.b20))
        XCTAssertNil(model.eq.state.requested)
        XCTAssertTrue(model.eq.state.canEdit)
        clock.advance(1)
        model.eq.setEqMode(twentyBand: false)
        await until("ten bands again") { !model.eq.state.isTwentyBand && model.eq.state.bandCount == 10 }
        await model.shutdown()
    }

    @MainActor
    func testTheModeSwitchHonoursTheMacGuards() async {
        let device = EqTestDevice()
        let model = await open(device)
        model.eq.modeRetryDelays = [0.05, 0.05, 0.2]

        model.eq.setEqMode(twentyBand: false)
        XCTAssertFalse(device.link.sentCommands.contains(.setEqMode))

        model.eq.setSessionActive(true)
        model.eq.setEqMode(twentyBand: true)
        XCTAssertEqual(notices.last?.message, EqEditorModel.sessionRefusal)
        model.eq.setSessionActive(false)

        model.eq.setFollowing(true)
        model.eq.setEqMode(twentyBand: true)
        XCTAssertEqual(notices.last?.message, EqEditorModel.followRefusal)
        model.eq.setFollowing(false)
        XCTAssertFalse(device.link.sentCommands.contains(.setEqMode))

        model.eq.setEqMode(twentyBand: true)
        model.eq.setEqMode(twentyBand: true)
        await until("switched") { model.eq.state.isTwentyBand && !model.eq.state.modeChanging }
        XCTAssertEqual(device.link.payloads(for: .setEqMode).count, 1)
        await model.shutdown()
    }

    @MainActor
    func testAnUnansweredModeSwitchUnlocksTheEditorAndSaysSo() async {
        let device = EqTestDevice()
        device.acceptsModeSwitch = false
        let model = await open(device)
        model.eq.modeRetryDelays = [0.05, 0.05]
        model.eq.setEqMode(twentyBand: true)
        await until("failure notice") { self.notices.contains { $0.kind == .failure } }
        await settle(model)
        XCTAssertFalse(model.eq.state.isTwentyBand)
        XCTAssertFalse(model.eq.state.modeChanging)
        XCTAssertTrue(model.eq.state.canEdit)
        XCTAssertTrue(notices.last?.message.hasPrefix("The 5K did not switch EQ mode.") ?? false)
        await model.shutdown()
    }

    @MainActor
    func testSavingAnImportedCurveNamesTheSlotAfterTheSourceOnlyWhileUnchanged() async {
        let device = EqTestDevice(slot: 0, names: [0: "Flat"])
        let model = await open(device)
        model.eq.importText("Preamp: -2 dB\nFilter 1: ON PK Fc 100 Hz Gain 3 dB Q 1.0\n", named: "Studio cans")
        await settle(model)
        XCTAssertNil(model.presets.requestSave(slot: 4))
        await settle(model)
        XCTAssertEqual(device.names[4], "Studio cans")
        XCTAssertNotNil(device.slots[4])

        clock.advance(2)
        await settle(model)
        model.eq.setBand(6, EqBand(filter: .peak, freq: 2000, gain: 3, q: 1))
        await settle(model)
        model.presets.save(slot: 6)
        await settle(model)
        XCTAssertNil(device.names[6])
        XCTAssertNotNil(device.slots[6])
        await model.shutdown()
    }

    @MainActor
    func testSaveToSlotAsksOnlyForNamedSlotsAndUpdateOverwritesTheActiveOne() async {
        let device = EqTestDevice(slot: 2, names: [2: "Warm", 5: "Vocal"])
        let model = await open(device)
        let prompt = model.presets.requestSave(slot: 5)
        XCTAssertEqual(prompt?.slot, 5)
        XCTAssertEqual(prompt?.title, PresetSlotsModel.overwriteTitle)
        XCTAssertEqual(prompt?.confirmLabel, "Save here")
        XCTAssertTrue(prompt?.message.contains("Vocal") ?? false)
        XCTAssertNil(device.slots[5])

        XCTAssertNil(model.presets.requestSave(slot: 7))
        await settle(model)
        XCTAssertNotNil(device.slots[7])

        XCTAssertTrue(model.presets.canUpdateActive)
        XCTAssertEqual(model.presets.updateHelp(), "Overwrite Warm with the current EQ")
        model.eq.setBand(1, EqBand(filter: .peak, freq: 63, gain: 7, q: 1))
        model.presets.updateActive()
        await settle(model)
        XCTAssertEqual(device.slots[2]?.bands[1].gain ?? 0, 7, accuracy: 0.001)
        XCTAssertEqual(device.link.payloads(for: .saveEqPreset).last, [2])

        model.eq.setFollowing(true)
        XCTAssertFalse(model.presets.canUpdateActive)
        device.link.clearSends()
        model.presets.updateActive()
        XCTAssertTrue(device.link.payloads(for: .saveEqPreset).isEmpty)
        await model.shutdown()
    }

    @MainActor
    func testLoadingTheActiveSlotSaysWhatHappened() async {
        let device = EqTestDevice(slot: 2, names: [2: "Warm"])
        device.slots[2] = (-3, EqTestSupport.shaped())
        let model = await open(device)
        model.presets.load(slot: 2)
        await settle(model)
        XCTAssertEqual(notices.last?.message, PresetSlotsModel.loadMessage(slot: 2, wasActive: true, changed: true))

        clock.advance(2)
        model.presets.load(slot: 2)
        await settle(model)
        XCTAssertEqual(notices.last?.message, "Slot 3 is already loaded \u{2014} nothing changed.")

        model.eq.setBand(0, EqBand(filter: .peak, freq: 31, gain: 9, q: 1))
        await settle(model)
        model.presets.load(slot: 2)
        await settle(model)
        XCTAssertEqual(notices.last?.message, "Slot 3 reloaded \u{2014} unsaved changes discarded.")

        model.presets.load(slot: 0)
        await settle(model)
        XCTAssertEqual(notices.last?.message, "Loaded slot 1.")
        await model.shutdown()
    }

    func testTheCustomSettingNoteIsTheMacsWording() {
        XCTAssertEqual(PresetSlotsModel.customSettingNote, "Current EQ is a custom setting, not a saved slot.")
        XCTAssertEqual(PresetSlotsModel.noActiveSlotHelp, "No slot is active \u{2014} load or save one first.")
    }

    func testTheAutomationSummaryAndForcingFollowTheMacRules() {
        var state = AutomationState()
        XCTAssertEqual(state.summary, "Off")
        XCTAssertFalse(state.isForced)
        XCTAssertFalse(state.strengthEnabled)
        state.autoTrimOn = true
        state.trimMode = .resolution
        XCTAssertTrue(state.isForced)
        XCTAssertTrue(state.strengthEnabled)
        XCTAssertEqual(state.summary, "Auto-trim resolution")
        state.trimMode = .audiophile
        XCTAssertFalse(state.strengthEnabled)
        state.autoFit = true
        state.following = true
        XCTAssertEqual(state.summary, "Auto-fit on \u{00B7} Auto-trim audiophile \u{00B7} following")
        state.paused = true
        XCTAssertTrue(state.summary.hasSuffix("paused"))
        var reference = AutomationState()
        reference.hasReference = true
        XCTAssertTrue(reference.isForced)
        XCTAssertEqual(AutomationState.readOnlyHelp, AutomationReadout.readOnlyHelp)
    }

    @MainActor
    func testAPreviewStateMakesTheEditorReadOnlyWithoutAnyAutomationRunning() async {
        let device = EqTestDevice()
        let model = await open(device)
        let automation = AutomationModel(app: model, stage: nil,
                                         url: directory.appendingPathComponent("autofit.json"))
        var preview = AutomationState()
        preview.following = true
        preview.autoFit = true
        preview.referenceLine = AutomationLine(bands: [EqBand(filter: .peak, freq: 1000, gain: 3, q: 1)],
                                               offsetDb: 0)
        automation.showPreview(preview)
        XCTAssertEqual(automation.state.referenceLine?.bands.count, 1)
        XCTAssertFalse(model.eq.state.canEdit)
        XCTAssertEqual(model.eq.state.readOnlyReason, EqEditorModel.followRefusal)
        model.eq.setBand(2, EqBand(filter: .peak, freq: 250, gain: 5, q: 1))
        XCTAssertTrue(device.link.payloads(for: .setEqBandParam).isEmpty)
        XCTAssertEqual(automation.state.referenceLine?.response(count: 50).count, 50)
        automation.shutdown()
        await model.shutdown()
    }
}
