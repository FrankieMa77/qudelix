import CoreBluetooth
import XCTest
@testable import QudelixBar

final class BLEReconnectTests: XCTestCase {
    func testARepeatedAttemptIsLoggedOnceUntilSomethingChanges() {
        var gate = AttemptLogGate()
        XCTAssertTrue(gate.shouldLog("pinned"))
        for _ in 0..<50 { XCTAssertFalse(gate.shouldLog("pinned")) }
        XCTAssertTrue(gate.shouldLog("scan"), "a different path is news")
        XCTAssertFalse(gate.shouldLog("scan"))
        XCTAssertTrue(gate.shouldLog("pinned"), "going back is news too")
        gate.reset()
        XCTAssertTrue(gate.shouldLog("pinned"), "a state change starts the story over")
    }

    func testAPinnedConnectIsLeftPendingOnlyOnceTheDeviceHasGoneQuiet() {
        let limit = BLETransport.failuresBeforeAbsent
        XCTAssertFalse(BLETransport.staysPending(failures: 0, state: .connecting))
        XCTAssertFalse(BLETransport.staysPending(failures: limit - 1, state: .connecting))
        XCTAssertTrue(BLETransport.staysPending(failures: limit, state: .connecting))
        XCTAssertTrue(BLETransport.staysPending(failures: limit + 40, state: .connecting))
    }

    func testAPeripheralThatConnectedButStalledIsNeverLeftPending() {
        let limit = BLETransport.failuresBeforeAbsent
        XCTAssertFalse(BLETransport.staysPending(failures: limit + 5, state: .connected))
        XCTAssertFalse(BLETransport.staysPending(failures: limit + 5, state: .disconnecting))
        XCTAssertFalse(BLETransport.staysPending(failures: limit + 5, state: .disconnected))
    }
}
