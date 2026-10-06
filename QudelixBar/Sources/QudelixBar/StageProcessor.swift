import CoreAudio
import Foundation
import os.lock

struct BiquadSection {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    static let passthrough = BiquadSection(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    static func peak(freq: Double, gainDb: Double, q: Double,
                     sampleRate: Double) -> BiquadSection {
        let f0 = max(10, min(freq, sampleRate / 2 - 1))
        let Q = max(0.05, q)
        let G = pow(10, gainDb / 20)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let qp = 1 / (2 * Q * sqrt(G))

        let expqw = exp(-qp * w0)
        let a1: Double
        if qp <= 1 {
            a1 = -2 * expqw * cos(sqrt(1 - qp * qp) * w0)
        } else {
            a1 = -2 * expqw * cosh(sqrt(qp * qp - 1) * w0)
        }
        let a2 = exp(-2 * qp * w0)

        let sinHalf = sin(w0 / 2)
        let phi1 = sinHalf * sinHalf
        let phi0 = 1 - phi1
        let phi2 = 4 * phi0 * phi1
        let A0 = (1 + a1 + a2) * (1 + a1 + a2)
        let A1 = (1 - a1 + a2) * (1 - a1 + a2)
        let A2 = -4 * a2

        let G2 = G * G
        let B0 = A0
        let R1 = (A0 * phi0 + A1 * phi1 + A2 * phi2) * G2
        let R2 = (-A0 + A1 + 4 * (phi0 - phi1) * A2) * G2
        let B2 = (R1 - R2 * phi1 - B0) / (4 * phi1 * phi1)
        let B1 = R2 + B0 + 4 * (phi1 - phi0) * B2

        let sqB0 = 1 + a1 + a2
        let sqB1 = sqrt(max(0, B1))
        let W = 0.5 * (sqB0 + sqB1)
        let b0 = 0.5 * (W + sqrt(max(0, W * W + B2)))
        let b1 = 0.5 * (sqB0 - sqB1)
        let b2 = -B2 / (4 * b0)
        return BiquadSection(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2)
    }

    static func highShelf(freq: Double, gainDb: Double, q: Double,
                          sampleRate: Double) -> BiquadSection {
        let f0 = max(10, min(freq, sampleRate / 2 - 1))
        let Q = max(0.05, q)
        let a = pow(10, gainDb / 40)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cosW0 = cos(w0), sinW0 = sin(w0)
        let alpha = sinW0 / (2 * Q)
        let sq = 2 * sqrt(a) * alpha
        let b0 = a * ((a + 1) + (a - 1) * cosW0 + sq)
        let b1 = -2 * a * ((a - 1) + (a + 1) * cosW0)
        let b2 = a * ((a + 1) + (a - 1) * cosW0 - sq)
        let a0 = (a + 1) - (a - 1) * cosW0 + sq
        let a1 = 2 * ((a - 1) - (a + 1) * cosW0)
        let a2 = (a + 1) - (a - 1) * cosW0 - sq
        return BiquadSection(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0,
                             a1: a1 / a0, a2: a2 / a0)
    }

    static func lowShelf(freq: Double, gainDb: Double, q: Double,
                         sampleRate: Double) -> BiquadSection {
        let f0 = max(10, min(freq, sampleRate / 2 - 1))
        let Q = max(0.05, q)
        let a = pow(10, gainDb / 40)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cosW0 = cos(w0), sinW0 = sin(w0)
        let alpha = sinW0 / (2 * Q)
        let sq = 2 * sqrt(a) * alpha
        let b0 = a * ((a + 1) - (a - 1) * cosW0 + sq)
        let b1 = 2 * a * ((a - 1) - (a + 1) * cosW0)
        let b2 = a * ((a + 1) - (a - 1) * cosW0 - sq)
        let a0 = (a + 1) + (a - 1) * cosW0 + sq
        let a1 = -2 * ((a - 1) + (a + 1) * cosW0)
        let a2 = (a + 1) + (a - 1) * cosW0 - sq
        return BiquadSection(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0,
                             a1: a1 / a0, a2: a2 / a0)
    }

    static func lowPass(freq: Double, q: Double,
                        sampleRate: Double) -> BiquadSection {
        let (cosW0, alpha) = passShape(freq: freq, q: q, sampleRate: sampleRate)
        let b0 = (1 - cosW0) / 2, b1 = 1 - cosW0, b2 = (1 - cosW0) / 2
        let a0 = 1 + alpha, a1 = -2 * cosW0, a2 = 1 - alpha
        return BiquadSection(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0,
                             a1: a1 / a0, a2: a2 / a0)
    }

    static func highPass(freq: Double, q: Double,
                         sampleRate: Double) -> BiquadSection {
        let (cosW0, alpha) = passShape(freq: freq, q: q, sampleRate: sampleRate)
        let b0 = (1 + cosW0) / 2, b1 = -(1 + cosW0), b2 = (1 + cosW0) / 2
        let a0 = 1 + alpha, a1 = -2 * cosW0, a2 = 1 - alpha
        return BiquadSection(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0,
                             a1: a1 / a0, a2: a2 / a0)
    }

    func magnitudeDb(at hz: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * hz / sampleRate
        let cos1 = cos(w), cos2 = cos(2 * w)
        let sin1 = sin(w), sin2 = sin(2 * w)
        let numRe = b0 + b1 * cos1 + b2 * cos2
        let numIm = -(b1 * sin1 + b2 * sin2)
        let denRe = 1 + a1 * cos1 + a2 * cos2
        let denIm = -(a1 * sin1 + a2 * sin2)
        let den = denRe * denRe + denIm * denIm
        guard den > 0 else { return 0 }
        let power = (numRe * numRe + numIm * numIm) / den
        return power > 0 ? 10 * log10(power) : -200
    }

    private static func passShape(freq: Double, q: Double,
                                  sampleRate: Double) -> (cosW0: Double, alpha: Double) {
        let f0 = max(10, min(freq, sampleRate / 2 - 1))
        let Q = max(0.05, q)
        let w0 = 2 * Double.pi * f0 / sampleRate
        return (cos(w0), sin(w0) / (2 * Q))
    }
}

struct KneeShaper {
    let threshold: Double
    let span: Double
    let invSpan: Double

    init(threshold: Double) {
        self.threshold = threshold
        span = 1 - threshold
        invSpan = 1 / (1 - threshold)
    }

    @inline(__always)
    func shape(_ x: Double) -> Double {
        let a = abs(x)
        if a <= threshold { return x }
        let y = threshold + span * tanh((a - threshold) * invSpan)
        return x < 0 ? -y : y
    }

    @inline(__always)
    func residualAntiderivative(_ x: Double) -> Double {
        let a = abs(x)
        if a <= threshold { return 0 }
        let u = (a - threshold) * invSpan
        let lnCosh = u + log1p(exp(-2 * u)) - 0.693_147_180_559_945_3
        return span * span * (lnCosh - 0.5 * u * u)
    }

    @inline(__always)
    func step(_ input: Double, prev priorInput: Double,
              prevResidual: Double?) -> (out: Double, residual: Double?) {
        let x = min(max(input, -1024), 1024)
        let prev = min(max(priorInput, -1024), 1024)
        let inside = abs(x) <= threshold
        if inside && abs(prev) <= threshold { return (x, nil) }
        let current = inside ? 0 : residualAntiderivative(x)
        let carried: Double? = inside ? nil : current
        let dx = x - prev
        if abs(dx) < 1e-6 {
            return (shape(0.5 * (x + prev)), carried)
        }
        let before = prevResidual ?? residualAntiderivative(prev)
        let out = x + (current - before) / dx
        return (min(max(out, -1), 1), carried)
    }
}

struct AppCurve: Equatable {
    var bundleID: String
    var preGain: Double
    var bands: [QxEqBandValue]
}

final class AppChainTable {
    let count: Int
    let preGain: UnsafeMutablePointer<Float>
    let sections: UnsafeMutablePointer<Int32>
    let coeffs: UnsafeMutablePointer<Double>

    init(count: Int) {
        let apps = StageProcessor.maxAssignedApps
        self.count = min(max(count, 0), apps)
        preGain = UnsafeMutablePointer<Float>.allocate(capacity: apps)
        preGain.initialize(repeating: 1, count: apps)
        sections = UnsafeMutablePointer<Int32>.allocate(capacity: apps)
        sections.initialize(repeating: 0, count: apps)
        let slots = apps * StageProcessor.maxAppSections * 5
        coeffs = UnsafeMutablePointer<Double>.allocate(capacity: slots)
        coeffs.initialize(repeating: 0, count: slots)
    }

    deinit {
        preGain.deallocate()
        sections.deallocate()
        coeffs.deallocate()
    }

    func set(_ section: BiquadSection, app: Int, index: Int) {
        guard app >= 0, app < StageProcessor.maxAssignedApps,
              index >= 0, index < StageProcessor.maxAppSections else { return }
        let base = coeffs + (app * StageProcessor.maxAppSections + index) * 5
        base[0] = section.b0
        base[1] = section.b1
        base[2] = section.b2
        base[3] = section.a1
        base[4] = section.a2
    }
}

final class StageProcessor {
    struct Config {
        var muted = false
        var monitorOnly = false
        var epoch: UInt64 = 0
        var stage = StageParams()
        var kShelf = BiquadSection.passthrough
        var kHighpass = BiquadSection.passthrough
        var perAppStreams: Int32 = 1
        var perAppActive = false
        var perAppEpoch: UInt64 = 0
    }

