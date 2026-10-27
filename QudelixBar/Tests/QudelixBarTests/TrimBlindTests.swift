import XCTest
@testable import QudelixBar

@MainActor
final class TrimBlindTests: XCTestCase {
    private var dir: URL!
    private let trim = TrimGains(bassDb: 1.2, tiltDbPerOctave: -0.3, presenceDb: 0.8, airDb: 0.5)
    private var alwaysTrimmedA: Chance { Chance(coin: { true }, index: { _ in 0 }) }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qa-trimblind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        DeviceRig.cleanUp()
    }

    private func base() -> [QxEqBandValue] {
        zip(QxEq.defaultFreqs, [3.0, 2.0, -1.0, 0.5, 1.0, -2.0, 1.5, -1.0, 2.0, -1.5]).map {
            QxEqBandValue(filter: .peak, freq: $0, gain: $1, q: 1.0)
        }
    }

    private func make(trim: TrimGains? = nil, on: Bool = true)
        async -> (DeviceRig, QudelixController, EqAutomation) {
        let rig = DeviceRig()
        await rig.connect(bands: base())
        let a = EqAutomation(controller: rig.controller,
                             url: dir.appendingPathComponent("autofit.json"))
        a.previewSet(autoTrimOn: on, source: .listening, trim: trim ?? self.trim)
        rig.controller.eqEnabled = true
        return (rig, rig.controller, a)
    }

    func testBlockerNeedsAutoTrimOnAndAnAudibleTrim() async {
        let (_, c, a) = await make(on: false)
        XCTAssertEqual(BlindTuner.trimBlocker(c, automation: a), .trimOff)
        a.previewSet(autoTrimOn: true, source: .listening, trim: .zero)
        XCTAssertEqual(BlindTuner.trimBlocker(c, automation: a), .trimInaudible)
        a.previewSet(autoTrimOn: true, source: .listening,
                     trim: TrimGains(bassDb: 0.09, tiltDbPerOctave: -0.09,
                                     presenceDb: 0.05, airDb: 0))
        XCTAssertEqual(BlindTuner.trimBlocker(c, automation: a), .trimInaudible)
        a.previewSet(autoTrimOn: true, source: .listening,
                     trim: TrimGains(bassDb: 0, tiltDbPerOctave: 0.1, presenceDb: 0, airDb: 0))
        XCTAssertNil(BlindTuner.trimBlocker(c, automation: a))
        c.eqEnabled = false
        XCTAssertEqual(BlindTuner.trimBlocker(c, automation: a), .eqOff)
        c.eqEnabled = true
        c.sampleRate = "16 kHz"
        XCTAssertEqual(BlindTuner.trimBlocker(c, automation: a), .voiceCall)
    }

    func testStartRefusedWhenTheTrimIsInaudible() async {
        let (_, c, _) = await make()
        let blind = BlindTuner()
        blind.startTrim(c, trim: .zero)
        XCTAssertEqual(blind.phase, .idle)
    }

    func testTheTwoSidesDifferByTheSolvedTrimAndAreLevelMatched() async {
        let (_, c, a) = await make()
        let startBands = c.bands
        let startPre = c.preGain
        let blind = BlindTuner()
        blind.startTrim(c, trim: a.trim, chance: alwaysTrimmedA)
        XCTAssertEqual(blind.phase, .running)
        let solved = ReferenceFollower.solve(
            base: startBands, basePreGain: startPre,
            reference: startBands, referencePreGain: startPre,
            trim: a.trim, iterations: ReferenceFollower.startIterations).bands
        XCTAssertNotEqual(solved, startBands)

        let trimmedBands = Array(c.bands.prefix(c.bandCount))
        let trimmedPre = c.preGain
        XCTAssertEqual(trimmedBands, Array(solved.prefix(c.bandCount)))

        blind.toggleSide(c)
        XCTAssertEqual(Array(c.bands.prefix(c.bandCount)), Array(startBands.prefix(c.bandCount)))
        let basePre = c.preGain

        let trimmedLevel = LevelMatch.meanLevelDb(bands: trimmedBands, preGain: trimmedPre)
        let baseLevel = LevelMatch.meanLevelDb(bands: startBands, preGain: basePre)
        XCTAssertEqual(trimmedLevel, baseLevel, accuracy: 0.15)
        blind.cancel(c)
    }

    func testFinishRestoresTheBaseAndTheFollowerResumes() async {
        let (_, c, a) = await make()
        let startBands = c.bands
        let startPre = c.preGain
        let blind = BlindTuner()
        blind.startTrim(c, trim: a.trim, chance: alwaysTrimmedA)
        for _ in 0..<BlindTuner.bypassTrials { blind.choose(preferA: true, c) }
        XCTAssertEqual(blind.phase, .finished)
        XCTAssertEqual(blind.bypassOutcome, .preferredEQ(BlindTuner.bypassTrials))
        XCTAssertEqual(c.bands, startBands)
        XCTAssertEqual(c.preGain, startPre, accuracy: 0.05)
        XCTAssertFalse(a.sessionsActive)
        XCTAssertFalse(a.suspended)
        blind.discardResult(c)
        XCTAssertEqual(blind.phase, .idle)
        XCTAssertEqual(c.bands, startBands)
    }

    func testCancelRestoresTheBase() async {
        let (_, c, a) = await make()
        let startBands = c.bands
        let startPre = c.preGain
        let blind = BlindTuner()
        blind.startTrim(c, trim: a.trim, chance: alwaysTrimmedA)
        XCTAssertNotEqual(c.bands, startBands)
        blind.cancel(c)
        XCTAssertEqual(blind.phase, .idle)
        XCTAssertEqual(c.bands, startBands)
        XCTAssertEqual(c.preGain, startPre, accuracy: 0.05)
        XCTAssertFalse(a.sessionsActive)
        XCTAssertFalse(a.suspended)
    }

    func testTheFollowerIsSuspendedAndTheTrimFrozenDuringTheSession() async {
        let (_, c, a) = await make()
        a.setAutoTrim(on: true, mode: .presentation, strength: 1)
        let reading = BalanceFeatures(bassDb: -9, tiltDbPerOctave: -3, presenceDb: -4)
        var ctx = EqAutomation.Context()
        ctx.reading = reading
        for _ in 0..<40 { a.tick(ctx) }
        let before = a.trim
        let blind = BlindTuner()
        blind.startTrim(c, trim: before.isZero ? trim : before, chance: alwaysTrimmedA)
        guard blind.phase == .running else { return XCTFail("session did not start") }
        XCTAssertTrue(a.sessionsActive)
        XCTAssertTrue(a.suspended)
        XCTAssertFalse(a.following)
        let shown = c.bands
        c.clearSendTrace()
        for _ in 0..<30 { a.tick(ctx) }
        XCTAssertEqual(a.trim, before)
        XCTAssertEqual(c.bands, shown)
        blind.cancel(c)
        XCTAssertFalse(a.suspended)
    }

    func testAnAudiophileModeAdvisoryShowsInTheSummary() {
        let advisory = TrimGains(bassDb: 0.8, tiltDbPerOctave: -0.2, presenceDb: 0.4, airDb: 0)
        let lines = AutomationReadout.trimLines(on: true, detecting: true, mode: .audiophile,
                                                trim: .zero, baseline: BalanceBaseline(readings: 900),
                                                advisory: advisory)
        XCTAssertTrue(lines[0].contains("would trim bass +0.8 \u{00B7} tilt \u{2212}0.2 \u{00B7} presence +0.4"))
        XCTAssertTrue(lines[0].contains("nothing moves"))
        let none = AutomationReadout.trimLines(on: true, detecting: true, mode: .audiophile,
                                               trim: .zero, baseline: BalanceBaseline(readings: 900))
        XCTAssertEqual(none, ["audiophile \u{2014} measures only, nothing moves"])
    }

    func testTheAdvisoryIsPublishedByTheAutomation() async {
        let (_, _, a) = await make(on: false)
        a.setAutoTrim(on: true, mode: .audiophile, strength: 0.5)
        var ctx = EqAutomation.Context()
        ctx.reading = BalanceFeatures(bassDb: -9, tiltDbPerOctave: -3, presenceDb: -4)
        for _ in 0..<400 { a.tick(ctx) }
        XCTAssertTrue(a.trim.isZero)
        XCTAssertEqual(a.advisory, a.advisory.rounded())
    }
}
