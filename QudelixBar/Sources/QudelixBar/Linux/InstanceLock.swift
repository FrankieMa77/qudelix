import Foundation
import Glibc

package final class QxInstanceLock {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    package static var defaultURL: URL? {
        DebugLog.logURL()?.deletingLastPathComponent().appendingPathComponent("qudelix.lock")
    }

    package enum Outcome {
        case acquired(QxInstanceLock)
        case busy
        case unavailable(String)
    }

    package static func attempt(at url: URL?) -> Outcome {
        guard let url else { return .acquired(QxInstanceLock(descriptor: -1)) }
        let descriptor = url.path.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else {
            return .unavailable("cannot use the lock file \(url.path): " + String(cString: strerror(errno)))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            close(descriptor)
            if reason == EWOULDBLOCK { return .busy }
            return .unavailable("cannot lock \(url.path): " + String(cString: strerror(reason)))
        }
        return .acquired(QxInstanceLock(descriptor: descriptor))
    }

    package static func acquire(at url: URL?) -> QxInstanceLock? {
        guard case .acquired(let lock) = attempt(at: url) else { return nil }
        return lock
    }

    package static func unavailability(at url: URL?) -> String? {
        switch attempt(at: url) {
        case .acquired(let lock):
            lock.release()
            return nil
        case .busy:
            return nil
        case .unavailable(let message):
            return message
        }
    }

    package func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
