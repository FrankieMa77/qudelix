import Foundation

package struct TonePoint: Equatable {
    package var hz: Int
    package var gain: Double
    package var deviation: Double
    package var measured: Bool
}

package enum ToneTestVerdict: Equatable {
    case tooFewReadings
    case unreliable
    case tooScattered(Double)
    case withinTestNoise
    case usable
}

final class ToneSource: @unchecked Sendable {
    static let capacity = 800_000

    private let lock = RTLock()
    private let buffer: UnsafeMutablePointer<Float>
    private var count = 0
    private var cursor = 0

    init() {
        buffer = UnsafeMutablePointer<Float>.allocate(capacity: Self.capacity)
        buffer.initialize(repeating: 0, count: Self.capacity)
    }

    deinit {
        buffer.deallocate()
        lock.destroy()
    }

    func load(_ samples: [Float]) {
        let used = min(samples.count, Self.capacity)
        lock.lock()
        for index in 0..<used { buffer[index] = samples[index] }
        count = used
        cursor = 0
        lock.unlock()
    }

    func clear() {
        lock.lock()
        count = 0
        cursor = 0
        lock.unlock()
    }

    func render(_ output: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        guard frames > 0, channels > 0 else { return }
        lock.lock()
        var position = cursor
        let limit = count
        for frame in 0..<frames {
            var value: Float = 0
            if position < limit {
                value = buffer[position]
                position += 1
            }
            let base = frame * channels
            for channel in 0..<channels { output[base + channel] = value }
        }
        cursor = position
        lock.unlock()
    }
}

@MainActor
final class ToneTestModel {
    typealias Phase = ToneTestMath.Phase
    typealias Staircase = ToneTestMath.Staircase

    enum Blocker: Equatable {
        case notConnected, unsupported, voiceCall, noOutput, wrongOutput(String), overAmplified

        var message: String {
            switch self {
            case .notConnected: return "Connect the 5K first."
            case .unsupported: return "This device isn't supported, so nothing can be written."
            case .voiceCall:
                return "The link is in hands-free (voice) mode at 16 kHz \u{2014} too narrow to "
                    + "measure with. Close whatever is using the microphone."
            case .noOutput:
                return "No audio output is available, so the tones cannot play."
            case .wrongOutput(let name):
                return "Sound is going to \(name). Choose the Qudelix as the output device."
            case .overAmplified:
                return "The output volume is above 100 %, which could make the tones far too loud. "
                    + "Lower it to 100 % or less in Sound settings first."
            }
        }
    }

    static let levelCaution = "Set your usual listening volume first; the loudest tone is \u{2212}12 dBFS."
    static let maxSinkGain: Float = 1.001
    static let playerDeadlinePolls = 40
    static let playerPollMs = 50

    private let host: LinuxEqHost
    private let routing: OutputRouting?
    private let backend: LinuxAudioBackend?
    private weak var stage: StageModel?
    private let source = ToneSource()

    var sleepMs: @MainActor (Int) async -> Void = { ms in
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }
    var randomPause: () -> Int = { Int.random(in: 400...1300) }
    var randomCatch: () -> Bool = { Int.random(in: 0..<5) == 0 }
    var onChange: (() -> Void)?

    private(set) var phase: Phase = .idle
    private(set) var currentHz = 0
    private(set) var bandsDone = 0
    private(set) var thresholds: [Int: Double?] = [:]
    private(set) var suggestion: [ToneTestMath.Point] = []
    private(set) var catchPlayed = 0
    private(set) var catchFalsePositives = 0
    private(set) var listening = false
    private(set) var note: String?
    private(set) var lastPresented: (hz: Int, level: Double?)?
    private(set) var sampleRate = ToneTestMath.fallbackRate
    private(set) var playingSink: String?

    private var heard = false
    private var task: Task<Void, Never>?
    private var handle: AudioStreamHandle?
    private var restoreEqEnabled = true
    private var sessionGroup: QxEqGroup = .user
    private var interrupted: SessionInterruption?

