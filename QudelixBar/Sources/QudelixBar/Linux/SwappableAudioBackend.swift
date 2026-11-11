import Foundation

package final class SwappableAudioBackend: LinuxAudioBackend {
    private let lock = NSLock()
    private var inner: LinuxAudioBackend?
    private var handler: (() -> Void)?

    package init() {}

    private var current: LinuxAudioBackend? {
        lock.lock()
        defer { lock.unlock() }
        return inner
    }

    package var hasBackend: Bool { current != nil }

    package func install(_ backend: LinuxAudioBackend) {
        lock.lock()
        let previous = inner
        inner = backend
        lock.unlock()
        previous?.shutdown()
        backend.changeHandler = { [weak self] in self?.fire() }
        fire()
    }

    @discardableResult
    package func detach() -> LinuxAudioBackend? {
        lock.lock()
        let previous = inner
        inner = nil
        lock.unlock()
        previous?.changeHandler = nil
        fire()
        return previous
    }

    private func fire() {
        changeHandler?()
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

    package var sinks: [AudioSink] { current?.sinks ?? [] }
    package var defaultSinkName: String? { current?.defaultSinkName }
    package var configuredDefaultSinkName: String? { current?.configuredDefaultSinkName }
    package var forceRate: Int { current?.forceRate ?? 0 }
    package var connected: Bool { current?.connected ?? false }

    package func sinkVolume(named name: String) -> AudioSinkVolume? {
        current?.sinkVolume(named: name)
    }

    package func scaleSinkVolume(named name: String, by factor: Float, muted: Bool?) -> Bool {
        current?.scaleSinkVolume(named: name, by: factor, muted: muted) ?? false
    }

    package func setDefaultSink(named name: String?) -> Bool {
        current?.setDefaultSink(named: name) ?? false
    }

    package func setForceRate(_ rate: Int) -> Bool {
        current?.setForceRate(rate) ?? false
    }

    package func startMonitor(sink: String, block: @escaping AudioCaptureBlock) throws -> AudioStreamHandle {
        guard let backend = current else { throw AudioBackendError.unavailable(-1) }
        return try backend.startMonitor(sink: sink, block: block)
    }

    package func startInsert(target: String, render: @escaping AudioRenderBlock) throws -> AudioStreamHandle {
        guard let backend = current else { throw AudioBackendError.unavailable(-1) }
        return try backend.startInsert(target: target, render: render)
    }

    package func startTone(sink: String, render: @escaping AudioToneBlock) throws -> AudioStreamHandle {
        guard let backend = current else { throw AudioBackendError.unavailable(-1) }
        return try backend.startTone(sink: sink, render: render)
    }

    package func shutdown() {
        detach()?.shutdown()
    }
}
