#if os(Linux)
import XCTest
@testable import QudelixBar

func awaitCondition(_ timeout: TimeInterval = 4, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

func makeTemporaryDirectory() -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("qx-ls-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

final class ServiceHarness {
    let directory: URL
    let socketPath: String
    let lockURL: URL
    let transport: FakeLink
    let service: LinkService
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var exitStatus: Int32?

    init(directory: URL = makeTemporaryDirectory(),
         transport: FakeLink = FakeLink(kind: .bluetooth),
         handlesSignals: Bool = false) {
        self.directory = directory
        self.transport = transport
        socketPath = directory.appendingPathComponent("link.sock").path
        lockURL = directory.appendingPathComponent("link-service.lock")
        service = LinkService(socketPath: socketPath, lockURL: lockURL,
                              makeTransport: { transport },
                              pollInterval: 0.02, stopWait: 1,
                              handlesSignals: handlesSignals, log: { _ in })
    }

    var status: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return exitStatus
    }

    func startInBackground() {
        let thread = Thread { [self] in
            let result = service.run()
            lock.lock()
            exitStatus = result
            lock.unlock()
            finished.signal()
        }
        thread.start()
    }

    func start() {
        startInBackground()
        XCTAssertTrue(awaitCondition { acceptsConnections() }, "service did not start listening")
    }

    func acceptsConnections() -> Bool {
        let probe = LinkServiceSocket.connect(path: socketPath)
        guard probe >= 0 else { return false }
        close(probe)
        return true
    }

    func waitForExit(_ timeout: TimeInterval = 4) -> Bool {
        finished.wait(timeout: .now() + timeout) == .success
    }

    func stop() {
        service.requestShutdown("test")
        _ = waitForExit()
    }

    var socketExists: Bool { FileManager.default.fileExists(atPath: socketPath) }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

final class TestPeer {
    let descriptor: Int32

    init?(path: String) {
        descriptor = LinkServiceSocket.connect(path: path)
        guard descriptor >= 0 else { return nil }
    }

    deinit { close(descriptor) }

    func send(_ frame: LinkServiceFrame) {
        XCTAssertTrue(LinkServiceSocket.write(descriptor, frame))
    }

    func next(_ timeout: TimeInterval = 2) -> LinkServiceFrame? {
        guard case .frame(let bytes) = LinkServiceSocket.wait(descriptor, timeout: timeout) else {
            return nil
        }
        return LinkServiceFrame.decode(bytes)
    }

    func next(_ timeout: TimeInterval = 2,
              where matches: (LinkServiceFrame) -> Bool) -> LinkServiceFrame? {
        let deadline = Date().addingTimeInterval(timeout)
        while deadline.timeIntervalSinceNow > 0 {
            guard let frame = next(deadline.timeIntervalSinceNow) else { return nil }
            if matches(frame) { return frame }
        }
        return nil
    }

    @discardableResult
    func greet() -> LinkServiceState? {
        send(.hello(version: LinkServiceFrame.protocolVersion))
        guard case .welcome? = next() else { return nil }
        guard case .state(let state)? = next() else { return nil }
        return state
    }

    func isClosed(_ timeout: TimeInterval = 2) -> Bool {
        if case .closed = LinkServiceSocket.wait(descriptor, timeout: timeout) { return true }
        return false
    }
}

final class RawServer {
    let listener: Int32
    let path: String
    private let lock = NSLock()
    private(set) var received: [LinkServiceFrame] = []
    var welcomeVersion: UInt8 = 2

    init?(path: String) {
        self.path = path
        listener = LinkServiceSocket.listen(path: path)
        guard listener >= 0 else { return nil }
    }

    func serveOnce() {
        Thread { [self] in
            var descriptors = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0)]
            guard poll(&descriptors, 1, 4000) > 0 else { return }
            let connection = LinkServiceSocket.accept(listener)
            guard connection >= 0 else { return }
            defer {
                close(connection)
                close(listener)
                unlink(path)
            }
            for _ in 0..<2 {
                guard case .frame(let bytes) = LinkServiceSocket.wait(connection, timeout: 3),
                      let frame = LinkServiceFrame.decode(bytes) else { return }
                lock.lock()
                received.append(frame)
                lock.unlock()
                if case .hello = frame {
                    LinkServiceSocket.write(connection, .welcome(version: welcomeVersion))
                }
            }
        }.start()
    }

    var frames: [LinkServiceFrame] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }
}
#endif
