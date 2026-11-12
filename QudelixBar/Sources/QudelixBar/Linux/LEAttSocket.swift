#if os(Linux)
import Foundation
import Glibc

enum LEAttConnectState: Equatable {
    case connected
    case pending
    case failed(Int32)
}

enum LEAttRead: Equatable {
    case pdu([UInt8])
    case timeout
    case closed(String)
}

protocol LEAttSocket: AnyObject {
    func beginConnect(address: String, addressType: String?) throws -> LEAttConnectState
    func pollConnect(timeoutMs: Int32) -> LEAttConnectState
    func read(timeoutMs: Int32) -> LEAttRead
    func write(_ pdu: [UInt8]) -> Bool
    func close()
}

struct LEAttSocketError: Error, CustomStringConvertible {
    let code: Int32
    let what: String

    var description: String { "\(what): \(String(cString: strerror(code)))" }
}

enum LEAttAddress {
    static let family: UInt16 = 31
    static let attributeChannel: UInt16 = 4
    static let publicType: UInt8 = 1
    static let randomType: UInt8 = 2
    static let imageSize = 14

    static func parse(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard part.count == 2, let byte = UInt8(part, radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes.reversed()
    }

    static func addressType(_ text: String?) -> UInt8 {
        text?.lowercased() == "random" ? randomType : publicType
    }

    static func image(bdaddr: [UInt8], type: UInt8) -> [UInt8] {
        precondition(bdaddr.count == 6)
        var bytes: [UInt8] = []
        bytes += [UInt8(family & 0xFF), UInt8(family >> 8)]
        bytes += [0, 0]
        bytes += bdaddr
        bytes += [UInt8(attributeChannel & 0xFF), UInt8(attributeChannel >> 8)]
        bytes += [type, 0]
        return bytes
    }

    static func connectImage(address: String, type: String?) -> [UInt8]? {
        parse(address).map { image(bdaddr: $0, type: addressType(type)) }
    }

    static func bindImage(type: UInt8 = publicType) -> [UInt8] {
        image(bdaddr: [0, 0, 0, 0, 0, 0], type: type)
    }
}

enum LEAttSupport {
    static func canOpen() -> Bool {
        let descriptor = LEAttSystemSocket.openDescriptor()
        guard descriptor >= 0 else { return false }
        Glibc.close(descriptor)
        return true
    }
}

final class LEAttSystemSocket: LEAttSocket {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var shutDown = false

    static let protocolL2CAP: Int32 = 0
    static let bluetoothFamily: Int32 = 31

    static func openDescriptor() -> Int32 {
        let type = Int32(SOCK_SEQPACKET.rawValue) | Int32(SOCK_NONBLOCK.rawValue)
            | Int32(SOCK_CLOEXEC.rawValue)
        return socket(bluetoothFamily, type, protocolL2CAP)
    }

    deinit {
        if descriptor >= 0 { Glibc.close(descriptor) }
    }

    func beginConnect(address: String, addressType: String?) throws -> LEAttConnectState {
        guard let target = LEAttAddress.connectImage(address: address, type: addressType) else {
            throw LEAttSocketError(code: EINVAL, what: "the Bluetooth address is not valid")
        }
        let fd = Self.openDescriptor()
        guard fd >= 0 else {
            throw LEAttSocketError(code: errno, what: "cannot open a Bluetooth LE socket")
        }
        lock.lock()
        descriptor = fd
        lock.unlock()
        let local = LEAttAddress.bindImage()
        let bound = local.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return bind(fd, base.assumingMemoryBound(to: sockaddr.self), socklen_t(raw.count))
        }
        guard bound == 0 else {
            throw LEAttSocketError(code: errno, what: "cannot bind the Bluetooth LE socket")
        }
        let result = target.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return Glibc.connect(fd, base.assumingMemoryBound(to: sockaddr.self), socklen_t(raw.count))
        }
        if result == 0 { return .connected }
        let code = errno
        if code == EINPROGRESS || code == EALREADY || code == EAGAIN { return .pending }
        return .failed(code)
    }

    func pollConnect(timeoutMs: Int32) -> LEAttConnectState {
        guard let fd = currentDescriptor() else { return .failed(EBADF) }
        var entry = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = Glibc.poll(&entry, 1, timeoutMs)
        if ready < 0 {
            return errno == EINTR ? .pending : .failed(errno)
        }
        if ready == 0 { return .pending }
        var failure: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length) == 0 else {
            return .failed(errno)
        }
        if failure != 0 { return .failed(failure) }
        if Int32(entry.revents) & (POLLERR | POLLHUP) != 0 { return .failed(ECONNRESET) }
        return Int32(entry.revents) & POLLOUT != 0 ? .connected : .pending
    }

    func read(timeoutMs: Int32) -> LEAttRead {
        guard let fd = currentDescriptor() else { return .closed("the link was closed") }
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = Glibc.poll(&entry, 1, timeoutMs)
        if ready < 0 {
            if errno == EINTR { return .timeout }
            return .closed(String(cString: strerror(errno)))
        }
        if ready == 0 { return .timeout }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Glibc.read(fd, base, raw.count)
        }
        if count > 0 { return .pdu(Array(buffer[0..<count])) }
        if count == 0 { return .closed("the 5K closed the link") }
        if errno == EINTR || errno == EAGAIN { return .timeout }
        return .closed(String(cString: strerror(errno)))
    }

    func write(_ pdu: [UInt8]) -> Bool {
        guard let fd = currentDescriptor() else { return false }
        let written = pdu.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Glibc.write(fd, base, raw.count)
        }
        return written == pdu.count
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0, !shutDown else { return }
        shutDown = true
        _ = shutdown(descriptor, Int32(SHUT_RDWR))
    }

    private func currentDescriptor() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return descriptor >= 0 && !shutDown ? descriptor : nil
    }
}
#endif
