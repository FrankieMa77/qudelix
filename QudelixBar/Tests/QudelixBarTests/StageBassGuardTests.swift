import CoreAudio
import XCTest
@testable import QudelixBar

final class StageBassGuardTests: XCTestCase {
    func testAFlatCurveOffersNothingToGuard() {
        XCTAssertEqual(StageState.bassGuardBoostDb(bands: Self.flatBands,
                                                   loudnessShelfDb: 0), 0)
        XCTAssertEqual(StageState.bassGuardCeilingDb(worstBoostDb: 0, strength: 1), 0)
    }

    func testACutIsNotABoost() {
        XCTAssertEqual(StageState.bassGuardBoostDb(
            bands: [Self.band(.peak, 60, -6)], loudnessShelfDb: 0), 0)
    }

    func testTrebleIsOutsideTheScannedDecade() {
        let worst = StageState.bassGuardBoostDb(
            bands: [Self.band(.peak, 8000, 10)], loudnessShelfDb: 0)
        XCTAssertLessThan(worst, StageState.bassGuardInertDb)
        XCTAssertEqual(StageState.bassGuardCeilingDb(worstBoostDb: worst,
                                                     strength: 1), 0)
    }

    func testALowShelfIsMeasuredWhereItActuallyPeaks() {
        let worst = StageState.bassGuardBoostDb(
            bands: [Self.band(.lowShelf, 100, 6)], loudnessShelfDb: 0)
        XCTAssertEqual(worst, 6.44, accuracy: 0.1)
        XCTAssertEqual(StageState.bassGuardCeilingDb(worstBoostDb: worst,
                                                     strength: 1),
                       worst, accuracy: 1e-9)
    }

    func testABellIsMeasuredAtItsOwnCentre() {
        XCTAssertEqual(StageState.bassGuardBoostDb(
            bands: [Self.band(.peak, 50, 10)], loudnessShelfDb: 0),
                       10, accuracy: 0.05)
    }

    func testTheMacSideLoudnessShelfCountsTowardTheBoost() {
        XCTAssertEqual(StageState.bassGuardBoostDb(bands: Self.flatBands,
                                                   loudnessShelfDb: 6),
                       6.07, accuracy: 0.1)
        XCTAssertEqual(StageState.bassGuardBoostDb(
            bands: [Self.band(.peak, 50, 10)], loudnessShelfDb: 6),
                       16.04, accuracy: 0.1)
    }

    func testThePreGainIsNotSubtractedFromWhatThereIsToGuard() {
        let bands = [Self.band(.peak, 50, 10)]
        let withPreGain = StageState.bassGuardBoostDb(bands: bands,
                                                      loudnessShelfDb: 0)
        XCTAssertEqual(withPreGain, 10, accuracy: 0.05)
        XCTAssertEqual(EQCurve.response(bands: bands, preGain: -10, at: [50])[0],
                       0, accuracy: 0.05)
    }

    func testAnEnormousBoostStillStopsAtTheCap() {
        let worst = StageState.bassGuardBoostDb(
            bands: [Self.band(.peak, 50, 20)], loudnessShelfDb: 0)
        XCTAssertEqual(worst, 20, accuracy: 0.05)
        XCTAssertEqual(StageState.bassGuardCeilingDb(worstBoostDb: worst,
                                                     strength: 1),
                       StageProcessor.bassGuardMaxCeilingDb)
    }

    func testHalfADecibelIsNotWorthGuarding() {
        XCTAssertEqual(StageState.bassGuardCeilingDb(worstBoostDb: 0.4,
                                                     strength: 1), 0)
        XCTAssertEqual(StageState.bassGuardCeilingDb(worstBoostDb: 0.6,
                                                     strength: 1), 0.6,
                       accuracy: 1e-9)
    }

