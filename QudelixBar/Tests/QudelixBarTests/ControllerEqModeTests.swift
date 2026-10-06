import XCTest
@testable import QudelixBar

@MainActor
final class ControllerEqModeTests: XCTestCase {
    override func tearDown() async throws {
        DeviceRig.cleanUp()
    }

    private func settledRig() async throws -> DeviceRig {
        let rig = DeviceRig()
        await rig.connect()
        try await Task.sleep(for: .milliseconds(400))
        rig.controller.eqModeRetryDelays = [0.03, 0.03, 0.03]
        rig.controller.clearSendTrace()
        return rig
    }

    private func count(_ needle: String, in c: QudelixController) -> Int {
        c.sendTrace.filter { $0.contains(needle) }.count
    }

    func testAnUnansweredModeSwitchAsksAgainThenGivesUpAndUnlocksTheEq() async throws {
        let rig = try await settledRig()
        let c = rig.controller
        c.setEqMode(twentyBand: true)
        XCTAssertFalse(c.canEditEqNow, "the group is in flux while the switch is pending")
        XCTAssertEqual(count("setEqMode", in: c), 1)

        let deadline = Date().addingTimeInterval(5)
        while !c.canEditEqNow, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(count("reqDevConfig", in: c), 2, "asked twice before giving up")
        XCTAssertTrue(c.canEditEqNow, "an unanswered switch must not lock EQ writes for good")
        XCTAssertEqual(c.eqGroup, .user)
    }

    func testAnAnsweredModeSwitchStopsAskingAndIsNotUnlockedEarly() async throws {
        let rig = try await settledRig()
        let c = rig.controller
        c.setEqMode(twentyBand: true)
        c.debugIngest(Wire.deviceConfig(eqMode: 1, group: 2, slot: 255))
        XCTAssertEqual(c.eqGroup, .b20)
        XCTAssertTrue(c.canEditEqNow)
        c.clearSendTrace()

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(count("reqDevConfig", in: c), 0)
        XCTAssertEqual(c.eqGroup, .b20)
    }

    func testAnOlderRequestsTimerLeavesANewerRequestAlone() async throws {
        let rig = try await settledRig()
        let c = rig.controller
        c.eqModeRetryDelays = [0.5, 0.5, 0.5]
        c.setEqMode(twentyBand: true)
        c.debugIngest(Wire.deviceConfig(eqMode: 1, group: 2, slot: 255))
        XCTAssertEqual(c.eqGroup, .b20)

        try await Task.sleep(for: .milliseconds(350))
        c.setEqMode(twentyBand: false)
        XCTAssertFalse(c.canEditEqNow)
        c.clearSendTrace()

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(count("reqDevConfig", in: c), 0,
                       "the first request was answered; its timer has nothing left to ask")
        XCTAssertFalse(c.canEditEqNow)
    }
}
