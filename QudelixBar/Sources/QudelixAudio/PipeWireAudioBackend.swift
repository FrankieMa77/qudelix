import CQxAudio
import Foundation
import QudelixBar

private func text<T>(_ field: T) -> String {
    var copy = field
    return withUnsafeBytes(of: &copy) { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[0..<end], as: UTF8.self)
    }
}

private final class CaptureBox {
    let block: AudioCaptureBlock

    init(_ block: @escaping AudioCaptureBlock) {
        self.block = block
    }
}

private final class RenderBox {
    let block: AudioRenderBlock

    init(_ block: @escaping AudioRenderBlock) {
        self.block = block
    }
}

private final class ToneBox {
    let block: AudioToneBlock

    init(_ block: @escaping AudioToneBlock) {
        self.block = block
    }
}

private final class PipeWireStream: AudioStreamHandle {
    private var stream: OpaquePointer?
    private var retained: Unmanaged<AnyObject>?
    private weak var owner: PipeWireAudioBackend?
    private let lock = NSLock()

    init(stream: OpaquePointer, retained: Unmanaged<AnyObject>, owner: PipeWireAudioBackend) {
        self.stream = stream
        self.retained = retained
        self.owner = owner
    }

    deinit {
        stop()
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return false }
        let state = qx_stream_state(stream)
        return state == Int32(QX_STREAM_STREAMING) || state == Int32(QX_STREAM_READY)
    }

    var isStreaming: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return false }
        return qx_stream_state(stream) == Int32(QX_STREAM_STREAMING)
    }

    var hasFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return false }
        return qx_stream_state(stream) == Int32(QX_STREAM_FAILED)
    }

    var format: AudioStreamFormat? {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return nil }
        let rate = Int(qx_stream_rate(stream))
        let channels = Int(qx_stream_channels(stream))
        return rate > 0 && channels > 0 ? AudioStreamFormat(rate: rate, channels: channels) : nil
    }

    var sinkLegFormat: AudioStreamFormat? {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return nil }
        let rate = Int(qx_stream_leg_rate(stream, 0))
        return rate > 0 ? AudioStreamFormat(rate: rate, channels: 2) : nil
    }

    var sinkLegState: AudioLegState { legState(0) }

    var playbackLegState: AudioLegState { legState(1) }

    private func legState(_ leg: Int32) -> AudioLegState {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return .failed }
        switch qx_stream_leg_state(stream, leg) {
        case Int32(QX_STREAM_STREAMING): return .streaming
        case Int32(QX_STREAM_READY): return .ready
        case Int32(QX_STREAM_FAILED): return .failed
        default: return .connecting
        }
    }

    var underruns: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return 0 }
        return qx_stream_underruns(stream)
    }

    var overruns: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return 0 }
        return qx_stream_overruns(stream)
    }

    func stop() {
        lock.lock()
        let stream = self.stream
        let retained = self.retained
        self.stream = nil
        self.retained = nil
        lock.unlock()
        guard let stream else { return }
        qx_stream_stop(stream)
        retained?.release()
        owner?.forget(self)
    }
}