    func testStrengthScalesTheCeiling() {
        XCTAssertEqual(StageState.bassGuardCeilingDb(worstBoostDb: 10,
                                                     strength: 0.5), 5,
                       accuracy: 1e-9)
        XCTAssertEqual(StageState.bassGuardCeilingDb(worstBoostDb: 10,
                                                     strength: 0), 0)
        XCTAssertEqual(StageState.bassGuardCeilingDb(worstBoostDb: 10,
                                                     strength: 4), 10,
                       accuracy: 1e-9)
        XCTAssertEqual(StageState.bassGuardCeilingDb(worstBoostDb: 10,
                                                     strength: .nan), 0)
    }

    func testNonsenseNeverBecomesACeiling() {
        XCTAssertEqual(StageState.bassGuardCeilingDb(worstBoostDb: .nan,
                                                     strength: 1), 0)
        XCTAssertEqual(StageState.bassGuardCeilingDb(worstBoostDb: .infinity,
                                                     strength: 1), 0)
        XCTAssertEqual(StageState.bassGuardBoostDb(
            bands: [Self.band(.peak, 50, .nan)], loudnessShelfDb: 0), 0)
        XCTAssertEqual(StageState.bassGuardBoostDb(bands: Self.flatBands,
                                                   loudnessShelfDb: .nan), 0)
        XCTAssertEqual(StageState.bassGuardBoostDb(bands: Self.flatBands,
                                                   loudnessShelfDb: -20), 0)
    }

    func testABypassedBandBoostsNothing() {
        var muted = Self.band(.peak, 50, 12)
        muted.filter = .bypass
        XCTAssertEqual(StageState.bassGuardBoostDb(bands: [muted],
                                                   loudnessShelfDb: 0), 0)
    }
    func testTheGuardIsOffByDefaultAndSavesNothing() {
        let s = StageSettings()
        XCTAssertFalse(s.bassGuardValue)
        XCTAssertEqual(s.bassGuardStrengthValue, 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try! encoder.encode(s.clamped()), encoding: .utf8)
        XCTAssertFalse(json?.contains("bassGuard") ?? true, json ?? "")
    }

    func testAStageSavedBeforeTheGuardExistedStillDecodes() {
        let legacy = """
        {"enabled": true, "width": 130, "crossfeed": 0.3,
         "dialogue": 0, "room": 0}
        """
        guard let s = try? JSONDecoder().decode(StageSettings.self,
                                                from: Data(legacy.utf8)) else {
            return XCTFail("a pre-change document must still decode")
        }
        XCTAssertNil(s.bassGuard)
        XCTAssertNil(s.bassGuardStrength)
        var explicit = s
        explicit.bassGuard = false
        explicit.bassGuardStrength = 1
        XCTAssertTrue(s.audiblyEquals(explicit))
    }

    func testTheStrengthIsClampedWhereverItCameFrom() {
        var s = StageSettings()
        s.bassGuardStrength = 4
        XCTAssertEqual(s.clamped().bassGuardStrengthValue, 1)
        s.bassGuardStrength = -3
        XCTAssertEqual(s.clamped().bassGuardStrengthValue, 0)
        s.bassGuardStrength = .nan
        XCTAssertEqual(s.clamped().bassGuardStrengthValue, 1)
    }

    func testTurningTheGuardOnIsAnAudibleDifference() {
        var off = StageSettings()
        off.enabled = true
        var on = off
        on.bassGuard = true
        XCTAssertFalse(off.audiblyEquals(on))
        XCTAssertFalse(on.isAudiblyNeutral)
        var weaker = on
        weaker.bassGuardStrength = 0.4
        XCTAssertFalse(on.audiblyEquals(weaker))
    }

