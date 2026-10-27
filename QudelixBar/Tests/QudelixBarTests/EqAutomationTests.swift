import XCTest
@testable import QudelixBar

@MainActor
final class EqAutomationTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("autofit.json") }
    private let flat = DeviceRig.curve()

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qa-autofit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        DeviceRig.cleanUp()
    }

    private func file(_ bands: [QxEqBandValue], preamp: Double = -3) -> ParametricEQFile {
        var f = ParametricEQFile()
        f.preamp = preamp
        f.bands = bands
        return f
    }

    private func reference(_ bands: [QxEqBandValue] = FollowFixtures.tenBandReference())
        -> ReferenceCurve {
        ReferenceCurve(file: file(bands), source: "test", headphone: "Test Phone")
    }

    private func reading(_ bass: Double = -8) -> BalanceFeatures {
        BalanceFeatures(bassDb: bass, tiltDbPerOctave: -2, presenceDb: 0)
    }

    private func ticks(_ a: EqAutomation, _ n: Int, _ context: EqAutomation.Context = .init()) {
        for _ in 0..<n { a.tick(context) }
    }

    private func make(bands: [QxEqBandValue]? = nil)
        async -> (DeviceRig, QudelixController, EqAutomation) {
        let rig = DeviceRig()
        await rig.connect(bands: bands ?? flat)
        let a = EqAutomation(controller: rig.controller, url: url)
        return (rig, rig.controller, a)
    }

    private func engaged(bands: [QxEqBandValue]? = nil)
        async -> (DeviceRig, QudelixController, EqAutomation) {
        let (rig, c, a) = await make(bands: bands)
        a.recordReference(reference(), for: .user)
        a.setAutoFit(true)
        a.tick(.init())
        c.clearSendTrace()
        return (rig, c, a)
    }

    private func learnedReadings(_ a: EqAutomation) -> Int {
        let text = a.diagnostics()
        guard let slash = text.range(of: "base="),
              let end = text[slash.upperBound...].firstIndex(of: "/") else { return -1 }
        let tail = text[text.index(after: end)...].prefix { $0.isNumber }
        return Int(tail) ?? -1
    }

    func testSettingsRoundTripThroughTheFile() async {
        let (_, _, a) = await make()
        a.recordReference(reference(), for: .user)
        a.setAutoTrim(on: true, mode: .presentation, strength: 0.8)
        a.setAutoFit(true)
        a.setReferenceSource(.catalog)
        a.setShowReference(false)
        a.persistNow()

        let rig2 = DeviceRig()
        let b = EqAutomation(controller: rig2.controller, url: url)
        XCTAssertTrue(b.autoTrimOn)
        XCTAssertEqual(b.autoTrimMode, .presentation)
        XCTAssertEqual(b.autoTrimStrength, 0.8)
        XCTAssertTrue(b.autoFit)
        XCTAssertEqual(b.referenceSource, .catalog)
        XCTAssertFalse(b.showReference)
        XCTAssertEqual(b.references[0]?.bands, a.references[0]?.bands)
        XCTAssertEqual(b.references[0]?.headphone, "Test Phone")
    }

    func testTheFileIsOwnerOnly() async {
        let (_, _, a) = await make()
        a.setAutoTrim(strength: 0.3)
        a.persistNow()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attrs?[.posixPermissions] as? Int, 0o600)
    }

    func testAnUnreadableFileIsParkedAndDefaultsApply() async {
        let junk = Data("{ not json".utf8)
        try? junk.write(to: url)
        let rig = DeviceRig()
        let a = EqAutomation(controller: rig.controller, url: url)
        XCTAssertFalse(a.autoTrimOn)
        XCTAssertFalse(a.autoFit)
        XCTAssertEqual(a.autoTrimMode, .clarity)
        XCTAssertTrue(a.references.isEmpty)
        let parked = dir.appendingPathComponent("autofit.json.recovered")
        XCTAssertEqual(try? Data(contentsOf: parked), junk)
    }

    func testALenientLoadDropsOnlyTheBadParts() async throws {
        let good = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(reference()))
        let object: [String: Any] = [
            "autoTrimStrength": 9, "autoTrimMode": "nope", "autoFit": "yes",
            "balanceBaseline": ["bassDb": 99, "tiltDbPerOctave": "bad"],
            "referenceByGroup": ["0": good, "2": ["bands": "x"], "9": good, "x": good]
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let rig = DeviceRig()
        let a = EqAutomation(controller: rig.controller, url: url)
        XCTAssertEqual(a.autoTrimStrength, 1)
        XCTAssertEqual(a.autoTrimMode, .clarity)
        XCTAssertFalse(a.autoFit)
        XCTAssertEqual(a.baseline.bassDb, 12)
        XCTAssertEqual(a.baseline.tiltDbPerOctave, -2)
        XCTAssertEqual(Set(a.references.keys), [0])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("autofit.json.recovered").path))
    }

    func testIncomingStrengthIsClamped() async {
        let (_, _, a) = await make()
        a.setAutoTrim(strength: -4)
        XCTAssertEqual(a.autoTrimStrength, 0)
        a.setAutoTrim(strength: .nan)
        XCTAssertEqual(a.autoTrimStrength, 0.5)
        a.setAutoTrim(strength: 3)
        XCTAssertEqual(a.autoTrimStrength, 1)
    }

    func testEngagingWritesFollowedGainsWithoutPersistingOrUndo() async {
        let (_, c, a) = await make()
        a.recordReference(reference(), for: .user)
        a.setAutoFit(true)
        c.clearSendTrace()
        a.tick(.init())

        XCTAssertTrue(a.following)
        XCTAssertGreaterThan(c.writeCount(), 0)
        XCTAssertNotEqual(c.bands, flat)
        XCTAssertEqual(a.followedBands, c.bands)
        XCTAssertEqual(a.baseBands, flat)
        XCTAssertFalse(c.debugFlashSavePending)
        XCTAssertFalse(c.canUndo)
        XCTAssertFalse(c.sendTrace.contains("saveAll"))
        XCTAssertNotNil(a.deviationDb)
    }

    func testNothingIsWrittenWhenTheFiveKIsNotConnected() {
        let rig = DeviceRig()
        let a = EqAutomation(controller: rig.controller, url: url)
        a.setAutoTrim(on: true)
        ticks(a, 3)
        XCTAssertEqual(a.waitingReason, "Connect the 5K")
        XCTAssertFalse(a.following)
        XCTAssertTrue(rig.controller.sendTrace.filter { $0.contains("setEq") }.isEmpty)
    }

    func testNothingIsWrittenWhileTheEqIsOff() async {
        let (_, c, a) = await engaged()
        c.setEqEnabled(false)
        c.clearSendTrace()
        ticks(a, 3)
        XCTAssertEqual(c.writeCount(), 0)
        XCTAssertNotNil(a.waitingReason)
    }

    func testTheSpeakerEqIsNeverWritten() async {
        let (_, c, a) = await make()
        c.applyPreviewGroup(.speaker)
        a.setAutoTrim(on: true)
        c.clearSendTrace()
        ticks(a, 3)
        XCTAssertEqual(a.waitingReason, "Not available for the speaker EQ")
        XCTAssertEqual(c.writeCount(), 0)
        XCTAssertFalse(a.following)
    }

    func testNothingIsWrittenOnACall() async {
        let (_, c, a) = await engaged()
        ticks(a, 3, .init(onCall: true))
        XCTAssertEqual(c.writeCount(), 0)
        XCTAssertEqual(a.waitingReason, "Paused for the call")
        ticks(a, 2)
        XCTAssertNil(a.waitingReason)
    }

    func testNothingIsWrittenWhileATunerSessionIsActive() async {
        let (_, c, a) = await engaged()
        c.setByEarSessionActive(true)
        c.clearSendTrace()
        ticks(a, 4)
        XCTAssertEqual(c.writeCount(), 0)
        XCTAssertTrue(a.suspended)
        XCTAssertFalse(a.following)
        c.setByEarSessionActive(false)
    }

    private func raisedTrim(_ context: EqAutomation.Context = .init(),
                            session: Bool = false) async -> Double {
        let (_, c, a) = await make()
        a.setAutoTrim(on: true, mode: .presentation, strength: 1)
        if session { c.setByEarSessionActive(true) }
        var ctx = context
        ctx.reading = reading()
        ticks(a, 1, .init())
        ticks(a, 12, ctx)
        return a.trim.bassDb
    }

    func testTheTrimMovesWhenTheMusicIsOffTheBaseline() async {
        let moved = await raisedTrim()
        XCTAssertGreaterThan(moved, 0.5)
    }

    func testTheTrimIsFrozenWhileMutedOnACallOrInASession() async {
        let muted = await raisedTrim(.init(muted: true))
        let call = await raisedTrim(.init(onCall: true))
        let session = await raisedTrim(session: true)
        XCTAssertEqual(muted, 0)
        XCTAssertEqual(call, 0)
        XCTAssertEqual(session, 0)
    }

    private func relaxedTrim(_ context: EqAutomation.Context,
                             count: Int = 3) async -> (before: Double, after: Double) {
        let (_, _, a) = await make()
        a.setAutoTrim(on: true, mode: .presentation, strength: 1)
        var live = EqAutomation.Context()
        live.reading = reading()
        ticks(a, 14, live)
        let before = a.trim.bassDb
        var next = context
        next.reading = reading()
        ticks(a, count, next)
        return (before, a.trim.bassDb)
    }

    func testTheTrimResetsWhenDetectionStopsTheOutputChangesOrIsNotTheFiveK() async {
        let off = await relaxedTrim(.init(detecting: false))
        XCTAssertGreaterThan(off.before, 0.5)
        XCTAssertLessThan(off.after, off.before)
        let elsewhere = await relaxedTrim(.init(onQudelixOutput: false))
        XCTAssertLessThan(elsewhere.after, elsewhere.before)
        let other = await relaxedTrim(.init(deviceUID: "another"), count: 1)
        XCTAssertLessThan(other.after, other.before)
    }

    func testTheBaselineLearnsWhileAutoTrimIsOffButNotOnAnotherOutput() async {
        let (_, _, a) = await make()
        var live = EqAutomation.Context()
        live.reading = reading()
        ticks(a, 5, live)
        XCTAssertEqual(learnedReadings(a), 4)
        var elsewhere = live
        elsewhere.onQudelixOutput = false
        ticks(a, 5, elsewhere)
        XCTAssertEqual(learnedReadings(a), 4)
        XCTAssertTrue(a.trim.isZero)
    }

    func testAReadbackEchoOfTheFollowedGainsIsNotABaseChange() async {
        let (rig, c, a) = await engaged()
        let before = a.baseBands
        let followed = c.bands
        rig.ingest(Wire.presetPackets(group: .user, bands: followed, preGain: c.preGain))
        XCTAssertEqual(a.baseBands, before)
        XCTAssertTrue(a.following)
        XCTAssertEqual(c.bands, followed)
    }

    func testAStaleEchoFromAFewTicksAgoIsStillAnEcho() async {
        let (rig, c, a) = await engaged()
        let first = c.bands
        let firstPre = c.preGain
        ticks(a, 2)
        let before = a.baseBands
        rig.ingest(Wire.presetPackets(group: .user, bands: first, preGain: firstPre))
        XCTAssertEqual(a.baseBands, before)
    }

    func testAnExternalChangeBecomesTheNewBaseAndFollowingContinues() async {
        let (rig, c, a) = await engaged()
        let external = DeviceRig.curve(gain: 5)
        rig.ingest(Wire.presetPackets(group: .user, bands: external, preGain: 0))
        XCTAssertEqual(a.baseBands, external)
        XCTAssertTrue(a.following)
        c.clearSendTrace()
        a.tick(.init())
        XCTAssertGreaterThan(c.writeCount(), 0)
        XCTAssertEqual(a.baseBands, external)
    }

    func testALayoutChangeInTheReadbackIsExternal() async {
        let (rig, _, a) = await engaged()
        var moved = flat
        moved[3].freq = 300
        rig.ingest(Wire.presetPackets(group: .user, bands: moved, preGain: 0))
        XCTAssertEqual(a.baseBands, moved)
    }

    func testLoadingASlotWaitsForTheReadbackThenRebases() async {
        let (rig, c, a) = await engaged()
        c.loadPreset(1)
        c.clearSendTrace()
        ticks(a, 3)
        XCTAssertEqual(c.writeCount(), 0, "the loaded slot is not yet known")
        let slot = DeviceRig.curve(gain: 1)
        rig.ingest(Wire.presetPackets(group: .user, bands: slot, preGain: 0))
        XCTAssertEqual(a.baseBands, slot)
        a.tick(.init())
        XCTAssertGreaterThan(c.writeCount(), 0)
    }

    func testALandedFitBecomesTheBase() async {
        let (_, c, a) = await engaged()
        let fit = file([QxEqBandValue(filter: .peak, freq: 1000, gain: 2, q: 1),
                        QxEqBandValue(filter: .peak, freq: 4000, gain: -2, q: 1)], preamp: -2)
        XCTAssertTrue(c.apply(fit, named: "fit"))
        XCTAssertEqual(a.baseBands, c.bands)
        XCTAssertEqual(a.baseBands.first(where: { $0.freq == 1000 })?.gain, 2)
        XCTAssertTrue(a.following)
    }

    func testUndoReturnsTheUsersCurveAndRebases() async {
        let (_, c, a) = await engaged()
        c.setPreGain(-5)
        c.undoEqEdit()
        XCTAssertEqual(c.bands, flat)
        XCTAssertEqual(c.preGain, 0)
        XCTAssertEqual(a.baseBands, flat)
        XCTAssertTrue(a.following)
    }

    func testSwitchingTheEqGroupStopsFollowingAndClearsTheBase() async {
        let (_, c, a) = await engaged()
        c.debugIngest(Wire.deviceConfig(eqMode: 1, group: 2, slot: 255))
        XCTAssertEqual(c.eqGroup, .b20)
        XCTAssertFalse(a.following)
        XCTAssertTrue(a.baseBands.isEmpty)
        XCTAssertNil(a.currentReference)
    }

    func testADisconnectClearsFollowingAndAReconnectEngagesAgain() async {
        let (rig, _, a) = await engaged()
        await rig.detachUSB()
        XCTAssertFalse(a.following)
        XCTAssertTrue(a.baseBands.isEmpty)
        await rig.connect(bands: flat)
        a.tick(.init())
        XCTAssertTrue(a.following)
        XCTAssertEqual(a.baseBands, flat)
    }

    func testKeepWritesTheFollowedGainsAsTheUsersOwnWithOneUndoStep() async {
        let (_, c, a) = await engaged()
        let followed = c.bands
        let followedPre = c.preGain
        a.keep()

        XCTAssertFalse(a.autoFit)
        XCTAssertFalse(a.following)
        XCTAssertEqual(c.bands, followed)
        XCTAssertEqual(c.preGain, followedPre)
        XCTAssertEqual(c.undoStack.count, 1)
        XCTAssertEqual(c.undoLabel, "Keep auto-fit")
        XCTAssertTrue(c.debugFlashSavePending)

        c.clearSendTrace()
        ticks(a, 3)
        XCTAssertEqual(c.writeCount(), 0)
        c.debugFireFlashSave()
        XCTAssertEqual(c.writeCount(), 0, "the kept curve is the user's, nothing is swapped back")
        XCTAssertTrue(c.sendTrace.contains("saveAll"))

        c.undoEqEdit()
        XCTAssertEqual(c.bands, flat)
    }

    func testKeepOnTheListeningSourceZeroesTheTrimAndTurnsItOff() async {
        let (_, c, a) = await make()
        a.setAutoFit(true)
        XCTAssertTrue(a.autoTrimOn)
        var live = EqAutomation.Context()
        live.reading = reading(-8)
        ticks(a, 20, live)
        XCTAssertTrue(a.following)
        XCTAssertGreaterThan(a.trim.bassDb, 0.5)
        XCTAssertNotEqual(c.bands, flat)
        let followed = c.bands

        a.keep()

        XCTAssertFalse(a.autoTrimOn)
        XCTAssertFalse(a.autoFit)
        XCTAssertTrue(a.trim.isZero)
        XCTAssertEqual(c.bands, followed)
        ticks(a, 2, live)
        XCTAssertTrue(a.trim.isZero)
        XCTAssertFalse(a.following)
    }

    private func pausingSetup() async -> (DeviceRig, QudelixController, EqAutomation, [QxEqBandValue]) {
        var movable = flat.map { b -> QxEqBandValue in
            var v = b
            v.filter = .bypass
            return v
        }
        movable[5].filter = .peak
        let (rig, c, a) = await make(bands: movable)
        let impossible = [QxEqBandValue(filter: .lowShelf, freq: 105, gain: 12, q: 0.7),
                          QxEqBandValue(filter: .highShelf, freq: 5000, gain: -12, q: 0.7)]
        a.recordReference(reference(impossible), for: .user)
        a.setAutoFit(true)
        return (rig, c, a, c.bands)
    }

    func testAnUnreachableReferencePausesPutsTheBaseBackAndStaysPaused() async {
        let (_, c, a, original) = await pausingSetup()
        a.tick(.init())
        XCTAssertNotEqual(c.bands, original)
        ticks(a, 6)

        XCTAssertTrue(a.paused)
        XCTAssertFalse(a.following)
        XCTAssertEqual(c.bands, original)
        XCTAssertEqual(c.preGain, 0)

        c.clearSendTrace()
        ticks(a, 10)
        XCTAssertTrue(a.paused)
        XCTAssertEqual(c.writeCount(), 0)
    }

    func testReEnablingClearsThePause() async {
        let (_, c, a, original) = await pausingSetup()
        ticks(a, 7)
        XCTAssertTrue(a.paused)
        a.setAutoFit(false)
        XCTAssertFalse(a.paused)
        a.setAutoFit(true)
        c.clearSendTrace()
        a.tick(.init())
        XCTAssertFalse(a.paused)
        XCTAssertTrue(a.following)
        XCTAssertNotEqual(c.bands, original)
    }

    func testListeningWithAutoFitTurnsAutoTrimOnAndEnablesDetection() async {
        let (_, _, a) = await make()
        var enabled = 0
        a.enableDetection = { enabled += 1 }
        a.setAutoFit(true)
        XCTAssertTrue(a.autoTrimOn)
        XCTAssertEqual(a.effectiveSource, .listening)
        XCTAssertGreaterThan(enabled, 0)
    }

    func testACatalogReferenceKeepsAutoTrimOffWhenAutoFitTurnsOn() async {
        let (_, _, a) = await make()
        a.recordReference(reference(), for: .user)
        a.setAutoFit(true)
        XCTAssertFalse(a.autoTrimOn)
        XCTAssertEqual(a.effectiveSource, .catalog)
        a.setReferenceSource(.listening)
        XCTAssertTrue(a.autoTrimOn)
    }

    func testTurningAutoTrimOnEnablesDetection() async {
        let (_, _, a) = await make()
        var enabled = 0
        a.enableDetection = { enabled += 1 }
        a.setAutoTrim(on: true)
        XCTAssertEqual(enabled, 1)
        a.setAutoTrim(mode: .resolution)
        XCTAssertEqual(enabled, 1)
    }

    func testAReferenceIsKeptPerEqGroup() async {
        let (_, c, a) = await make()
        let ten = reference()
        let twenty = reference(FollowFixtures.twentyBandReference())
        a.recordReference(ten, for: .user)
        a.recordReference(twenty, for: .b20)
        XCTAssertEqual(a.currentReference?.bands, ten.sanitized().bands)

        c.debugIngest(Wire.deviceConfig(eqMode: 1, group: 2, slot: 255))
        XCTAssertEqual(a.currentReference?.bands, twenty.sanitized().bands)

        c.landReference(reference([QxEqBandValue(filter: .peak, freq: 1000, gain: 1, q: 1)]))
        XCTAssertEqual(a.references[2]?.bands.count, 1)
        XCTAssertEqual(a.references[0]?.bands, ten.sanitized().bands)
    }

    func testABadReferenceIsRefused() async {
        let (_, _, a) = await make()
        a.recordReference(reference([QxEqBandValue(filter: .bypass, freq: 1000, gain: 0, q: 1)]),
                          for: .user)
        XCTAssertTrue(a.references.isEmpty)
    }

    func testASessionSuspendsFollowingWritesTheBaseAndResumesOnEnd() async {
        let (_, c, a) = await engaged()
        XCTAssertNotEqual(c.bands, flat)

        c.setByEarSessionActive(true)
        XCTAssertTrue(a.suspended)
        XCTAssertEqual(c.bands, flat)
        XCTAssertEqual(c.preGain, 0)
        XCTAssertFalse(a.following)

        c.setByEarSessionActive(false)
        XCTAssertFalse(a.suspended)
        c.clearSendTrace()
        a.tick(.init())
        XCTAssertTrue(a.following)
        XCTAssertGreaterThan(c.writeCount(), 0)
        XCTAssertNotEqual(c.bands, flat)
    }

    func testTheCompareTunerCapturesTheBaseNotTheFollowedGains() async {
        let (_, c, a) = await engaged()
        let tuner = ABTuner()
        tuner.start(c)
        XCTAssertEqual(tuner.phase, .running)
        XCTAssertTrue(a.suspended)
        tuner.cancel(c)
        XCTAssertEqual(c.bands, flat)
        XCTAssertFalse(a.suspended)
        a.tick(.init())
        XCTAssertTrue(a.following)
        XCTAssertEqual(a.baseBands, flat)
    }

    func testTheBlindTunerCapturesTheBaseNotTheFollowedGains() async {
        let (_, c, a) = await engaged()
        let tuner = BlindTuner()
        tuner.start(c, mode: .shape)
        XCTAssertEqual(tuner.phase, .running)
        XCTAssertTrue(a.suspended)
        tuner.cancel(c)
        XCTAssertEqual(c.bands, flat)
        XCTAssertFalse(a.suspended)
        a.tick(.init())
        XCTAssertEqual(a.baseBands, flat)
    }

    func testAFlashSaveWhileFollowingPutsTheBaseBackThenFollowingRewrites() async {
        let (rig, c, a) = await engaged()
        XCTAssertNotEqual(c.bands, flat)
        c.debugFireFlashSave()
        let trace = c.sendTrace
        XCTAssertLessThan(trace.lastIndex(of: "coalesced:setEqBandParam") ?? 99,
                          trace.firstIndex(of: "saveAll") ?? -1)
        XCTAssertEqual(c.bands, flat)
        c.flushEqSnapshot()
        XCTAssertEqual(rig.savedSnapshots[0]?.bands, flat)

        c.clearSendTrace()
        a.tick(.init())
        XCTAssertGreaterThan(c.writeCount(), 0)
        XCTAssertNotEqual(c.bands, flat)
        c.flushEqSnapshot()
        XCTAssertEqual(rig.savedSnapshots[0]?.bands, flat, "the snapshot still holds the base")
    }

    func testTheHeartbeatFragmentCarriesTheFields() async {
        let (_, _, a) = await make()
        a.recordReference(reference(), for: .user)
        a.setAutoFit(true)
        a.tick(.init())
        let first = a.diagnostics()
        for key in ["trim=", "base=", "sess=0", "follow=1", "src=c", "dev=", "w="] {
            XCTAssertTrue(first.contains(key), "\(key) in \(first)")
        }
        XCTAssertFalse(first.contains("w=0"))
        XCTAssertTrue(a.diagnostics().hasSuffix("w=0"))
    }
}
