import XCTest
@testable import QudelixBar

final class LoudnessTests: XCTestCase {
    private let publishedShelf = BiquadSection(b0: 1.53512485958697,
                                               b1: -2.69169618940638,
                                               b2: 1.19839281085285,
                                               a1: -1.69065929318241,
                                               a2: 0.73248077421585)
    private let publishedHighpass = BiquadSection(b0: 1, b1: -2, b2: 1,
                                                  a1: -1.99004745483398,
                                                  a2: 0.99007225036621)

    func testTheDesignReproducesThePublishedCoefficientsAt48k() {
        let shelf = KWeighting.shelf(sampleRate: 48000)
        XCTAssertEqual(shelf.b0, publishedShelf.b0, accuracy: 1e-12)
        XCTAssertEqual(shelf.b1, publishedShelf.b1, accuracy: 1e-12)
        XCTAssertEqual(shelf.b2, publishedShelf.b2, accuracy: 1e-12)
        XCTAssertEqual(shelf.a1, publishedShelf.a1, accuracy: 1e-12)
        XCTAssertEqual(shelf.a2, publishedShelf.a2, accuracy: 1e-12)

        let highpass = KWeighting.highpass(sampleRate: 48000)
        XCTAssertEqual(highpass.b0, publishedHighpass.b0, accuracy: 1e-12)
        XCTAssertEqual(highpass.b1, publishedHighpass.b1, accuracy: 1e-12)
        XCTAssertEqual(highpass.b2, publishedHighpass.b2, accuracy: 1e-12)
        XCTAssertEqual(highpass.a1, publishedHighpass.a1, accuracy: 1e-8)
        XCTAssertEqual(highpass.a2, publishedHighpass.a2, accuracy: 1e-8)
    }

    func testAThousandHertzPassesAtTheGainTheOffsetCancels() {
        XCTAssertEqual(gainDb(at: 1000, sampleRate: 48000),
                       -ShortTermLoudness.offsetDb, accuracy: 0.01)
    }

    func testTheShouldersMatchThePublishedFilter() {
        for hz in [100.0, 1000, 10000] {
            XCTAssertEqual(gainDb(at: hz, sampleRate: 48000),
                           publishedGainDb(at: hz), accuracy: 0.001,
                           "\(hz) Hz")
        }
    }

    func testTheResponseHoldsAcrossSampleRates() {
        for rate in [44100.0, 88200, 96000, 192000] {
            for hz in [100.0, 1000, 10000] {
                XCTAssertEqual(gainDb(at: hz, sampleRate: rate),
                               publishedGainDb(at: hz), accuracy: 0.05,
                               "\(hz) Hz at \(rate)")
            }
        }
    }

    func testAnImpossibleRateStillDesignsAFiniteFilter() {
        for rate in [Double.infinity, .nan, 0, -48000, 1e12] {
            let shelf = KWeighting.shelf(sampleRate: rate)
            let highpass = KWeighting.highpass(sampleRate: rate)
            XCTAssertTrue([shelf.b0, shelf.b1, shelf.b2, shelf.a1, shelf.a2,
                           highpass.a1, highpass.a2].allSatisfy(\.isFinite),
                          "rate \(rate)")
        }
    }

    func testAMinus23dBFSSineReadsMinus23LUFS() {
        let rate = 48000.0
        let amplitude = (2.0).squareRoot() * pow(10, -23.0 / 20)
        let shelf = KWeighting.shelf(sampleRate: rate)
        let highpass = KWeighting.highpass(sampleRate: rate)
        var z1 = 0.0, z2 = 0.0, z3 = 0.0, z4 = 0.0
        var sum = 0.0
        let frames = Int(rate)
        for i in 0..<frames {
            let x = amplitude * sin(2 * .pi * 1000 * Double(i) / rate)
            let y1 = shelf.b0 * x + z1
            z1 = shelf.b1 * x - shelf.a1 * y1 + z2
            z2 = shelf.b2 * x - shelf.a2 * y1
            let y2 = highpass.b0 * y1 + z3
            z3 = highpass.b1 * y1 - highpass.a1 * y2 + z4
            z4 = highpass.b2 * y1 - highpass.a2 * y2
            sum += y2 * y2
        }
        var window = ShortTermLoudness()
        window.add(sumSquares: sum, frames: frames)
        XCTAssertEqual(window.lufs ?? .nan, -23, accuracy: 0.05)
    }

