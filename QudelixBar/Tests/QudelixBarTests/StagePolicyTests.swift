import XCTest
@testable import QudelixBar

final class StagePolicyTests: XCTestCase {
    func testWantedModePrefersInsertOverMonitor() {
        XCTAssertEqual(StagePolicy.wantedMode(stageEnabled: true, perAppEQ: false,
                                              levelTracking: true, detectQuality: true), .insert)
        XCTAssertEqual(StagePolicy.wantedMode(stageEnabled: false, perAppEQ: true,
                                              levelTracking: false, detectQuality: false), .insert)
        XCTAssertEqual(StagePolicy.wantedMode(stageEnabled: false, perAppEQ: false,
                                              levelTracking: false, detectQuality: true), .monitor)
        XCTAssertNil(StagePolicy.wantedMode(stageEnabled: false, perAppEQ: false,
                                            levelTracking: false, detectQuality: false))
    }

    func testCallWitnessesAndVerdicts() {
        var w = CallWitnesses()
        XCTAssertFalse(w.outputOnCall)
        XCTAssertFalse(w.deviceSaysCall)
        XCTAssertEqual(w.summary, "none")
        w.deviceInputSource = "HFP mic"
        XCTAssertTrue(w.deviceSaysCall)
        XCTAssertEqual(w.summary, "src=HFPmic")
        XCTAssertTrue(StagePolicy.callVerdict(w, releasedByHand: false).active)
        let released = StagePolicy.callVerdict(w, releasedByHand: true)
        XCTAssertFalse(released.active)
        XCTAssertTrue(released.stillReleased)
        w.outputAtCallRate = true
        XCTAssertTrue(StagePolicy.callVerdict(w, releasedByHand: true).active)
        XCTAssertEqual(w.summary, "rate16k+src=HFPmic")
        XCTAssertTrue(StagePolicy.callIsActive(outputOnCall: false, deviceActiveCall: true,
                                               deviceInputSource: nil))
        XCTAssertFalse(StagePolicy.callIsActive(outputOnCall: false, deviceActiveCall: false,
                                                deviceInputSource: "USB"))
    }

    func testRatesAfterACallAndPlaybackRates() {
        XCTAssertEqual(StagePolicy.playbackRates([16000, 44100, 48000]), [44100, 48000])
        XCTAssertEqual(StagePolicy.rateAfterCall(manual: 44100, available: [16000, 44100, 48000]),
                       44100)
        XCTAssertEqual(StagePolicy.rateAfterCall(manual: nil, available: [16000, 44100, 96000]),
                       44100)
        XCTAssertEqual(StagePolicy.rateAfterCall(manual: nil, available: [16000, 96000]), 96000)
        XCTAssertNil(StagePolicy.acceptableManualRate(16000))
        XCTAssertNil(StagePolicy.acceptableManualRate(nil))
        XCTAssertEqual(StagePolicy.acceptableManualRate(48000), 48000)
    }

    func testRateForVerdict() {
        let rates = [44100.0, 48000, 96000, 192000]
        XCTAssertEqual(StagePolicy.rateForVerdict(.hiRes(cutoffKHz: 30), availableRates: rates,
                                                  manualRateHz: nil, deviceRate: 48000), 192000)
        XCTAssertEqual(StagePolicy.rateForVerdict(.losslessLike(cutoffKHz: 21), availableRates: rates,
                                                  manualRateHz: 96000, deviceRate: 48000), 44100)
        XCTAssertEqual(StagePolicy.rateForVerdict(.lossy(cutoffKHz: 16), availableRates: rates,
                                                  manualRateHz: 96000, deviceRate: 48000), 96000)
        XCTAssertEqual(StagePolicy.rateForVerdict(.lossy(cutoffKHz: 16), availableRates: rates,
                                                  manualRateHz: nil, deviceRate: 48000), 48000)
        XCTAssertNil(StagePolicy.rateForVerdict(.natural(cutoffKHz: 18), availableRates: rates,
                                                manualRateHz: nil, deviceRate: 48000))
    }

    func testAutoRateTargetGates() {
        let usb = AutoRateDevice(uid: "u", isBluetooth: false, rate: 48000)
        func target(device: AutoRateDevice? = usb, autoRate: Bool = true, stage: Bool = false,
                    call: Bool = false, stable: Double? = 20, since: Double = 60,
                    measuredOn: String? = "u") -> Double? {
            StagePolicy.autoRateTarget(verdict: .losslessLike(cutoffKHz: 21),
                                       measuredOn: measuredOn, device: device,
                                       availableRates: [44100, 48000, 96000],
                                       manualRateHz: nil, autoRate: autoRate,
                                       stageEnabled: stage, callActive: call,
                                       secondsStable: stable, secondsSinceLastSwitch: since)
        }
        XCTAssertEqual(target(), 44100)
        XCTAssertNil(target(autoRate: false))
        XCTAssertNil(target(stage: true))
        XCTAssertNil(target(call: true))
        XCTAssertNil(target(stable: 9))
        XCTAssertNil(target(stable: nil))
        XCTAssertNil(target(since: 44))
        XCTAssertNil(target(measuredOn: "other"))
        XCTAssertNil(target(device: AutoRateDevice(uid: "u", isBluetooth: true, rate: 48000)))
        XCTAssertNil(target(device: AutoRateDevice(uid: "u", isBluetooth: false, rate: 44100)))
        XCTAssertNil(target(device: nil))
    }

