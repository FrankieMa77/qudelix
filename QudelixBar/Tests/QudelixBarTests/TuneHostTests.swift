import XCTest
@testable import QudelixBar

@MainActor
final class TuneHostTests: XCTestCase {
    private func host() -> FakeEqHost {
        FakeEqHost(bands: FollowFixtures.tenBandReference())
    }

    func testBlockersFollowTheHostState() {
        let h = host()
        XCTAssertNil(ABTuner.blocker(h))
        h.isConnectedNow = false
        XCTAssertEqual(ABTuner.blocker(h), .notConnected)
        h.isConnectedNow = true
        h.isCompatible = false
        XCTAssertEqual(ABTuner.blocker(h), .unsupported)
        h.isCompatible = true
        h.isOnVoiceLink = true
        XCTAssertEqual(ABTuner.blocker(h), .voiceCall)
        h.isOnVoiceLink = false
        h.eqEnabled = false
        XCTAssertEqual(ABTuner.blocker(h), .eqOff)
        h.eqEnabled = true
        XCTAssertNil(BlindTuner.blocker(h, mode: .shape))
        h.bands = h.bands.map { var b = $0; b.gain = 0; return b }
        XCTAssertEqual(BlindTuner.blocker(h, mode: .bypass), .alreadyFlat)
    }

    func testAComparisonRunsToTheEndAndRestoresTheBaselineWhenDiscarded() {
        let h = host()
        let base = h.bands
        let basePre = h.preGain
        let tuner = ABTuner()
        tuner.start(h, chance: .seeded(7))
        XCTAssertEqual(tuner.phase, .running)
        XCTAssertTrue(h.byEarSessionActive)
        var guardCount = 0
        while tuner.phase == .running, guardCount < 100 {
            tuner.choose(preferA: guardCount % 2 == 0, h)
            guardCount += 1
        }
        XCTAssertEqual(tuner.phase, .finished)
        XCTAssertEqual(tuner.trialsDone, tuner.trialsTotal)
        XCTAssertFalse(tuner.resultBands.isEmpty)
        tuner.discardResult(h)
        XCTAssertEqual(tuner.phase, .idle)
        XCTAssertFalse(h.byEarSessionActive)
        XCTAssertEqual(h.bands, base)
        XCTAssertEqual(h.preGain, basePre, accuracy: 0.051)
    }

    func testKeepingAComparisonLeavesTheResultOnTheDevice() {
        let h = host()
        let tuner = ABTuner()
        tuner.start(h, chance: .seeded(3))
        while tuner.phase == .running { tuner.choose(preferA: true, h) }
        tuner.keepResult(h)
        XCTAssertEqual(tuner.phase, .idle)
        XCTAssertFalse(h.byEarSessionActive)
        XCTAssertEqual(h.preGain, ABTuner.safePreGain(for: tuner.resultBands, notAbove: 0))
    }

    func testCancellingMidwayPutsTheBaselineBack() {
        let h = host()
        let base = h.bands
        let tuner = ABTuner()
        tuner.start(h, chance: .seeded(11))
        tuner.toggleSide(h)
        tuner.noDifference(h)
        tuner.cancel(h)
        XCTAssertEqual(tuner.phase, .idle)
        XCTAssertEqual(h.bands, base)
        XCTAssertFalse(h.byEarSessionActive)
    }

    func testADisconnectEndsTheSessionWithAReason() {
        let h = host()
        let tuner = ABTuner()
        tuner.start(h, chance: .seeded(5))
        h.isConnectedNow = false
        tuner.choose(preferA: true, h)
        XCTAssertEqual(tuner.phase, .idle)
        XCTAssertEqual(tuner.note, "Comparison stopped — the 5K disconnected.")
        XCTAssertFalse(h.byEarSessionActive)
    }

    func testAnEqModeChangeEndsTheSessionWithoutRestoringOverTheNewMode() {
        let h = host()
        let tuner = ABTuner()
        tuner.start(h, chance: .seeded(5))
        h.eqGroup = .b20
        let writesBefore = h.bandUpdates
        tuner.choose(preferA: true, h)
        XCTAssertEqual(tuner.phase, .idle)
        XCTAssertEqual(h.bandUpdates, writesBefore)
        XCTAssertTrue(tuner.note?.contains("changed EQ mode") ?? false)
    }

    func testABlindShapeSessionRunsToAResult() {
        let h = host()
        let tuner = BlindTuner()
        tuner.start(h, mode: .shape, chance: .seeded(9))
        XCTAssertEqual(tuner.phase, .running)
        var guardCount = 0
        while tuner.phase == .running, guardCount < 200 {
            tuner.choose(preferA: guardCount % 3 != 0, h)
            guardCount += 1
        }
        XCTAssertEqual(tuner.phase, .finished)
        XCTAssertFalse(tuner.resultBands.isEmpty)
        tuner.discardResult(h)
        XCTAssertFalse(h.byEarSessionActive)
    }

    func testABypassCheckCountsItsAnswers() {
        let h = host()
        let tuner = BlindTuner()
        tuner.start(h, mode: .bypass, chance: .seeded(2))
        for _ in 0..<BlindTuner.bypassTrials { tuner.noDifference(h) }
        XCTAssertEqual(tuner.phase, .finished)
        XCTAssertEqual(tuner.bypassOutcome, .noneSurvived(eq: 0, flat: 0, same: 5))
    }

    func testWritesDuringASessionAreNeverUndoSteps() {
        let h = host()
        let tuner = ABTuner()
        tuner.start(h, chance: .seeded(4))
        tuner.choose(preferA: true, h)
        XCTAssertEqual(h.undoLabels, ["by-ear tuning"])
    }
}
