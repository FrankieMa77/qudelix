import XCTest
@testable import QudelixBar

/// The DAC reconstruction filter picker: encoding, domain, and write gating.
///
/// The wire format here was derived from the read side — the same 4-bit
/// field `QxStatusParser.parseDevConfig` decodes into `dacFilterType` — so
/// these tests pin both ends against the same domain (`dacFilters.count`)
/// rather than a hardcoded number that could drift out of sync with it.
final class DacFilterTests: XCTestCase {

    // MARK: - Encoding

    /// SetDacFilter's payload is the raw index, one byte, nothing else.
    func testEncodesEachValidIndexAsItsOwnByte() {
        for i in QxStatusParser.dacFilters.indices {
            XCTAssertEqual(QxPacket.dacFilterPayload(i), [UInt8(i)])
        }
    }

    // MARK: - Domain

    /// Only indices the label table actually defines may reach the wire. An
    /// out-of-domain index must be refused outright — not clamped to the
    /// nearest valid one, which would silently ask for a different filter
    /// than the caller named.
    func testRejectsOutOfDomainIndicesRatherThanClamping() {
        XCTAssertNil(QxPacket.dacFilterPayload(-1))
        XCTAssertNil(QxPacket.dacFilterPayload(QxStatusParser.dacFilters.count))
        XCTAssertNil(QxPacket.dacFilterPayload(255))
        XCTAssertNil(QxPacket.dacFilterPayload(.max))
        XCTAssertNil(QxPacket.dacFilterPayload(.min))
    }

    /// The label table is what both ends of the wire agree on: 8 entries,
    /// so the field's whole 4-bit domain (0...15) is not all valid, and
    /// indices 8...15 must be refused even though they'd fit in the field.
    func testDomainMatchesTheLabelTableNotTheFieldWidth() {
        XCTAssertEqual(QxStatusParser.dacFilters.count, 8)
        for i in 8...15 {
            XCTAssertNil(QxPacket.dacFilterPayload(i))
        }
    }

    // MARK: - Write gating

    /// Disconnected: the setter must be a complete no-op, including the
    /// optimistic local update — nothing may reach the device before the
    /// handshake has identified it, and nothing should ever get written on
    /// connect for this control.
    @MainActor
    func testSetterDoesNothingWhileWritesAreUnauthorised() {
        let c = QudelixController()
        XCTAssertEqual(c.connection, .disconnected)

        c.setDacFilter(2)

        XCTAssertNil(c.dacFilterType)
        XCTAssertNil(c.dacFilterLabel)
    }

    /// Same gate, but with an index the device never defined — the two
    /// failure reasons (not connected, out of domain) must not mask each
    /// other into a false pass.
    @MainActor
    func testSetterRejectsOutOfDomainIndexEvenIfItWereConnected() {
        let c = QudelixController()
        c.setDacFilter(99)
        XCTAssertNil(c.dacFilterType)
    }
}
