import XCTest
@testable import QudelixBar

@MainActor
final class EqAutomationHostTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("autofit.json") }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-autofit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func reference() -> ReferenceCurve {
        var file = ParametricEQFile()
        file.preamp = -3
        file.bands = FollowFixtures.tenBandReference()
        return ReferenceCurve(file: file, source: "test", headphone: "Test Phone")
    }

    private func engaged() -> (FakeEqHost, EqAutomation) {
        let host = FakeEqHost(bands: FollowFixtures.tenBandBase())
        let automation = EqAutomation(controller: host, url: url)
        automation.recordReference(reference(), for: .user)
        automation.setAutoFit(true)
        return (host, automation)
    }

    func testTheAutomationWiresItselfIntoTheHost() {
        let host = FakeEqHost(bands: FollowFixtures.tenBandBase())
        _ = EqAutomation(controller: host, url: url)
        XCTAssertNotNil(host.baseProvider)
        XCTAssertNotNil(host.onReadback)
        XCTAssertNotNil(host.onBaseEvent)
        XCTAssertNotNil(host.onFlashCommitted)
        XCTAssertNotNil(host.onSessionBegin)
        XCTAssertNotNil(host.onSessionEnd)
        XCTAssertNotNil(host.onReferenceLanded)
    }

    func testAutoFitMovesTheGainsTowardTheReferenceThroughTheHost() {
        let (host, automation) = engaged()
        let before = host.bands
        automation.tick(.init())
        XCTAssertTrue(automation.following)
        XCTAssertFalse(host.writes.isEmpty)
        XCTAssertNotEqual(host.bands, before)
        XCTAssertEqual(automation.baseBands, before)
    }

    func testTurningAutoFitOffWritesTheBaseBack() {
        let (host, automation) = engaged()
        let base = host.bands
        automation.tick(.init())
        XCTAssertNotEqual(host.bands, base)
        automation.setAutoFit(false)
        XCTAssertEqual(host.bands, base)
        XCTAssertFalse(automation.following)
    }

    func testNothingIsWrittenOnACall() {
        let (host, automation) = engaged()
        var context = EqAutomation.Context()
        context.onCall = true
        automation.tick(context)
        XCTAssertTrue(host.writes.isEmpty)
        XCTAssertEqual(automation.waitingReason, "Paused for the call")
    }

    func testNothingIsWrittenOverAHandsFreeLink() {
        let (host, automation) = engaged()
        host.inputSource = "HFP headset"
        automation.tick(.init())
        XCTAssertTrue(host.writes.isEmpty)
        XCTAssertEqual(automation.waitingReason, "Paused for the call")
    }

    func testASessionSuspendsFollowingAndRestoresTheBase() {
        let (host, automation) = engaged()
        let base = host.bands
        automation.tick(.init())
        XCTAssertNotEqual(host.bands, base)
        host.setByEarSessionActive(true)
        XCTAssertTrue(automation.suspended)
        XCTAssertEqual(host.bands, base)
        let writesDuringSession = host.writes.count
        automation.tick(.init())
        XCTAssertEqual(host.writes.count, writesDuringSession)
        XCTAssertEqual(automation.waitingReason, "Paused while a tuning session runs")
        host.setByEarSessionActive(false)
        XCTAssertFalse(automation.suspended)
    }

    func testBlockedStatesNameTheirReason() {
        let (host, automation) = engaged()
        host.canWriteNow = false
        automation.tick(.init())
        XCTAssertEqual(automation.waitingReason, "Connect the 5K")
        host.canWriteNow = true
        host.eqEnabled = false
        automation.tick(.init())
        XCTAssertEqual(automation.waitingReason, "Turn the EQ on to use it")
        host.eqEnabled = true
        host.eqSettling = true
        automation.tick(.init())
        XCTAssertEqual(automation.waitingReason, "Waiting for the 5K's EQ mode")
        host.eqSettling = false
        host.eqReadBack = false
        automation.tick(.init())
        XCTAssertEqual(automation.waitingReason, "Reading the 5K's EQ")
        host.eqReadBack = true
        automation.setAutoTrim(on: true)
        host.eqGroup = .speaker
        automation.tick(.init())
        XCTAssertEqual(automation.waitingReason, "Not available for the speaker EQ")
    }

    func testKeepBakesTheFollowedGainsThroughTheHost() {
        let (host, automation) = engaged()
        automation.tick(.init())
        let followed = host.bands
        automation.keep()
        XCTAssertEqual(host.keeps, 1)
        XCTAssertEqual(host.undoLabels.last, "Keep auto-fit")
        XCTAssertEqual(host.bands, followed)
        XCTAssertFalse(automation.autoFit)
        XCTAssertFalse(automation.following)
    }

    func testQuitFlushRestoresTheBaseBlocking() {
        let (host, automation) = engaged()
        let base = host.bands
        automation.tick(.init())
        automation.restoreBaseForQuit()
        XCTAssertEqual(host.bands, base)
        XCTAssertEqual(host.blockingFlushes, 1)
    }

    func testABaseEventClearsTheFollowState() {
        let (host, automation) = engaged()
        automation.tick(.init())
        XCTAssertFalse(automation.baseBands.isEmpty)
        host.onBaseEvent?(.group)
        XCTAssertTrue(automation.baseBands.isEmpty)
        XCTAssertFalse(automation.following)
    }

    func testAReferenceLandingIsRecordedForItsGroup() {
        let host = FakeEqHost(bands: FollowFixtures.tenBandBase())
        let automation = EqAutomation(controller: host, url: url)
        host.onReferenceLanded?(reference(), .user)
        XCTAssertNotNil(automation.currentReference)
        XCTAssertEqual(automation.effectiveSource, .catalog)
    }

    func testReadoutInputsComeFromTheHost() {
        let host = FakeEqHost(bands: FollowFixtures.tenBandBase())
        let automation = EqAutomation(controller: host, url: url)
        let inputs = AutomationReadout.inputs(automation, host)
        XCTAssertEqual(inputs.userBands, FollowFixtures.tenBandBase())
        XCTAssertFalse(inputs.following)
    }

    func testSettingsPersistAndReload() {
        let host = FakeEqHost(bands: FollowFixtures.tenBandBase())
        let a = EqAutomation(controller: host, url: url)
        a.setAutoTrim(on: true, mode: .presentation, strength: 0.8)
        a.persistNow()
        let b = EqAutomation(controller: FakeEqHost(bands: FollowFixtures.tenBandBase()), url: url)
        XCTAssertTrue(b.autoTrimOn)
        XCTAssertEqual(b.autoTrimMode, .presentation)
        XCTAssertEqual(b.autoTrimStrength, 0.8)
    }
}
