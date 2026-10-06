import AVFoundation
import CoreAudio
import Foundation
import SwiftUI

@MainActor
final class ToneTester: ObservableObject {
    nonisolated static let maxLevelDBFS: Double = -12
    nonisolated static let minLevelDBFS: Double = -90

    static func clamp(_ dbfs: Double) -> Double {
        min(max(dbfs, minLevelDBFS), maxLevelDBFS)
    }

    nonisolated static let reference: [Int: Double] = [
        31: 60, 63: 40, 125: 22, 250: 11, 500: 4,
        1000: 2, 2000: -1, 4000: -5, 8000: 2, 16000: 15,
    ]

    static let order = [1000, 2000, 500, 4000, 250, 8000, 125, 16000, 63, 31]

    nonisolated static let minCatchTrials = 6

    nonisolated static let minFalseAlarms = 2

    nonisolated static let unreliableFalseAlarmRate = 1.0 / 3.0

    nonisolated static let cautionFalseAlarmRate = 0.2

    nonisolated static let maxDeviationSpread: Double = 30

    nonisolated static let withinTestNoiseSpread: Double = 8

    enum Phase: Equatable { case idle, running, finished }

    typealias Point = (hz: Int, gain: Double, deviation: Double, measured: Bool)

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentHz = 0
    @Published private(set) var bandsDone = 0
    @Published private(set) var thresholds: [Int: Double?] = [:]
    @Published private(set) var suggestion: [Point] = []
    @Published private(set) var catchPlayed = 0
    @Published private(set) var catchFalsePositives = 0
    @Published private(set) var listening = false
    @Published private(set) var note: String?

    private var heard = false
    private var task: Task<Void, Never>?

    private let engine: AVAudioEngine
    let player = AVAudioPlayerNode()
    private(set) var sampleRate: Double = fallbackRate

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    nonisolated static let fallbackRate: Double = 44100
    nonisolated static let plausibleRates: ClosedRange<Double> = 8000...768000

    nonisolated static func plausibleRate(_ rate: Double) -> Double {
        rate.isFinite && plausibleRates.contains(rate) ? rate : fallbackRate
    }

    enum Blocker: Equatable {
        case notConnected, unsupported, voiceCall, wrongOutput(String)

        var message: String {
            switch self {
            case .notConnected: return "Connect the 5K first."
            case .unsupported: return "This device isn't supported, so nothing can be written."
            case .voiceCall:
                return "The link is in hands-free (voice) mode at 16 kHz — too narrow to "
                    + "measure with. Close whatever is using the microphone."
            case .wrongOutput(let name):
                return "Sound is going to \(name). Choose the Qudelix as the output device."
            }
        }
    }

    static func blocker(_ c: QudelixController) -> Blocker? {
        if case .connected = c.connection {} else { return .notConnected }
        guard c.compatibility == .ok else { return .unsupported }
        if let src = c.inputSource, src.hasPrefix("HFP") { return .voiceCall }
        if c.sampleRate == "16 kHz" { return .voiceCall }
        let out = Self.defaultOutputName() ?? "another device"
        if !out.localizedCaseInsensitiveContains("qudelix") { return .wrongOutput(out) }
        return nil
    }

