import AVFoundation
import CoreAudio
import Foundation
import SwiftUI

@MainActor
final class ToneTester: ObservableObject {
    typealias Phase = ToneTestMath.Phase
    typealias Point = ToneTestMath.Point
    typealias Staircase = ToneTestMath.Staircase
    typealias Verdict = ToneTestMath.Verdict

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
    private(set) var sampleRate: Double = ToneTestMath.fallbackRate

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
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
        c.beginEqSession()
        restoreEqEnabled = c.eqEnabled
        sessionGroup = c.eqGroup
        c.setEqEnabled(false, persistToFlash: false, duringSession: true)
        startEngine()
        guard engine.isRunning else {
            c.setEqEnabled(restoreEqEnabled, persistToFlash: false, duringSession: true)
            c.endEqSession()
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
        guard c.byEarSessionActive, c.eqGroup == sessionGroup else { return }
        c.setEqEnabled(restoreEqEnabled, persistToFlash: false, duringSession: true)
    }

    private func endSession(_ c: QudelixController) {
        c.setByEarSessionActive(false)
        phase = .idle
    }

    func abandon(_ c: QudelixController) {
        guard phase == .running, !c.byEarSessionActive else { return }
        let reason = interruption(c) ?? .disconnected
        task?.cancel(); task = nil
        interrupted = nil
        listening = false
        engine.stop()
        note = "Tone test stopped \u{2014} \(reason.reason)."
        endSession(c)
    }

    func startEngine() {
        guard !engine.isRunning else { return }
        engine.attach(player)
        sampleRate = ToneTestMath.plausibleRate(
            engine.outputNode.outputFormat(forBus: 0).sampleRate)
        engine.connect(player, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                             channels: 2))
        engine.prepare()
        try? engine.start()
    }

    private var interrupted: SessionInterruption?

    private func interruption(_ c: QudelixController) -> SessionInterruption? {
        let output = Self.defaultOutputName()
        return ToneTestMath.interruption(
            connected: c.isConnectedNow,
            compatible: c.isCompatible,
            voiceCall: c.isOnVoiceLink,
            eqModeChanged: c.eqGroup != sessionGroup,
            playerRunning: engine.isRunning,
            outputIsDevice: output?.localizedCaseInsensitiveContains("qudelix") ?? false)
            ?? (c.byEarSessionActive ? nil : .disconnected)
    }

    private func runAll(_ c: QudelixController) async {
        for hz in ToneTestMath.order {
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
        let results = ToneTestMath.order.sorted().map { ($0, thresholds[$0] ?? nil) }
        suggestion = ToneTestMath.suggest(results)
        phase = .finished
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
        let samples = ToneTestMath.pulseSamples(hz: hz, dbfs: dbfs, sampleRate: sampleRate,
                                                ms: ms, pulses: pulses, gapMs: gapMs)
        let total = samples.count
        guard total > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(total)),
              let ch = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(total)
        for i in 0..<total {
            ch[0][i] = samples[i]
            ch[1][i] = samples[i]
        }
        return buf
    }

    var readingCount: Int {
        ToneTestMath.readingCount(in: ToneTestMath.order.sorted().map { ($0, thresholds[$0] ?? nil) })
    }

    var measurementFailed: Bool { verdict == .tooFewReadings }

    var deviationSpread: Double { ToneTestMath.spread(of: suggestion) }

    var falsePositiveRate: Double {
        catchPlayed == 0 ? 0 : Double(catchFalsePositives) / Double(catchPlayed)
    }

    var verdict: Verdict {
        ToneTestMath.verdict(readings: readingCount, catchTrials: catchPlayed,
                     falseAlarms: catchFalsePositives, spread: deviationSpread)
    }

    var falseAlarmsElevated: Bool {
        ToneTestMath.falseAlarmsElevated(catchTrials: catchPlayed, falseAlarms: catchFalsePositives)
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
            band.gain = min(max(ToneTestMath.gain(at: Double(band.freq), from: points), -12), 12)
            c.updateBand(i, band, recordUndo: false)
        }
        endSession(c)
    }

}