    func testTheSignalPathNamesTheGuardOnlyWhenItHasSomethingToDo() {
        var stage = StageSettings()
        stage.enabled = true
        stage.bassGuard = true
        let active = SignalPath.rows(.init(engineMode: .insert, stage: stage,
                                           bassGuardActive: true))
            .first { $0.id == "app" }
        XCTAssertEqual(active?.indicator, .altering)
        XCTAssertTrue(active?.state.contains("dynamic bass") ?? false,
                      active?.state ?? "")

        let inert = SignalPath.rows(.init(engineMode: .insert, stage: stage,
                                          bassGuardActive: false))
            .first { $0.id == "app" }
        XCTAssertFalse(inert?.state.contains("dynamic bass") ?? true,
                       inert?.state ?? "")

        stage.bassGuard = false
        let gone = SignalPath.rows(.init(engineMode: .insert, stage: stage,
                                         bassGuardActive: true))
            .first { $0.id == "app" }
        XCTAssertFalse(gone?.state.contains("dynamic bass") ?? true,
                       gone?.state ?? "")
    }
    func testTheGuardOffRendersExactlyTheSameSamples() {
        let samples = Self.stereoNoise(frames: 4096)
        let plain = render(flatStage(), input: samples)

        var off = flatStage()
        off.bassGuard = false
        XCTAssertEqual(render(off, input: samples, ceilingDb: 12, boostDb: 12)
                        .map(\.bitPattern),
                       plain.map(\.bitPattern))
    }

    func testAnInertGuardRendersExactlyTheSameSamples() {
        let samples = Self.stereoNoise(frames: 4096)
        let plain = render(flatStage(), input: samples)

        var on = flatStage()
        on.bassGuard = true
        let worst = StageState.bassGuardBoostDb(bands: Self.flatBands,
                                                loudnessShelfDb: 0)
        let ceiling = StageState.bassGuardCeilingDb(worstBoostDb: worst,
                                                    strength: 1)
        XCTAssertEqual(ceiling, 0)
        XCTAssertEqual(render(on, input: samples, ceilingDb: ceiling,
                              boostDb: worst).map(\.bitPattern),
                       plain.map(\.bitPattern))
    }

    func testALoudBassNoteIsEasedByUpToTheCeiling() {
        let frames = 48000
        let samples = Self.tone(hz: 60, frames: frames, amplitude: 0.1)
        var on = flatStage()
        on.bassGuard = true

        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyStage(on)
        p.applyBassGuard(ceilingDb: 12, predictedBoostDb: 20)
        let guarded = renderOnce(p, samples)
        let deepest = Double(p.drainBassGuardReduction())

        let plain = render(flatStage(), input: samples)
        let from = frames / 2
        let reduction = 20 * log10(Self.rms(plain, channel: 0, from: from)
                                   / Self.rms(guarded, channel: 0, from: from))

        XCTAssertGreaterThan(deepest, 5)
        XCTAssertLessThanOrEqual(deepest, 12)
        XCTAssertGreaterThan(reduction, 2)
        XCTAssertLessThan(reduction, deepest)
    }

    func testTheReductionStopsAtTheCeilingHoweverLoudItGets() {
        let frames = 24000
        let samples = Self.tone(hz: 60, frames: frames, amplitude: 0.5)
        for ceiling in [4.0, 12.0] {
            var on = flatStage()
            on.bassGuard = true
            let p = StageProcessor()
            p.prepare(sampleRate: 48000)
            p.applyStage(on)
            p.applyBassGuard(ceilingDb: ceiling, predictedBoostDb: 20)
            _ = renderOnce(p, samples)
            XCTAssertEqual(Double(p.drainBassGuardReduction()), ceiling,
                           accuracy: 0.01, "ceiling \(ceiling)")
        }
    }

    func testStrengthScalesWhatTheGuardActuallyTakesBack() {
        let frames = 24000
        let samples = Self.tone(hz: 40, frames: frames, amplitude: 0.7)
        let worst = StageState.bassGuardBoostDb(
            bands: [Self.band(.peak, 50, 10)], loudnessShelfDb: 0)

        func deepest(strength: Double) -> Double {
            var on = flatStage()
            on.bassGuard = true
            on.bassGuardStrength = strength
            let p = StageProcessor()
            p.prepare(sampleRate: 48000)
            p.applyStage(on)
            p.applyBassGuard(
                ceilingDb: StageState.bassGuardCeilingDb(worstBoostDb: worst,
                                                         strength: strength),
                predictedBoostDb: worst)
            _ = renderOnce(p, samples)
            return Double(p.drainBassGuardReduction())
        }

        let full = deepest(strength: 1)
        XCTAssertEqual(full, 10, accuracy: 0.05)
        XCTAssertEqual(deepest(strength: 0.5), 5, accuracy: 0.05)
        XCTAssertEqual(deepest(strength: 0), 0)
    }

