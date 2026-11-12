#if os(Linux)
import Foundation
import Glibc

struct LinkServiceState: Codable, Equatable {
    var connected = false
    var attachedName: String?
    var failureReason: String?
    var needsAttention = false
    var unusable: String?
    var busy: String?
}

enum LinkServiceFrame: Equatable {
    case hello(version: UInt8)
    case send(cmd: UInt16, data: [UInt8])
    case shutdown
    case welcome(version: UInt8)
    case state(LinkServiceState)
    case packet([UInt8])

    static let protocolVersion: UInt8 = 1
    static let maxSize = 65_536

    private enum Tag {
        static let hello: UInt8 = 0x01
        static let send: UInt8 = 0x02
        static let shutdown: UInt8 = 0x03
        static let welcome: UInt8 = 0x81
        static let state: UInt8 = 0x82
        static let packet: UInt8 = 0x83
    }

    func encoded() -> [UInt8] {
        switch self {
        case .hello(let version):
            return [Tag.hello, version]
        case .send(let cmd, let data):
            return [Tag.send, UInt8(cmd & 0xFF), UInt8(cmd >> 8)] + data
        case .shutdown:
            return [Tag.shutdown]
        case .welcome(let version):
            return [Tag.welcome, version]
        case .state(let state):
            let json = (try? JSONEncoder().encode(state)) ?? Data()
            return [Tag.state] + [UInt8](json)
        case .packet(let bytes):
            return [Tag.packet] + bytes
        }
    }

    static func decode(_ bytes: [UInt8]) -> LinkServiceFrame? {
        guard let tag = bytes.first else { return nil }
        let body = Array(bytes.dropFirst())
        switch tag {
        case Tag.hello:
            guard body.count == 1 else { return nil }
            return .hello(version: body[0])
        case Tag.send:
            guard body.count >= 2 else { return nil }
            return .send(cmd: UInt16(body[0]) | UInt16(body[1]) << 8, data: Array(body.dropFirst(2)))
        case Tag.shutdown:
            return body.isEmpty ? .shutdown : nil
        case Tag.welcome:
            guard body.count == 1 else { return nil }
            return .welcome(version: body[0])
        case Tag.state:
            guard let state = try? JSONDecoder().decode(LinkServiceState.self, from: Data(body)) else {
                return nil
            }
            return .state(state)
        case Tag.packet:
            return .packet(body)
        default:
            return nil
        }
    }
}

enum LinkServicePaths {
    static let socketName = "link.sock"
    static let lockName = "link-service.lock"
    static let runtimeDirectoryName = "qudelix"

    static var lockURL: URL? {
        QxInstanceLock.defaultURL?.deletingLastPathComponent().appendingPathComponent(lockName)
    }

    static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                           lockURL: URL? = LinkServicePaths.lockURL) -> String? {
        if let runtime = environment["XDG_RUNTIME_DIR"], runtime.hasPrefix("/") {
            let directory = URL(fileURLWithPath: runtime, isDirectory: true)
                .appendingPathComponent(runtimeDirectoryName, isDirectory: true)
            if usable(directory) {
                let path = directory.appendingPathComponent(socketName).path
                if LinkServiceSocket.fits(path) { return path }
            }
        }
        guard let lockURL else { return nil }
        let path = lockURL.deletingLastPathComponent().appendingPathComponent(socketName).path
        return LinkServiceSocket.fits(path) ? path : nil
    }

    private static func usable(_ directory: URL) -> Bool {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard stat(directory.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == getuid()
            && access(directory.path, W_OK) == 0
    }
}

enum LinkServiceReceive {
    case frame([UInt8])
    case timedOut
    case woken
    case closed
}

private struct PeerCredentials {
    var pid: Int32 = 0
    var uid: UInt32 = 0
    var gid: UInt32 = 0
}

enum LinkServiceSocket {
    static func fits(_ path: String) -> Bool {
        path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }

