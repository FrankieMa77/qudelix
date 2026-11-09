#if os(Linux)
import XCTest
import Glibc
@testable import QudelixBar

final class HidrawTransportTests: XCTestCase {
    private var local: Int32 = -1
    private var peer: Int32 = -1
    private var transport: HidrawTransport!
    private let lock = NSLock()
    private var packets: [[UInt8]] = []
    private var disconnects = 0
    private var unusable: [String] = []

    override func setUp() {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &pair), 0)
        local = pair[0]
        peer = pair[1]
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        transport = HidrawTransport()
        transport.onPacket = { [self] bytes in
            lock.lock(); packets.append(bytes); lock.unlock()
        }
        transport.onDisconnected = { [self] in
            lock.lock(); disconnects += 1; lock.unlock()
        }
        transport.onLinkUnusable = { [self] reason in
            lock.lock(); unusable.append(reason); lock.unlock()
        }
        transport.attach(descriptor: local, node: "hidraw9", name: "Qudelix-5K",
                         output: (id: 8, size: 64), inputIDs: [])
    }

    override func tearDown() {
        transport.stop()
        close(peer)
    }

    private func eventually(_ what: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            lock.lock()
            let ok = condition()
            lock.unlock()
            if ok { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func writePeer(_ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { Glibc.write(peer, $0.baseAddress, $0.count) }
    }

    private func readPeer() -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = buffer.withUnsafeMutableBytes { Glibc.read(peer, $0.baseAddress, $0.count) }
        return count > 0 ? Array(buffer[0..<count]) : []
    }

    func testPartialReadsAreDeliveredAsTheyArrive() {
        writePeer([1, 2])
        eventually("first fragment") { packets.flatMap { $0 }.count >= 2 }
        writePeer([3, 4])
        eventually("second fragment") { packets.flatMap { $0 }.count >= 4 }
        lock.lock()
        XCTAssertEqual(packets.flatMap { $0 }, [1, 2, 3, 4])
        lock.unlock()
    }

    func testSendWritesOneFullReportWithTheReportID() {
        transport.send(.setVolume, [1, 2, 3])
        let report = readPeer()
        XCTAssertEqual(report.count, 65)
        XCTAssertEqual(report.first, 8)
    }

    func testInterruptedWriteIsRetried() {
        var calls = 0
        transport.writeFunction = { fd, base, count in
            calls += 1
            if calls == 1 {
                errno = EINTR
                return -1
            }
            return Glibc.write(fd, base, count)
        }
        transport.send(.setVolume, [1])
        XCTAssertEqual(readPeer().count, 65)
        XCTAssertEqual(calls, 2)
    }

    func testShortWritesSuspendTheLinkAfterTheErrorLimit() {
        transport.writeFunction = { _, _, count in count - 1 }
        for _ in 0..<HidrawTransport.txErrorLimit { transport.send(.setVolume, [1]) }
        eventually("unusable notice") { unusable.count == 1 }
        lock.lock()
        XCTAssertTrue(unusable[0].contains("short write"))
        lock.unlock()
    }

    func testDeviceGoneEndsTheReaderAndReportsOnce() {
        close(peer)
        peer = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        eventually("disconnect") { disconnects == 1 }
        XCTAssertFalse(transport.isConnected)
    }

    func testDescriptorIsClosedAfterTheDeviceDisappears() {
        shutdown(peer, Int32(SHUT_RDWR))
        eventually("disconnect") { disconnects == 1 }
        XCTAssertEqual(fcntl(local, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testWriteAfterStopDoesNothing() {
        transport.stop()
        eventually("disconnect") { disconnects == 1 }
        transport.send(.setVolume, [1])
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(readPeer().isEmpty)
    }
}
#endif
