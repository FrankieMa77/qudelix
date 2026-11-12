#if os(Linux)
import XCTest
import Glibc
import CDBus
@testable import QudelixBar

final class DBusConnectionLeakTests: XCTestCase {
    private var daemon: Process?
    override func tearDown() {
        daemon?.terminate()
        daemon?.waitUntilExit()
        daemon = nil
        super.tearDown()
    }

    private func startDaemon() throws -> String {
        let candidates = ["/usr/bin/dbus-daemon", "/bin/dbus-daemon", "/usr/local/bin/dbus-daemon"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("dbus-daemon is not installed")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--session", "--nofork", "--print-address=1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        daemon = process
        var collected = Data()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            collected.append(chunk)
            if collected.contains(UInt8(ascii: "\n")) { break }
        }
        let text = String(decoding: collected, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw XCTSkip("dbus-daemon printed no address") }
        return text
    }

    private func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd").count) ?? 0
    }

    func testDroppedConnectionsWithARunningPumpReleaseTheirDescriptors() throws {
        let address = try startDaemon()
        let baseline = openDescriptors()
        for _ in 0..<20 {
            let connection = try DBusConnection(address: address)
            connection.startSignalPump()
            Thread.sleep(forTimeInterval: 0.1)
        }
        let deadline = Date().addingTimeInterval(4)
        while openDescriptors() > baseline && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertLessThanOrEqual(openDescriptors(), baseline)
    }
    private final class StopFlag {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    private static let responderName = "org.qudelix.Responder"

    private func startResponder(address: String) throws -> StopFlag {
        var error = DBusError()
        dbus_error_init(&error)
        defer { dbus_error_free(&error) }
        guard let handle = dbus_connection_open_private(address, &error),
              dbus_bus_register(handle, &error) != 0 else {
            throw XCTSkip("cannot open the responder connection")
        }
        dbus_bus_request_name(handle, DBusConnectionLeakTests.responderName, 0, &error)
        let flag = StopFlag()
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            ready.signal()
            var served = 0
            while !flag.isSet {
                dbus_connection_read_write(handle, 20)
                while let message = dbus_connection_pop_message(handle) {
                    if dbus_message_get_type(message) == DBUS_MESSAGE_TYPE_METHOD_CALL,
                       dbus_message_get_interface(message).map({ String(cString: $0) })
                        == DBusConnectionLeakTests.responderName {
                        served += 1
                        Thread.sleep(forTimeInterval: 0.05 + Double(served % 6) * 0.05)
                        if let reply = dbus_message_new_method_return(message) {
                            dbus_connection_send(handle, reply, nil)
                            dbus_connection_flush(handle)
                            dbus_message_unref(reply)
                        }
                    }
                    dbus_message_unref(message)
                }
            }
            dbus_connection_close(handle)
            dbus_connection_unref(handle)
        }
        thread.start()
        ready.wait()
        return flag
    }

    private func slowCallLatencies(calls: Int, deadline: TimeInterval,
                                   _ call: @escaping () throws -> Void) -> [TimeInterval] {
        let box = LatencyBox()
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            for _ in 0..<calls {
                let started = Date()
                _ = try? call()
                box.add(Date().timeIntervalSince(started))
            }
            finished.signal()
        }
        thread.start()
        _ = finished.wait(timeout: .now() + deadline)
        return box.values
    }

    private final class LatencyBox {
        private let lock = NSLock()
        private var stored: [TimeInterval] = []
        func add(_ value: TimeInterval) {
            lock.lock()
            stored.append(value)
            lock.unlock()
        }
        var values: [TimeInterval] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    func testCallsThroughTheSplitBusOnAQuietBus() throws {
        let address = try startDaemon()
        let responder = try startResponder(address: address)
        defer { responder.set() }
        let bus = try SystemBluezBus(address: address, service: DBusConnectionLeakTests.responderName,
                                     permit: { _, _ in })
        bus.onSignal { _ in }
        let latencies = slowCallLatencies(calls: 30, deadline: 90) {
            _ = try bus.call(path: "/", interface: DBusConnectionLeakTests.responderName,
                             method: "Slow", arguments: [], timeoutMs: 2000)
        }
        let worst = latencies.max() ?? 999
        XCTAssertEqual(latencies.count, 30)
        XCTAssertLessThan(worst, 3)
        bus.close()
    }

    func testDroppedSplitBusesReleaseTheirDescriptors() throws {
        let address = try startDaemon()
        let baseline = openDescriptors()
        for index in 0..<20 {
            let bus = try SystemBluezBus(address: address, service: "org.freedesktop.DBus")
            if index % 2 == 0 { bus.close() }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let deadline = Date().addingTimeInterval(4)
        while openDescriptors() > baseline && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertLessThanOrEqual(openDescriptors(), baseline)
    }
}
#endif