    struct EarlyTap {
        var cross = false
        var offset = 1
        var gain: Float = 0
    }

    struct StageParams {
        var enabled = false
        var sideGain: Float = 1
        var sideShelf: BiquadSection?
        var centerGain: Float = 1
        var dryGain: Float = 1
        var crossGain: Float = 0
        var crossDirect: Float = 1
        var crossDelaySamples: Int = 14
        var crossLPCoef: Float = 0.09
        var crossLowTrim: Float = 1
        var crossMidTrim: Float = 1
        var crossHighTrim: Float = 1
        var crossBandsActive = false
        var crossBandLP: BiquadSection?
        var crossBandHP: BiquadSection?
        var balanceGainL: Float = 1
        var balanceGainR: Float = 1
        var alignActive = false
        var alignOnRight = true
        var alignInt: Int = 0
        var alignFrac: Float = 0
        var dialogue: BiquadSection?
        var roomWet: Float = 0
        var tailFeedback: Float = 0
        var earlyL = (EarlyTap(), EarlyTap(), EarlyTap(), EarlyTap())
        var earlyR = (EarlyTap(), EarlyTap(), EarlyTap(), EarlyTap())
        var tailLenL: Int = 2543
        var tailLenR: Int = 2963
        var tailDamp: Float = 0.35
        var roomSpan: Int = 16383
        var tailSpan: Int = 8191
        var roomLPCoef: Float = 0.3
        var nightAtk: Float = 0.008
        var nightRel: Float = 0.0006
        var night: Float = 0
        var trim: Float = 1
        var limiterOn = false
        var limitCeiling: Float = 0.891_250_9
        var limRelease: Float = 0.000_26
        var loudActive = false
        var loudLow = BiquadSection.passthrough
        var loudHigh = BiquadSection.passthrough
        var loudDcGain: Double = 1
        var loudGlide: Double = 0.0001
        var convWet: Float = 0
        var guardOn = false
        var guardLP = BiquadSection.passthrough
        var guardBoostGain: Float = 1
        var guardMaxRedDb: Float = 0
        var guardThreshDb: Float = -6
        var guardKneeDb: Float = 6
        var guardAtk: Float = 0
        var guardRel: Float = 0
    }

    static let maxChannels = 32

    private let lock: UnsafeMutablePointer<os_unfair_lock_s> = {
        let p = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock_s())
        return p
    }()
    private var config = Config()

    init() {
        assert(_isPOD(Config.self), "Config must stay free of heap references")
    }

    deinit {
        lock.deallocate()
        meterLock.deallocate()
        specLock.deallocate()
        convScratchL.deallocate()
        convScratchR.deallocate()
        appZ.deallocate()
        mixBus.deallocate()
    }

    private var sampleRate: Double = 48000
    private var stageSettings = StageSettings()
    private var kShelfDesign = KWeighting.shelf(sampleRate: 48000)
    private var kHighpassDesign = KWeighting.highpass(sampleRate: 48000)
    private var muted = false
    private var monitorOnly = false
    private var loudnessShelfDb: Double = 0
    private var loudnessAppliedDb: Double = 0
    private var bassGuardCeiling: Double = 0
    private var bassGuardBoost: Double = 0
    private var bassGuardAppliedDb: Double = 0
    private var epoch: UInt64 = 0

    func prepare(sampleRate: Double) {
        self.sampleRate = AudioOutputs.plausibleRate(sampleRate)
        epoch &+= 1
        kShelfDesign = KWeighting.shelf(sampleRate: self.sampleRate)
        kHighpassDesign = KWeighting.highpass(sampleRate: self.sampleRate)
        os_unfair_lock_lock(specLock)
        specWritten = 0
        specWriteIdx = 0
        specTotalWritten = 0
        specDrainedTotal = 0
        os_unfair_lock_unlock(specLock)
        os_unfair_lock_lock(meterLock)
        meterSumSquares = 0
        meterFrames = 0
        loudSumSquares = 0
        loudFrames = 0
        corrLR = 0; corrLL = 0; corrRR = 0
        limMinGain = 1
        guardMaxRedDb = 0
        os_unfair_lock_unlock(meterLock)
        rebuildImpulse(block: wantedBlockFrames)
        if !appCurves.isEmpty {
            rebuildAppChains()
        } else {
            redesign()
        }
    }

    func applyStage(_ settings: StageSettings) {
        let next = settings.clamped()
        guard !next.audiblyEquals(stageSettings) else { return }
        stageSettings = next
        redesign()
    }

    func setMuted(_ muted: Bool) {
        guard muted != self.muted else { return }
        self.muted = muted
        redesign()
    }

    var isMutedNow: Bool { muted }

    func setMonitorOnly(_ monitor: Bool) {
        guard monitor != monitorOnly else { return }
        monitorOnly = monitor
        redesign()
    }

    func applyLoudness(shelfDb: Double) {
        let next = shelfDb.isFinite
            ? min(max(shelfDb, 0), EarLevel.maxShelfDb) : 0
        guard abs(next - loudnessShelfDb) >= 0.1 else { return }
        loudnessShelfDb = next
        redesign()
    }

    var appliedLoudnessShelfDb: Double { loudnessAppliedDb }

    func applyBassGuard(ceilingDb: Double, predictedBoostDb: Double) {
        let ceiling = ceilingDb.isFinite
            ? min(max(ceilingDb, 0), Self.bassGuardMaxCeilingDb) : 0
        let boost = predictedBoostDb.isFinite
            ? min(max(predictedBoostDb, 0), Self.bassGuardMaxBoostDb) : 0
        guard abs(ceiling - bassGuardCeiling) >= 0.1
            || abs(boost - bassGuardBoost) >= 0.1 else { return }
        bassGuardCeiling = ceiling
        bassGuardBoost = boost
        redesign()
    }

    var appliedBassGuardCeilingDb: Double { bassGuardAppliedDb }

    private func designStage() -> StageParams {
        var p = StageParams()
        let s = stageSettings
        loudnessAppliedDb = 0
        bassGuardAppliedDb = 0
        guard s.enabled else { return p }
        p.enabled = true
        p.sideGain = Float(s.width / 100)
        if s.width > 105 {
            let shelfDb = min(4, (s.width - 100) / 100 * 4)
            p.sideShelf = BiquadSection.highShelf(freq: 700, gainDb: shelfDb,
                                                  q: 0.71, sampleRate: sampleRate)
        }
        p.centerGain = Float(pow(10, s.centerValue / 20))
        p.dryGain = Float(1 - 0.15 * s.distanceValue)

        let delayMs = 0.18 + 0.5 * s.spanValue
        p.crossDelaySamples = max(1, min(Self.crossBufSize - 1,
                                         Int(delayMs / 1000 * sampleRate)))
        let shadowHz = 900 - 400 * s.spanValue
        p.crossLPCoef = Float(1 - exp(-2 * Double.pi * shadowHz / sampleRate))
        p.crossGain = Float(s.crossfeed) * 0.35
        p.crossDirect = 1 / (1 + p.crossGain * 0.7)

        p.crossLowTrim = Float(s.crossLowTrimValue)
        p.crossMidTrim = Float(s.crossMidTrimValue)
        p.crossHighTrim = Float(s.crossHighTrimValue)
        p.crossBandsActive = p.crossLowTrim != 1 || p.crossMidTrim != 1
            || p.crossHighTrim != 1
        p.crossBandLP = BiquadSection.lowPass(freq: 800, q: 0.71,
                                              sampleRate: sampleRate)
        p.crossBandHP = BiquadSection.highPass(freq: 4000, q: 0.71,
                                               sampleRate: sampleRate)

        let half = s.balanceDbValue / 2
        p.balanceGainL = Float(pow(10, -half / 20))
        p.balanceGainR = Float(pow(10, half / 20))
        let alignSamples = min(Double(Self.alignBufSize - 2),
                               abs(s.alignMsValue) / 1000 * sampleRate)
        p.alignActive = alignSamples > 0
        p.alignOnRight = s.alignMsValue > 0
        p.alignInt = Int(alignSamples)
        p.alignFrac = Float(alignSamples - Double(p.alignInt))

        if s.dialogue > 0.05 {
            p.dialogue = BiquadSection.peak(freq: 2500, gainDb: s.dialogue,
                                            q: 0.9, sampleRate: sampleRate)
        }

        let scale = 0.6 + s.sizeValue
        let predelay = Int(s.distanceValue * 0.022 * sampleRate)
        func tap(_ cross: Bool, _ ms: Double, _ gain: Float) -> EarlyTap {
            EarlyTap(cross: cross,
                     offset: min(Self.roomBufSize - 1,
                                 Int(ms * scale / 1000 * sampleRate) + predelay),
                     gain: gain)
        }
        p.earlyL = (tap(true, 17, 0.80), tap(false, 23, 0.50),
                    tap(true, 31, 0.45), tap(false, 43, 0.32))
        p.earlyR = (tap(true, 19, 0.80), tap(false, 29, 0.50),
                    tap(true, 37, 0.45), tap(false, 47, 0.32))
        p.tailLenL = max(64, min(Self.tailBufSize - 1, Int(0.053 * scale * sampleRate)))
        p.tailLenR = max(64, min(Self.tailBufSize - 1, Int(0.061 * scale * sampleRate)))
        p.tailDamp = Float(1 - exp(-2 * Double.pi * Self.tailDampHz / sampleRate))
        p.roomSpan = min(Self.roomBufSize - 1, Int(0.0972 * sampleRate) + 2)
        p.tailSpan = min(Self.tailBufSize - 1, Int(0.0976 * sampleRate) + 2)
        p.roomLPCoef = Float(1 - exp(-2 * Double.pi * 3500 / sampleRate))
        p.nightAtk = Float(1 - exp(-1 / (0.005 * sampleRate)))
        p.nightRel = Float(1 - exp(-1 / (0.15 * sampleRate)))
        p.roomWet = Float(s.room) * 0.8
        p.tailFeedback = Float(s.room) * 0.45
        p.night = Float(s.nightValue)
        let excess = max(0, p.sideGain - 1) * 0.35 + p.roomWet * 0.3
        p.trim = 1 / (1 + excess * 0.5)
        p.limiterOn = s.limiterValue
        p.limRelease = Float(1 - exp(-1 / (0.08 * sampleRate)))

        let shelf = s.loudnessValue
            ? min(max(loudnessShelfDb, 0), EarLevel.maxShelfDb) : 0
        p.loudActive = shelf > 0.05
        if p.loudActive {
            loudnessAppliedDb = shelf
            p.loudDcGain = pow(10, shelf / 20)
            p.loudLow = BiquadSection.lowShelf(
                freq: Self.loudnessLowHz, gainDb: shelf,
                q: Self.loudnessShelfQ, sampleRate: sampleRate)
            p.loudHigh = BiquadSection.highShelf(
                freq: Self.loudnessHighHz, gainDb: shelf * EarLevel.trebleShelfRatio,
                q: Self.loudnessShelfQ, sampleRate: sampleRate)
        }
        p.loudGlide = 1 - exp(-1 / (Self.loudnessGlideSeconds * sampleRate))
        p.convWet = s.hasImpulse
            ? Float(min(max(s.impulseMixValue, 0), 1)) : 0

        p.guardOn = s.bassGuardValue && bassGuardCeiling > 0
        if p.guardOn {
            bassGuardAppliedDb = bassGuardCeiling
            p.guardLP = BiquadSection.lowPass(freq: Self.bassGuardLowHz, q: 0.71,
                                              sampleRate: sampleRate)
            p.guardBoostGain = Float(pow(10, bassGuardBoost / 20))
            p.guardMaxRedDb = Float(bassGuardCeiling)
            p.guardThreshDb = Float(Self.bassGuardThresholdDb)
            p.guardKneeDb = Float(Self.bassGuardKneeDb)
            p.guardAtk = Float(1 - exp(-1 / (Self.bassGuardAttackSeconds * sampleRate)))
            p.guardRel = Float(1 - exp(-1 / (Self.bassGuardReleaseSeconds * sampleRate)))
        }
        return p
    }