    func testBassGuardMathIsInertWithoutBoost() {
        XCTAssertEqual(StagePolicy.bassGuardBoostDb(bands: [], loudnessShelfDb: 0), 0)
        let boost = QxEqBandValue(filter: .peak, freq: 80, gain: 8, q: 1)
        let worst = StagePolicy.bassGuardBoostDb(bands: [boost], loudnessShelfDb: 0)
        XCTAssertGreaterThan(worst, 6)
        XCTAssertEqual(StagePolicy.bassGuardCeilingDb(worstBoostDb: 0.4, strength: 1), 0)
        XCTAssertEqual(StagePolicy.bassGuardCeilingDb(worstBoostDb: 8, strength: 0.5), 4)
        XCTAssertEqual(StagePolicy.bassGuardCeilingDb(worstBoostDb: 30, strength: 1),
                       StageProcessor.bassGuardMaxCeilingDb)
        XCTAssertEqual(StagePolicy.bassGuardCeilingDb(worstBoostDb: 8, strength: .nan), 0)
    }

    func testExposureAccumulatesOnlyAboveTheSilenceFloor() {
        let days: [DayExposure] = []
        XCTAssertTrue(StagePolicy.exposureAfterTick(days, db: -60, power: 1, tracking: true,
                                                    today: "2026-01-01").isEmpty)
        XCTAssertTrue(StagePolicy.exposureAfterTick(days, db: -20, power: 1, tracking: false,
                                                    today: "2026-01-01").isEmpty)
        var next = StagePolicy.exposureAfterTick(days, db: -20, power: 2, tracking: true,
                                                 today: "2026-01-01")
        next = StagePolicy.exposureAfterTick(next, db: -5, power: 3, tracking: true,
                                             today: "2026-01-01")
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].audibleSeconds, 2)
        XCTAssertEqual(next[0].loudSeconds, 1)
        XCTAssertEqual(next[0].energySum, 5)
    }

    func testExposureKeepsFourteenDays() {
        var days: [DayExposure] = []
        for d in 1...16 {
            days = StagePolicy.exposureAfterTick(days, db: -20, power: 1, tracking: true,
                                                 today: String(format: "2026-01-%02d", d))
        }
        XCTAssertEqual(days.count, 14)
        XCTAssertEqual(days.first?.day, "2026-01-03")
    }

    func testVolumeAnchorPrefersTheDeviceWhenPlayingToIt() {
        XCTAssertEqual(StagePolicy.volumeAnchor(playingToQudelix: true, qudelixVolumeDb: -20,
                                                systemVolumeDb: -10), .qudelix(-20))
        XCTAssertEqual(StagePolicy.volumeAnchor(playingToQudelix: false, qudelixVolumeDb: -20,
                                                systemVolumeDb: -10), .system(-10))
        XCTAssertNil(StagePolicy.volumeAnchor(playingToQudelix: false, qudelixVolumeDb: nil,
                                              systemVolumeDb: nil))
    }

    func testImpulsePrimeGateStateMachine() {
        var gate = ImpulsePrimeGate()
        XCTAssertEqual(gate.verdict(sourceRate: nil, targetRate: 48000), .proceed)
        XCTAssertEqual(gate.verdict(sourceRate: 44100, targetRate: 44100), .proceed)
        XCTAssertEqual(gate.verdict(sourceRate: 44100, targetRate: 48000), .prime(rate: 48000))
        XCTAssertEqual(gate.verdict(sourceRate: 44100, targetRate: 48000), .wait)
        gate.finished(generation: gate.generation, rate: 48000)
        XCTAssertEqual(gate.verdict(sourceRate: 44100, targetRate: 48000), .proceed)
        gate.adopted()
        XCTAssertNil(gate.cachedRate)
        XCTAssertEqual(gate.verdict(sourceRate: 44100, targetRate: 48000), .prime(rate: 48000))
    }

    func testCallBadgeHelpNamesTheWitness() {
        var w = CallWitnesses()
        w.deviceActiveCall = true
        XCTAssertTrue(StagePolicy.callBadgeHelp(w).contains("5K reports"))
        w.outputAtCallRate = true
        XCTAssertTrue(StagePolicy.callBadgeHelp(w).contains("call sample rate"))
        w.headsetMicRunning = true
        XCTAssertTrue(StagePolicy.callBadgeHelp(w).contains("microphone"))
    }
}
