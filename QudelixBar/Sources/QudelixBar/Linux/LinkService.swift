#if os(Linux)
import Foundation
import Glibc

final class LinkService {
    private final class Client {
        let descriptor: Int32
        let source: DispatchSourceRead
        var greeted = false

        init(descriptor: Int32, source: DispatchSourceRead) {
            self.descriptor = descriptor
            self.source = source
        }
    }

    private let socketPath: String
    private let lockURL: URL?
    private let makeTransport: () -> QxLink
    private let pollInterval: TimeInterval
    private let stopWait: TimeInterval
    private let handlesSignals: Bool
    private let log: (String) -> Void

    private let queue = DispatchQueue(label: "qudelix.link-service")
    private let sendQueue = DispatchQueue(label: "qudelix.link-service.send")
    private let finished = DispatchSemaphore(value: 0)
    private let shutdownLock = NSLock()
    private var shutdownReason: String?

    private var transport: QxLink?
    private var listenerSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var clients: [Int32: Client] = [:]
    private var lastState = LinkServiceState()
    private var unusable: String?
    private var busy: String?
    private var closing = false

    init(socketPath: String,
         lockURL: URL?,
         makeTransport: @escaping () -> QxLink,
         pollInterval: TimeInterval = 0.1,
         stopWait: TimeInterval = 3,
         handlesSignals: Bool = false,
         log: @escaping (String) -> Void = { Trace.log("service: " + $0) }) {
        self.socketPath = socketPath
        self.lockURL = lockURL
        self.makeTransport = makeTransport
        self.pollInterval = pollInterval
        self.stopWait = stopWait
        self.handlesSignals = handlesSignals
        self.log = log
    }

    func requestShutdown(_ reason: String) {
        shutdownLock.lock()
        let first = shutdownReason == nil
        if first { shutdownReason = reason }
        shutdownLock.unlock()
        if first { finished.signal() }
    }

    func run() -> Int32 {
        guard let lockURL else {
            log("no lock directory is available; exiting")
            return CLIExit.deviceError
        }
        let lock: QxInstanceLock
        switch QxInstanceLock.attempt(at: lockURL) {
        case .acquired(let acquired):
            lock = acquired
        case .busy:
            log("another service already holds the lock; exiting")
            return CLIExit.ok
        case .unavailable(let message):
            log(message)
            return CLIExit.deviceError
        }
        defer { lock.release() }

        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        unlink(socketPath)
        let listener = LinkServiceSocket.listen(path: socketPath)
        guard listener >= 0 else {
            log("cannot listen on \(socketPath): " + String(cString: strerror(-listener)))
            return CLIExit.deviceError
        }

        log("started pid \(getpid()) version \(CLI.version) protocol \(LinkServiceFrame.protocolVersion)")
        let link = makeTransport()
        transport = link
        let restoreSignals = installSignalHandlers()
        queue.sync { startListening(listener) }
        attach(link)
        link.start()
        queue.sync { startPolling() }

        finished.wait()

        shutdownLock.lock()
        let reason = shutdownReason ?? "shutdown"
        shutdownLock.unlock()
        log("shutting down: \(reason)")
        queue.sync {
            closing = true
            timer?.cancel()
            timer = nil
        }
        restoreSignals()
        link.stopAndWait(timeout: stopWait)
        link.onConnected = nil
        link.onDisconnected = nil
        link.onLinkUnusable = nil
        link.onLinkBusy = nil
        link.onPacket = nil
        queue.sync {
            listenerSource?.cancel()
            listenerSource = nil
            for client in clients.values { client.source.cancel() }
            clients.removeAll()
        }
        unlink(socketPath)
        log("stopped")
        return CLIExit.ok
    }