    private static func withAddress<T>(_ path: String,
                                       _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        guard fits(path) else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = path.withCString { strncpy(destination, $0, capacity - 1) }
            }
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private static func makeSocket(nonblocking: Bool) -> Int32 {
        var type = Int32(SOCK_SEQPACKET.rawValue) | Int32(SOCK_CLOEXEC.rawValue)
        if nonblocking { type |= Int32(SOCK_NONBLOCK.rawValue) }
        return socket(AF_UNIX, type, 0)
    }

    static func listen(path: String) -> Int32 {
        let descriptor = makeSocket(nonblocking: true)
        guard descriptor >= 0 else { return -errno }
        let bound = withAddress(path) { bind(descriptor, $0, $1) }
        guard let bound, bound == 0 else {
            let reason = bound == nil ? ENAMETOOLONG : errno
            close(descriptor)
            return -reason
        }
        chmod(path, 0o600)
        guard Glibc.listen(descriptor, 16) == 0 else {
            let reason = errno
            close(descriptor)
            unlink(path)
            return -reason
        }
        return descriptor
    }

    static func connect(path: String, sendTimeout: TimeInterval = 2) -> Int32 {
        let descriptor = makeSocket(nonblocking: false)
        guard descriptor >= 0 else { return -errno }
        let connected = withAddress(path) { Glibc.connect(descriptor, $0, $1) }
        guard let connected, connected == 0 else {
            let reason = connected == nil ? ENAMETOOLONG : errno
            close(descriptor)
            return -reason
        }
        var timeout = timeval(tv_sec: Int(sendTimeout),
                              tv_usec: Int((sendTimeout - floor(sendTimeout)) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        return descriptor
    }

    static func accept(_ listener: Int32) -> Int32 {
        let descriptor = Glibc.accept(listener, nil, nil)
        guard descriptor >= 0 else { return -1 }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        return descriptor
    }

    static func peerUserID(_ descriptor: Int32) -> uid_t? {
        var credentials = PeerCredentials()
        var length = socklen_t(MemoryLayout<PeerCredentials>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0 else {
            return nil
        }
        return credentials.uid
    }

    @discardableResult
    static func write(_ descriptor: Int32, _ frame: LinkServiceFrame, dontWait: Bool = false) -> Bool {
        let bytes = frame.encoded()
        let flags = Int32(MSG_NOSIGNAL) | (dontWait ? Int32(MSG_DONTWAIT) : 0)
        while true {
            let written = bytes.withUnsafeBytes { send(descriptor, $0.baseAddress, bytes.count, flags) }
            if written == bytes.count { return true }
            if written < 0 && errno == EINTR { continue }
            return false
        }
    }

    static func read(_ descriptor: Int32) -> LinkServiceReceive {
        var buffer = [UInt8](repeating: 0, count: LinkServiceFrame.maxSize + 1)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                recv(descriptor, $0.baseAddress, $0.count, Int32(MSG_DONTWAIT))
            }
            if count > 0 {
                guard count <= LinkServiceFrame.maxSize else { return .closed }
                return .frame(Array(buffer.prefix(count)))
            }
            if count == 0 { return .closed }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return .timedOut }
            return .closed
        }
    }

    static func wait(_ descriptor: Int32, wake: Int32 = -1, timeout: TimeInterval) -> LinkServiceReceive {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            var descriptors = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
            let remaining = max(0, deadline.timeIntervalSinceNow)
            let ready = poll(&descriptors, 2, Int32(min(remaining * 1000, 60_000).rounded(.up)))
            if ready < 0 {
                if errno == EINTR { continue }
                return .closed
            }
            if descriptors[1].revents != 0 { return .woken }
            if descriptors[0].revents & Int16(POLLIN) != 0 {
                switch read(descriptor) {
                case .timedOut: break
                case let other: return other
                }
            } else if descriptors[0].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                return .closed
            }
            if Date() >= deadline { return .timedOut }
        }
    }
}
#endif
