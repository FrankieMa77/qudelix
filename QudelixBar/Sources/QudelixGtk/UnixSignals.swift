import CGtk
import Foundation

private final class TerminateBox {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }
}

package enum UnixSignals {
    package static let terminating: [Int32] = [SIGTERM, SIGINT, SIGHUP]

    @discardableResult
    package static func onTerminate(_ handler: @escaping () -> Void) -> [UInt32] {
        let box = Unmanaged.passRetained(TerminateBox(handler)).toOpaque()
        return terminating.map { signal in
            g_unix_signal_add(signal, { data in
                guard let data else { return 1 }
                Unmanaged<TerminateBox>.fromOpaque(data).takeUnretainedValue().handler()
                return 1
            }, box)
        }
    }

    package static func remove(_ ids: [UInt32]) {
        for id in ids { g_source_remove(id) }
    }
}