    func testAQuietBassNoteIsLeftExactlyAlone() {
        let frames = 24000
        let samples = Self.tone(hz: 60, frames: frames, amplitude: 0.002)
        var on = flatStage()
        on.bassGuard = true
        let guarded = render(on, input: samples, ceilingDb: 10, boostDb: 10)
        let plain = render(flatStage(), input: samples)
        XCTAssertEqual(guarded.map(\.bitPattern), plain.map(\.bitPattern))
    }

    func testOnlyTheLowBandIsEased() {
        let frames = 48000
        let bass = Self.tone(hz: 40, frames: frames, amplitude: 0.2)
        var mixed = bass
        for i in 0..<frames {
            let treble = Float(0.2 * sin(2 * .pi * 4000 * Double(i) / 48000))
            mixed[i * 2] += treble
            mixed[i * 2 + 1] += treble
        }
        var on = flatStage()
        on.bassGuard = true
        let guarded = render(on, input: mixed, ceilingDb: 12, boostDb: 20)
        let plain = render(flatStage(), input: mixed)
        let from = frames / 2
        XCTAssertLessThan(Self.bandRms(guarded, hz: 40, from: from),
                          Self.bandRms(plain, hz: 40, from: from) * 0.8)
        XCTAssertEqual(Self.bandRms(guarded, hz: 4000, from: from),
                       Self.bandRms(plain, hz: 4000, from: from),
                       accuracy: Self.bandRms(plain, hz: 4000, from: from) * 0.02)
    }

    func testTheGuardLeansInOverMillisecondsRatherThanInstantly() {
        let rate = 48000.0
        let frames = 9600
        let samples = Self.tone(hz: 40, frames: frames, amplitude: 0.2)
        var on = flatStage()
        on.bassGuard = true
        let guarded = render(on, input: samples, ceilingDb: 12, boostDb: 20)
        let plain = render(flatStage(), input: samples)

        func ratio(msFrom: Double, msTo: Double) -> Double {
            let from = Int(msFrom / 1000 * rate), to = Int(msTo / 1000 * rate)
            return Self.rms(guarded, channel: 0, from: from, to: to)
                / Self.rms(plain, channel: 0, from: from, to: to)
        }

        let opening = ratio(msFrom: 0, msTo: 5)
        let settled = ratio(msFrom: 100, msTo: 200)
        XCTAssertGreaterThan(opening, 0.9, "the first milliseconds were clamped")
        XCTAssertLessThan(settled, 0.75, "the guard never leaned in")
        XCTAssertEqual(ratio(msFrom: 40, msTo: 60), settled,
                       accuracy: settled * 0.1, "the attack was far too slow")
    }

    func testTheGuardLetsGoOverATenthOfASecondRatherThanAtOnce() {
        let rate = 48000.0
        let loudFrames = 12000
        let quietFrames = 72000
        var samples = [Float]()
        samples.append(contentsOf: Self.tone(hz: 40, frames: loudFrames,
                                             amplitude: 0.3))
        samples.append(contentsOf: Self.tone(hz: 40, frames: quietFrames,
                                             amplitude: 0.01, phase: Double(loudFrames)))
        var on = flatStage()
        on.bassGuard = true
        let guarded = render(on, input: samples, ceilingDb: 12, boostDb: 20)
        let plain = render(flatStage(), input: samples)

        func ratio(msAfterBurst from: Double, to: Double) -> Double {
            let base = Double(loudFrames)
            let f = Int(base + from / 1000 * rate)
            let t = Int(base + to / 1000 * rate)
            return Self.rms(guarded, channel: 0, from: f, to: t)
                / Self.rms(plain, channel: 0, from: f, to: t)
        }

        XCTAssertLessThan(ratio(msAfterBurst: 10, to: 60), 0.8,
                          "the guard let go the instant the level dropped")
        XCTAssertGreaterThan(ratio(msAfterBurst: 1200, to: 1400), 0.99,
                             "the guard never gave the bass back")
    }