    func testTheWindowIsMeanPowerNotAMeanOfMeans() {
        var window = ShortTermLoudness()
        window.add(sumSquares: 1, frames: 100)
        window.add(sumSquares: 9, frames: 900)
        XCTAssertEqual(window.lufs ?? .nan,
                       ShortTermLoudness.offsetDb + 10 * log10(0.01), accuracy: 1e-9)
    }

    func testTheWindowKeepsOnlyThreeSeconds() {
        var window = ShortTermLoudness()
        window.add(sumSquares: 100, frames: 1)
        for _ in 0..<ShortTermLoudness.windowSeconds {
            window.add(sumSquares: 1, frames: 1)
        }
        XCTAssertEqual(window.lufs ?? .nan,
                       ShortTermLoudness.offsetDb, accuracy: 1e-9)
    }

    func testAnEmptyDrainIsDroppedRatherThanCountedAsSilence() {
        var window = ShortTermLoudness()
        window.add(sumSquares: 1, frames: 1)
        window.add(sumSquares: 0, frames: 0)
        window.add(sumSquares: -1, frames: 10)
        window.add(sumSquares: .nan, frames: 10)
        XCTAssertEqual(window.lufs ?? .nan,
                       ShortTermLoudness.offsetDb, accuracy: 1e-9)
    }

    func testNothingMeasuredYetIsNilRatherThanZero() {
        var window = ShortTermLoudness()
        XCTAssertNil(window.lufs)
        window.add(sumSquares: 1, frames: 1)
        window.reset()
        XCTAssertNil(window.lufs)
    }

    func testTheAverageStartsAtTheFirstReadingAndConvergesOnTheLast() {
        var average = AveragedLoudness()
        XCTAssertNil(average.lufs)
        average.add(-30)
        XCTAssertEqual(average.lufs ?? .nan, -30, accuracy: 1e-12)
        for _ in 0..<300 { average.add(-20) }
        XCTAssertEqual(average.lufs ?? .nan, -20, accuracy: 0.01)
    }

    func testTheAverageMovesAtTheRateItsNameClaims() {
        var average = AveragedLoudness()
        average.add(-40)
        for _ in 0..<Int(AveragedLoudness.seconds) { average.add(-20) }
        XCTAssertEqual(average.lufs ?? .nan, -40 + 20 * 0.632, accuracy: 0.2)
    }

    func testNonFiniteReadingsNeverEnterTheAverage() {
        var average = AveragedLoudness()
        average.add(-30)
        average.add(.nan)
        average.add(-.infinity)
        XCTAssertEqual(average.lufs ?? .nan, -30, accuracy: 1e-12)
    }

    func testTheEstimateIsLoudnessPlusVolumePlusCalibration() {
        let estimate = EarLevel.estimate(shortTermLUFS: -18, volumeDb: -12,
                                         calibrationDb: 100)
        XCTAssertEqual(estimate, .estimated(70))
    }

    func testTheEstimateIsRoundedWhereItIsMade() {
        XCTAssertEqual(EarLevel.estimate(shortTermLUFS: -18.4, volumeDb: -12.2,
                                         calibrationDb: 100),
                       .estimated(69))
    }

    func testNoVolumeReadingMeansNoEstimateAtAll() {
        XCTAssertEqual(EarLevel.estimate(shortTermLUFS: -18, volumeDb: nil,
                                         calibrationDb: 100), .unavailable)
    }

    func testAnImplausibleVolumeIsRefusedRatherThanAddedUp() {
        for volume in [-1e10, 1e10, Double.infinity, .nan, -200, 60] {
            XCTAssertEqual(EarLevel.estimate(shortTermLUFS: -18, volumeDb: volume,
                                             calibrationDb: 100),
                           .unavailable, "\(volume)")
        }
    }

