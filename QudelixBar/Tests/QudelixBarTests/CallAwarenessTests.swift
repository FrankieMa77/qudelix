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
