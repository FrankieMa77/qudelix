import XCTest
@testable import QudelixBar

final class CallAwarenessTests: XCTestCase {
    func testCoreAudioAloneIsEnough() {
        XCTAssertTrue(StageState.callIsActive(outputOnCall: true,
                                              deviceActiveCall: false,
                                              deviceInputSource: "A2DP 1"))
    }

    func testTheDevicesOwnReportIsEnough() {
        XCTAssertTrue(StageState.callIsActive(outputOnCall: false,
                                              deviceActiveCall: true,
                                              deviceInputSource: "USB"))
    }

    func testAnHfpInputSourceIsEnough() {
        for source in ["HFP 1", "HFP 2"] {
            XCTAssertTrue(StageState.callIsActive(outputOnCall: false,
                                                  deviceActiveCall: nil,
                                                  deviceInputSource: source),
                          source)
        }
    }

    func testNeitherWitnessMeansNoCall() {
        XCTAssertFalse(StageState.callIsActive(outputOnCall: false,
                                               deviceActiveCall: false,
                                               deviceInputSource: "A2DP 2"))
    }

    func testAnUnknownDeviceStateIsNotACall() {
        XCTAssertFalse(StageState.callIsActive(outputOnCall: false,
                                               deviceActiveCall: nil,
                                               deviceInputSource: nil))
        XCTAssertFalse(StageState.callIsActive(outputOnCall: false,
                                               deviceActiveCall: nil,
                                               deviceInputSource: "None"))
    }

    func testTheDeviceAloneCountsUntilReleasedByHand() {
        var w = CallWitnesses()
        w.deviceActiveCall = true
        let before = StageState.callVerdict(w, releasedByHand: false)
        XCTAssertTrue(before.active)
        XCTAssertFalse(before.stillReleased)
        let after = StageState.callVerdict(w, releasedByHand: true)
        XCTAssertFalse(after.active)
        XCTAssertTrue(after.stillReleased)
    }

    func testAnHfpLabelAloneIsReleasedTheSameWay() {
        var w = CallWitnesses()
        w.deviceInputSource = "HFP 1"
        XCTAssertFalse(StageState.callVerdict(w, releasedByHand: true).active)
    }

    func testReleasingByHandDoesNotOverruleTheMacsOwnAudioState() {
        var w = CallWitnesses()
        w.headsetMicRunning = true
        w.deviceActiveCall = true
        let verdict = StageState.callVerdict(w, releasedByHand: true)
        XCTAssertTrue(verdict.active)
        XCTAssertTrue(verdict.stillReleased)
        w.headsetMicRunning = false
        w.outputAtCallRate = true
        XCTAssertTrue(StageState.callVerdict(w, releasedByHand: true).active)
    }

    func testTheReleaseIsSpentOnceTheDeviceClearsSoTheNextCallCounts() {
        var w = CallWitnesses()
        w.deviceActiveCall = false
        w.deviceInputSource = "A2DP 1"
        let cleared = StageState.callVerdict(w, releasedByHand: true)
        XCTAssertFalse(cleared.active)
        XCTAssertFalse(cleared.stillReleased)
        w.deviceActiveCall = true
        XCTAssertTrue(StageState.callVerdict(w, releasedByHand: cleared.stillReleased).active)
    }

    func testTheWitnessSummaryNamesEveryVoiceThatIsUp() {
        var w = CallWitnesses()
        XCTAssertEqual(w.summary, "none")
        w.outputAtCallRate = true
        w.headsetMicRunning = true
        w.deviceActiveCall = true
        w.deviceInputSource = "HFP 2"
        XCTAssertEqual(w.summary, "rate16k+mic+devcall+src=HFP2")
        w.deviceInputSource = "A2DP 1"
        w.deviceActiveCall = false
        XCTAssertEqual(w.summary, "rate16k+mic")
    }

    func testTheRateAfterACallPrefersTheUsersOwnPick() {
        XCTAssertEqual(StageState.rateAfterCall(manual: 96000,
                                                available: [8000, 16000, 44100, 48000, 96000]),
                       96000)
    }

    func testWithoutAPickTheRateAfterACallIsTheHighestEverydayRate() {
        XCTAssertEqual(StageState.rateAfterCall(manual: nil,
                                                available: [8000, 16000, 44100, 48000, 96000]),
                       48000)
        XCTAssertEqual(StageState.rateAfterCall(manual: 22050,
                                                available: [16000, 44100]), 44100)
    }

    func testAHeadsetOfferingOnlyCallRatesGetsNoRateAfterACall() {
        XCTAssertNil(StageState.rateAfterCall(manual: nil, available: [8000, 16000]))
        XCTAssertNil(StageState.rateAfterCall(manual: 44100, available: []))
    }

    func testTheBadgeHelpNamesTheWitnessThatHoldsTheCall() {
        var w = CallWitnesses()
        w.deviceActiveCall = true
        XCTAssertTrue(StageState.callBadgeHelp(w).contains("The 5K reports"))
        w.outputAtCallRate = true
        XCTAssertTrue(StageState.callBadgeHelp(w).contains("call sample rate"))
        w.headsetMicRunning = true
        XCTAssertTrue(StageState.callBadgeHelp(w).contains("using the headset's microphone"))
    }

    func testAQuietEventWaitsTheSettlingWindow() {
        XCTAssertEqual(StageEngine.coalesceWait(sinceBurstStart: 0), 0.4, accuracy: 1e-9)
    }

    func testTheBurstCapShortensTheWaitAsItApproaches() {
        XCTAssertEqual(StageEngine.coalesceWait(sinceBurstStart: 1.2), 0.3, accuracy: 1e-9)
        XCTAssertEqual(StageEngine.coalesceWait(sinceBurstStart: 1.49), 0.01, accuracy: 1e-9)
    }

    func testPastTheCapTheAnswerIsImmediate() {
        XCTAssertEqual(StageEngine.coalesceWait(sinceBurstStart: 1.5), 0)
        XCTAssertEqual(StageEngine.coalesceWait(sinceBurstStart: 30), 0)
    }

    func testTheWaitIsNeverNegativeAndNeverLongerThanTheWindow() {
        for elapsed in stride(from: -1.0, through: 5.0, by: 0.05) {
            let wait = StageEngine.coalesceWait(sinceBurstStart: elapsed)
            XCTAssertGreaterThanOrEqual(wait, 0, "\(elapsed)")
            XCTAssertLessThanOrEqual(wait, 0.4, "\(elapsed)")
        }
    }

    func testTheSiblingUidSwapsTheScopeSuffix() {
        XCTAssertEqual(
            AudioOutputs.inputSiblingUID(forOutputUID: "00-11-22-33-44-55:output"),
            "00-11-22-33-44-55:input")
    }

    func testAUidWithoutTheSuffixHasNoDerivedSibling() {
        for uid in ["AppleUSBAudioEngine:Qudelix:5K", "BuiltInSpeakerDevice",
                    ":output:something", "output"] {
            XCTAssertNil(AudioOutputs.inputSiblingUID(forOutputUID: uid), uid)
        }
    }

    func testTheSuffixIsStrippedOnceNotEverywhereItAppears() {
        XCTAssertEqual(
            AudioOutputs.inputSiblingUID(forOutputUID: "dock:output:output"),
            "dock:output:input")
    }

    func testTheCallCeilingIsTheTopScoRate() {
        XCTAssertEqual(AudioOutputs.callModeCeilingHz, 16000)
    }
}
