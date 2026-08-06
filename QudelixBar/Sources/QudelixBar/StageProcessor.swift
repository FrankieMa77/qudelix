import CoreAudio
import Foundation
import os.lock

/// Normalised biquad coefficients (a0 divided out), designed in double
/// precision — 32-bit state audibly quantizes on low-frequency sections.
struct BiquadSection {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    /// Peaking filter with a matched (impulse-invariant) design — Vicanek,
    /// "Matched Second Order Digital Filters" (2016), §3.2 + §4.4. Unlike the
    /// bilinear transform it doesn't cramp the bandwidth toward Nyquist, so a
    /// treble bell at 44.1 kHz is still the curve it claims to be.
    static func peak(freq: Double, gainDb: Double, q: Double,
                     sampleRate: Double) -> BiquadSection {
        let f0 = max(10, min(freq, sampleRate / 2 - 1))
        let Q = max(0.05, q)
        let G = pow(10, gainDb / 20)
        let w0 = 2 * Double.pi * f0 / sampleRate
        // Pole damping from the prototype's denominator (eq. 42):
        // s·ω0/(√G·Q) ⇒ q = 1/(2·Q·√G). The √G is load-bearing — dropping it
        // fits boosts by luck and audibly mis-shapes cuts.
        let qp = 1 / (2 * Q * sqrt(G))

        // Poles by impulse invariance (eq. 12).
        let expqw = exp(-qp * w0)
        let a1: Double
        if qp <= 1 {
            a1 = -2 * expqw * cos(sqrt(1 - qp * qp) * w0)
        } else {
            a1 = -2 * expqw * cosh(sqrt(qp * qp - 1) * w0)
        }
        let a2 = exp(-2 * qp * w0)

        // Helper quantities at w0 (eqs. 26–27).
        let sinHalf = sin(w0 / 2)
        let phi1 = sinHalf * sinHalf
        let phi0 = 1 - phi1
        let phi2 = 4 * phi0 * phi1
        let A0 = (1 + a1 + a2) * (1 + a1 + a2)
        let A1 = (1 - a1 + a2) * (1 - a1 + a2)
        let A2 = -4 * a2

        // Peaking numerator: unity at DC, |H| = G and extremum at w0
        // (eqs. 43–45).
        let G2 = G * G
        let B0 = A0
        let R1 = (A0 * phi0 + A1 * phi1 + A2 * phi2) * G2
        let R2 = (-A0 + A1 + 4 * (phi0 - phi1) * A2) * G2
        let B2 = (R1 - R2 * phi1 - B0) / (4 * phi1 * phi1)
        let B1 = R2 + B0 + 4 * (phi1 - phi0) * B2

        // Minimum-phase recovery (eqs. 28–29). B1 can dip epsilon-negative
        // through cancellation; clamp before the root.
        let sqB0 = 1 + a1 + a2
        let sqB1 = sqrt(max(0, B1))
        let W = 0.5 * (sqB0 + sqB1)
        let b0 = 0.5 * (W + sqrt(max(0, W * W + B2)))
        let b1 = 0.5 * (sqB0 - sqB1)
        let b2 = -B2 / (4 * b0)
        return BiquadSection(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2)
    }

    /// RBJ cookbook high shelf.
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
}

/// The realtime DSP core behind the Stage and Level features: the Soundstage
/// chain plus the level meter, applied to whatever passes through the render
/// callback.
///
/// Two threads touch this object. The main thread calls `apply`/`prepare`,
/// which redesign the parameters; the HAL render thread calls `render`. They
/// meet only at a snapshot of the `Config` value taken under an unfair lock —
/// held for a copy, never across the sample loop — so the render thread never
/// waits on filter design.
///
/// All render-side state (delay lines, filter memories) is preallocated at a
/// fixed ceiling so the render path performs no allocation once running.
final class StageProcessor {
    struct Config {
        /// Hard silence: the output stays zeroed. Used while a tone session
        /// wants the system mix out of the way.
        var muted = false
        /// Meter only: measure the input and write nothing to the output.
        /// Used when Level tracking runs without the Stage — the tap is
        /// unmuted in that mode, so the original audio is what's heard and
        /// echoing it into the output would double it.
        var monitorOnly = false
        var stage = StageParams()
    }

