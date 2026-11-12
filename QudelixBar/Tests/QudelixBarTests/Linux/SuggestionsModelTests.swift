import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import QudelixBar

final class SuggestionsModelTests: XCTestCase {
    private var directory: URL!
    private var lockURL: URL!
    private var clock: ManualClock!
    private var catalogue: RecordingCatalogue!
    private var published: PublishedFixtures!
    private var held: [AppModel] = []
    private var automations: [AutomationModel] = []

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("suggestions-\(UUID().uuidString)", isDirectory: true)
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
        let pending = automations
        for automation in pending { await automation.shutdown() }
        automations = []
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
        model.library.suggestions.engine.pollInterval = .milliseconds(5)
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

    @MainActor
    private func automation(_ model: AppModel) -> AutomationModel {
        let automation = AutomationModel(app: model, stage: nil,
                                         url: directory.appendingPathComponent("autofit.json"))
        automations.append(automation)
        model.library.suggestions.attach(automation: automation)
        return automation
    }

    @MainActor
    private func offered(_ model: AppModel, _ name: String) async -> SuggestionsState {
        let suggestions = model.library.suggestions
        suggestions.uiShown()
        model.library.saved.setHeadphoneName(name)
        await suggestions.waitForIdle()
        return suggestions.state
    }

    @MainActor
    func testANamedPairGetsABannerWithTheMacTextsAndAlternatives() async {
        let model = await open(EqTestDevice())
        let state = await offered(model, "Sennheiser HD 650")
        let banner = state.banner
        XCTAssertEqual(banner?.headline, "Sennheiser HD 650 \u{2014} measured correction available")
        XCTAssertEqual(banner?.detail, "Measured by oratory1990 \u{2014} fitted to this device's 10 bands "
                       + "before anything is written.")
        XCTAssertEqual(banner?.measuredBy, "Measured by oratory1990")
        XCTAssertEqual(banner?.alternatives.map(\.label),
                       ["Sennheiser HD 650 (oratory1990)", "Sennheiser HD 650 (crinacle)"])
        XCTAssertNil(state.row)
        XCTAssertTrue(state.canApply)
        XCTAssertEqual(SuggestionsModel.applyLinkLabel, "Apply correction")
    }

    @MainActor
    func testAStoredNameWaitsForTheWindowAndAShortNameOffersNothing() async {
        PresetLibraryFile.save(PresetLibraryDocument(headphoneName: "Sennheiser HD 650"),
                               to: directory.appendingPathComponent("presets.json"))
        let model = await open(EqTestDevice())
        let suggestions = model.library.suggestions
        await suggestions.waitForIdle()
        XCTAssertNil(suggestions.state.banner)
        XCTAssertTrue(catalogue.equalizeBodies.isEmpty)
        suggestions.uiShown()
        await suggestions.waitForIdle()
        XCTAssertNotNil(suggestions.state.banner)
        model.library.saved.setHeadphoneName("HD")
        await suggestions.waitForIdle()
        XCTAssertNil(suggestions.state.banner)
        XCTAssertNil(suggestions.state.row)
    }

    @MainActor
    func testDismissingMovesTheOfferToTheLibraryRowAndNameIsNotOfferedAgain() async {
        let model = await open(EqTestDevice())
        let suggestions = model.library.suggestions
        _ = await offered(model, "Sennheiser HD 650")
        suggestions.dismiss()
        XCTAssertNil(suggestions.state.banner)
        XCTAssertEqual(suggestions.state.row?.measuredBy, "Measured by oratory1990")
        model.library.saved.setHeadphoneName("Moondrop Aria")
        model.library.saved.flushPendingWrites()
        await suggestions.waitForIdle()
        XCTAssertEqual(suggestions.state.banner?.headline, "Moondrop Aria \u{2014} measured correction available")
        model.library.saved.setHeadphoneName("Sennheiser HD 650")
        model.library.saved.flushPendingWrites()
        await suggestions.waitForIdle()
        XCTAssertNil(suggestions.state.banner)
        XCTAssertNil(suggestions.state.row)
    }

    @MainActor
    func testApplyingFitsToTheDeviceWritesItAndOpensTheAutoEqPage() async {
        let device = EqTestDevice()
        let model = await open(device)
        let suggestions = model.library.suggestions
        var opened = 0
        suggestions.openAutoEq = { opened += 1 }
        var landed: [ReferenceCurve] = []
        model.eqHost.onReferenceLanded = { curve, _ in landed.append(curve) }
        var notices: [AppNotice] = []
        model.addNoticeObserver { notices.append($0) }
        let state = await offered(model, "Sennheiser HD 650")
        suggestions.accept(state.banner?.id ?? "")
        XCTAssertTrue(suggestions.state.busy)
        await suggestions.waitForIdle()
        await until("opened") { opened == 1 }
        XCTAssertNil(suggestions.state.banner)
        XCTAssertNil(suggestions.state.error)
        XCTAssertEqual(landed.count, 1)
        XCTAssertEqual(catalogue.equalizeBodies.count, 1)
        XCTAssertEqual(notices.last?.message, "Applied the correction for Sennheiser HD 650.")
        XCTAssertTrue(model.library.autoEq.state.summary?.contains("Applied") == true)
        await model.eq.waitForIdle()
        XCTAssertTrue(device.link.sentCommands.contains(.setEqBandParam))
    }

