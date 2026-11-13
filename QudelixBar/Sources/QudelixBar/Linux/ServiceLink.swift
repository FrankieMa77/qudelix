#if os(Linux)
import Foundation
import Glibc

final class ServiceLink: QxLink {
    struct Timing {
        var retryInterval: TimeInterval = 0.1
        var spawnWindow: TimeInterval = 3
        var reconnectPause: TimeInterval = 1
        var welcomeTimeout: TimeInterval = 3
        var shutdownWait: TimeInterval = 5
        var writeTimeout: TimeInterval = 2
        var shutdownPoll: TimeInterval = 0.05
    }

    private final class Run {
        let wakeRead: Int32
        let wakeWrite: Int32
        let done = DispatchSemaphore(value: 0)
        var stopped = false
        var finished = false

        init?() {
            var ends: [Int32] = [0, 0]
            guard pipe(&ends) == 0 else { return nil }
            for end in ends {
                _ = fcntl(end, F_SETFD, FD_CLOEXEC)
                _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK)
            }
            wakeRead = ends[0]
            wakeWrite = ends[1]
        }

        func wake() {
            var byte: UInt8 = 1
            _ = Glibc.write(wakeWrite, &byte, 1)
        }

        func closeWake() {
            close(wakeRead)
            close(wakeWrite)
        }
    }

    private enum Established {
        case connected(Int32)
        case retryNow
        case failed
    }

    let kind: QxLinkKind = .bluetooth
    var keepsArmed: Bool { true }
    var needsInstanceLock: Bool { false }
    var onConnected: ((String) -> Void)?
    var onDisconnected: (() -> Void)?
    var onLinkUnusable: ((String) -> Void)?
    var onLinkBusy: ((String) -> Void)?
    var onPacket: (([UInt8]) -> Void)?

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state?.connected ?? false
    }

    var failureReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return state?.failureReason
    }

    var failureNeedsAttention: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state?.needsAttention ?? false
    }

    var attachedName: String? {
        lock.lock()
        defer { lock.unlock() }
        guard let state, state.connected else { return nil }
        return state.attachedName
    }

    private let socketPath: () -> String?
    private let spawner: () -> Bool
    private let timing: Timing
    private let peerExecutable: (Int32) -> String?
    private let lock = NSLock()
    private let descriptorLock = NSLock()
    private let writeQueue = DispatchQueue(label: "qudelix.service-link.write")

    private var state: LinkServiceState?
    private var run: Run?
    private var descriptor: Int32 = -1
    private var announcedUnusable: String?
    private var announcedBusy: String?
    private var mismatches = 0
    private var replacedOnce = false

    init(socketPath: @escaping () -> String? = { LinkServicePaths.socketPath() },
         spawner: @escaping () -> Bool,
         timing: Timing = Timing(),
         peerExecutable: @escaping (Int32) -> String? = { LinkServiceSpawner.peerExecutable($0) }) {
        self.socketPath = socketPath
        self.spawner = spawner
        self.timing = timing
        self.peerExecutable = peerExecutable
    }

    func recycle() {
        lock.lock()
        let connected = state?.connected ?? false
        lock.unlock()
        guard connected else { return }
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.descriptorLock.lock()
            defer { self.descriptorLock.unlock() }
            guard self.descriptor >= 0 else { return }
            _ = LinkServiceSocket.write(self.descriptor, .recycle)
        }
    }

    func start() {
        lock.lock()
        if let run, !run.stopped {
            lock.unlock()
            return
        }
        guard let fresh = Run() else {
            lock.unlock()
            Trace.log("service link cannot start: no wake pipe")
            return
        }
        run = fresh
        replacedOnce = false
        lock.unlock()
        let thread = Thread { [weak self] in self?.loop(fresh) }
        thread.name = "qudelix.service-link"
        thread.start()
    }

    func stop() {
        lock.lock()
        let current = run
        current?.stopped = true
        if let current, !current.finished { current.wake() }
        lock.unlock()
    }

    func stopAndWait(timeout: TimeInterval) {
        let flushed = DispatchSemaphore(value: 0)
        writeQueue.async { flushed.signal() }
        let deadline = Date().addingTimeInterval(timeout)
        _ = flushed.wait(timeout: .now() + timeout)
        lock.lock()
        let current = run
        lock.unlock()
        stop()
        _ = current?.done.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow))
    }

    func send(_ cmd: QxCmd, _ data: [UInt8]) {
        let frame = LinkServiceFrame.send(cmd: cmd.rawValue, data: data)
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.descriptorLock.lock()
            defer { self.descriptorLock.unlock() }
            guard self.descriptor >= 0, LinkServiceSocket.write(self.descriptor, frame) else {
                Trace.log("service link send dropped (no service): \(cmd)")
                return
            }
        }
    }

    private func isStopped(_ run: Run) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return run.stopped
    }

    private func pause(_ run: Run, _ seconds: TimeInterval) {
        _ = LinkServiceSocket.wait(-1, wake: run.wakeRead, timeout: seconds)
    }

    private func loop(_ run: Run) {
        while !isStopped(run) {
            switch establish(run) {
            case .connected(let connection):
                publish(connection, for: run)
                mismatches = 0
                read(connection, run)
                unpublish(connection)
                close(connection)
                markDown(run)
                if !isStopped(run) { pause(run, timing.reconnectPause) }
            case .retryNow:
                break
            case .failed:
                markDown(run)
                if !isStopped(run) { pause(run, timing.reconnectPause) }
            }
        }
        lock.lock()
        run.finished = true
        lock.unlock()
        run.closeWake()
        run.done.signal()
    }

    private func publish(_ connection: Int32, for run: Run) {
        descriptorLock.lock()
        descriptor = connection
        descriptorLock.unlock()
    }

    private func unpublish(_ connection: Int32) {
        descriptorLock.lock()
        if descriptor == connection { descriptor = -1 }
        descriptorLock.unlock()
    }

    private func establish(_ run: Run) -> Established {
        guard let path = socketPath() else {
            Trace.log("service link has no socket path")
            return .failed
        }
        var connection = LinkServiceSocket.connect(path: path, sendTimeout: timing.writeTimeout)
        if connection < 0 {
            Trace.log("service link: no service on the socket; starting one")
            if !spawner() { Trace.log("service link: could not start the service") }
            let deadline = Date().addingTimeInterval(timing.spawnWindow)
            while connection < 0, !isStopped(run), Date() < deadline {
                pause(run, timing.retryInterval)
                if isStopped(run) { break }
                connection = LinkServiceSocket.connect(path: path, sendTimeout: timing.writeTimeout)
            }
        }
        guard connection >= 0, !isStopped(run) else {
            if connection >= 0 { close(connection) }
            return .failed
        }
        guard LinkServiceSocket.write(connection, .hello(version: LinkServiceFrame.protocolVersion)) else {
            close(connection)
            return .failed
        }
        switch LinkServiceSocket.wait(connection, wake: run.wakeRead, timeout: timing.welcomeTimeout) {
        case .frame(let bytes):
            guard case .welcome(let version)? = LinkServiceFrame.decode(bytes) else {
                close(connection)
                return .failed
            }
            if version == LinkServiceFrame.protocolVersion {
                guard !replacedOnce,
                      LinkServiceSpawner.isReplaced(peerExecutable: peerExecutable(connection)) else {
                    return .connected(connection)
                }
                replacedOnce = true
                Trace.log("service link: the background process runs a replaced build; restarting it")
                LinkServiceSocket.write(connection, .shutdown)
                drain(connection, run)
                close(connection)
                awaitGone(path, run)
                return .retryNow
            }
            Trace.log("service link: the service speaks protocol \(version); replacing it")
            LinkServiceSocket.write(connection, .shutdown)
            close(connection)
            awaitGone(path, run)
            mismatches += 1
            return mismatches > 1 ? .failed : .retryNow
        case .closed, .timedOut, .woken:
            close(connection)
            return .failed
        }
    }

    private func drain(_ connection: Int32, _ run: Run) {
        let deadline = Date().addingTimeInterval(timing.shutdownWait)
        while Date() < deadline, !isStopped(run) {
            guard case .frame = LinkServiceSocket.wait(connection, wake: run.wakeRead,
                                                       timeout: deadline.timeIntervalSinceNow) else { return }
        }
    }

    private func awaitGone(_ path: String, _ run: Run) {
        let deadline = Date().addingTimeInterval(timing.shutdownWait)
        while Date() < deadline, !isStopped(run) {
            let probe = LinkServiceSocket.connect(path: path, sendTimeout: timing.writeTimeout)
            if probe < 0 { return }
            close(probe)
            pause(run, timing.shutdownPoll)
        }
    }

    private func read(_ connection: Int32, _ run: Run) {
        while !isStopped(run) {
            switch LinkServiceSocket.wait(connection, wake: run.wakeRead, timeout: 3600) {
            case .frame(let bytes):
                switch LinkServiceFrame.decode(bytes) {
                case .state(let incoming)?: apply(incoming, run)
                case .packet(let packet)?:
                    if !isStopped(run) { onPacket?(packet) }
                default: break
                }
            case .timedOut:
                continue
            case .closed, .woken:
                return
            }
        }
    }

    private func apply(_ incoming: LinkServiceState, _ run: Run) {
        lock.lock()
        let was = state?.connected ?? false
        state = incoming
        let stopped = run.stopped
        let newUnusable = incoming.unusable != announcedUnusable ? incoming.unusable : nil
        let newBusy = incoming.busy != announcedBusy ? incoming.busy : nil
        announcedUnusable = incoming.unusable
        announcedBusy = incoming.busy
        lock.unlock()
        guard !stopped else { return }
        if incoming.connected && !was { onConnected?(incoming.attachedName ?? "Qudelix 5K") }
        if !incoming.connected && was { onDisconnected?() }
        if let newUnusable { onLinkUnusable?(newUnusable) }
        if let newBusy { onLinkBusy?(newBusy) }
    }

    private func markDown(_ run: Run) {
        lock.lock()
        let was = state?.connected ?? false
        state = nil
        announcedUnusable = nil
        announcedBusy = nil
        let stopped = run.stopped
        lock.unlock()
        if was && !stopped { onDisconnected?() }
    }
}
#endif