    func testMonoContentIsGuardedIdenticallyOnBothEars() {
        let frames = 24000
        let samples = Self.tone(hz: 50, frames: frames, amplitude: 0.2)
        var on = flatStage()
        on.bassGuard = true
        let out = render(on, input: samples, ceilingDb: 12, boostDb: 20)
        for frame in stride(from: 0, to: frames, by: 89) {
            XCTAssertEqual(out[frame * 2], out[frame * 2 + 1], accuracy: 1e-7)
        }
        XCTAssertTrue(out.allSatisfy(\.isFinite))
    }

    func testASingleChannelTapIsLeftAloneRatherThanCrashing() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        var on = flatStage()
        on.bassGuard = true
        p.applyStage(on)
        p.applyBassGuard(ceilingDb: 12, predictedBoostDb: 20)
        let input = Buffers([(1, 256)])
        input.fill(0, (0..<256).map { Float(sin(Double($0) * 0.008)) * 0.4 })
        let output = Buffers([(1, 256)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        XCTAssertTrue(output.samples(0, count: 256).allSatisfy(\.isFinite))
        XCTAssertFalse(p.renderDiagnostics().stageRan)
        XCTAssertEqual(p.drainBassGuardReduction(), 0)
    }

    func testTheGuardNeverTouchesTheAudioInMonitorMode() {
        let frames = 4096
        let samples = Self.tone(hz: 50, frames: frames, amplitude: 0.4)
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.setMonitorOnly(true)
        var on = flatStage()
        on.bassGuard = true
        p.applyStage(on)
        p.applyBassGuard(ceilingDb: 12, predictedBoostDb: 20)

        let input = Buffers([(2, frames)])
        input.fill(0, samples)
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        XCTAssertEqual(input.samples(0, count: frames * 2).map(\.bitPattern),
                       samples.map(\.bitPattern))
        XCTAssertEqual(p.drainBassGuardReduction(), 0)
    }

    func testAnEpochWipeStartsTheGuardFromRestAgain() {
        let rate = 48000.0
        let frames = 24000
        let p = StageProcessor()
        p.prepare(sampleRate: rate)
        var on = flatStage()
        on.bassGuard = true
        p.applyStage(on)
        p.applyBassGuard(ceilingDb: 12, predictedBoostDb: 20)

        _ = renderOnce(p, Self.tone(hz: 40, frames: frames, amplitude: 0.4))
        XCTAssertGreaterThan(p.drainBassGuardReduction(), 6)

        p.prepare(sampleRate: rate)
        let quiet = Self.tone(hz: 40, frames: frames, amplitude: 0.002)
        let after = renderOnce(p, quiet)
        XCTAssertEqual(p.drainBassGuardReduction(), 0)
        XCTAssertEqual(after.map(\.bitPattern),
                       render(flatStage(), input: quiet).map(\.bitPattern))
    }

    func testTurningTheGuardOnMidStreamStartsFromRest() {
        let frames = 12000
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        var on = flatStage()
        on.bassGuard = true
        p.applyStage(on)
        p.applyBassGuard(ceilingDb: 12, predictedBoostDb: 20)
        _ = renderOnce(p, Self.tone(hz: 40, frames: frames, amplitude: 0.4))
        _ = p.drainBassGuardReduction()

        var off = flatStage()
        off.bassGuard = false
        p.applyStage(off)
        _ = renderOnce(p, Self.tone(hz: 40, frames: frames, amplitude: 0.4))
        XCTAssertEqual(p.drainBassGuardReduction(), 0)

        p.applyStage(on)
        let quiet = Self.tone(hz: 40, frames: frames, amplitude: 0.002)
        let out = renderOnce(p, quiet)
        XCTAssertEqual(p.drainBassGuardReduction(), 0,
                       "the guard resumed from the loud passage it slept through")
        XCTAssertTrue(out.allSatisfy(\.isFinite))
    }

    func testNonFiniteSamplesNeverLodgeInTheGuard() {
        let frames = 2048
        var samples = Self.tone(hz: 50, frames: frames, amplitude: 0.3)
        samples[8] = .nan
        samples[9] = .infinity
        var on = flatStage()
        on.bassGuard = true
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyStage(on)
        p.applyBassGuard(ceilingDb: 12, predictedBoostDb: 20)
        XCTAssertTrue(renderOnce(p, samples).allSatisfy(\.isFinite))
        let clean = renderOnce(p, Self.tone(hz: 50, frames: frames,
                                            amplitude: 0.3))
        XCTAssertTrue(clean.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(Self.rms(clean, channel: 0), 0.05)
    }

    func testTheGuardSurvivesRatesNoDeviceCouldRunAt() {
        for rate in [Double.infinity, .nan, 0, -48000, 1e30] {
            let p = StageProcessor()
            p.prepare(sampleRate: rate)
            var on = flatStage()
            on.bassGuard = true
            p.applyStage(on)
            p.applyBassGuard(ceilingDb: 12, predictedBoostDb: 20)
            let input = Buffers([(2, 128)])
            input.fill(0, (0..<256).map { Float(sin(Double($0) * 0.01)) * 0.4 })
            let output = Buffers([(2, 128)])
            p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
            XCTAssertTrue(output.samples(0, count: 256).allSatisfy(\.isFinite),
                          "rate \(rate)")
        }
    }

    func testAMoveTooSmallToHearIsNotRedesigned() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        var on = flatStage()
        on.bassGuard = true
        p.applyStage(on)
        p.applyBassGuard(ceilingDb: 6, predictedBoostDb: 6)
        XCTAssertEqual(p.appliedBassGuardCeilingDb, 6, accuracy: 1e-9)
        p.applyBassGuard(ceilingDb: 6.05, predictedBoostDb: 6.05)
        XCTAssertEqual(p.appliedBassGuardCeilingDb, 6, accuracy: 1e-9)
        p.applyBassGuard(ceilingDb: 6.2, predictedBoostDb: 6.2)
        XCTAssertEqual(p.appliedBassGuardCeilingDb, 6.2, accuracy: 1e-9)
    }

    func testTheAppliedCeilingIsZeroWhileTheStageOrTheSwitchIsOff() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyBassGuard(ceilingDb: 9, predictedBoostDb: 9)

        var off = flatStage()
        off.bassGuard = false
        p.applyStage(off)
        XCTAssertEqual(p.appliedBassGuardCeilingDb, 0)

        var on = off
        on.bassGuard = true
        p.applyStage(on)
        XCTAssertEqual(p.appliedBassGuardCeilingDb, 9, accuracy: 1e-9)

        var idle = on
        idle.enabled = false
        p.applyStage(idle)
        XCTAssertEqual(p.appliedBassGuardCeilingDb, 0)
    }

