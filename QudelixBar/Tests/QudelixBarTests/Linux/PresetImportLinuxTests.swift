#if os(Linux)
import XCTest
import Foundation
import FoundationNetworking
import Glibc
import Dispatch
@testable import QudelixBar

private final class LoopbackHTTPServer: @unchecked Sendable {
    enum Framing {
        case contentLength(Int)
        case chunked
    }

    let port: UInt16
    private let listener: Int32
    private let status: Int
    private let framing: Framing
    private let body: [UInt8]
    private let chunkSize: Int
    private let lock = NSLock()
    private var sent = 0
    private var stopping = false

    var bytesSent: Int {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    init(status: Int, framing: Framing, body: [UInt8], chunkSize: Int = 1024) throws {
        self.status = status
        self.framing = framing
        self.body = body
        self.chunkSize = chunkSize
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        listener = descriptor
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse,
                   socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        port = UInt16(bigEndian: assigned.sin_port)
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/preset.txt")! }

    func start() {
        DispatchQueue.global().async { [self] in
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            defer { close(connection) }
            var request = [UInt8](repeating: 0, count: 4096)
            _ = recv(connection, &request, request.count, 0)
            var header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\n"
            header += "Content-Type: text/plain\r\n"
            switch framing {
            case .contentLength(let declared):
                header += "Content-Length: \(declared)\r\n"
            case .chunked:
                header += "Transfer-Encoding: chunked\r\n"
            }
            header += "Connection: close\r\n\r\n"
            var headerBytes = Array(header.utf8)
            guard send(connection, &headerBytes, headerBytes.count, Int32(MSG_NOSIGNAL)) > 0 else {
                return
            }
            var offset = 0
            while offset < body.count {
                lock.lock()
                let halt = stopping
                lock.unlock()
                if halt { return }
                let count = min(chunkSize, body.count - offset)
                var payload: [UInt8] = []
                switch framing {
                case .contentLength:
                    payload = Array(body[offset..<(offset + count)])
                case .chunked:
                    payload = Array("\(String(count, radix: 16))\r\n".utf8)
                    payload.append(contentsOf: body[offset..<(offset + count)])
                    payload.append(contentsOf: Array("\r\n".utf8))
                }
                let wrote = send(connection, &payload, payload.count, Int32(MSG_NOSIGNAL))
                if wrote <= 0 { return }
                offset += count
                lock.lock()
                sent = offset
                lock.unlock()
                if body.count > chunkSize { usleep(10_000) }
            }
            if case .chunked = framing {
                var terminator = Array("0\r\n\r\n".utf8)
                _ = send(connection, &terminator, terminator.count, Int32(MSG_NOSIGNAL))
            }
            usleep(20_000)
        }
    }

    func stop() {
        lock.lock()
        stopping = true
        lock.unlock()
        close(listener)
    }
}

private final class PermissiveRedirects: NSObject, URLSessionTaskDelegate {}

final class PresetImportLinuxTests: XCTestCase {
    private let limit = 8192

    override func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
    }

    private func load(_ server: LoopbackHTTPServer) async throws -> PinnedHTTP.BoundedBody {
        server.start()
        return try await PinnedHTTP.boundedLoad(URLRequest(url: server.url),
                                                limit: limit,
                                                session: PinnedHTTP.session,
                                                delegate: PermissiveRedirects())
    }

    func testDeclaredContentLengthAboveTheLimitIsRefusedWithoutReadingTheBody() async throws {
        let payload = [UInt8](repeating: 0x41, count: 256 * 1024)
        let server = try LoopbackHTTPServer(status: 200,
                                            framing: .contentLength(payload.count),
                                            body: payload)
        defer { server.stop() }
        let bounded = try await load(server)
        XCTAssertTrue(bounded.exceededLimit)
        XCTAssertEqual(bounded.response?.statusCode, 200)
        XCTAssertLessThan(server.bytesSent, payload.count)
        XCTAssertThrowsError(try PinnedHTTP.validated(bounded, limit: limit)) { error in
            XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
        }
    }

    func testChunkedBodyPastTheLimitIsCutOff() async throws {
        let payload = [UInt8](repeating: 0x42, count: 256 * 1024)
        let server = try LoopbackHTTPServer(status: 200, framing: .chunked, body: payload)
        defer { server.stop() }
        let bounded = try await load(server)
        XCTAssertTrue(bounded.exceededLimit)
        XCTAssertEqual(bounded.response?.expectedContentLength, -1)
        XCTAssertLessThan(server.bytesSent, payload.count)
        XCTAssertLessThan(bounded.data.count, payload.count)
        XCTAssertThrowsError(try PinnedHTTP.validated(bounded, limit: limit)) { error in
            XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
        }
    }

    func testBodyWithinTheLimitIsReturnedWhole() async throws {
        let text = "Preamp: -6.1 dB\nFilter 1: ON PK Fc 105 Hz Gain 6.4 dB Q 0.70\n"
        let payload = Array(text.utf8)
        let server = try LoopbackHTTPServer(status: 200,
                                            framing: .contentLength(payload.count),
                                            body: payload)
        defer { server.stop() }
        let bounded = try await load(server)
        XCTAssertFalse(bounded.exceededLimit)
        XCTAssertEqual(bounded.response?.statusCode, 200)
        let body = try PinnedHTTP.validated(bounded, limit: limit)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), text)
        XCTAssertEqual(ParametricEQFile.parse(text)?.bands.count, 1)
    }

    func testErrorBodyIsReadOnlyUpToTheErrorCap() async throws {
        let payload = [UInt8](repeating: 0x43, count: 256 * 1024)
        let server = try LoopbackHTTPServer(status: 404,
                                            framing: .contentLength(payload.count),
                                            body: payload)
        defer { server.stop() }
        let bounded = try await load(server)
        XCTAssertFalse(bounded.exceededLimit)
        XCTAssertEqual(bounded.response?.statusCode, 404)
        XCTAssertLessThan(server.bytesSent, payload.count)
        XCTAssertThrowsError(try PinnedHTTP.validated(bounded, limit: limit)) { error in
            let status = error as? HTTPStatusError
            XCTAssertEqual(status?.status, 404)
            XCTAssertLessThanOrEqual(status?.body.count ?? .max, PinnedHTTP.maxErrorBodyBytes)
        }
    }
}
#endif