package final class PipeWireAudioBackend: LinuxAudioBackend {
    private var audio: OpaquePointer?
    private let lock = NSLock()
    private var handler: (() -> Void)?
    private var streams: [PipeWireStream] = []

    package init() throws {
        var error: Int32 = 0
        guard let audio = qx_audio_create("Qudelix", &error) else {
            throw AudioBackendError.unavailable(error)
        }
        self.audio = audio
        qx_audio_set_change_handler(audio, { user in
            guard let user else { return }
            Unmanaged<PipeWireAudioBackend>.fromOpaque(user).takeUnretainedValue().fireChange()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        shutdown()
    }

    package var changeHandler: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return handler
        }
        set {
            lock.lock()
            handler = newValue
            lock.unlock()
        }
    }

    fileprivate func fireChange() {
        changeHandler?()
    }

    fileprivate func forget(_ stream: PipeWireStream) {
        lock.lock()
        streams.removeAll { $0 === stream }
        lock.unlock()
    }

    package var sinks: [AudioSink] {
        guard let audio else { return [] }
        var infos = [QxSinkInfo](repeating: QxSinkInfo(), count: 64)
        let count = Int(qx_audio_list_sinks(audio, &infos, Int32(infos.count)))
        return infos.prefix(count).map { info in
            AudioSink(id: info.id,
                      name: text(info.name),
                      description: text(info.description),
                      deviceApi: text(info.device_api),
                      deviceBus: text(info.device_bus),
                      vendorId: text(info.vendor_id),
                      productId: text(info.product_id),
                      bluezAddress: text(info.bluez_address),
                      profile: text(info.profile))
        }
    }

    private func defaultSink(configured: Bool) -> String? {
        guard let audio else { return nil }
        var buffer = [CChar](repeating: 0, count: 256)
        guard qx_audio_get_default_sink(audio, configured ? 1 : 0, &buffer, buffer.count) != 0 else { return nil }
        return String(cString: buffer)
    }

    package var defaultSinkName: String? { defaultSink(configured: false) }

    package var configuredDefaultSinkName: String? { defaultSink(configured: true) }

    package var connected: Bool {
        lock.lock()
        let audio = self.audio
        lock.unlock()
        guard let audio else { return false }
        return qx_audio_connected(audio) != 0
    }

    package var forceRate: Int {
        guard let audio else { return 0 }
        return Int(qx_audio_get_force_rate(audio))
    }

    package func sinkVolume(named name: String) -> AudioSinkVolume? {
        guard let audio else { return nil }
        var volume = QxSinkVolume()
        guard qx_audio_get_sink_volume(audio, name, &volume) != 0 else { return nil }
        return AudioSinkVolume(volume: volume.volume, channelVolume: volume.channel_volume, muted: volume.muted != 0)
    }

    package func scaleSinkVolume(named name: String, by factor: Float, muted: Bool?) -> Bool {
        guard let audio else { return false }
        let mute: Int32 = muted.map { $0 ? 1 : 0 } ?? -1
        return qx_audio_scale_sink_volume(audio, name, factor, mute) >= 0
    }

    package func setDefaultSink(named name: String?) -> Bool {
        guard let audio else { return false }
        return qx_audio_set_default_sink(audio, name) >= 0
    }

    package func setForceRate(_ rate: Int) -> Bool {
        guard let audio else { return false }
        return qx_audio_set_force_rate(audio, Int32(rate)) >= 0
    }

    private func adopt(_ stream: OpaquePointer?, box: AnyObject) throws -> AudioStreamHandle {
        let retained = Unmanaged<AnyObject>.passRetained(box)
        guard let stream else {
            retained.release()
            throw AudioBackendError.streamFailed
        }
        let handle = PipeWireStream(stream: stream, retained: retained, owner: self)
        lock.lock()
        streams.append(handle)
        lock.unlock()
        return handle
    }

    package func startMonitor(sink: String, block: @escaping AudioCaptureBlock) throws -> AudioStreamHandle {
        guard let audio else { throw AudioBackendError.streamFailed }
        let box = CaptureBox(block)
        let user = Unmanaged.passUnretained(box).toOpaque()
        let stream = qx_audio_start_monitor(audio, sink, { user, samples, frames, channels, rate in
            guard let user, let samples else { return }
            Unmanaged<CaptureBox>.fromOpaque(user).takeUnretainedValue()
                .block(samples, Int(frames), Int(channels), Int(rate))
        }, user)
        return try adopt(stream, box: box)
    }

    package func startInsert(target: String, bluetooth: Bool, render: @escaping AudioRenderBlock) throws -> AudioStreamHandle {
        guard let audio else { throw AudioBackendError.streamFailed }
        let box = RenderBox(render)
        let user = Unmanaged.passUnretained(box).toOpaque()
        let stream = qx_audio_start_insert(audio, LinuxAudioNames.stageSinkName, LinuxAudioNames.stageSinkDescription,
                                           target, bluetooth ? 1 : 0, { user, input, output, frames, channels, rate in
            guard let user, let input, let output else { return }
            Unmanaged<RenderBox>.fromOpaque(user).takeUnretainedValue()
                .block(input, output, Int(frames), Int(channels), Int(rate))
        }, user)
        return try adopt(stream, box: box)
    }

    package func startTone(sink: String, render: @escaping AudioToneBlock) throws -> AudioStreamHandle {
        guard let audio else { throw AudioBackendError.streamFailed }
        let box = ToneBox(render)
        let user = Unmanaged.passUnretained(box).toOpaque()
        let stream = qx_audio_start_tone(audio, sink, { user, output, frames, channels, rate in
            guard let user, let output else { return }
            Unmanaged<ToneBox>.fromOpaque(user).takeUnretainedValue()
                .block(output, Int(frames), Int(channels), Int(rate))
        }, user)
        return try adopt(stream, box: box)
    }

    package func shutdown() {
        lock.lock()
        let audio = self.audio
        self.audio = nil
        let alive = streams
        lock.unlock()
        guard let audio else { return }
        qx_audio_set_change_handler(audio, nil, nil)
        for stream in alive { stream.stop() }
        qx_audio_destroy(audio)
    }
}
