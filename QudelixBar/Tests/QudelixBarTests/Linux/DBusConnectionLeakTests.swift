#if os(Linux)
import XCTest
import Glibc
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
}
#endif