    init(host: LinuxEqHost, routing: OutputRouting?, backend: LinuxAudioBackend?, stage: StageModel?) {
        self.host = host
        self.routing = routing
        self.backend = backend
        self.stage = stage
    }

    var blocker: Blocker? {
        guard host.isConnectedNow else { return .notConnected }
        guard host.isCompatible else { return .unsupported }
        if host.isOnVoiceLink || host.activeCall == true { return .voiceCall }
        guard let routing, backend != nil else { return .noOutput }
        guard let output = routing.realOutput else { return .noOutput }
        guard output.isQudelix5K else {
            return .wrongOutput(output.description.isEmpty ? output.name : output.description)
        }
        if let level = backend?.sinkVolume(named: output.name), level.gain > Self.maxSinkGain {
            return .overAmplified
        }
        return nil
    }

    func start() {
        guard blocker == nil, phase == .idle, let routing, let backend,
              let output = routing.realOutput else { return }
        note = nil
        interrupted = nil
        thresholds = [:]
        suggestion = []
        bandsDone = 0
        catchPlayed = 0
        catchFalsePositives = 0
        host.beginEqSession()
        restoreEqEnabled = host.eqEnabled
        sessionGroup = host.eqGroup
        host.setEqEnabled(false, persistToFlash: false)
        let render = source
        do {
            handle = try backend.startTone(sink: output.name) { out, frames, channels, _ in
                render.render(out, frames: frames, channels: channels)
            }
        } catch {
            handle = nil
        }
        guard handle != nil else {
            host.setEqEnabled(restoreEqEnabled, persistToFlash: false)
            host.endEqSession()
            note = "Couldn't start the tone player, so nothing was measured. Try again."
            notify()
            return
        }
        playingSink = output.name
        stage?.setToneHold(true)
        phase = .running
        notify()
        task = Task { [weak self] in await self?.runAll() }
    }

    func stop() {
        task?.cancel()
        task = nil
        listening = false
        stopPlayer()
        restoreDevice()
        endSession()
        notify()
    }

    func reportHeard() { heard = true }

    func abandon() {
        guard phase == .running, !host.byEarSessionActive else { return }
        let reason = interruption() ?? .disconnected
        task?.cancel()
        task = nil
        interrupted = nil
        listening = false
        stopPlayer()
        note = "Tone test stopped \u{2014} \(reason.reason)."
        endSession()
        notify()
    }

    func checkInterruption() {
        guard phase == .running, host.byEarSessionActive, let reason = interruption() else { return }
        interrupted = reason
    }

    private func notify() { onChange?() }

    private func stopPlayer() {
        source.clear()
        handle?.stop()
        handle = nil
        playingSink = nil
        stage?.setToneHold(false)
    }

    private func restoreDevice() {
        guard host.byEarSessionActive, host.eqGroup == sessionGroup else { return }
        host.setEqEnabled(restoreEqEnabled, persistToFlash: false)
    }

    private func endSession() {
        host.setByEarSessionActive(false)
        phase = .idle
    }

    private func playerRunning() -> Bool {
        guard let handle else { return false }
        return !handle.hasFailed && (handle.isReady || handle.isStreaming)
    }

    private func interruption() -> SessionInterruption? {
        let output = routing?.realOutput
        let onDevice = output?.isQudelix5K == true && output?.name == playingSink
        return ToneTestMath.interruption(
            connected: host.isConnectedNow,
            compatible: host.isCompatible,
            voiceCall: host.isOnVoiceLink || host.activeCall == true,
            eqModeChanged: host.eqGroup != sessionGroup,
            playerRunning: playerRunning(),
            outputIsDevice: onDevice)
            ?? (host.byEarSessionActive ? nil : .disconnected)
    }

    private func waitForPlayer() async -> Bool {
        var polls = 0
        while polls < Self.playerDeadlinePolls {
            if Task.isCancelled { return false }
            guard let handle, !handle.hasFailed else { return false }
            if handle.isReady || handle.isStreaming {
                sampleRate = ToneTestMath.plausibleRate(Double(handle.format?.rate ?? 0))
                return true
            }
            await sleepMs(Self.playerPollMs)
            polls += 1
        }
        return false
    }

