#if os(Linux)
import XCTest
@testable import QudelixBar

final class BluezLinkPlanTests: XCTestCase {
    private let base = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
    private let audioUUIDs = ["0000110b-0000-1000-8000-00805f9b34fb", "0000111e-0000-1000-8000-00805f9b34fb"]

    private func device(name: String? = nil, alias: String? = nil, uuids: [String] = [],
                        paired: Bool = true, connected: Bool = false) -> [String: [String: DBusValue]] {
        var props: [String: DBusValue] = ["UUIDs": .strings(uuids), "Paired": .boolean(paired),
                                          "Connected": .boolean(connected)]
        if let name { props["Name"] = .string(name) }
        if let alias { props["Alias"] = .string(alias) }
        return ["org.bluez.Device1": props]
    }

    private func bearer(connected: Bool) -> [String: DBusValue] {
        ["Connected": .boolean(connected)]
    }

    private func characteristic(_ uuid: String) -> [String: [String: DBusValue]] {
        ["org.bluez.GattCharacteristic1": ["UUID": .string(uuid)]]
    }

    private func scenario(connected: Bool, characteristics: Bool = false,
                          resolved: Bool? = nil) -> BluezPresence.Objects {
        var interfaces = device(name: "Qudelix-5K", uuids: audioUUIDs, connected: connected)
        interfaces["org.bluez.Device1"]?["ServicesResolved"] = .boolean(resolved ?? characteristics)
        var objects: BluezPresence.Objects = ["/org/bluez/hci0": ["org.bluez.Adapter1": [:]], base: interfaces]
        if characteristics {
            objects[base + "/service0010/char0011"] = characteristic(GaiaFraming.commandUUID)
            objects[base + "/service0010/char0013"] = characteristic(GaiaFraming.responseUUID)
        }
        return objects
    }

    func testMatchingByUuidNameAndAlias() {
        XCTAssertTrue(BluezLinkPlan.looksLikeQudelix(device(uuids: [GaiaFraming.serviceUUID.uppercased()])))
        XCTAssertTrue(BluezLinkPlan.looksLikeQudelix(device(name: "Qudelix-5K", uuids: audioUUIDs)))
        XCTAssertTrue(BluezLinkPlan.looksLikeQudelix(device(name: "other", alias: "my QUDELIX")))
        XCTAssertFalse(BluezLinkPlan.looksLikeQudelix(device(name: "Sony WH-1000", alias: "Headphones",
                                                             uuids: audioUUIDs)))
        XCTAssertFalse(BluezLinkPlan.looksLikeQudelix(["org.bluez.Battery1": ["Name": .string("Qudelix")]]))
        XCTAssertFalse(BluezLinkPlan.looksLikeQudelix([:]))
        XCTAssertTrue(BluezLinkPlan.looksLikeQudelix(properties: ["Name": .string("qudelix")]))
        XCTAssertFalse(BluezLinkPlan.looksLikeQudelix(properties: ["RSSI": .int16(-40)]))
    }

    func testTheTransportRuleIsTheSameRule() {
        XCTAssertTrue(BluezTransport.looksLikeQudelix(device(name: "Qudelix-5K")))
        XCTAssertTrue(BluezPresence(nameHasOwner: { true },
                                    managedObjects: { ["/x": self.device(alias: "Qudelix-5K", connected: true)] })
            .qudelixPresent())
    }

    func testPickOrderIsPinnedThenPairedThenConnectedThenPath() {
        let objects: BluezPresence.Objects = [
            "/a": device(name: "Qudelix", paired: false, connected: true),
            "/b": device(name: "Qudelix", paired: true, connected: false),
            "/c": device(name: "Qudelix", paired: true, connected: true),
            "/d": device(name: "Qudelix", paired: true, connected: true),
            "/e": device(name: "Headphones"),
        ]
        XCTAssertEqual(BluezLinkPlan.pickDevice(in: objects, pinned: "/a"), "/a")
        XCTAssertEqual(BluezLinkPlan.pickDevice(in: objects, pinned: "/e"), "/c")
        XCTAssertEqual(BluezLinkPlan.pickDevice(in: objects, pinned: nil), "/c")
        var unpaired = objects
        unpaired["/c"] = nil
        unpaired["/d"] = nil
        XCTAssertEqual(BluezLinkPlan.pickDevice(in: unpaired, pinned: nil), "/b")
        XCTAssertNil(BluezLinkPlan.pickDevice(in: ["/e": device(name: "Headphones")], pinned: nil))
    }

    func testReadinessNeedsBothTheCharacteristicsAndResolvedServices() {
        let both = scenario(connected: true, characteristics: true, resolved: true)
        XCTAssertEqual(BluezLinkPlan.ready(base, in: both)?.command, base + "/service0010/char0011")
        XCTAssertEqual(BluezLinkPlan.ready(base, in: both)?.response, base + "/service0010/char0013")
        XCTAssertTrue(BluezLinkPlan.servicesResolved(base, in: both))
        let unresolved = scenario(connected: true, characteristics: true, resolved: false)
        XCTAssertNil(BluezLinkPlan.ready(base, in: unresolved))
        XCTAssertFalse(BluezLinkPlan.servicesResolved(base, in: unresolved))
        let bare = scenario(connected: true, characteristics: false, resolved: true)
        XCTAssertNil(BluezLinkPlan.ready(base, in: bare))
        XCTAssertFalse(BluezLinkPlan.servicesResolved("/missing", in: both))
    }

