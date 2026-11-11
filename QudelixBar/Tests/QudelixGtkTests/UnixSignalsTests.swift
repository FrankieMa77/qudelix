import CGtk
import XCTest
@testable import QudelixGtk

final class UnixSignalsTests: XCTestCase {
    private func iterate(timeout: TimeInterval = 3, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            while g_main_context_iteration(nil, 0) != 0 {}
            usleep(5_000)
        }
    }

    func testTheThreeTerminatingSignalsAreCovered() {
        XCTAssertEqual(Set(UnixSignals.terminating), Set([SIGTERM, SIGINT, SIGHUP]))
    }

    func testEachTerminatingSignalReachesTheHandlerOnTheMainLoop() {
        var received = 0
        let ids = UnixSignals.onTerminate { received += 1 }
        defer { UnixSignals.remove(ids) }
        XCTAssertEqual(ids.count, 3)
        for (index, signal) in UnixSignals.terminating.enumerated() {
            raise(signal)
            iterate { received > index }
            XCTAssertEqual(received, index + 1, "signal \(signal)")
        }
    }

    func testRemovedHandlersNoLongerFire() {
        var received = 0
        let ids = UnixSignals.onTerminate { received += 1 }
        let guardIDs = UnixSignals.onTerminate { }
        UnixSignals.remove(ids)
        raise(SIGHUP)
        iterate(timeout: 0.3) { false }
        UnixSignals.remove(guardIDs)
        XCTAssertEqual(received, 0)
    }
}