    static func defaultOutputName() -> String? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &id) == noErr else { return nil }
        var ref: Unmanaged<CFString>?
        var refSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &refSize, &ref) == noErr,
              let r = ref else { return nil }
        return r.takeRetainedValue() as String
    }

    private var restoreEqEnabled = true
    private var sessionGroup: QxEqGroup = .user

    func start(_ c: QudelixController) {
        guard Self.blocker(c) == nil, phase == .idle else { return }
        note = nil
        interrupted = nil
        thresholds = [:]; suggestion = []; bandsDone = 0
        catchPlayed = 0; catchFalsePositives = 0
        restoreEqEnabled = c.eqEnabled
        sessionGroup = c.eqGroup
        c.setEqEnabled(false, persistToFlash: false)
        startEngine()
        guard engine.isRunning else {
            c.setEqEnabled(restoreEqEnabled, persistToFlash: false)
            note = "Couldn't start the tone player, so nothing was measured. Try again."
            return
        }
        c.setByEarSessionActive(true)
        phase = .running
        task = Task { [weak self] in await self?.runAll(c) }
    }

    func stop(_ c: QudelixController) {
        task?.cancel(); task = nil
        listening = false
        engine.stop()
        restoreDevice(c)
        endSession(c)
    }

    func reportHeard() { heard = true }

    private func restoreDevice(_ c: QudelixController) {
        guard c.eqGroup == sessionGroup else { return }
        c.setEqEnabled(restoreEqEnabled, persistToFlash: false)
    }

    private func endSession(_ c: QudelixController) {
        c.setByEarSessionActive(false)
        phase = .idle
    }

    func startEngine() {
        guard !engine.isRunning else { return }
        engine.attach(player)
        sampleRate = Self.plausibleRate(
            engine.outputNode.outputFormat(forBus: 0).sampleRate)
        engine.connect(player, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                             channels: 2))
        engine.prepare()
        try? engine.start()
    }

    private var interrupted: SessionInterruption?

    nonisolated static func interruption(connected: Bool, compatible: Bool,
                                         voiceCall: Bool, eqModeChanged: Bool,
                                         playerRunning: Bool,
                                         outputIsDevice: Bool) -> SessionInterruption? {
        if !connected { return .disconnected }
        if !compatible { return .unsupported }
        if voiceCall { return .voiceCall }
        if eqModeChanged { return .eqModeChanged }
        if !playerRunning { return .playerStopped }
        if !outputIsDevice { return .outputChanged }
        return nil
    }

    private func interruption(_ c: QudelixController) -> SessionInterruption? {
        var connected = false
        if case .connected = c.connection { connected = true }
        let voice = (c.inputSource?.hasPrefix("HFP") ?? false) || c.sampleRate == "16 kHz"
        let output = Self.defaultOutputName()
        return Self.interruption(
            connected: connected,
            compatible: c.compatibility == .ok,
            voiceCall: voice,
            eqModeChanged: c.eqGroup != sessionGroup,
            playerRunning: engine.isRunning,
            outputIsDevice: output?.localizedCaseInsensitiveContains("qudelix") ?? false)
    }

    private func runAll(_ c: QudelixController) async {
        for hz in Self.order {
            if Task.isCancelled { return }
            if let reason = interruption(c) { abort(c, reason); return }
            currentHz = hz
            let t = await threshold(hz: hz, c)
            if let reason = interrupted { abort(c, reason); return }
            thresholds[hz] = t
            bandsDone += 1
        }
        guard !Task.isCancelled else { return }
        finish(c)
    }

    private func abort(_ c: QudelixController, _ reason: SessionInterruption) {
        task = nil
        interrupted = nil
        listening = false
        engine.stop()
        restoreDevice(c)
        note = "Tone test stopped — \(reason.reason)."
        endSession(c)
    }

    private func finish(_ c: QudelixController) {
        listening = false
        engine.stop()
        restoreDevice(c)
        c.setByEarSessionActive(false)
        let results = Self.order.sorted().map { ($0, thresholds[$0] ?? nil) }
        suggestion = Self.suggest(results)
        phase = .finished
    }

    struct Staircase {
        private(set) var level: Double = -40
        private var heardCount: [Double: Int] = [:]
        private var descending = true
        private var missesAtCap = 0

        enum Outcome: Equatable {
            case ask(Double)
            case settled(Double?)
        }

        mutating func answer(_ didHear: Bool) -> Outcome {
            if didHear { heardCount[level, default: 0] += 1 }

            if descending {
                if didHear {
                    if level - 10 < ToneTester.minLevelDBFS { return .settled(level) }
                    level -= 10
                } else {
                    descending = false
                    level += 5
                }
            } else {
                if didHear {
                    missesAtCap = 0
                    if heardCount[level, default: 0] >= 2 { return .settled(level) }
                    level -= 5
                    if level < ToneTester.minLevelDBFS { return .settled(nil) }
                    descending = true
                } else {
                    if level == ToneTester.maxLevelDBFS {
                        missesAtCap += 1
                        if missesAtCap >= 2 { return .settled(nil) }
                    }
                    level = min(level + 5, ToneTester.maxLevelDBFS)
                }
            }
            return .ask(level)
        }

        var bestRepeated: Double? {
            heardCount.filter { $0.value >= 2 }.keys.min()
        }
    }

    private func threshold(hz: Int, _ c: QudelixController) async -> Double? {
        var staircase = Staircase()

        for _ in 0..<34 {
            if Task.isCancelled { return nil }
            if let reason = interruption(c) {
                interrupted = reason
                return nil
            }
            try? await Task.sleep(for: .milliseconds(Int.random(in: 400...1300)))
            if Int.random(in: 0..<5) == 0 {
                catchPlayed += 1
                if await present(hz: hz, level: nil) { catchFalsePositives += 1 }
                continue
            }

            let didHear = await present(hz: hz, level: staircase.level)
            if case .settled(let t) = staircase.answer(didHear) { return t }
        }
        return staircase.bestRepeated
    }

    private func present(hz: Int, level: Double?) async -> Bool {
        heard = false
        listening = true
        if let level, engine.isRunning, let buf = buffer(hz: Double(hz), dbfs: level) {
            player.scheduleBuffer(buf, at: nil, options: [],
                                  completionCallbackType: .dataPlayedBack) { _ in }
            if !player.isPlaying { player.play() }
        }
        try? await Task.sleep(for: .milliseconds(1250))
        listening = false
        return heard
    }

    func buffer(hz: Double, dbfs: Double, ms: Int = 220,
                pulses: Int = 3, gapMs: Int = 120) -> AVAudioPCMBuffer? {
        let amp = pow(10.0, Self.clamp(dbfs) / 20.0)
        let onFrames = Int(Double(ms) / 1000 * sampleRate)
        let gapFrames = Int(Double(gapMs) / 1000 * sampleRate)
        let total = pulses * onFrames + (pulses - 1) * gapFrames
        guard total > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(total)),
              let ch = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(total)

        let ramp = max(1, min(Int(0.025 * sampleRate), onFrames / 4))
        let twoPi = 2.0 * Double.pi
        let inc = twoPi * hz / sampleRate
        var phase = 0.0
        var cursor = 0
        for p in 0..<pulses {
            for i in 0..<onFrames {
                var env = 1.0
                if i < ramp {
                    env = 0.5 * (1 - cos(Double.pi * Double(i) / Double(ramp)))
                } else if i >= onFrames - ramp {
                    let k = onFrames - i - 1
                    env = 0.5 * (1 - cos(Double.pi * Double(k) / Double(ramp)))
                }
                let s = Float(amp * env * sin(phase))
                phase += inc
                if phase > twoPi { phase -= twoPi }
                ch[0][cursor + i] = s
                ch[1][cursor + i] = s
            }
            cursor += onFrames + (p < pulses - 1 ? gapFrames : 0)
        }
        return buf
    }

    static func suggest(_ results: [(Int, Double?)], fraction: Double = 0.4,
                        cap: Double = 6) -> [Point] {
        var devs: [(Int, Double)] = []
        for (hz, t) in results {
            guard let t, let ref = reference[hz] else { continue }
            devs.append((hz, t - ref))
        }
        guard devs.count >= minThresholds else { return [] }
        let mean = devs.map(\.1).reduce(0, +) / Double(devs.count)

        return results.map { (hz, t) in
            guard let t, let ref = reference[hz] else { return (hz, 0, 0, false) }
            let dev = (t - ref) - mean
            return (hz, min(max(dev * fraction, -cap), cap), dev, true)
        }
    }

    nonisolated static let minThresholds = 3

    var readingCount: Int {
        Self.readingCount(in: Self.order.sorted().map { ($0, thresholds[$0] ?? nil) })
    }

    nonisolated static func readingCount(in results: [(Int, Double?)]) -> Int {
        results.filter { $0.1 != nil && reference[$0.0] != nil }.count
    }

    var measurementFailed: Bool { verdict == .tooFewReadings }

    var deviationSpread: Double { Self.spread(of: suggestion) }

    nonisolated static func spread(of points: [Point]) -> Double {
        let ds = points.filter(\.measured).map(\.deviation)
        guard let lo = ds.min(), let hi = ds.max() else { return 0 }
        return hi - lo
    }

    var falsePositiveRate: Double {
        catchPlayed == 0 ? 0 : Double(catchFalsePositives) / Double(catchPlayed)
    }

    enum Verdict: Equatable {
        case tooFewReadings
        case unreliable
        case tooScattered(spread: Double)
        case withinTestNoise
        case usable
    }

    var verdict: Verdict {
        Self.verdict(readings: readingCount, catchTrials: catchPlayed,
                     falseAlarms: catchFalsePositives, spread: deviationSpread)
    }

    nonisolated static func verdict(readings: Int, catchTrials: Int,
                                    falseAlarms: Int, spread: Double) -> Verdict {
        if readings < minThresholds { return .tooFewReadings }
        if catchTrials >= minCatchTrials, falseAlarms >= minFalseAlarms,
           rate(falseAlarms, of: catchTrials) >= unreliableFalseAlarmRate {
            return .unreliable
        }
        if spread > maxDeviationSpread { return .tooScattered(spread: spread) }
        if spread < withinTestNoiseSpread { return .withinTestNoise }
        return .usable
    }

    var falseAlarmsElevated: Bool {
        Self.falseAlarmsElevated(catchTrials: catchPlayed, falseAlarms: catchFalsePositives)
    }

    nonisolated static func falseAlarmsElevated(catchTrials: Int, falseAlarms: Int) -> Bool {
        let r = rate(falseAlarms, of: catchTrials)
        return catchTrials >= minCatchTrials && falseAlarms >= minFalseAlarms
            && r > cautionFalseAlarmRate && r < unreliableFalseAlarmRate
    }

    private nonisolated static func rate(_ alarms: Int, of trials: Int) -> Double {
        trials == 0 ? 0 : Double(alarms) / Double(trials)
    }

    func applySuggestion(_ c: QudelixController) {
        guard verdict == .usable else { return }
        c.setEqEnabled(true)
        c.beginUndoStep("hearing correction")
        let points = suggestion.filter(\.measured)
            .map { (hz: Double($0.hz), gain: $0.gain) }
            .sorted { $0.hz < $1.hz }
        guard !points.isEmpty else { endSession(c); return }
        for i in 0..<min(c.bandCount, c.bands.count)
        where c.bands[i].filter.rendersGain {
            var band = c.bands[i]
            band.gain = min(max(Self.gain(at: Double(band.freq), from: points), -12), 12)
            c.updateBand(i, band, recordUndo: false)
        }
        endSession(c)
    }

    static func gain(at hz: Double, from points: [(hz: Double, gain: Double)]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if hz <= first.hz { return first.gain }
        if hz >= last.hz { return last.gain }
        for i in 1..<points.count where hz <= points[i].hz {
            let lo = points[i - 1], hi = points[i]
            guard hi.hz > lo.hz else { return hi.gain }
            let t = (log10(hz) - log10(lo.hz)) / (log10(hi.hz) - log10(lo.hz))
            return lo.gain + t * (hi.gain - lo.gain)
        }
        return last.gain
    }
}