    static let tailDampHz: Double = -log(0.65) * 48000 / (2 * Double.pi)
    static let loudnessLowHz: Double = 120
    static let loudnessHighHz: Double = 8000
    static let loudnessShelfQ: Double = 0.8
    static let loudnessGlideSeconds: Double = 0.2
    static let loudnessMaxWet: Double = 8

    static let bassGuardLowHz: Double = 120
    static let bassGuardThresholdDb: Double = -6
    static let bassGuardKneeDb: Double = 6
    static let bassGuardAttackSeconds: Double = 0.005
    static let bassGuardReleaseSeconds: Double = 0.25
    static let bassGuardMaxCeilingDb: Double = 12
    static let bassGuardMaxBoostDb: Double = 40

    private func redesign() {
        var next = Config()
        next.muted = muted
        next.monitorOnly = monitorOnly
        next.epoch = epoch
        next.stage = designStage()
        next.kShelf = kShelfDesign
        next.kHighpass = kHighpassDesign
        next.perAppActive = !appCurves.isEmpty && appChainCurrent != nil
        next.perAppStreams = next.perAppActive
            ? Int32(min(appCurves.count + 1, Self.maxTapStreams)) : 1
        next.perAppEpoch = perAppEpoch
        let chains = appChainCurrent.map { Unmanaged.passUnretained($0) }
        os_unfair_lock_lock(lock)
        config = next
        appChainSlot = chains
        os_unfair_lock_unlock(lock)
    }

    static let maxAssignedApps = 8
    static let maxAppSections = 20
    static let maxTapStreams = 9
    static let mixBusFrames = 8192
    static let appChainGraveyardDepth = 4

    private var appCurves: [AppCurve] = []
    private var appChainCurrent: AppChainTable?
    private var appChainRetired: [AppChainTable] = []
    private var appChainSlot: Unmanaged<AppChainTable>?
    private var perAppEpoch: UInt64 = 0

    var assignedAppCount: Int { appCurves.count }

    func applyAppChains(_ curves: [AppCurve]) {
        let next = Array(curves.prefix(Self.maxAssignedApps))
        guard next != appCurves else { return }
        appCurves = next
        rebuildAppChains()
    }

    private func rebuildAppChains() {
        guard !appCurves.isEmpty else {
            publishAppChains(nil)
            return
        }
        let table = AppChainTable(count: appCurves.count)
        for (app, curve) in appCurves.enumerated() {
            let clamped = curve.preGain.isFinite
                ? min(max(curve.preGain, -Self.maxAppPreGainDb), Self.maxAppPreGainDb) : 0
            table.preGain[app] = Float(pow(10, clamped / 20))
            var used = 0
            for band in curve.bands.prefix(Self.maxAppSections) {
                guard let section = Self.appSection(band, sampleRate: sampleRate)
                else { continue }
                table.set(section, app: app, index: used)
                used += 1
            }
            table.sections[app] = Int32(used)
        }
        publishAppChains(table)
    }

    static let maxAppPreGainDb: Double = 24

    static func appSection(_ band: QxEqBandValue, sampleRate: Double) -> BiquadSection? {
        let clean = PresetLibraryFile.clamped(band)
        let freq = Double(clean.freq)
        let gain = clean.gain
        let q = clean.q
        switch clean.filter {
        case .bypass:
            return nil
        case .peak:
            guard abs(gain) > 0.001 else { return nil }
            return .peak(freq: freq, gainDb: gain, q: q, sampleRate: sampleRate)
        case .lowShelf:
            guard abs(gain) > 0.001 else { return nil }
            return .lowShelf(freq: freq, gainDb: gain, q: q, sampleRate: sampleRate)
        case .highShelf:
            guard abs(gain) > 0.001 else { return nil }
            return .highShelf(freq: freq, gainDb: gain, q: q, sampleRate: sampleRate)
        case .lpf:
            return .lowPass(freq: freq, q: q, sampleRate: sampleRate)
        case .hpf:
            return .highPass(freq: freq, q: q, sampleRate: sampleRate)
        }
    }

    private func publishAppChains(_ table: AppChainTable?) {
        if let old = appChainCurrent {
            appChainRetired.append(old)
            while appChainRetired.count > Self.appChainGraveyardDepth {
                appChainRetired.removeFirst()
            }
        }
        appChainCurrent = table
        perAppEpoch &+= 1
        redesign()
    }

    static let defaultBlockFrames = 512
    static let convGraveyardDepth = 4

    enum ImpulseStatus: Equatable {
        case off
        case ready(name: String, partitions: Int, taps: Int, hop: Int, rate: Double)
        case refused(String)
    }

    private var impulse: ImpulseResponse?
    private var convCurrent: ConvolverState?
    private var convRetired: [ConvolverState] = []
    private var convSlot: Unmanaged<ConvolverState>?
    private var convProblem: String?
    private var convBuiltBlock = 0
    private var convBuiltRate: Double = 0

    var impulseStatus: ImpulseStatus {
        if let problem = convProblem { return .refused(problem) }
        guard let c = convCurrent else { return .off }
        return .ready(name: c.name, partitions: c.partitions, taps: c.taps,
                      hop: c.hop, rate: c.sampleRate)
    }

    var impulseName: String? { convCurrent?.name }

    func setImpulse(_ response: ImpulseResponse?) {
        impulse = response
        rebuildImpulse(block: wantedBlockFrames)
    }

    func refreshImpulseLayout() {
        guard impulse != nil else { return }
        let block = wantedBlockFrames
        guard block != convBuiltBlock || sampleRate != convBuiltRate else { return }
        rebuildImpulse(block: block)
    }

    private var wantedBlockFrames: Int {
        let seen = observedBlockFrames
        return seen > 0 ? seen : Self.defaultBlockFrames
    }

    private func rebuildImpulse(block: Int) {
        convBuiltBlock = block
        convBuiltRate = sampleRate
        guard let response = impulse else {
            publishConvolver(nil, problem: nil)
            return
        }
        do {
            let state = try ConvolverState(impulse: response,
                                           sampleRate: sampleRate,
                                           blockFrames: block)
            publishConvolver(state, problem: nil)
        } catch {
            let message = (error as? ImpulseError)?.message
                ?? error.localizedDescription
            publishConvolver(nil, problem: message)
        }
    }