    func testAcquireErrorsAreClassifiedByNameAndMessage() {
        let notConnected = DBusCallError(name: "org.bluez.Error.Failed", message: "Not connected")
        XCTAssertTrue(BluezLinkPlan.isNotConnected(notConnected))
        XCTAssertTrue(BluezLinkPlan.isNotConnected(DBusCallError(name: "org.bluez.Error.NotConnected", message: "")))
        XCTAssertFalse(BluezLinkPlan.isNotConnected(DBusCallError(name: "org.bluez.Error.Failed", message: "Busy")))
        let notify = DBusCallError(name: "org.bluez.Error.NotPermitted", message: "Notify acquired")
        let write = DBusCallError(name: "org.bluez.Error.NotPermitted", message: "Write acquired")
        XCTAssertTrue(BluezLinkPlan.isNotifyHeld(notify))
        XCTAssertFalse(BluezLinkPlan.isNotifyHeld(write))
        XCTAssertFalse(BluezLinkPlan.isNotifyHeld(DBusCallError(name: "org.bluez.Error.Failed",
                                                                message: "Notify acquired")))
    }

    func testBenignAnswersAreRecognizedByTheirSuffix() {
        let already = DBusCallError(name: "org.bluez.Error.AlreadyConnected", message: "")
        let progress = DBusCallError(name: "org.bluez.Error.InProgress", message: "")
        let failed = DBusCallError(name: "org.bluez.Error.Failed", message: "")
        XCTAssertTrue(BluezLinkPlan.isBenign(already, "AlreadyConnected"))
        XCTAssertTrue(BluezLinkPlan.isBenign(progress, "AlreadyConnected", "InProgress"))
        XCTAssertFalse(BluezLinkPlan.isBenign(failed, "AlreadyConnected", "InProgress"))
    }

    func testPresenceNeedsTheDeviceToBeAroundNotJustKnown() {
        let off = device(name: "Qudelix-5K", connected: false)
        XCTAssertFalse(BluezLinkPlan.isPresent(off))
        XCTAssertTrue(BluezLinkPlan.isPresent(device(name: "Qudelix-5K", connected: true)))
        var advertising = off
        advertising["org.bluez.Device1"]?["RSSI"] = .int16(-60)
        XCTAssertTrue(BluezLinkPlan.isPresent(advertising))
        var bearerUp = off
        bearerUp["org.bluez.Bearer.LE1"] = bearer(connected: true)
        XCTAssertTrue(BluezLinkPlan.isPresent(bearerUp))
        var bearerDown = off
        bearerDown["org.bluez.Bearer.LE1"] = bearer(connected: false)
        XCTAssertFalse(BluezLinkPlan.isPresent(bearerDown))
        XCTAssertFalse(BluezLinkPlan.isPresent(device(name: "Sony", connected: true)))
    }

    func testAddressMaskingKeepsTheLastTwoBytes() {
        XCTAssertEqual(BluezMask.text("AA:BB:CC:DD:EE:FF"), "XX:XX:XX:XX:EE:FF")
        XCTAssertEqual(BluezMask.text("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF/service0010/char0011"),
                       "/org/bluez/hci0/dev_XX_XX_XX_XX_EE_FF/service0010/char0011")
        XCTAssertEqual(BluezMask.text("link on aa:bb:cc:dd:ee:ff failed"), "link on XX:XX:XX:XX:ee:ff failed")
        XCTAssertEqual(BluezMask.text("no address here"), "no address here")
    }

    func testProbeReportForAnAudioConnectedFiveKWithoutLE() {
        var interfaces = device(name: "Qudelix-5K", alias: "Qudelix-5K", uuids: audioUUIDs, connected: true)
        interfaces["org.bluez.Device1"]?["Address"] = .string("AA:BB:CC:DD:EE:FF")
        interfaces["org.bluez.Device1"]?["Trusted"] = .boolean(true)
        let objects: BluezPresence.Objects = [
            "/org/bluez/hci0": ["org.bluez.Adapter1": ["Powered": .boolean(true), "Discovering": .boolean(false)]],
            base: interfaces,
        ]
        let report = BluezLinkPlan.report(onBus: true, objects: objects)
        XCTAssertEqual(report.adapterPath, "/org/bluez/hci0")
        XCTAssertEqual(report.devices.count, 1)
        XCTAssertEqual(report.devices[0].address, "XX:XX:XX:XX:EE:FF")
        XCTAssertFalse(report.devices[0].gaiaCharacteristics)
        let lines = BluetoothProbe.lines(report)
        XCTAssertTrue(lines.contains { $0.contains("adapter /org/bluez/hci0: powered, not scanning") })
        XCTAssertTrue(lines.contains { $0.contains("0000110b") && $0.contains("A2DP sink") })
        XCTAssertTrue(lines.contains { $0.contains("0000111e") && $0.contains("HFP") })
        XCTAssertFalse(lines.joined().contains("AA:BB:CC:DD"))
        let object = BluetoothProbe.object(report)
        let devices = object["devices"] as? [[String: Any]]
        XCTAssertEqual(devices?.first?["connected"] as? Bool, true)
        XCTAssertEqual(object["powered"] as? Bool, true)
        XCTAssertFalse(QxFormat.json(object).isEmpty)
    }