    func testAHandEditedCeilingCannotClimbPastTheCap() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        var on = flatStage()
        on.bassGuard = true
        p.applyStage(on)
        p.applyBassGuard(ceilingDb: 400, predictedBoostDb: 400)
        XCTAssertEqual(p.appliedBassGuardCeilingDb,
                       StageProcessor.bassGuardMaxCeilingDb)
        p.applyBassGuard(ceilingDb: .nan, predictedBoostDb: .nan)
        XCTAssertEqual(p.appliedBassGuardCeilingDb, 0)
        p.applyBassGuard(ceilingDb: -30, predictedBoostDb: -30)
        XCTAssertEqual(p.appliedBassGuardCeilingDb, 0)
    }
    private static let flatBands = (0..<10).map { _ in
        band(.peak, 1000, 0)
    }

    private static func band(_ filter: QxFilter, _ hz: Int, _ gain: Double,
                             _ q: Double = 1) -> QxEqBandValue {
        QxEqBandValue(filter: filter, freq: hz, gain: gain, q: q)
    }

    private func flatStage() -> StageSettings {
        var s = StageSettings()
        s.enabled = true
        s.width = 100
        s.crossfeed = 0
        s.dialogue = 0
        s.room = 0
        s.distance = 0
        s.span = 0.5
        s.center = 0
        s.size = 0.5
        s.night = 0
        return s
    }

    private func render(_ settings: StageSettings, input samples: [Float],
                        ceilingDb: Double = 0, boostDb: Double = 0,
                        sampleRate: Double = 48000) -> [Float] {
        let p = StageProcessor()
        p.prepare(sampleRate: sampleRate)
        p.applyStage(settings)
        if ceilingDb > 0 || boostDb > 0 {
            p.applyBassGuard(ceilingDb: ceilingDb, predictedBoostDb: boostDb)
        }
        return renderOnce(p, samples)
    }

    private func renderOnce(_ p: StageProcessor, _ samples: [Float]) -> [Float] {
        let frames = samples.count / 2
        let input = Buffers([(2, frames)])
        input.fill(0, samples)
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        return output.samples(0, count: frames * 2)
    }

    private static func tone(hz: Double, frames: Int, amplitude: Double,
                             phase: Double = 0) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Float(amplitude * sin(2 * .pi * hz * (Double(i) + phase) / 48000))
            out[i * 2] = v
            out[i * 2 + 1] = v
        }
        return out
    }

    private static func stereoNoise(frames: Int) -> [Float] {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: state)) / Float(Int64.max) * 0.1
            let tone = Float(sin(Double(i) * 0.007)) * 0.3
            out[i * 2] = tone + noise
            out[i * 2 + 1] = tone * 0.9 - noise
        }
        return out
    }

    private static func rms(_ interleaved: [Float], channel: Int,
                            from: Int = 0, to: Int = .max) -> Double {
        var sum = 0.0
        var n = 0
        var frame = from
        let last = min(to, interleaved.count / 2)
        while frame < last {
            let v = Double(interleaved[frame * 2 + channel])
            sum += v * v
            n += 1
            frame += 1
        }
        return n > 0 ? (sum / Double(n)).squareRoot() : 0
    }

    private static func bandRms(_ interleaved: [Float], hz: Double,
                                from: Int, sampleRate: Double = 48000) -> Double {
        var re = 0.0, im = 0.0
        var n = 0
        var frame = from
        let last = interleaved.count / 2
        while frame < last {
            let v = Double(interleaved[frame * 2])
            let w = 2 * Double.pi * hz * Double(frame) / sampleRate
            re += v * cos(w)
            im += v * sin(w)
            n += 1
            frame += 1
        }
        guard n > 0 else { return 0 }
        return (re * re + im * im).squareRoot() / Double(n) * 2
    }

    private final class Buffers {
        let list: UnsafeMutableAudioBufferListPointer
        private var blocks: [UnsafeMutablePointer<Float>] = []

        init(_ shapes: [(channels: Int, frames: Int)]) {
            list = AudioBufferList.allocate(maximumBuffers: shapes.count)
            for (i, shape) in shapes.enumerated() {
                let count = shape.channels * shape.frames
                let block = UnsafeMutablePointer<Float>.allocate(capacity: count)
                block.initialize(repeating: 0, count: count)
                blocks.append(block)
                list[i] = AudioBuffer(
                    mNumberChannels: UInt32(shape.channels),
                    mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(block))
            }
        }

        deinit {
            for block in blocks { block.deallocate() }
            free(list.unsafeMutablePointer)
        }

        var constPointer: UnsafePointer<AudioBufferList> {
            UnsafePointer(list.unsafeMutablePointer)
        }

        func fill(_ buffer: Int, _ samples: [Float]) {
            for (i, v) in samples.enumerated() { blocks[buffer][i] = v }
        }

        func samples(_ buffer: Int, count: Int) -> [Float] {
            Array(UnsafeBufferPointer(start: blocks[buffer], count: count))
        }
    }
}