    /// Designed (render-ready) form of StageSettings. Geometry — reflection
    /// offsets, crossfeed delay, tail lengths — lives here rather than in
    /// render-side state, so Distance/Span/Size edits swap in through the
    /// same graveyarded snapshot as everything else.
    struct StageParams {
        var enabled = false
        var sideGain: Float = 1        // width/100
        /// High-shelf on the side channel, scaled with width: brilliance in
        /// the sides is what the ear reads as "wide", beyond raw level.
        var sideShelf: BiquadSection?
        var centerGain: Float = 1      // mid level; cramped = center-heavy
        var dryGain: Float = 1         // eases with distance
        var crossGain: Float = 0       // 0…0.35
        var crossDirect: Float = 1     // loudness compensation for the blend
        var crossDelaySamples: Int = 14
        var crossLPCoef: Float = 0.09
        var dialogue: BiquadSection?   // mid-only presence peak
        var roomWet: Float = 0         // 0…0.8
        var tailFeedback: Float = 0    // 0…0.45, the diffuse tail's decay
        var earlyL: [(cross: Bool, offset: Int, gain: Float)] = []
        var earlyR: [(cross: Bool, offset: Int, gain: Float)] = []
        var tailLenL: Int = 2543
        var tailLenR: Int = 2963
        /// Night mode: gentle level convergence toward a comfort level —
        /// quiet dialogue up, explosions down. 0 = off, 1 = strongest.
        var night: Float = 0
        /// Mild static headroom; the soft clipper catches the rare peaks so
        /// loudness doesn't have to be sacrificed to the worst case.
        var trim: Float = 1
    }

    static let maxChannels = 32