    func testProbeReportForAFiveKWithCharacteristics() {
        var objects = scenario(connected: true, characteristics: true)
        objects[base]?["org.bluez.Device1"]?["UUIDs"] = .strings([GaiaFraming.serviceUUID,
                                                                  "00001107-d102-11e1-9b23-00025b00a5a5"])
        let report = BluezLinkPlan.report(onBus: true, objects: objects)
        XCTAssertTrue(report.devices[0].gaiaCharacteristics)
        let lines = BluetoothProbe.lines(report)
        XCTAssertTrue(lines.contains { $0.contains("GAIA over LE") })
        XCTAssertTrue(lines.contains { $0.contains("GAIA over RFCOMM") })
        XCTAssertTrue(lines.contains { $0.contains("GAIA chars") && $0.contains("present") })
    }

    func testProbeReportWithNoDeviceOrNoBus() {
        let empty = BluezLinkPlan.report(onBus: true, objects: ["/org/bluez/hci0": ["org.bluez.Adapter1": [:]]])
        XCTAssertTrue(BluetoothProbe.lines(empty).contains {
            $0.contains("no Qudelix known to BlueZ — pair the 5K in your Bluetooth settings")
        })
        let missing = BluezLinkPlan.report(onBus: false, objects: [:])
        XCTAssertEqual(BluetoothProbe.lines(missing), ["bluetooth     BlueZ is not reachable on the system bus"])
        let object = BluetoothProbe.object(missing)
        XCTAssertEqual(object["bluez_on_bus"] as? Bool, false)
        XCTAssertEqual((object["devices"] as? [Any])?.count, 0)
    }

    func testTheWaitingAndNoDeviceTextsAreFixed() {
        XCTAssertEqual(BluezLinkFailure.waitingForLink,
                       "Waiting for the Qudelix 5K's Bluetooth control link. "
                       + "The 5K offers it for a few seconds after it is switched on. "
                       + "If it is already on, switch it off, wait two minutes and switch it on again.")
        XCTAssertTrue(BluezLinkFailure.noDeviceKnown.contains("Pair it once"))
        XCTAssertEqual(BluezLinkFailure.waitLog("Connection refused"),
                       "BLE waiting for the 5K to offer its control link (Connection refused)")
    }

    func testTheBluetoothAppearanceWaitStaysFortySeconds() {
        XCTAssertEqual(QxLinkTimeouts.bluetoothAppearance, 40)
    }

    func testAddressAndAdapterComeFromBlueZOrFromThePath() {
        var objects = scenario(connected: false)
        XCTAssertEqual(BluezLinkPlan.address(of: base, in: objects), "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(BluezLinkPlan.adapterPath(in: objects), "/org/bluez/hci0")
        XCTAssertNil(BluezLinkPlan.addressType(of: base, in: objects))
        objects[base]?["org.bluez.Device1"]?["Address"] = .string("11:22:33:44:55:66")
        objects[base]?["org.bluez.Device1"]?["AddressType"] = .string("random")
        XCTAssertEqual(BluezLinkPlan.address(of: base, in: objects), "11:22:33:44:55:66")
        XCTAssertEqual(BluezLinkPlan.addressType(of: base, in: objects), "random")
        objects[base]?["org.bluez.Device1"]?["Address"] = .string("garbage")
        XCTAssertEqual(BluezLinkPlan.address(of: base, in: objects), "AA:BB:CC:DD:EE:FF")
        XCTAssertNil(BluezLinkPlan.address(of: "/org/bluez/hci0/other", in: objects))
        XCTAssertNil(BluezLinkPlan.adapterPath(in: [:]))
    }

    func testTheProbeSaysWhetherAnLEControlSocketCanBeOpened() {
        let objects = scenario(connected: false)
        for (value, text) in [(true as Bool?, "this machine can open one"),
                              (false, "this machine cannot open one"), (nil, "not checked")] {
            let report = BluezLinkPlan.report(onBus: true, objects: objects, leSocket: value)
            let lines = BluetoothProbe.lines(report)
            XCTAssertTrue(lines.contains { $0.contains("LE control socket") && $0.contains(text) }, text)
            XCTAssertEqual(BluetoothProbe.object(report)["le_control_socket"] as? Bool, value)
        }
    }
}
#endif