    @MainActor
    func testApplyIsRefusedWithoutADeviceAndSaysSo() async {
        let model = await open(nil)
        let state = await offered(model, "Sennheiser HD 650")
        XCTAssertNotNil(state.banner)
        XCTAssertFalse(state.canApply)
        XCTAssertEqual(state.applyHelp, "Connect the 5K to apply.")
        model.library.suggestions.accept(state.banner?.id ?? "")
        await model.library.suggestions.waitForIdle()
        XCTAssertEqual(model.library.suggestions.state.error,
                       "Not applied \u{2014} the 5K isn't taking EQ writes right now.")
        XCTAssertNotNil(model.library.suggestions.state.banner)
    }

    @MainActor
    func testTheUnsavedCurveWarningShowsWhenNoSlotIsActive() async {
        let model = await open(EqTestDevice())
        _ = await offered(model, "Sennheiser HD 650")
        let activeSlot = model.eq.state.activeSlot
        let warning = model.library.suggestions.state.unsavedWarning
        XCTAssertEqual(warning == nil, activeSlot != nil)
        XCTAssertEqual(SuggestionsModel.unsavedWarning,
                       "Your current EQ is a custom setting that isn\u{2019}t saved to a slot "
                       + "\u{2014} applying this will replace it.")
    }

    @MainActor
    func testTheFitButtonFitsAnExactNameWithoutLeavingTheEqPage() async {
        let device = EqTestDevice()
        let model = await open(device)
        let automation = automation(model)
        var opened = 0
        model.library.suggestions.openAutoEq = { opened += 1 }
        var landed: [ReferenceCurve] = []
        model.eqHost.onReferenceLanded = { curve, _ in landed.append(curve) }
        model.library.saved.setHeadphoneName("Sennheiser HD 600")
        model.library.suggestions.requestFit()
        XCTAssertEqual(automation.state.fitRequest, "Sennheiser HD 600")
        XCTAssertTrue(model.library.suggestions.state.fitting)
        await model.library.suggestions.waitForIdle()
        await until("request cleared") { automation.state.fitRequest == nil }
        XCTAssertFalse(model.library.suggestions.state.fitting)
        XCTAssertNil(model.library.suggestions.state.fitNote)
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(landed.count, 1)
        XCTAssertEqual(landed.first?.headphone, "Sennheiser HD 600")
        await model.eq.waitForIdle()
        XCTAssertTrue(device.link.sentCommands.contains(.setEqBandParam))
    }

    @MainActor
    func testTheFitButtonOpensTheAutoEqSearchWhenTheNameIsAmbiguousOrMissing() async {
        let device = EqTestDevice()
        let model = await open(device)
        let automation = automation(model)
        var opened = 0
        model.library.suggestions.openAutoEq = { opened += 1 }
        model.library.saved.setHeadphoneName("Sennheiser HD 6")
        model.library.suggestions.requestFit()
        await model.library.suggestions.waitForIdle()
        await until("request cleared") { automation.state.fitRequest == nil }
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(model.library.autoEq.state.query, "Sennheiser HD 6")
        XCTAssertTrue(model.library.autoEq.state.summary?.hasPrefix("More than one measurement matches") == true)
        XCTAssertTrue(device.link.sentCommands.filter { $0 == .setEqBandParam }.isEmpty)
        model.library.saved.setHeadphoneName("")
        model.library.suggestions.requestFit()
        await model.library.suggestions.waitForIdle()
        await until("second request cleared") { automation.state.fitRequest == nil }
        XCTAssertEqual(opened, 2)
        XCTAssertTrue(model.library.autoEq.state.summary?.hasPrefix("Search for your headphones") == true)
    }

    @MainActor
    func testTheFitButtonWithoutADeviceExplainsAndClearsTheRequest() async {
        let model = await open(nil)
        let automation = automation(model)
        model.library.saved.setHeadphoneName("Sennheiser HD 600")
        model.library.suggestions.requestFit()
        XCTAssertNil(automation.state.fitRequest)
        XCTAssertEqual(model.library.suggestions.state.fitNote, "Connect the 5K to fit a correction.")
        XCTAssertFalse(model.library.suggestions.state.fitting)
        XCTAssertEqual(SuggestionsModel.fitButtonLabel(hasReference: false), "Fit")
        XCTAssertEqual(SuggestionsModel.fitButtonLabel(hasReference: true), "Re-fit")
    }
}