    /// Heap-allocated: passing `&property` of a class to the C lock functions
    /// has no guaranteed stable address under Swift's exclusivity rules; a
    /// pointer that never moves does.
    private let lock: UnsafeMutablePointer<os_unfair_lock_s> = {
        let p = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock_s())
        return p
    }()
    private var config = Config()
    /// Recently-replaced configs, kept alive so the *last* release of a
    /// config's arrays can never happen on the render thread (a last release
    /// is a heap free, and free has no place in an IO cycle) nor inside the
    /// lock. Trimmed on the main thread, well after any in-flight render.
    private var retiredConfigs: [Config] = []

    deinit {
        lock.deallocate()
        meterLock.deallocate()
    }

    private var sampleRate: Double = 48000
    private var stageSettings = StageSettings()
    private var muted = false
    private var monitorOnly = false

    // MARK: Control side

    /// Set the design rate. Called once when the engine starts, before any
    /// render, with the output device's nominal rate. Everything
    /// rate-dependent is laid out here, while no IOProc is running — the
    /// render thread never allocates.
    func prepare(sampleRate: Double) {
        self.sampleRate = max(8000, sampleRate)

        roomLPCoef = Float(1 - exp(-2 * Double.pi * 3500 / self.sampleRate))

        // Night-mode envelope times: ~5 ms attack, ~150 ms release.
        nightAtk = Float(1 - exp(-1 / (0.005 * self.sampleRate)))
        nightRel = Float(1 - exp(-1 / (0.15 * self.sampleRate)))

        // A rate change re-times every ring; stale contents would replay
        // pitch-shifted. No IOProc runs during prepare, so this is safe.
        resetStageState()
        stageEngaged = false

        redesign()
    }

    /// Update the Soundstage. The new design swaps in atomically.
    func applyStage(_ settings: StageSettings) {
        stageSettings = settings.clamped()
        redesign()
    }

    /// Silence the output entirely (a tone session needs a quiet channel).
    func setMuted(_ muted: Bool) {
        self.muted = muted
        redesign()
    }

    /// Meter without touching the audio path (Level tracking on its own).
    func setMonitorOnly(_ monitor: Bool) {
        monitorOnly = monitor
        redesign()
    }

    private func designStage() -> StageParams {
        var p = StageParams()
        let s = stageSettings
        guard s.enabled else { return p }
        p.enabled = true
        p.sideGain = Float(s.width / 100)
        if s.width > 105 {
            // Up to +4 dB of side brilliance at 200% — width the ear believes.
            let shelfDb = min(4, (s.width - 100) / 100 * 4)
            p.sideShelf = BiquadSection.highShelf(freq: 700, gainDb: shelfDb,
                                                  q: 0.71, sampleRate: sampleRate)
        }
        p.centerGain = Float(pow(10, s.centerValue / 20))
        p.dryGain = Float(1 - 0.15 * s.distanceValue)

        // Span: the virtual speaker angle. Narrow = short interaural delay
        // and bright shadow; wide = longer delay, darker shadow.
        let delayMs = 0.18 + 0.5 * s.spanValue          // 0.18…0.68 ms
        p.crossDelaySamples = max(1, min(Self.crossBufSize - 1,
                                         Int(delayMs / 1000 * sampleRate)))
        let shadowHz = 900 - 400 * s.spanValue          // 900…500 Hz
        p.crossLPCoef = Float(1 - exp(-2 * Double.pi * shadowHz / sampleRate))
        p.crossGain = Float(s.crossfeed) * 0.35
        p.crossDirect = 1 / (1 + p.crossGain * 0.7)

        if s.dialogue > 0.05 {
            p.dialogue = BiquadSection.peak(freq: 2500, gainDb: s.dialogue,
                                            q: 0.9, sampleRate: sampleRate)
        }

        // Room geometry: Size scales every path length, Distance pre-delays
        // the whole field so the first reflection arrives from farther away.
        let scale = 0.6 + s.sizeValue                    // 0.6…1.6
        let predelay = Int(s.distanceValue * 0.022 * sampleRate)
        func taps(_ spec: [(Bool, Double, Float)]) -> [(cross: Bool, offset: Int, gain: Float)] {
            spec.map { cross, ms, gain in
                (cross: cross,
                 offset: min(Self.roomBufSize - 1,
                             Int(ms * scale / 1000 * sampleRate) + predelay),
                 gain: gain)
            }
        }
        p.earlyL = taps([(true, 17, 0.80), (false, 23, 0.50), (true, 31, 0.45), (false, 43, 0.32)])
        p.earlyR = taps([(true, 19, 0.80), (false, 29, 0.50), (true, 37, 0.45), (false, 47, 0.32)])
        p.tailLenL = max(64, min(Self.tailBufSize - 1, Int(0.053 * scale * sampleRate)))
        p.tailLenR = max(64, min(Self.tailBufSize - 1, Int(0.061 * scale * sampleRate)))
        p.roomWet = Float(s.room) * 0.8
        p.tailFeedback = Float(s.room) * 0.45
        p.night = Float(s.nightValue)
        // Mild static headroom only — the render-side soft clipper absorbs
        // the rare true peak, so the stage doesn't buy safety with loudness.
        let excess = max(0, p.sideGain - 1) * 0.35 + p.roomWet * 0.3
        p.trim = 1 / (1 + excess * 0.5)
        return p
    }

    private func redesign() {
        var next = Config()
        next.muted = muted
        next.monitorOnly = monitorOnly
        next.stage = designStage()
        retiredConfigs.append(config)   // keep the old one alive past the swap
        os_unfair_lock_lock(lock)
        config = next
        os_unfair_lock_unlock(lock)
        // Depth 32: a render callback outlives at most a handful of UI-paced
        // redesigns, so dozens of generations of headroom make the "render
        // thread takes the last reference" window unreachable in practice.
        if retiredConfigs.count > 32 {
            retiredConfigs.removeFirst(retiredConfigs.count - 32)
        }
    }

    // MARK: Level metering

    /// Accumulated by the render thread, drained once a second by the UI.
    /// Separate lock from the config one so the meter can't ever delay a
    /// parameter snapshot.
    private let meterLock: UnsafeMutablePointer<os_unfair_lock_s> = {
        let p = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock_s())
        return p
    }()
    private var meterSumSquares: Double = 0
    private var meterFrames: Int = 0

    /// What the last render cycle actually saw — the ground truth for "is
    /// the stage really running", readable from the control thread.
    private var diagChannels: Int32 = 0
    private var diagStageRan: Bool = false
    // Source L/R correlation accumulators (pre-stage): mono content defeats
    // width and crossfeed by design, and the UI should say so, not shrug.
    private var corrLR: Double = 0
    private var corrLL: Double = 0
    private var corrRR: Double = 0

    func renderDiagnostics() -> (channels: Int, stageRan: Bool) {
        os_unfair_lock_lock(meterLock)
        defer { os_unfair_lock_unlock(meterLock) }
        return (Int(diagChannels), diagStageRan)
    }

    /// Correlation of the source's first two channels since the last call.
    /// +1 = mono, 0 = fully independent. nil while too quiet to judge.
    func drainSourceCorrelation() -> Double? {
        os_unfair_lock_lock(meterLock)
        defer { os_unfair_lock_unlock(meterLock) }
        let (lr, ll, rr) = (corrLR, corrLL, corrRR)
        corrLR = 0; corrLL = 0; corrRR = 0
        guard ll > 1e-6, rr > 1e-6 else { return nil }
        return lr / (ll * rr).squareRoot()
    }

    /// Returns and resets the accumulated signal energy. Main thread.
    func drainMeter() -> (sumSquares: Double, frames: Int) {
        os_unfair_lock_lock(meterLock)
        defer { os_unfair_lock_unlock(meterLock) }
        let result = (meterSumSquares, meterFrames)
        meterSumSquares = 0
        meterFrames = 0
        return result
    }

    // MARK: Render side (HAL IO thread only)

    // Soundstage render state. Ring buffers are powers of two so the render
    // loop wraps with a mask instead of a modulo; all fixed-size, allocated
    // once, big enough for any sample rate a device reports.
    static let crossBufSize = 512          // covers the 0.68 ms max Span delay up to ~750 kHz
    static let roomBufSize = 16384         // 41 ms up to ~400 kHz
    private var crossDelayL = [Float](repeating: 0, count: crossBufSize)
    private var crossDelayR = [Float](repeating: 0, count: crossBufSize)
    private var crossIdx = 0
    private var crossLPl: Float = 0
    private var crossLPr: Float = 0
    private var dialogueZ1: Double = 0
    private var dialogueZ2: Double = 0
    private var sideShelfZ1: Double = 0
    private var sideShelfZ2: Double = 0
    // Two reflection buses (true stereo: each ear's reflections draw mostly
    // from the OPPOSITE channel — that cross-pattern is what envelopment is),
    // plus one damped feedback comb per ear for a short diffuse tail.
    private var roomBufL = [Float](repeating: 0, count: roomBufSize)
    private var roomBufR = [Float](repeating: 0, count: roomBufSize)
    private var roomIdx = 0
    static let tailBufSize = 8192
    private var tailBufL = [Float](repeating: 0, count: tailBufSize)
    private var tailBufR = [Float](repeating: 0, count: tailBufSize)
    private var tailIdxL = 0
    private var tailIdxR = 0
    private var tailLPL: Float = 0
    private var tailLPR: Float = 0
    private var roomLPCoef: Float = 0.3
    private var roomLPStateL: Float = 0
    private var roomLPStateR: Float = 0

    // Night-mode envelope (stage render state). Rests at the comfort level,
    // not at silence — an envelope resting near zero makes every stage
    // engage open with a burst until the attack catches up.
    private var nightEnv: Double = 0.05
    private var nightAtk: Float = 0.008
    private var nightRel: Float = 0.0006

    /// False while the stage is idle; the first engaged render wipes the
    /// rings and filter states so hours-old audio can't replay out of
    /// frozen buffers.
    private var stageEngaged = false

    /// Render thread (engage edge) or control thread with no IOProc running
    /// (prepare). ~50k float stores — trivial as a one-shot, and the price
    /// of never hearing a ghost.
    private func resetStageState() {
        for i in 0..<Self.crossBufSize { crossDelayL[i] = 0; crossDelayR[i] = 0 }
        for i in 0..<Self.roomBufSize { roomBufL[i] = 0; roomBufR[i] = 0 }
        for i in 0..<Self.tailBufSize { tailBufL[i] = 0; tailBufR[i] = 0 }
        crossIdx = 0; roomIdx = 0; tailIdxL = 0; tailIdxR = 0
        crossLPl = 0; crossLPr = 0; tailLPL = 0; tailLPR = 0
        roomLPStateL = 0; roomLPStateR = 0
        sideShelfZ1 = 0; sideShelfZ2 = 0
        dialogueZ1 = 0; dialogueZ2 = 0
        nightEnv = 0.05
    }

    private var inRefs: [(ptr: UnsafeMutablePointer<Float>, stride: Int, frames: Int)] = {
        var a = [(ptr: UnsafeMutablePointer<Float>, stride: Int, frames: Int)]()
        a.reserveCapacity(maxChannels)
        return a
    }()

    /// Called for every IO cycle of the aggregate device. The input buffers
    /// carry the tap's capture of everything the system is playing; whatever
    /// is written to the output buffers is what actually reaches the
    /// hardware. Everything here assumes Float32 samples, which is what taps
    /// deliver and what every macOS output device presents at the HAL client
    /// level.
    func render(input: UnsafePointer<AudioBufferList>,
                output: UnsafeMutablePointer<AudioBufferList>) {
        os_unfair_lock_lock(lock)
        let cfg = config
        os_unfair_lock_unlock(lock)

        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        for buf in outList where buf.mData != nil {
            memset(buf.mData, 0, Int(buf.mDataByteSize))
        }

        // Locate each input channel; the stage filters them in place.
        inRefs.removeAll(keepingCapacity: true)
        for buf in inList {
            guard let raw = buf.mData, buf.mNumberChannels > 0 else { continue }
            let chans = Int(buf.mNumberChannels)
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * chans)
            let data = raw.assumingMemoryBound(to: Float.self)
            for c in 0..<chans where inRefs.count < Self.maxChannels {
                inRefs.append((ptr: data + c, stride: chans, frames: frames))
            }
        }

        // Muted: leave the zeroed output as-is. The tap keeps running so the
        // pipeline (and its permission grant) stays warm. Diagnostics still
        // update ("what render last saw" must not lie during a tone test),
        // and the stage disengages so unmute starts from silence, not from
        // pre-mute leftovers.
        if cfg.muted {
            os_unfair_lock_lock(meterLock)
            diagChannels = Int32(inRefs.count)
            diagStageRan = false
            os_unfair_lock_unlock(meterLock)
            stageEngaged = false
            return
        }

        guard !inRefs.isEmpty else { return }

        // Source stereo-ness, measured before the stage touches anything.
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

        // The Soundstage needs the stereo pair frame-locked, so it iterates
        // L and R together. Never in monitor mode: the tap is unmuted there,
        // so the buffers are a copy of what's already playing, not the path
        // the listener hears.
        let stageRan = cfg.stage.enabled && inRefs.count >= 2 && !cfg.monitorOnly
        if stageRan {
            if !stageEngaged {
                resetStageState()
                stageEngaged = true
            }
            renderStage(cfg.stage)
        } else {
            stageEngaged = false
        }
        os_unfair_lock_lock(meterLock)
        diagChannels = Int32(inRefs.count)
        diagStageRan = stageRan
        corrLR += cLR; corrLL += cLL; corrRR += cRR
        os_unfair_lock_unlock(meterLock)

        // Meter what actually reaches the ears: post-stage in insert mode,
        // the system mix as-is in monitor mode. Channel 0 is representative;
        // stereo differences don't matter at one-second resolution.
        if let first = inRefs.first {
            var ss = 0.0
            var p = first.ptr
            for _ in 0..<first.frames {
                let v = Double(p.pointee)
                ss += v * v
                p += first.stride
            }
            os_unfair_lock_lock(meterLock)
            meterSumSquares += ss
            meterFrames += first.frames
            os_unfair_lock_unlock(meterLock)
        }

        // Monitor mode writes nothing: the original audio is still playing
        // directly, and echoing the capture into the output would double it.
        guard !cfg.monitorOnly else { return }

        // Copy the processed channels out. Extra output channels repeat the
        // last input channel (mono tap → both earpieces) rather than staying
        // silent.
        copyOut(outList)
    }

    /// The Soundstage: mid/side width with a mid-only dialogue lift,
    /// interaural crossfeed, and sparse early reflections. In place on the
    /// first two channels; identical L/R content passes width untouched
    /// (its side channel is zero), which keeps mono material honest.
    private func renderStage(_ p: StageParams) {
        let l = inRefs[0], r = inRefs[1]
        let frames = min(l.frames, r.frames)
        let crossMask = Self.crossBufSize - 1
        let roomMask = Self.roomBufSize - 1
        var pl = l.ptr, pr = r.ptr

        for _ in 0..<frames {
            var L = pl.pointee, R = pr.pointee

            // Width, and dialogue on the mid only. The side additionally gets
            // a width-scaled brilliance shelf: high-frequency side energy is
            // the strongest "wide" cue the ear has.
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

            // Crossfeed: each ear hears a delayed, darkened copy of the
            // other channel — the cue that moves sound out of the skull.
            // Delay and darkness come from the Span control (speaker angle).
            // The delay lines run whenever the stage does (only the blend is
            // gated), so dragging Crossfeed up from zero blends in *current*
            // audio, not whatever was frozen in the ring. No feedback path:
            // rings are written pre-blend.
            crossDelayL[crossIdx] = L
            crossDelayR[crossIdx] = R
            let read = (crossIdx - p.crossDelaySamples) & crossMask
            crossLPl += p.crossLPCoef * (crossDelayR[read] - crossLPl)
            crossLPr += p.crossLPCoef * (crossDelayL[read] - crossLPr)
            crossIdx = (crossIdx + 1) & crossMask
            if p.crossGain > 0 {
                L = L * p.crossDirect + crossLPl * p.crossGain
                R = R * p.crossDirect + crossLPr * p.crossGain
            }

            // Room: per-ear early reflections drawn from both channels
            // (mostly the opposite one), plus a short damped comb tail per
            // ear. Cross-pattern + mismatched tails = envelopment, not echo.
            // Like the crossfeed, the field runs whenever the stage does —
            // only the wet mix is gated — so Room fades in current audio.
            // Reads are indexed straight off the stored arrays (no local
            // array binding) so no reference can ever overlap a write and
            // trigger a copy-on-write on the render thread.
            roomLPStateL += roomLPCoef * (L - roomLPStateL)
            roomLPStateR += roomLPCoef * (R - roomLPStateR)
            roomBufL[roomIdx] = roomLPStateL
            roomBufR[roomIdx] = roomLPStateR
            var wl: Float = 0, wr: Float = 0
            for tap in p.earlyL {
                let idx = (roomIdx - tap.offset) & roomMask
                wl += (tap.cross ? roomBufR[idx] : roomBufL[idx]) * tap.gain
            }
            for tap in p.earlyR {
                let idx = (roomIdx - tap.offset) & roomMask
                wr += (tap.cross ? roomBufL[idx] : roomBufR[idx]) * tap.gain
            }
            roomIdx = (roomIdx + 1) & roomMask

            // Diffuse tail: damped feedback combs fed by the early field.
            // Indices re-wrap against the config's lengths so a Size edit
            // mid-flight can't read past a shortened loop.
            if tailIdxL >= p.tailLenL { tailIdxL = 0 }
            if tailIdxR >= p.tailLenR { tailIdxR = 0 }
            let outL = tailBufL[tailIdxL]
            let outR = tailBufR[tailIdxR]
            tailLPL += 0.35 * ((wl + outL * p.tailFeedback) - tailLPL)
            tailLPR += 0.35 * ((wr + outR * p.tailFeedback) - tailLPR)
            tailBufL[tailIdxL] = tailLPL
            tailBufR[tailIdxR] = tailLPR
            tailIdxL = (tailIdxL + 1) % p.tailLenL
            tailIdxR = (tailIdxR + 1) % p.tailLenR

            if p.roomWet > 0 {
                L += (wl + outL * 0.6) * p.roomWet
                R += (wr + outR * 0.6) * p.roomWet
            }

            // Night mode: converge levels toward a comfort point. Quiet
            // dialogue comes up, action comes down; the slow release keeps
            // it from pumping.
            if p.night > 0 {
                let lvl = (abs(L) + abs(R)) * 0.5
                let coef = Double(lvl) > nightEnv ? nightAtk : nightRel
                nightEnv += Double(coef) * (Double(lvl) - nightEnv)
                let levelDb = 20 * log10(Float(max(nightEnv, 1e-5)))
                // Gate: inter-track noise and silence get no ride up.
                var gDb: Float = 0
                if levelDb > -50 {
                    gDb = (-26 - levelDb) * 0.5 * p.night
                    gDb = min(8 * p.night, max(-10 * p.night, gDb))
                }
                let g = pow(10, gDb / 20)
                L *= g
                R *= g
            }

            // Soft clip instead of hard headroom: unity below ~0.5, gentle
            // saturation above, so theatrical levels survive the widening.
            L = softClip(L * p.trim)
            R = softClip(R * p.trim)
            pl.pointee = L
            pr.pointee = R
            pl += l.stride
            pr += r.stride
        }
    }

    /// Padé tanh approximation: transparent at normal levels, saturating
    /// smoothly toward ±1.7 — never lets a widened peak slam the DAC.
    @inline(__always)
    private func softClip(_ x: Float) -> Float {
        let c = min(max(x, -3), 3)
        return c * (27 + c * c) / (27 + 9 * c * c)
    }

    private func copyOut(_ outList: UnsafeMutableAudioBufferListPointer) {
        var outChan = 0
        for buf in outList {
            guard let raw = buf.mData, buf.mNumberChannels > 0 else { continue }
            let chans = Int(buf.mNumberChannels)
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * chans)
            let data = raw.assumingMemoryBound(to: Float.self)
            for c in 0..<chans {
                let ref = inRefs[min(outChan, inRefs.count - 1)]
                var src = ref.ptr
                var dst = data + c
                for _ in 0..<min(frames, ref.frames) {
                    dst.pointee = src.pointee
                    dst += chans
                    src += ref.stride
                }
                outChan += 1
            }
        }
    }
}