    private func publishConvolver(_ state: ConvolverState?, problem: String?) {
        if let old = convCurrent {
            convRetired.append(old)
            while convRetired.count > Self.convGraveyardDepth {
                convRetired.removeFirst()
            }
        }
        convCurrent = state
        convProblem = problem
        let slot = state.map { Unmanaged.passUnretained($0) }
        os_unfair_lock_lock(lock)
        convSlot = slot
        os_unfair_lock_unlock(lock)
    }

    private let meterLock: UnsafeMutablePointer<os_unfair_lock_s> = {
        let p = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock_s())
        return p
    }()
    private var meterSumSquares: Double = 0
    private var meterFrames: Int = 0
    private var loudSumSquares: Double = 0
    private var loudFrames: Int = 0
    private var limMinGain: Float = 1
    private var guardMaxRedDb: Float = 0

    private var diagChannels: Int32 = 0
    private var diagStageRan: Bool = false
    private var diagBlockFrames: Int32 = 0
    private var diagInputBuffers: Int32 = 0
    private var corrLR: Double = 0
    private var corrLL: Double = 0
    private var corrRR: Double = 0

    var observedBlockFrames: Int {
        os_unfair_lock_lock(meterLock)
        let frames = Int(diagBlockFrames)
        os_unfair_lock_unlock(meterLock)
        return frames
    }

    func renderDiagnostics() -> (channels: Int, stageRan: Bool, inputBuffers: Int) {
        os_unfair_lock_lock(meterLock)
        defer { os_unfair_lock_unlock(meterLock) }
        return (Int(diagChannels), diagStageRan, Int(diagInputBuffers))
    }

    func drainSourceCorrelation() -> Double? {
        os_unfair_lock_lock(meterLock)
        defer { os_unfair_lock_unlock(meterLock) }
        let (lr, ll, rr) = (corrLR, corrLL, corrRR)
        corrLR = 0; corrLL = 0; corrRR = 0
        guard ll > 1e-6, rr > 1e-6 else { return nil }
        return lr / (ll * rr).squareRoot()
    }

    func drainMeter() -> (sumSquares: Double, frames: Int) {
        os_unfair_lock_lock(meterLock)
        defer { os_unfair_lock_unlock(meterLock) }
        let result = (meterSumSquares, meterFrames)
        meterSumSquares = 0
        meterFrames = 0
        return result
    }

    func drainLimiterFloor() -> Float {
        os_unfair_lock_lock(meterLock)
        defer { os_unfair_lock_unlock(meterLock) }
        let floor = limMinGain
        limMinGain = 1
        return floor
    }

    func drainBassGuardReduction() -> Float {
        os_unfair_lock_lock(meterLock)
        defer { os_unfair_lock_unlock(meterLock) }
        let deepest = guardMaxRedDb
        guardMaxRedDb = 0
        return deepest
    }

    func drainLoudnessMeter() -> (sumSquares: Double, frames: Int) {
        os_unfair_lock_lock(meterLock)
        defer { os_unfair_lock_unlock(meterLock) }
        let result = (loudSumSquares, loudFrames)
        loudSumSquares = 0
        loudFrames = 0
        return result
    }

    static let specRingSize = 16384
    private let specLock: UnsafeMutablePointer<os_unfair_lock_s> = {
        let p = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock_s())
        return p
    }()
    private var specRing = [Float](repeating: 0, count: specRingSize)
    private var specWriteIdx = 0
    private var specWritten = 0
    private var specTotalWritten = 0
    private var specDrainedTotal = 0

    func drainSpectrumSamples(_ count: Int) -> [Float] {
        let n = min(count, Self.specRingSize)
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        os_unfair_lock_lock(specLock)
        defer { os_unfair_lock_unlock(specLock) }
        guard specWritten >= n else { return [] }
        guard specTotalWritten - specDrainedTotal >= n else { return [] }
        specDrainedTotal = specTotalWritten
        let mask = Self.specRingSize - 1
        let start = (specWriteIdx - n) & mask
        let firstRun = min(n, Self.specRingSize - start)
        out.withUnsafeMutableBufferPointer { dst in
            specRing.withUnsafeBufferPointer { src in
                guard let d = dst.baseAddress, let s = src.baseAddress else { return }
                d.update(from: s + start, count: firstRun)
                if firstRun < n {
                    (d + firstRun).update(from: s, count: n - firstRun)
                }
            }
        }
        return out
    }

    static let crossBufSize = 512
    static let roomBufSize = 131072
    private var crossDelayL = [Float](repeating: 0, count: crossBufSize)
    private var crossDelayR = [Float](repeating: 0, count: crossBufSize)
    private var crossIdx = 0
    private var crossLPl: Float = 0
    private var crossLPr: Float = 0
    private var crossLoZ1L: Double = 0, crossLoZ2L: Double = 0
    private var crossLoZ1R: Double = 0, crossLoZ2R: Double = 0
    private var crossHiZ1L: Double = 0, crossHiZ2L: Double = 0
    private var crossHiZ1R: Double = 0, crossHiZ2R: Double = 0
    static let alignBufSize = 512
    private var alignBufL = [Float](repeating: 0, count: alignBufSize)
    private var alignBufR = [Float](repeating: 0, count: alignBufSize)
    private var alignIdx = 0
    private var dialogueZ1: Double = 0
    private var dialogueZ2: Double = 0
    private var sideShelfZ1: Double = 0
    private var sideShelfZ2: Double = 0
    private var roomBufL = [Float](repeating: 0, count: roomBufSize)
    private var roomBufR = [Float](repeating: 0, count: roomBufSize)
    private var roomIdx = 0
    static let tailBufSize = 131072
    private var tailBufL = [Float](repeating: 0, count: tailBufSize)
    private var tailBufR = [Float](repeating: 0, count: tailBufSize)
    private var tailIdxL = 0
    private var tailIdxR = 0
    private var tailLPL: Float = 0
    private var tailLPR: Float = 0
    private var roomLPStateL: Float = 0
    private var roomLPStateR: Float = 0
    private var adaaPrevL: Float = 0
    private var adaaPrevR: Float = 0
    private var adaaPrevFL: Double?
    private var adaaPrevFR: Double?
    private var loudLowCur = BiquadSection.passthrough
    private var loudHighCur = BiquadSection.passthrough
    private var loudCurDcGain: Double = 1
    private var loudWet: Double = 0
    private var loudLoZ1L: Double = 0, loudLoZ2L: Double = 0
    private var loudLoZ1R: Double = 0, loudLoZ2R: Double = 0
    private var loudHiZ1L: Double = 0, loudHiZ2L: Double = 0
    private var loudHiZ1R: Double = 0, loudHiZ2R: Double = 0
    private var loudEngaged = false
    private var guardLoZ1L: Double = 0, guardLoZ2L: Double = 0
    private var guardLoZ1R: Double = 0, guardLoZ2R: Double = 0
    private var guardEnv: Float = 0
    private var guardEngaged = false

    private var nightEnv: Double = 0.05
    private var nightEngaged = false

    static let limRingSize = 128
    static let limLookahead = 64
    private var limDelay = [Float](repeating: 0, count: maxChannels * limRingSize)
    private var limIdx = 0
    private let tpPhase1 = StageProcessor.sincPhase(0.25)
    private let tpPhase2 = StageProcessor.sincPhase(0.5)
    private let tpPhase3 = StageProcessor.sincPhase(0.75)
    private var tpHistL = [Float](repeating: 0, count: 8)
    private var tpHistR = [Float](repeating: 0, count: 8)
    private var limBlockMax = [Float](repeating: 0, count: 8)
    private var limBlockIdx = 0
    private var limSampleInBlock = 0
    private var limCurBlockMax: Float = 0
    private var limGain: Float = 1
    private var limEngaged = false

    static func sincPhase(_ frac: Double) -> [Float] {
        var taps = [Double](repeating: 0, count: 8)
        let center = 3.0 + frac
        for n in 0..<8 {
            let x = Double(n) - center
            let sinc = x == 0 ? 1 : sin(.pi * x) / (.pi * x)
            let window = 0.5 - 0.5 * cos(2 * .pi * (Double(n) + 0.5) / 8)
            taps[n] = sinc * window
        }
        let sum = taps.reduce(0, +)
        return taps.map { Float($0 / sum) }
    }

    private func resetLimiterState() {
        limDelay.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        for i in 0..<8 { tpHistL[i] = 0; tpHistR[i] = 0; limBlockMax[i] = 0 }
        limIdx = 0; limBlockIdx = 0; limSampleInBlock = 0
        limCurBlockMax = 0; limGain = 1
    }

    private var kState = [Double](repeating: 0, count: 8)
    private var kEngaged = false

    private var stageEngaged = false
    private var renderEpoch: UInt64 = 0

    @inline(__always)
    private static func zeroRing(_ ring: inout [Float]) {
        ring.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
    }

    private(set) var stageResetCount = 0

    #if DEBUG
    func poisonStageStateForTesting() {
        crossLPl = .nan
    }
    #endif

    @inline(__always)
    private static func zeroSpan(_ ring: inout [Float], from start: Int, count: Int) {
        guard count > 0 else { return }
        ring.withUnsafeMutableBufferPointer {
            guard let base = $0.baseAddress else { return }
            (base + start).update(repeating: 0, count: count)
        }
    }

    private func resetStageState(_ p: StageParams) {
        stageResetCount += 1
        Self.zeroRing(&crossDelayL); Self.zeroRing(&crossDelayR)
        let roomFrom = Self.roomBufSize - p.roomSpan
        Self.zeroSpan(&roomBufL, from: roomFrom, count: p.roomSpan)
        Self.zeroSpan(&roomBufR, from: roomFrom, count: p.roomSpan)
        Self.zeroSpan(&tailBufL, from: 0, count: p.tailSpan)
        Self.zeroSpan(&tailBufR, from: 0, count: p.tailSpan)
        Self.zeroRing(&alignBufL); Self.zeroRing(&alignBufR)
        crossIdx = 0; roomIdx = 0; tailIdxL = 0; tailIdxR = 0; alignIdx = 0
        crossLPl = 0; crossLPr = 0; tailLPL = 0; tailLPR = 0
        crossLoZ1L = 0; crossLoZ2L = 0; crossLoZ1R = 0; crossLoZ2R = 0
        crossHiZ1L = 0; crossHiZ2L = 0; crossHiZ1R = 0; crossHiZ2R = 0
        roomLPStateL = 0; roomLPStateR = 0
        sideShelfZ1 = 0; sideShelfZ2 = 0
        dialogueZ1 = 0; dialogueZ2 = 0
        adaaPrevL = 0; adaaPrevR = 0
        adaaPrevFL = nil; adaaPrevFR = nil
        loudLowCur = .passthrough; loudHighCur = .passthrough
        loudCurDcGain = 1; loudWet = 0
        loudLoZ1L = 0; loudLoZ2L = 0; loudLoZ1R = 0; loudLoZ2R = 0
        loudHiZ1L = 0; loudHiZ2L = 0; loudHiZ1R = 0; loudHiZ2R = 0
        loudEngaged = false
        guardLoZ1L = 0; guardLoZ2L = 0; guardLoZ1R = 0; guardLoZ2R = 0
        guardEnv = 0
        guardEngaged = false
        nightEnv = 0.05
        nightEngaged = false
        convEngaged = false
    }

    static let convScratchFrames = 8192
    private var convEngaged = false
    private let convScratchL: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: convScratchFrames)
        p.initialize(repeating: 0, count: convScratchFrames)
        return p
    }()
    private let convScratchR: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: convScratchFrames)
        p.initialize(repeating: 0, count: convScratchFrames)
        return p
    }()

    static let appStateSlots = maxAssignedApps * maxAppSections * 4
    private var perAppEngaged = false
    private var renderPerAppEpoch: UInt64 = 0
    private let appZ: UnsafeMutablePointer<Double> = {
        let p = UnsafeMutablePointer<Double>.allocate(capacity: appStateSlots)
        p.initialize(repeating: 0, count: appStateSlots)
        return p
    }()
    private let mixBus: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: mixBusFrames * 2)
        p.initialize(repeating: 0, count: mixBusFrames * 2)
        return p
    }()

    private func resetAppChainState() {
        appZ.update(repeating: 0, count: Self.appStateSlots)
    }

    private var inRefs: [(ptr: UnsafeMutablePointer<Float>, stride: Int, frames: Int)] = {
        var a = [(ptr: UnsafeMutablePointer<Float>, stride: Int, frames: Int)]()
        a.reserveCapacity(maxChannels)
        return a
    }()

    func render(input: UnsafePointer<AudioBufferList>,
                output: UnsafeMutablePointer<AudioBufferList>) {
        os_unfair_lock_lock(lock)
        let cfg = config
        let slot = convSlot
        let chainSlot = appChainSlot
        os_unfair_lock_unlock(lock)
        let conv = slot?.takeUnretainedValue()
        let chains = chainSlot?.takeUnretainedValue()

        if cfg.epoch != renderEpoch {
            renderEpoch = cfg.epoch
            stageEngaged = false
            kEngaged = false
            limEngaged = false
            perAppEngaged = false
        }
        if cfg.perAppEpoch != renderPerAppEpoch {
            renderPerAppEpoch = cfg.perAppEpoch
            perAppEngaged = false
        }

        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        for buf in outList where buf.mData != nil {
            memset(buf.mData, 0, Int(buf.mDataByteSize))
        }

        let wantedStreams = cfg.perAppActive && !cfg.monitorOnly
            ? min(Int(cfg.perAppStreams), Self.maxTapStreams) : 1
        let consumed = wantedStreams > 1 && inList.count >= wantedStreams
            ? wantedStreams : 1
        inRefs.removeAll(keepingCapacity: true)
        if consumed > 1 {
            if !perAppEngaged {
                resetAppChainState()
                perAppEngaged = true
            }
            mixPerAppStreams(inList, consumed: consumed,
                             blockFrames: Self.outputBlockFrames(outList),
                             chains: chains)
        } else {
            perAppEngaged = false
            collectInputChannels(inList, consumed: consumed)
        }

        if cfg.muted {
            os_unfair_lock_lock(meterLock)
            diagChannels = Int32(inRefs.count)
            diagStageRan = false
            diagInputBuffers = Int32(clamping: inList.count)
            os_unfair_lock_unlock(meterLock)
            stageEngaged = false
            kEngaged = false
            limEngaged = false
            return
        }

        guard !inRefs.isEmpty else { return }

        if let first = inRefs.first {
            os_unfair_lock_lock(specLock)
            let mask = Self.specRingSize - 1
            var p = first.ptr
            for _ in 0..<first.frames {
                let v = p.pointee
                specRing[specWriteIdx] = Self.sane(v)
                specWriteIdx = (specWriteIdx + 1) & mask
                p += first.stride
            }
            specWritten = min(specWritten + first.frames, Self.specRingSize)
            specTotalWritten += first.frames
            os_unfair_lock_unlock(specLock)
        }

        var cLR = 0.0, cLL = 0.0, cRR = 0.0
        if inRefs.count >= 2 {
            let l = inRefs[0], r = inRefs[1]
            var pl = l.ptr, pr = r.ptr
            for _ in 0..<min(l.frames, r.frames) {
                let lv = Double(pl.pointee), rv = Double(pr.pointee)
                cLR += lv * rv; cLL += lv * lv; cRR += rv * rv
                pl += l.stride; pr += r.stride
            }
        }

        var kss = 0.0
        var kFrames = 0
        if let first = inRefs.first {
            if !kEngaged {
                for i in kState.indices { kState[i] = 0 }
                kEngaged = true
            }
            let kChannels = min(inRefs.count, 2)
            kFrames = first.frames
            for c in 1..<kChannels { kFrames = min(kFrames, inRefs[c].frames) }
            for c in 0..<kChannels {
                let ref = inRefs[c]
                let base = c * 4
                var z1 = kState[base], z2 = kState[base + 1]
                var z3 = kState[base + 2], z4 = kState[base + 3]
                var q = ref.ptr
                for _ in 0..<kFrames {
                    var x = Double(q.pointee)
                    x = Self.sane(x)
                    let y1 = cfg.kShelf.b0 * x + z1
                    z1 = cfg.kShelf.b1 * x - cfg.kShelf.a1 * y1 + z2
                    z2 = cfg.kShelf.b2 * x - cfg.kShelf.a2 * y1
                    let y2 = cfg.kHighpass.b0 * y1 + z3
                    z3 = cfg.kHighpass.b1 * y1 - cfg.kHighpass.a1 * y2 + z4
                    z4 = cfg.kHighpass.b2 * y1 - cfg.kHighpass.a2 * y2
                    kss += y2 * y2
                    q += ref.stride
                }
                kState[base] = flushDenormal(z1)
                kState[base + 1] = flushDenormal(z2)
                kState[base + 2] = flushDenormal(z3)
                kState[base + 3] = flushDenormal(z4)
            }
        }

        let stageRan = cfg.stage.enabled && inRefs.count >= 2 && !cfg.monitorOnly
        if stageRan {
            if !stageEngaged {
                resetStageState(cfg.stage)
                stageEngaged = true
            }
            renderStage(cfg.stage, conv: conv)
        } else {
            stageEngaged = false
        }

        if cfg.stage.limiterOn && !cfg.monitorOnly {
            if !limEngaged {
                resetLimiterState()
                limEngaged = true
            }
            renderLimiter(ceiling: cfg.stage.limitCeiling,
                          release: cfg.stage.limRelease)
        } else {
            limEngaged = false
        }
        if consumed > 1 && !stageRan && !cfg.monitorOnly {
            capPerAppPeaks()
        }
        os_unfair_lock_lock(meterLock)
        diagChannels = Int32(inRefs.count)
        diagStageRan = stageRan
        diagBlockFrames = Int32(clamping: inRefs.first?.frames ?? 0)
        diagInputBuffers = Int32(clamping: inList.count)
        corrLR += cLR; corrLL += cLL; corrRR += cRR
        os_unfair_lock_unlock(meterLock)

        if let first = inRefs.first {
            var ss = 0.0
            var p = first.ptr
            for _ in 0..<first.frames {
                let v = Double(p.pointee)
                ss += v * v
                p += first.stride
            }

            os_unfair_lock_lock(meterLock)
            if ss.isFinite {
                meterSumSquares += ss
                meterFrames += first.frames
            }
            if kss.isFinite {
                loudSumSquares += kss
                loudFrames += kFrames
            }
            os_unfair_lock_unlock(meterLock)
        }

        guard !cfg.monitorOnly else { return }

        copyOut(outList)
    }

    private func collectInputChannels(_ inList: UnsafeMutableAudioBufferListPointer,
                                      consumed: Int) {
        for i in (inList.count - consumed)..<inList.count {
            let buf = inList[i]
            guard let raw = buf.mData, buf.mNumberChannels > 0 else { continue }
            let chans = Int(buf.mNumberChannels)
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * chans)
            let data = raw.assumingMemoryBound(to: Float.self)
            for c in 0..<min(chans, max(0, Self.maxChannels - inRefs.count)) {
                inRefs.append((ptr: data + c, stride: chans, frames: frames))
            }
        }
    }

    private static func outputBlockFrames(
        _ outList: UnsafeMutableAudioBufferListPointer) -> Int {
        for buf in outList {
            guard buf.mData != nil, buf.mNumberChannels > 0 else { continue }
            let chans = Int(buf.mNumberChannels)
            return Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * chans)
        }
        return 0
    }

    private func mixPerAppStreams(_ inList: UnsafeMutableAudioBufferListPointer,
                                  consumed: Int, blockFrames: Int,
                                  chains: AppChainTable?) {
        let frames = min(max(blockFrames, 0), Self.mixBusFrames)
        guard frames > 0 else { return }
        mixBus.update(repeating: 0, count: frames * 2)

        let first = inList.count - consumed
        let chained = min(consumed - 1, chains?.count ?? 0)
        for stream in 0..<consumed {
            let buf = inList[first + stream]
            guard let raw = buf.mData, buf.mNumberChannels > 0,
                  buf.mNumberChannels <= UInt32(Self.maxChannels) else { continue }
            let chans = Int(buf.mNumberChannels)
            let claimed = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * chans)
            let n = min(frames, claimed)
            guard n > 0 else { continue }
            let data = raw.assumingMemoryBound(to: Float.self)
            let right = chans >= 2 ? 1 : 0
            if stream < chained, let chains {
                renderAppChain(chains, app: stream, source: data, stride: chans,
                               right: right, frames: n)
            } else {
                for f in 0..<n {
                    var l = data[f * chans]
                    var r = data[f * chans + right]
                    l = Self.sane(l)
                    r = Self.sane(r)
                    mixBus[f * 2] += l
                    mixBus[f * 2 + 1] += r
                }
            }
        }
        inRefs.append((ptr: mixBus, stride: 2, frames: frames))
        inRefs.append((ptr: mixBus + 1, stride: 2, frames: frames))
    }

    private func renderAppChain(_ chains: AppChainTable, app: Int,
                                source: UnsafeMutablePointer<Float>, stride: Int,
                                right: Int, frames: Int) {
        let gain = Double(chains.preGain[app])
        let sections = min(Int(chains.sections[app]), Self.maxAppSections)
        let coeffs = chains.coeffs + app * Self.maxAppSections * 5
        let z = appZ + app * Self.maxAppSections * 4
        for f in 0..<frames {
            var l = Double(source[f * stride])
            var r = Double(source[f * stride + right])
            l = Self.sane(l)
            r = Self.sane(r)
            l *= gain
            r *= gain
            for s in 0..<sections {
                let c = coeffs + s * 5
                let zs = z + s * 4
                let yl = c[0] * l + zs[0]
                zs[0] = c[1] * l - c[3] * yl + zs[1]
                zs[1] = c[2] * l - c[4] * yl
                l = yl
                let yr = c[0] * r + zs[2]
                zs[2] = c[1] * r - c[3] * yr + zs[3]
                zs[3] = c[2] * r - c[4] * yr
                r = yr
            }
            if !l.isFinite { l = 0 }
            if !r.isFinite { r = 0 }
            mixBus[f * 2] += Float(l)
            mixBus[f * 2 + 1] += Float(r)
        }
        for i in 0..<(sections * 4) where !z[i].isFinite || abs(z[i]) < 1e-30 {
            z[i] = 0
        }
    }

    private func renderStage(_ p: StageParams, conv: ConvolverState?) {
        let l = inRefs[0], r = inRefs[1]
        let frames = min(l.frames, r.frames)
        let crossMask = Self.crossBufSize - 1
        let roomMask = Self.roomBufSize - 1
        let alignMask = Self.alignBufSize - 1
        var pl = l.ptr, pr = r.ptr

        if p.loudActive {
            if p.loudDcGain != loudCurDcGain {
                let effective = 1 + loudWet * (loudCurDcGain - 1)
                loudWet = min(Self.loudnessMaxWet,
                              max(0, (effective - 1) / (p.loudDcGain - 1)))
                loudCurDcGain = p.loudDcGain
                loudLowCur = p.loudLow
                loudHighCur = p.loudHigh
            }
            loudEngaged = true
        }
        let loudWetTarget: Double = p.loudActive ? 1 : 0
        let loudRunning = loudEngaged
        let glide = p.loudGlide

        if p.guardOn {
            if !guardEngaged {
                guardLoZ1L = 0; guardLoZ2L = 0; guardLoZ1R = 0; guardLoZ2R = 0
                guardEnv = 0
                guardEngaged = true
            }
        } else {
            guardEngaged = false
        }
        if p.night > 0 {
            if !nightEngaged {
                nightEnv = 0.05
                nightEngaged = true
            }
        } else {
            nightEngaged = false
        }
        let guardHalfKnee = p.guardKneeDb * 0.5
        var guardLocalRedDb: Float = 0

        func front(_ inL: Float, _ inR: Float) -> (Float, Float) {
            var L = inL, R = inR

            L = Self.sane(L)
            R = Self.sane(R)

            var m = (L + R) * 0.5
            var s = (L - R) * 0.5 * p.sideGain
            if let sh = p.sideShelf {
                let x = Double(s)
                let y = sh.b0 * x + sideShelfZ1
                sideShelfZ1 = sh.b1 * x - sh.a1 * y + sideShelfZ2
                sideShelfZ2 = sh.b2 * x - sh.a2 * y
                s = Float(y)
            }
            if let d = p.dialogue {
                let x = Double(m)
                let y = d.b0 * x + dialogueZ1
                dialogueZ1 = d.b1 * x - d.a1 * y + dialogueZ2
                dialogueZ2 = d.b2 * x - d.a2 * y
                m = Float(y)
            }
            m *= p.centerGain
            L = (m + s) * p.dryGain
            R = (m - s) * p.dryGain

            crossDelayL[crossIdx] = L
            crossDelayR[crossIdx] = R
            let read = (crossIdx - p.crossDelaySamples) & crossMask
            crossLPl += p.crossLPCoef * (crossDelayR[read] - crossLPl)
            crossLPr += p.crossLPCoef * (crossDelayL[read] - crossLPr)
            crossIdx = (crossIdx + 1) & crossMask

            var fedL = crossLPl, fedR = crossLPr
            if let lo = p.crossBandLP, let hi = p.crossBandHP {
                let xl = Double(crossLPl), xr = Double(crossLPr)
                var y = lo.b0 * xl + crossLoZ1L
                crossLoZ1L = lo.b1 * xl - lo.a1 * y + crossLoZ2L
                crossLoZ2L = lo.b2 * xl - lo.a2 * y
                let lowL = Float(y)
                y = lo.b0 * xr + crossLoZ1R
                crossLoZ1R = lo.b1 * xr - lo.a1 * y + crossLoZ2R
                crossLoZ2R = lo.b2 * xr - lo.a2 * y
                let lowR = Float(y)
                y = hi.b0 * xl + crossHiZ1L
                crossHiZ1L = hi.b1 * xl - hi.a1 * y + crossHiZ2L
                crossHiZ2L = hi.b2 * xl - hi.a2 * y
                let highL = Float(y)
                y = hi.b0 * xr + crossHiZ1R
                crossHiZ1R = hi.b1 * xr - hi.a1 * y + crossHiZ2R
                crossHiZ2R = hi.b2 * xr - hi.a2 * y
                let highR = Float(y)
                if p.crossBandsActive {
                    fedL = lowL * p.crossLowTrim
                        + (crossLPl - lowL - highL) * p.crossMidTrim
                        + highL * p.crossHighTrim
                    fedR = lowR * p.crossLowTrim
                        + (crossLPr - lowR - highR) * p.crossMidTrim
                        + highR * p.crossHighTrim
                }
            }
            if p.crossGain > 0 {
                L = L * p.crossDirect + fedL * p.crossGain
                R = R * p.crossDirect + fedR * p.crossGain
            }

            roomLPStateL += p.roomLPCoef * (L - roomLPStateL)
            roomLPStateR += p.roomLPCoef * (R - roomLPStateR)
            roomBufL[roomIdx] = roomLPStateL
            roomBufR[roomIdx] = roomLPStateR
            func tapL(_ t: EarlyTap) -> Float {
                let idx = (roomIdx - t.offset) & roomMask
                return (t.cross ? roomBufR[idx] : roomBufL[idx]) * t.gain
            }
            func tapR(_ t: EarlyTap) -> Float {
                let idx = (roomIdx - t.offset) & roomMask
                return (t.cross ? roomBufL[idx] : roomBufR[idx]) * t.gain
            }
            let wl = tapL(p.earlyL.0) + tapL(p.earlyL.1)
                   + tapL(p.earlyL.2) + tapL(p.earlyL.3)
            let wr = tapR(p.earlyR.0) + tapR(p.earlyR.1)
                   + tapR(p.earlyR.2) + tapR(p.earlyR.3)
            roomIdx = (roomIdx + 1) & roomMask

            if tailIdxL >= p.tailLenL { tailIdxL = 0 }
            if tailIdxR >= p.tailLenR { tailIdxR = 0 }
            let outL = tailBufL[tailIdxL]
            let outR = tailBufR[tailIdxR]
            tailLPL += p.tailDamp * ((wl + outL * p.tailFeedback) - tailLPL)
            tailLPR += p.tailDamp * ((wr + outR * p.tailFeedback) - tailLPR)
            tailBufL[tailIdxL] = tailLPL
            tailBufR[tailIdxR] = tailLPR
            tailIdxL += 1
            if tailIdxL >= p.tailLenL { tailIdxL = 0 }
            tailIdxR += 1
            if tailIdxR >= p.tailLenR { tailIdxR = 0 }

            if p.roomWet > 0 {
                L += (wl + outL * 0.6) * p.roomWet
                R += (wr + outR * 0.6) * p.roomWet
            }

            if p.night > 0 {
                let lvl = (abs(L) + abs(R)) * 0.5
                let coef = Double(lvl) > nightEnv ? p.nightAtk : p.nightRel
                nightEnv += Double(coef) * (Double(lvl) - nightEnv)
                let levelDb = 20 * log10(Float(max(nightEnv, 1e-5)))
                var gDb: Float = 0
                if levelDb > -50 {
                    gDb = (-26 - levelDb) * 0.5 * p.night
                    gDb = min(8 * p.night, max(-10 * p.night, gDb))
                }
                let g = pow(10, gDb / 20)
                L *= g
                R *= g
            }

            alignBufL[alignIdx] = L
            alignBufR[alignIdx] = R
            if p.alignActive {
                let i0 = (alignIdx - p.alignInt) & alignMask
                let i1 = (alignIdx - p.alignInt - 1) & alignMask
                if p.alignOnRight {
                    R = alignBufR[i0] + (alignBufR[i1] - alignBufR[i0]) * p.alignFrac
                } else {
                    L = alignBufL[i0] + (alignBufL[i1] - alignBufL[i0]) * p.alignFrac
                }
            }
            alignIdx = (alignIdx + 1) & alignMask

            L *= p.balanceGainL
            R *= p.balanceGainR
            return (L, R)
        }

        func back(_ inL: Float, _ inR: Float) -> (Float, Float) {
            var L = inL, R = inR

            if p.guardOn {
                let xgl = Double(L), xgr = Double(R)
                var yg = p.guardLP.b0 * xgl + guardLoZ1L
                guardLoZ1L = p.guardLP.b1 * xgl - p.guardLP.a1 * yg + guardLoZ2L
                guardLoZ2L = p.guardLP.b2 * xgl - p.guardLP.a2 * yg
                let lowL = Float(yg)
                yg = p.guardLP.b0 * xgr + guardLoZ1R
                guardLoZ1R = p.guardLP.b1 * xgr - p.guardLP.a1 * yg + guardLoZ2R
                guardLoZ2R = p.guardLP.b2 * xgr - p.guardLP.a2 * yg
                let lowR = Float(yg)

                let predicted = max(abs(lowL), abs(lowR)) * p.guardBoostGain
                let coef = predicted > guardEnv ? p.guardAtk : p.guardRel
                guardEnv += coef * (predicted - guardEnv)

                let over = 20 * log10f(max(guardEnv, 1e-7)) - p.guardThreshDb
                var redDb: Float = 0
                if over >= guardHalfKnee {
                    redDb = over
                } else if over > -guardHalfKnee {
                    let t = over + guardHalfKnee
                    redDb = t * t / (2 * p.guardKneeDb)
                }
                if redDb > p.guardMaxRedDb { redDb = p.guardMaxRedDb }
                if redDb > 0 {
                    let g = powf(10, -redDb / 20) - 1
                    L += g * lowL
                    R += g * lowR
                    if redDb > guardLocalRedDb { guardLocalRedDb = redDb }
                }
            }

            if loudRunning {
                loudWet += glide * (loudWetTarget - loudWet)

                let dryL = Double(L)
                var x = dryL
                var y = loudLowCur.b0 * x + loudLoZ1L
                loudLoZ1L = loudLowCur.b1 * x - loudLowCur.a1 * y + loudLoZ2L
                loudLoZ2L = loudLowCur.b2 * x - loudLowCur.a2 * y
                x = y
                y = loudHighCur.b0 * x + loudHiZ1L
                loudHiZ1L = loudHighCur.b1 * x - loudHighCur.a1 * y + loudHiZ2L
                loudHiZ2L = loudHighCur.b2 * x - loudHighCur.a2 * y
                L = Float(dryL + loudWet * (y - dryL))

                let dryR = Double(R)
                x = dryR
                y = loudLowCur.b0 * x + loudLoZ1R
                loudLoZ1R = loudLowCur.b1 * x - loudLowCur.a1 * y + loudLoZ2R
                loudLoZ2R = loudLowCur.b2 * x - loudLowCur.a2 * y
                x = y
                y = loudHighCur.b0 * x + loudHiZ1R
                loudHiZ1R = loudHighCur.b1 * x - loudHighCur.a1 * y + loudHiZ2R
                loudHiZ2R = loudHighCur.b2 * x - loudHighCur.a2 * y
                R = Float(dryR + loudWet * (y - dryR))
            }

            var xl = L * p.trim
            var xr = R * p.trim
            if !xl.isFinite { xl = 0 }
            if !xr.isFinite { xr = 0 }
            let clippedL = softClipADAAStep(xl, prev: adaaPrevL, prevF: adaaPrevFL)
            let clippedR = softClipADAAStep(xr, prev: adaaPrevR, prevF: adaaPrevFR)
            L = clippedL.out
            R = clippedR.out
            adaaPrevL = xl
            adaaPrevR = xr
            adaaPrevFL = clippedL.f
            adaaPrevFR = clippedR.f
            return (L, R)
        }

        let convolving = p.convWet > 0 && frames <= Self.convScratchFrames
            && (conv?.accepts(frames: frames) ?? false)
        if convolving, let conv {
            if !convEngaged {
                conv.reset()
                convEngaged = true
            }
            var ql = pl, qr = pr
            for i in 0..<frames {
                let (a, b) = front(ql.pointee, qr.pointee)
                convScratchL[i] = a
                convScratchR[i] = b
                ql += l.stride
                qr += r.stride
            }
            conv.render(left: convScratchL, right: convScratchR,
                        frames: frames, wet: p.convWet)
            ql = pl
            qr = pr
            for i in 0..<frames {
                let (a, b) = back(convScratchL[i], convScratchR[i])
                ql.pointee = a
                qr.pointee = b
                ql += l.stride
                qr += r.stride
            }
        } else {
            convEngaged = false
            for _ in 0..<frames {
                let (a, b) = front(pl.pointee, pr.pointee)
                let (c, d) = back(a, b)
                pl.pointee = c
                pr.pointee = d
                pl += l.stride
                pr += r.stride
            }
        }

        if abs(crossLPl) < 1e-20 { crossLPl = 0 }
        if abs(crossLPr) < 1e-20 { crossLPr = 0 }
        if abs(crossLoZ1L) < 1e-30 { crossLoZ1L = 0 }
        if abs(crossLoZ2L) < 1e-30 { crossLoZ2L = 0 }
        if abs(crossLoZ1R) < 1e-30 { crossLoZ1R = 0 }
        if abs(crossLoZ2R) < 1e-30 { crossLoZ2R = 0 }
        if abs(crossHiZ1L) < 1e-30 { crossHiZ1L = 0 }
        if abs(crossHiZ2L) < 1e-30 { crossHiZ2L = 0 }
        if abs(crossHiZ1R) < 1e-30 { crossHiZ1R = 0 }
        if abs(crossHiZ2R) < 1e-30 { crossHiZ2R = 0 }
        if abs(roomLPStateL) < 1e-20 { roomLPStateL = 0 }
        if abs(roomLPStateR) < 1e-20 { roomLPStateR = 0 }
        if abs(tailLPL) < 1e-20 { tailLPL = 0 }
        if abs(tailLPR) < 1e-20 { tailLPR = 0 }
        if abs(sideShelfZ1) < 1e-30 { sideShelfZ1 = 0 }
        if abs(sideShelfZ2) < 1e-30 { sideShelfZ2 = 0 }
        if abs(dialogueZ1) < 1e-30 { dialogueZ1 = 0 }
        if abs(dialogueZ2) < 1e-30 { dialogueZ2 = 0 }
        if abs(nightEnv) < 1e-30 { nightEnv = 0 }
        if abs(loudLoZ1L) < 1e-30 { loudLoZ1L = 0 }
        if abs(loudLoZ2L) < 1e-30 { loudLoZ2L = 0 }
        if abs(loudLoZ1R) < 1e-30 { loudLoZ1R = 0 }
        if abs(loudLoZ2R) < 1e-30 { loudLoZ2R = 0 }
        if abs(loudHiZ1L) < 1e-30 { loudHiZ1L = 0 }
        if abs(loudHiZ2L) < 1e-30 { loudHiZ2L = 0 }
        if abs(loudHiZ1R) < 1e-30 { loudHiZ1R = 0 }
        if abs(loudHiZ2R) < 1e-30 { loudHiZ2R = 0 }
        if abs(guardLoZ1L) < 1e-30 { guardLoZ1L = 0 }
        if abs(guardLoZ2L) < 1e-30 { guardLoZ2L = 0 }
        if abs(guardLoZ1R) < 1e-30 { guardLoZ1R = 0 }
        if abs(guardLoZ2R) < 1e-30 { guardLoZ2R = 0 }
        if abs(guardEnv) < 1e-20 { guardEnv = 0 }

        var stateProbe = Double(crossLPl) + Double(crossLPr)
            + Double(tailLPL) + Double(tailLPR)
        stateProbe += Double(roomLPStateL) + Double(roomLPStateR)
            + Double(guardEnv) + nightEnv + loudWet
        stateProbe += sideShelfZ1 + sideShelfZ2 + dialogueZ1 + dialogueZ2
        stateProbe += crossLoZ1L + crossLoZ2L + crossLoZ1R + crossLoZ2R
        stateProbe += crossHiZ1L + crossHiZ2L + crossHiZ1R + crossHiZ2R
        stateProbe += loudLoZ1L + loudLoZ2L + loudLoZ1R + loudLoZ2R
        stateProbe += loudHiZ1L + loudHiZ2L + loudHiZ1R + loudHiZ2R
        stateProbe += guardLoZ1L + guardLoZ2L + guardLoZ1R + guardLoZ2R
        if !stateProbe.isFinite { resetStageState(p) }

        if p.guardOn {
            os_unfair_lock_lock(meterLock)
            guardMaxRedDb = max(guardMaxRedDb, guardLocalRedDb)
            os_unfair_lock_unlock(meterLock)
        }

        if loudRunning, !p.loudActive, loudWet < 1e-6 {
            loudLowCur = .passthrough
            loudHighCur = .passthrough
            loudCurDcGain = 1
            loudWet = 0
            loudLoZ1L = 0; loudLoZ2L = 0; loudLoZ1R = 0; loudLoZ2R = 0
            loudHiZ1L = 0; loudHiZ2L = 0; loudHiZ1R = 0; loudHiZ2R = 0
            loudEngaged = false
        }
    }

    private func capPerAppPeaks() {
        guard inRefs.count >= 2 else { return }
        let l = inRefs[0], r = inRefs[1]
        var pl = l.ptr, pr = r.ptr
        for _ in 0..<min(l.frames, r.frames) {
            pl.pointee = Float(ceilingKnee.shape(Double(pl.pointee)))
            pr.pointee = Float(ceilingKnee.shape(Double(pr.pointee)))
            pl += l.stride
            pr += r.stride
        }
    }

    private func renderLimiter(ceiling: Float, release: Float) {
        let channels = min(inRefs.count, Self.maxChannels)
        guard channels > 0 else { return }
        var frames = inRefs[0].frames
        for c in 1..<channels { frames = min(frames, inRefs[c].frames) }
        let mask = Self.limRingSize - 1
        var localMinGain = limGain

        for f in 0..<frames {
            var xl = inRefs[0].ptr[f * inRefs[0].stride]
            if !xl.isFinite { xl = 0 }
            var xr = xl
            if channels >= 2 {
                xr = inRefs[1].ptr[f * inRefs[1].stride]
                if !xr.isFinite { xr = 0 }
            }
            var tp = max(abs(xl), abs(xr))
            if channels > 2 {
                for c in 2..<channels {
                    let v = inRefs[c].ptr[f * inRefs[c].stride]
                    if v.isFinite { tp = max(tp, abs(v)) }
                }
            }
            for i in 0..<7 {
                tpHistL[i] = tpHistL[i + 1]
                tpHistR[i] = tpHistR[i + 1]
            }
            tpHistL[7] = xl
            tpHistR[7] = xr
            var i1: Float = 0, i2: Float = 0, i3: Float = 0
            var j1: Float = 0, j2: Float = 0, j3: Float = 0
            for i in 0..<8 {
                i1 += tpHistL[i] * tpPhase1[i]; j1 += tpHistR[i] * tpPhase1[i]
                i2 += tpHistL[i] * tpPhase2[i]; j2 += tpHistR[i] * tpPhase2[i]
                i3 += tpHistL[i] * tpPhase3[i]; j3 += tpHistR[i] * tpPhase3[i]
            }
            tp = max(tp, max(abs(i1), max(abs(i2), abs(i3))))
            tp = max(tp, max(abs(j1), max(abs(j2), abs(j3))))

            limCurBlockMax = max(limCurBlockMax, tp)
            limSampleInBlock += 1
            if limSampleInBlock == 8 {
                limBlockMax[limBlockIdx] = limCurBlockMax
                limBlockIdx = (limBlockIdx + 1) & 7
                limCurBlockMax = 0
                limSampleInBlock = 0
            }
            var windowPeak = limCurBlockMax
            for i in 0..<8 { windowPeak = max(windowPeak, limBlockMax[i]) }

            let target: Float = windowPeak > ceiling ? ceiling / windowPeak : 1
            if target < limGain {
                limGain += (target - limGain) * 0.5
            } else {
                limGain += (target - limGain) * release
            }
            localMinGain = min(localMinGain, limGain)

            let read = (limIdx - Self.limLookahead) & mask
            for c in 0..<channels {
                let ring = c * Self.limRingSize
                let idx = f * inRefs[c].stride
                var x = inRefs[c].ptr[idx]
                if !x.isFinite { x = 0 }
                inRefs[c].ptr[idx] = limDelay[ring + read] * limGain
                limDelay[ring + limIdx] = x
            }
            limIdx = (limIdx + 1) & mask
        }

        for i in 0..<8 {
            if abs(tpHistL[i]) < 1e-20 { tpHistL[i] = 0 }
            if abs(tpHistR[i]) < 1e-20 { tpHistR[i] = 0 }
            if limBlockMax[i] < 1e-20 { limBlockMax[i] = 0 }
        }
        if limCurBlockMax < 1e-20 { limCurBlockMax = 0 }

        os_unfair_lock_lock(meterLock)
        limMinGain = min(limMinGain, localMinGain)
        os_unfair_lock_unlock(meterLock)
    }

    @inline(__always)
    private func flushDenormal(_ v: Double) -> Double {
        abs(v) < 1e-30 ? 0 : v
    }

    @inline(__always)
    private static func sane(_ v: Float) -> Float {
        v.isFinite && abs(v) <= 64 ? v : 0
    }

    @inline(__always)
    private static func sane(_ v: Double) -> Double {
        v.isFinite && abs(v) <= 64 ? v : 0
    }

    private let stageKnee = KneeShaper(threshold: 0.6)
    private let ceilingKnee = KneeShaper(threshold: 0.9)

    @inline(__always)
    func softClip(_ x: Float) -> Float {
        Float(stageKnee.shape(Double(x)))
    }

    @inline(__always)
    func softClipADAA(_ x: Float, prev: Float) -> Float {
        softClipADAAStep(x, prev: prev, prevF: nil).out
    }

    @inline(__always)
    func softClipADAAStep(_ x: Float, prev: Float,
                          prevF: Double?) -> (out: Float, f: Double?) {
        let step = stageKnee.step(Double(x), prev: Double(prev), prevResidual: prevF)
        return (Float(step.out), step.residual)
    }

    private func copyOut(_ outList: UnsafeMutableAudioBufferListPointer) {
        var totalChannels = 0
        for buf in outList where buf.mData != nil && buf.mNumberChannels > 0 {
            totalChannels += Int(buf.mNumberChannels)
        }
        let fanOut = inRefs.count == 1
        let mixDown = totalChannels == 1 && inRefs.count >= 2
        var outChan = 0
        for buf in outList {
            guard let raw = buf.mData, buf.mNumberChannels > 0 else { continue }
            let chans = Int(buf.mNumberChannels)
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * chans)
            let data = raw.assumingMemoryBound(to: Float.self)
            for c in 0..<chans {
                if mixDown {
                    let l = inRefs[0], r = inRefs[1]
                    var sl = l.ptr
                    var sr = r.ptr
                    var dst = data + c
                    for _ in 0..<min(frames, min(l.frames, r.frames)) {
                        dst.pointee = 0.5 * (sl.pointee + sr.pointee)
                        dst += chans
                        sl += l.stride
                        sr += r.stride
                    }
                } else if fanOut || outChan < inRefs.count {
                    let ref = inRefs[fanOut ? 0 : outChan]
                    var src = ref.ptr
                    var dst = data + c
                    for _ in 0..<min(frames, ref.frames) {
                        dst.pointee = src.pointee
                        dst += chans
                        src += ref.stride
                    }
                }
                outChan += 1
            }
        }
    }
}