    private func installSignalHandlers() -> () -> Void {
        guard handlesSignals else { return {} }
        let names: [(Int32, String)] = [(SIGTERM, "SIGTERM"), (SIGINT, "SIGINT"), (SIGHUP, "SIGHUP")]
        for (number, name) in names {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in self?.requestShutdown(name) }
            source.resume()
            signalSources.append(source)
        }
        return { [weak self] in
            guard let self else { return }
            for source in self.signalSources { source.cancel() }
            self.signalSources.removeAll()
            for (number, _) in names { signal(number, SIG_DFL) }
        }
    }

    private func attach(_ link: QxLink) {
        link.onConnected = { [weak self] _ in
            guard let self else { return }
            self.sendQueue.async { link.send(.reqInitData, QxInit.requestPayload) }
            self.queue.async {
                self.unusable = nil
                self.busy = nil
                self.refreshState()
            }
        }
        link.onDisconnected = { [weak self] in
            self?.queue.async { self?.refreshState() }
        }
        link.onLinkUnusable = { [weak self] text in
            self?.queue.async {
                self?.unusable = text
                self?.refreshState()
            }
        }
        link.onLinkBusy = { [weak self] text in
            self?.queue.async {
                self?.busy = text
                self?.refreshState()
            }
        }
        link.onPacket = { [weak self] bytes in
            self?.queue.async { self?.broadcast(.packet(bytes)) }
        }
    }

    private func startListening(_ listener: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients(listener) }
        source.setCancelHandler { close(listener) }
        source.resume()
        listenerSource = source
    }

    private func startPolling() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        source.setEventHandler { [weak self] in self?.refreshState() }
        source.resume()
        timer = source
    }

    private func acceptClients(_ listener: Int32) {
        while true {
            let descriptor = LinkServiceSocket.accept(listener)
            if descriptor < 0 { return }
            guard !closing, LinkServiceSocket.peerUserID(descriptor) == getuid() else {
                log("refused a connection from another user")
                close(descriptor)
                continue
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            let client = Client(descriptor: descriptor, source: source)
            source.setEventHandler { [weak self, weak client] in
                guard let self, let client else { return }
                self.readFrames(client)
            }
            source.setCancelHandler { close(descriptor) }
            clients[descriptor] = client
            source.resume()
        }
    }

    private func readFrames(_ client: Client) {
        while clients[client.descriptor] === client {
            switch LinkServiceSocket.read(client.descriptor) {
            case .frame(let bytes):
                handle(LinkServiceFrame.decode(bytes), from: client)
            case .timedOut, .woken:
                return
            case .closed:
                drop(client)
                return
            }
        }
    }

    private func handle(_ frame: LinkServiceFrame?, from client: Client) {
        switch frame {
        case .hello:
            refreshState()
            guard LinkServiceSocket.write(client.descriptor,
                                          .welcome(version: LinkServiceFrame.protocolVersion),
                                          dontWait: true),
                  LinkServiceSocket.write(client.descriptor, .state(lastState), dontWait: true)
            else {
                drop(client)
                return
            }
            client.greeted = true
            log("client attached (\(clients.values.filter(\.greeted).count) attached)")
        case .send(let rawCommand, let data):
            guard client.greeted, let command = QxCmd(rawValue: rawCommand),
                  QxSession.allowed.contains(command), let link = transport else {
                log("dropped a command from a client: \(String(format: "0x%04X", rawCommand))")
                return
            }
            sendQueue.async { link.send(command, data) }
        case .shutdown:
            requestShutdown("a client asked for it")
        case .recycle:
            guard client.greeted, let link = transport else {
                log("dropped an unexpected message from a client")
                return
            }
            log("a client asked to restart the link")
            sendQueue.async { link.recycle() }
        case .welcome, .state, .packet, nil:
            log("dropped an unexpected message from a client")
        }
    }

    private func drop(_ client: Client) {
        guard clients[client.descriptor] === client else { return }
        clients[client.descriptor] = nil
        client.source.cancel()
        if client.greeted {
            log("client detached (\(clients.values.filter(\.greeted).count) attached)")
        }
    }

    private func broadcast(_ frame: LinkServiceFrame) {
        for client in Array(clients.values) where client.greeted {
            if !LinkServiceSocket.write(client.descriptor, frame, dontWait: true) {
                drop(client)
            }
        }
    }

    private func currentState() -> LinkServiceState {
        guard let link = transport else { return LinkServiceState() }
        var state = LinkServiceState()
        state.connected = link.isConnected
        state.attachedName = link.attachedName
        state.failureReason = link.failureReason
        state.needsAttention = link.failureNeedsAttention
        state.unusable = unusable
        state.busy = busy
        return state
    }

    private func refreshState() {
        guard !closing else { return }
        let state = currentState()
        guard state != lastState else { return }
        lastState = state
        broadcast(.state(state))
    }
}
#endif