    func testNothingMeasuredYetIsUnavailableNotSilence() {
        XCTAssertEqual(EarLevel.estimate(shortTermLUFS: nil, volumeDb: -12,
                                         calibrationDb: 100), .unavailable)
    }

    func testBelowTheQuietFloorTheAnswerIsThatItIsTooQuiet() {
        XCTAssertEqual(EarLevel.estimate(shortTermLUFS: EarLevel.quietFloorLUFS - 0.1,
                                         volumeDb: 0, calibrationDb: 100), .tooQuiet)
        XCTAssertEqual(EarLevel.estimate(shortTermLUFS: -.infinity, volumeDb: 0,
                                         calibrationDb: 100), .tooQuiet)
    }

    func testTheCalibrationIsClampedWhereverItCameFrom() {
        XCTAssertEqual(EarLevel.clampedCalibration(1000),
                       EarLevel.calibrationRange.upperBound)
        XCTAssertEqual(EarLevel.clampedCalibration(-1000),
                       EarLevel.calibrationRange.lowerBound)
        XCTAssertEqual(EarLevel.clampedCalibration(.nan),
                       EarLevel.defaultCalibrationDb)
        XCTAssertEqual(EarLevel.clampedCalibration(94), 94)
    }

    func testAHandEditedCalibrationCannotDragTheEstimateOffTheScale() {
        XCTAssertEqual(EarLevel.estimate(shortTermLUFS: -18, volumeDb: -12,
                                         calibrationDb: 1e6),
                       .estimated(-30 + EarLevel.calibrationRange.upperBound))
    }

    func testARealDecibelReadingIsBelieved() {
        XCTAssertEqual(AudioOutputs.trustedVolumeDb(db: -18.5, scalar: 0.2), -18.5)
    }

    func testAConstantZeroDecibelsLosesToAScalarThatSaysOtherwise() {
        let fallback = AudioOutputs.trustedVolumeDb(db: 0, scalar: 0.4375)
        XCTAssertEqual(Double(fallback ?? .nan),
                       20 * log10(0.4375), accuracy: 1e-4)
    }

    func testZeroDecibelsIsBelievedWhenTheSliderIsReallyAtTheTop() {
        XCTAssertEqual(AudioOutputs.trustedVolumeDb(db: 0, scalar: 1), 0)
        XCTAssertEqual(AudioOutputs.trustedVolumeDb(
            db: 0, scalar: AudioOutputs.fullVolumeScalar), 0)
    }

    func testZeroDecibelsWithNoScalarToCheckIsBelieved() {
        XCTAssertEqual(AudioOutputs.trustedVolumeDb(db: 0, scalar: nil), 0)
        XCTAssertEqual(AudioOutputs.trustedVolumeDb(db: 0, scalar: .nan), 0)
    }

    func testAMutedScalarLeavesAsTheFloorNotAsMinusInfinity() {
        XCTAssertEqual(Double(AudioOutputs.trustedVolumeDb(db: 0, scalar: 0) ?? .nan),
                       EarLevel.plausibleVolumeDb.lowerBound, accuracy: 1e-6)
    }

    func testGarbageDecibelsAreNotAVolumeReadingAtAll() {
        XCTAssertNil(AudioOutputs.trustedVolumeDb(db: 1e10, scalar: 0.5))
        XCTAssertNil(AudioOutputs.trustedVolumeDb(db: .nan, scalar: 0.5))
        XCTAssertNil(AudioOutputs.trustedVolumeDb(db: nil, scalar: 0.5))
        XCTAssertNil(AudioOutputs.trustedVolumeDb(db: -400, scalar: 0.5))
    }

    private func gainDb(at hz: Double, sampleRate: Double) -> Double {
        KWeighting.responseDb(shelf: KWeighting.shelf(sampleRate: sampleRate),
                              highpass: KWeighting.highpass(sampleRate: sampleRate),
                              hz: hz, sampleRate: sampleRate)
    }

    private func publishedGainDb(at hz: Double) -> Double {
        KWeighting.responseDb(shelf: publishedShelf, highpass: publishedHighpass,
                              hz: hz, sampleRate: 48000)
    }
}
