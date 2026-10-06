import XCTest
@testable import QudelixBar

@MainActor
final class StageTrackingTests: XCTestCase {
    func testTrackingOffRecordsNothingHoweverLoudTheSecondWas() {
        let after = StageState.exposureAfterTick([], db: -6, power: 0.25,
                                                 tracking: false, today: "2026-08-06")
        XCTAssertTrue(after.isEmpty)
    }

    func testTrackingOffLeavesHistoryRecordedEarlierExactlyAsItWas() {
        let existing = [day("2026-08-05", audible: 900, loud: 60, energy: 4)]
        let after = StageState.exposureAfterTick(existing, db: -20, power: 0.01,
                                                 tracking: false, today: "2026-08-06")
        XCTAssertEqual(after, existing)
    }

    func testTrackingOnCountsTheSecond() {
        let after = StageState.exposureAfterTick([], db: -20, power: 0.01,
                                                 tracking: true, today: "2026-08-06")
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].day, "2026-08-06")
        XCTAssertEqual(after[0].audibleSeconds, 1)
        XCTAssertEqual(after[0].energySum, 0.01, accuracy: 1e-12)
        XCTAssertEqual(after[0].loudSeconds, 0)
    }

    func testLoudSecondsCountOnlyPastTheLoudThreshold() {
        let loud = StageState.exposureAfterTick([], db: StageState.loudThresholdDb + 1,
                                                power: 0.1, tracking: true,
                                                today: "2026-08-06")
        XCTAssertEqual(loud[0].loudSeconds, 1)
        let quiet = StageState.exposureAfterTick([], db: StageState.loudThresholdDb - 1,
                                                 power: 0.1, tracking: true,
                                                 today: "2026-08-06")
        XCTAssertEqual(quiet[0].loudSeconds, 0)
        XCTAssertEqual(quiet[0].audibleSeconds, 1)
    }

    func testSilenceIsNotListeningEvenWithTrackingOn() {
        let after = StageState.exposureAfterTick([], db: StageState.silenceFloorDb - 1,
                                                 power: 1e-9, tracking: true,
                                                 today: "2026-08-06")
        XCTAssertTrue(after.isEmpty)
    }

    func testANewDayStartsItsOwnEntry() {
        let after = StageState.exposureAfterTick([day("2026-08-05", audible: 10)],
                                                 db: -20, power: 0.01, tracking: true,
                                                 today: "2026-08-06")
        XCTAssertEqual(after.map(\.day), ["2026-08-05", "2026-08-06"])
        XCTAssertEqual(after[0].audibleSeconds, 10)
        XCTAssertEqual(after[1].audibleSeconds, 1)
    }

    func testHistoryStaysCappedAtFourteenDays() {
        let old = (1...14).map { day(String(format: "2026-07-%02d", $0), audible: 5) }
        let after = StageState.exposureAfterTick(old, db: -20, power: 0.01,
                                                 tracking: true, today: "2026-08-06")
        XCTAssertEqual(after.count, 14)
        XCTAssertEqual(after.first?.day, "2026-07-02")
        XCTAssertEqual(after.last?.day, "2026-08-06")
    }

    func testTodayIsFoundByKeyNotByPosition() {
        let existing = [day("2026-08-06", audible: 30), day("2026-08-07", audible: 5)]
        let after = StageState.exposureAfterTick(existing, db: -20, power: 0.01,
                                                 tracking: true, today: "2026-08-06")
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after[0].audibleSeconds, 31)
        XCTAssertEqual(after[1].audibleSeconds, 5)
    }

    func testRefusesToSwitchWhenTheVerdictCameFromAnotherDevice() {
        XCTAssertNil(target(measuredOn: "speakers-uid"))
    }

    func testSwitchesWhenTheVerdictCameFromTheDeviceBeingSwitched() {
        XCTAssertEqual(target(measuredOn: qudelix.uid), 44100)
    }

    func testRefusesWhenNoDeviceIsRecordedForTheVerdict() {
        XCTAssertNil(target(measuredOn: nil))
    }

    func testHiResContentTargets96kWhenTheDeviceOffersIt() {
        XCTAssertEqual(target(verdict: .hiRes(cutoffKHz: 24.5),
                              measuredOn: qudelix.uid), 96000)
    }

    func testHiResPrefers882WhenThatIsTheHighestOnOffer() {
        XCTAssertEqual(target(verdict: .hiRes(cutoffKHz: 24.5),
                              measuredOn: qudelix.uid,
                              availableRates: [44100, 48000, 88200]), 88200)
    }

    func testHiResHoldsRatherThanDownsamplingWhenNothingHighIsOffered() {
        XCTAssertNil(target(verdict: .hiRes(cutoffKHz: 24.5),
                            measuredOn: qudelix.uid,
                            availableRates: [44100, 48000]))
    }

    func testLossyReturnsToTheRateTheUserPickedByHand() {
        XCTAssertEqual(target(verdict: .lossy(cutoffKHz: 16.4),
                              measuredOn: qudelix.uid,
                              manualRateHz: 48000,
                              deviceRate: 44100), 48000)
    }

    func testVerdictsThatAbstainMoveNothing() {
        for verdict in [QualityAnalyzer.Verdict.tooQuiet, .noTreble,
                        .natural(cutoffKHz: 18), .lossyHigh(cutoffKHz: 19.9)] {
            XCTAssertNil(target(verdict: verdict, measuredOn: qudelix.uid),
                         "\(verdict) should not vote")
        }
    }

    func testRefusesWhileSoundstageIsInserted() {
        XCTAssertNil(target(measuredOn: qudelix.uid, stageEnabled: true))
    }

    func testRefusesWhenTheAutomationIsOff() {
        XCTAssertNil(target(measuredOn: qudelix.uid, autoRate: false))
    }

    func testRefusesUntilTheVerdictHasHeldTenSeconds() {
        XCTAssertNil(target(measuredOn: qudelix.uid, secondsStable: 9))
        XCTAssertNil(target(measuredOn: qudelix.uid, secondsStable: nil))
        XCTAssertEqual(target(measuredOn: qudelix.uid, secondsStable: 10), 44100)
    }

    func testRefusesWithinFortyFiveSecondsOfTheLastSwitch() {
        XCTAssertNil(target(measuredOn: qudelix.uid, secondsSinceLastSwitch: 44))
        XCTAssertEqual(target(measuredOn: qudelix.uid, secondsSinceLastSwitch: 45), 44100)
    }

    func testRefusesWhenTheDeviceIsAlreadyAtTheTargetRate() {
        XCTAssertNil(target(measuredOn: qudelix.uid, deviceRate: 44100))
    }

    func testRefusesWhenTheDeviceDoesNotOfferTheTarget() {
        XCTAssertNil(target(measuredOn: qudelix.uid, availableRates: [48000, 96000]))
    }

    func testRefusesWhenTheQudelixIsNotAnOutputDeviceAtAll() {
        XCTAssertNil(StageState.autoRateTarget(
            verdict: .losslessLike(cutoffKHz: 21.9), measuredOn: "some-uid",
            device: nil, availableRates: [44100, 48000], manualRateHz: nil,
            autoRate: true, stageEnabled: false, callActive: false,
            secondsStable: 30, secondsSinceLastSwitch: 300))
    }

    func testTheNarrationAndTheSwitchResolveTheSameRate() {
        let rates = [44100.0, 48000, 88200, 96000]
        for verdict in [QualityAnalyzer.Verdict.losslessLike(cutoffKHz: 21.9),
                        .hiRes(cutoffKHz: 24.5), .lossy(cutoffKHz: 16.4)] {
            let narrated = StageState.rateForVerdict(
                verdict, availableRates: rates,
                manualRateHz: 44100, deviceRate: 48000)
            let acted = target(verdict: verdict, measuredOn: qudelix.uid,
                               availableRates: rates, manualRateHz: 44100,
                               deviceRate: 48000)
            XCTAssertNotNil(narrated, "\(verdict)")
            XCTAssertEqual(narrated, acted, "\(verdict)")
        }
    }

    func testVerdictsThatAbstainResolveNoRateAtAll() {
        for verdict in [QualityAnalyzer.Verdict.tooQuiet, .noTreble,
                        .natural(cutoffKHz: 18), .lossyHigh(cutoffKHz: 19.9)] {
            XCTAssertNil(StageState.rateForVerdict(
                verdict, availableRates: [44100, 48000, 96000],
                manualRateHz: nil, deviceRate: 48000), "\(verdict)")
        }
    }

    func testLosslessOnAnOutputWithoutFortyFourPointOneStillResolvesToIt() {
        XCTAssertEqual(
            StageState.rateForVerdict(.losslessLike(cutoffKHz: 21.9),
                                      availableRates: [96000],
                                      manualRateHz: nil, deviceRate: 96000),
            44100)
        XCTAssertNil(target(measuredOn: qudelix.uid, availableRates: [96000],
                            deviceRate: 96000))
    }

    func testImplausibleRatesAreRejectedAtTheDeviceBoundary() {
        for rate in [Double.infinity, -.infinity, .nan, 0, -48000, 7999, 768_001, 1e12] {
            XCTAssertFalse(AudioOutputs.isPlausibleRate(rate), "\(rate)")
            XCTAssertEqual(AudioOutputs.plausibleRate(rate), AudioOutputs.fallbackRate)
        }
        for rate in [8000.0, 44100, 48000, 96000, 768_000] {
            XCTAssertTrue(AudioOutputs.isPlausibleRate(rate), "\(rate)")
            XCTAssertEqual(AudioOutputs.plausibleRate(rate), rate)
        }
    }

    func testRefusesWhileACallIsInProgress() {
        XCTAssertNil(target(measuredOn: qudelix.uid, callActive: true))
        XCTAssertEqual(target(measuredOn: qudelix.uid, callActive: false), 44100)
    }

    private let qudelix = AudioOutput(id: 42, uid: "qudelix-uid",
                                      name: "Qudelix 5K", sampleRate: 48000)

    func testTheQudelixOwnVolumeIsTheAnchorWhileTheMacPlaysToIt() {
        XCTAssertEqual(StageState.volumeAnchor(playingToQudelix: true,
                                               qudelixVolumeDb: -22,
                                               systemVolumeDb: 0),
                       .qudelix(-22))
    }

    func testAnyOtherOutputIsAnchoredByItsOwnVolume() {
        XCTAssertEqual(StageState.volumeAnchor(playingToQudelix: false,
                                               qudelixVolumeDb: -22,
                                               systemVolumeDb: -8),
                       .system(-8))
    }

    func testASilentControlLinkFallsBackToTheOutputsOwnVolume() {
        XCTAssertEqual(StageState.volumeAnchor(playingToQudelix: true,
                                               qudelixVolumeDb: nil,
                                               systemVolumeDb: -8),
                       .system(-8))
    }

    func testAnImplausibleDeviceReadingIsNotAnAnchor() {
        XCTAssertEqual(StageState.volumeAnchor(playingToQudelix: true,
                                               qudelixVolumeDb: 1e9,
                                               systemVolumeDb: -8),
                       .system(-8))
        XCTAssertNil(StageState.volumeAnchor(playingToQudelix: true,
                                             qudelixVolumeDb: .nan,
                                             systemVolumeDb: nil))
    }

    func testNoVolumeAnywhereLeavesNothingToAnchorTo() {
        XCTAssertNil(StageState.volumeAnchor(playingToQudelix: false,
                                             qudelixVolumeDb: -22,
                                             systemVolumeDb: nil))
    }

    func testABluetoothOutputIsNeverRenegotiated() {
        let headset = AudioOutput(id: 7, uid: "bt-uid", name: "Qudelix-5K",
                                  sampleRate: 44100, isBluetooth: true)
        let result = StageState.autoRateTarget(
            verdict: .hiRes(cutoffKHz: 40), measuredOn: headset.uid, device: headset,
            availableRates: [8000, 16000, 44100, 48000, 96000], manualRateHz: nil,
            autoRate: true, stageEnabled: false, callActive: false,
            secondsStable: 30, secondsSinceLastSwitch: 300)
        XCTAssertNil(result)
    }

    func testACallRateBaselineIsNeverActedOn() {
        XCTAssertNil(target(verdict: .lossy(cutoffKHz: 16),
                            measuredOn: qudelix.uid,
                            availableRates: [8000, 16000, 44100, 48000],
                            manualRateHz: 16000, deviceRate: 44100))
        XCTAssertEqual(target(verdict: .lossy(cutoffKHz: 16),
                              measuredOn: qudelix.uid,
                              availableRates: [8000, 16000, 44100, 48000],
                              manualRateHz: 48000, deviceRate: 44100), 48000)
    }

    func testCallRatesAreNotPlaybackRates() {
        XCTAssertEqual(StageState.playbackRates([8000, 16000, 44100, 96000]), [44100, 96000])
        XCTAssertNil(StageState.acceptableManualRate(16000))
        XCTAssertNil(StageState.acceptableManualRate(8000))
        XCTAssertNil(StageState.acceptableManualRate(nil))
        XCTAssertNil(StageState.acceptableManualRate(.infinity))
        XCTAssertEqual(StageState.acceptableManualRate(44100), 44100)
    }

    private func target(verdict: QualityAnalyzer.Verdict = .losslessLike(cutoffKHz: 21.9),
                        measuredOn: String?,
                        availableRates: [Double] = [44100, 48000, 88200, 96000],
                        manualRateHz: Double? = nil,
                        deviceRate: Double = 48000,
                        autoRate: Bool = true,
                        stageEnabled: Bool = false,
                        callActive: Bool = false,
                        secondsStable: Double? = 30,
                        secondsSinceLastSwitch: Double = 300) -> Double? {
        StageState.autoRateTarget(
            verdict: verdict,
            measuredOn: measuredOn,
            device: AudioOutput(id: qudelix.id, uid: qudelix.uid,
                                name: qudelix.name, sampleRate: deviceRate),
            availableRates: availableRates,
            manualRateHz: manualRateHz,
            autoRate: autoRate,
            stageEnabled: stageEnabled,
            callActive: callActive,
            secondsStable: secondsStable,
            secondsSinceLastSwitch: secondsSinceLastSwitch)
    }

    private func day(_ key: String, audible: Double, loud: Double = 0,
                     energy: Double = 0) -> DayExposure {
        DayExposure(day: key, audibleSeconds: audible, loudSeconds: loud,
                    energySum: energy)
    }
}
