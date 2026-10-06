import XCTest
@testable import QudelixBar

final class DacFilterTests: XCTestCase {
    func testEncodesEachValidIndexAsItsOwnByte() {
        for i in QxStatusParser.dacFilters.indices {
            XCTAssertEqual(QxPacket.dacFilterPayload(i), [UInt8(i)])
        }
    }

    func testRejectsOutOfDomainIndicesRatherThanClamping() {
        XCTAssertNil(QxPacket.dacFilterPayload(-1))
        XCTAssertNil(QxPacket.dacFilterPayload(QxStatusParser.dacFilters.count))
        XCTAssertNil(QxPacket.dacFilterPayload(255))
        XCTAssertNil(QxPacket.dacFilterPayload(.max))
        XCTAssertNil(QxPacket.dacFilterPayload(.min))
    }

    func testDomainMatchesTheLabelTableNotTheFieldWidth() {
        XCTAssertEqual(QxStatusParser.dacFilters.count, 8)
        for i in 8...15 {
            XCTAssertNil(QxPacket.dacFilterPayload(i))
        }
    }

    @MainActor
    func testSetterDoesNothingWhileWritesAreUnauthorised() {
        let c = QudelixController()
        XCTAssertEqual(c.connection, .disconnected)

        c.setDacFilter(2)

        XCTAssertNil(c.dacFilterType)
        XCTAssertNil(c.dacFilterLabel)
    }

    @MainActor
    func testSetterRejectsOutOfDomainIndexEvenIfItWereConnected() {
        let c = QudelixController()
        c.setDacFilter(99)
        XCTAssertNil(c.dacFilterType)
    }
}
