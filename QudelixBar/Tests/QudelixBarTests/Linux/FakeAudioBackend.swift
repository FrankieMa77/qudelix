import Foundation
@testable import QudelixBar

final class FakeAudioStream: AudioStreamHandle {
    var isReady = true
    var isStreaming = true
    var hasFailed = false
    var format: AudioStreamFormat? = AudioStreamFormat(rate: 48000, channels: 2)
    var underruns: UInt64 = 0
    var overruns: UInt64 = 0
    private(set) var stopped = false
    var onStop: (() -> Void)?

    func stop() {
        guard !stopped else { return }
        stopped = true
        isReady = false
        isStreaming = false
        onStop?()
    }
}

final class FakeAudioBackend: LinuxAudioBackend {
    var sinks: [AudioSink] = []
    var defaultSinkName: String?
    var configuredDefaultSinkName: String?
    var forceRate = 0
    var volumes: [String: AudioSinkVolume] = [:]
    var changeHandler: (() -> Void)?
    var failStreams = false
    var acceptDefaultChange = true
    var autoStageSink = true
    var streamFormat: AudioStreamFormat? = AudioStreamFormat(rate: 48000, channels: 2)
    var deferDefaultChange = false
    var applyForceRate = true
    private(set) var pendingDefault: String??
    private(set) var setDefaultCalls: [String?] = []
    private(set) var forceRateCalls: [Int] = []
    private(set) var monitors: [(sink: String, block: AudioCaptureBlock, stream: FakeAudioStream)] = []
    private(set) var inserts: [(target: String, render: AudioRenderBlock, stream: FakeAudioStream)] = []
    private(set) var tones: [(sink: String, render: AudioToneBlock, stream: FakeAudioStream)] = []
    private(set) var isShutDown = false

    func sinkVolume(named name: String) -> AudioSinkVolume? {
        volumes[name]
    }

    func setDefaultSink(named name: String?) -> Bool {
        setDefaultCalls.append(name)
        guard acceptDefaultChange else { return false }
        if deferDefaultChange {
            pendingDefault = .some(name)
            return true
        }
        applyDefault(name)
        return true
    }

    private func applyDefault(_ name: String?) {
        configuredDefaultSinkName = name
        defaultSinkName = name ?? sinks.first { !$0.isStageSink }?.name
        changeHandler?()
    }

    func flushDefault() {
        guard let pending = pendingDefault else { return }
        pendingDefault = nil
        applyDefault(pending)
    }

    func setForceRate(_ rate: Int) -> Bool {
        forceRateCalls.append(rate)
        if applyForceRate { forceRate = rate }
        changeHandler?()
        return true
    }

    func startMonitor(sink: String, block: @escaping AudioCaptureBlock) throws -> AudioStreamHandle {
        if failStreams { throw AudioBackendError.streamFailed }
        let stream = FakeAudioStream()
        stream.format = streamFormat
        monitors.append((sink, block, stream))
        return stream
    }

    func startInsert(target: String, render: @escaping AudioRenderBlock) throws -> AudioStreamHandle {
        if failStreams { throw AudioBackendError.streamFailed }
        let stream = FakeAudioStream()
        stream.format = streamFormat
        inserts.append((target, render, stream))
        if autoStageSink {
            sinks.append(AudioSink(id: 900, name: LinuxAudioNames.stageSinkName,
                                   description: LinuxAudioNames.stageSinkDescription))
            changeHandler?()
            stream.onStop = { [weak self] in
                self?.sinks.removeAll { $0.isStageSink }
                self?.changeHandler?()
            }
        }
        return stream
    }

    func startTone(sink: String, render: @escaping AudioToneBlock) throws -> AudioStreamHandle {
        if failStreams { throw AudioBackendError.streamFailed }
        let stream = FakeAudioStream()
        stream.format = streamFormat
        tones.append((sink, render, stream))
        return stream
    }

    func shutdown() {
        isShutDown = true
        for monitor in monitors { monitor.stream.stop() }
        for insert in inserts { insert.stream.stop() }
        for tone in tones { tone.stream.stop() }
    }
}