    private func runAll() async {
        guard await waitForPlayer() else {
            if !Task.isCancelled { abort(.playerStopped) }
            return
        }
        for hz in ToneTestMath.order {
            if Task.isCancelled { return }
            if let reason = interruption() { abort(reason); return }
            currentHz = hz
            notify()
            let found = await threshold(hz: hz)
            if Task.isCancelled { return }
            if let reason = interrupted { abort(reason); return }
            thresholds[hz] = found
            bandsDone += 1
            notify()
        }
        guard !Task.isCancelled else { return }
        finish()
    }

    private func abort(_ reason: SessionInterruption) {
        task = nil
        interrupted = nil
        listening = false
        stopPlayer()
        restoreDevice()
        note = "Tone test stopped \u{2014} \(reason.reason)."
        endSession()
        notify()
    }

    private func finish() {
        listening = false
        stopPlayer()
        restoreDevice()
        host.setByEarSessionActive(false)
        let results = ToneTestMath.order.sorted().map { ($0, thresholds[$0] ?? nil) }
        suggestion = ToneTestMath.suggest(results)
        phase = .finished
        task = nil
        notify()
    }

    private func threshold(hz: Int) async -> Double? {
        var staircase = Staircase()
        for _ in 0..<34 {
            if Task.isCancelled { return nil }
            if let reason = interruption() {
                interrupted = reason
                return nil
            }
            await sleepMs(randomPause())
            if randomCatch() {
                catchPlayed += 1
                if await present(hz: hz, level: nil) { catchFalsePositives += 1 }
                continue
            }
            let didHear = await present(hz: hz, level: staircase.level)
            if case .settled(let found) = staircase.answer(didHear) { return found }
        }
        return staircase.bestRepeated
    }

    private func present(hz: Int, level: Double?) async -> Bool {
        heard = false
        listening = true
        lastPresented = (hz, level)
        notify()
        if let level, playerRunning() {
            source.load(ToneTestMath.pulseSamples(hz: Double(hz), dbfs: level, sampleRate: sampleRate))
        }
        await sleepMs(1250)
        listening = false
        notify()
        return heard
    }

    var readingCount: Int {
        ToneTestMath.readingCount(in: ToneTestMath.order.sorted().map { ($0, thresholds[$0] ?? nil) })
    }

    var deviationSpread: Double { ToneTestMath.spread(of: suggestion) }

    var verdict: ToneTestMath.Verdict {
        ToneTestMath.verdict(readings: readingCount, catchTrials: catchPlayed,
                             falseAlarms: catchFalsePositives, spread: deviationSpread)
    }

    var falseAlarmsElevated: Bool {
        ToneTestMath.falseAlarmsElevated(catchTrials: catchPlayed, falseAlarms: catchFalsePositives)
    }

    func applySuggestion() -> Bool {
        guard verdict == .usable, phase == .finished else { return false }
        if app?.eq.following == true {
            note = "Auto-fit or Auto-trim is moving the gains \u{2014} press Keep, or turn them off, first."
            notify()
            return false
        }
        host.setEqEnabled(true, persistToFlash: true)
        host.beginUndoStep("hearing correction")
        let points = suggestion.filter(\.measured)
            .map { (hz: Double($0.hz), gain: $0.gain) }
            .sorted { $0.hz < $1.hz }
        guard !points.isEmpty else {
            phase = .idle
            notify()
            return false
        }
        let live = host.bands
        for index in 0..<min(host.bandCount, live.count) where live[index].filter.rendersGain {
            var band = live[index]
            band.gain = min(max(ToneTestMath.gain(at: Double(band.freq), from: points), -12), 12)
            host.updateBand(index, band, persistToFlash: true, recordUndo: false, force: false)
        }
        phase = .idle
        notify()
        return true
    }

    private var app: AppModel? { host.app }
}
