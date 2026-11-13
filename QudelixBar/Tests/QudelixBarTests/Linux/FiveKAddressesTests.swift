#if os(Linux)
import XCTest
@testable import QudelixBar

final class FiveKAddressesTests: XCTestCase {
    private func device(_ name: String?, alias: String?, address: String?) -> [String: [String: DBusValue]] {
        var props: [String: DBusValue] = [:]
        if let name { props["Name"] = .string(name) }
        if let alias { props["Alias"] = .string(alias) }
        if let address { props["Address"] = .string(address) }
        return [BluezLinkPlan.deviceInterface: props]
    }

    func testOnlyTheRemoteNameCountsNotTheAlias() {
        let objects: BluezPresence.Objects = [
            "/org/bluez/hci0/dev_A": device("Qudelix-5K", alias: "My Earbuds", address: "aa:bb:cc:dd:ee:01"),
            "/org/bluez/hci0/dev_B": device("Some Speaker", alias: "Qudelix lookalike", address: "AA:BB:CC:DD:EE:02"),
            "/org/bluez/hci0/dev_C": device("QUDELIX 5K Pro", alias: nil, address: "AA:BB:CC:DD:EE:03"),
            "/org/bluez/hci0/dev_D": device("Qudelix", alias: nil, address: nil),
            "/org/bluez/hci0": ["org.bluez.Adapter1": ["Name": .string("Qudelix box")]],
        ]
        XCTAssertEqual(FiveKAddresses.matching(objects), ["AA:BB:CC:DD:EE:01", "AA:BB:CC:DD:EE:03"])
    }

    func testAddressesAreComparedInOneForm() {
        XCTAssertEqual(AudioSink.normalizedAddress("aa_bb_cc_dd_ee_ff"), "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(AudioSink.normalizedAddress("AA:BB:CC:DD:EE:FF"), "AA:BB:CC:DD:EE:FF")
    }
}
#endif
