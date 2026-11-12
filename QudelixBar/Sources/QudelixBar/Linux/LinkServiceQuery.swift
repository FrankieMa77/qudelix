#if os(Linux)
import Foundation
import Glibc

enum LinkServiceQuery {
    static func system() -> LinkServiceProbe? {
        guard let path = LinkServicePaths.socketPath() else { return .notRunning }
        return query(socketPath: path)
    }

    static func query(socketPath: String, timeout: TimeInterval = 1) -> LinkServiceProbe {
        let connection = LinkServiceSocket.connect(path: socketPath, sendTimeout: timeout)
        guard connection >= 0 else { return .notRunning }
        defer { close(connection) }
        guard LinkServiceSocket.write(connection, .hello(version: LinkServiceFrame.protocolVersion)) else {
            return .notRunning
        }
        let deadline = Date().addingTimeInterval(timeout)
        var welcomed = false
        while deadline.timeIntervalSinceNow > 0 {
            guard case .frame(let bytes) = LinkServiceSocket.wait(
                connection, timeout: deadline.timeIntervalSinceNow) else { break }
            switch LinkServiceFrame.decode(bytes) {
            case .welcome?: welcomed = true
            case .state(let state)?: return .running(holdsLink: state.connected)
            default: break
            }
        }
        return welcomed ? .running(holdsLink: false) : .notRunning
    }
}
#endif
