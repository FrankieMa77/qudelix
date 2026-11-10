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

    private func scenario(connected: Bool, bearerState: BluezBearerState,
                          characteristics: Bool = false) -> BluezPresence.Objects {
        var interfaces = device(name: "Qudelix-5K", uuids: audioUUIDs, connected: connected)
        switch bearerState {
        case .unknown: break
        case .disconnected: interfaces["org.bluez.Bearer.LE1"] = bearer(connected: false)
        case .connected: interfaces["org.bluez.Bearer.LE1"] = bearer(connected: true)
        }
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
                                    managedObjects: { ["/x": self.device(alias: "Qudelix-5K")] }).qudelixKnown())
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

    func testCharacteristicsPresentAreUsedStraightAway() {
        for connected in [true, false] {
            let objects = scenario(connected: connected, bearerState: .unknown, characteristics: true)
            XCTAssertEqual(BluezLinkPlan.step(objects: objects, device: base, scanned: false, seen: false),
                           .useCharacteristics)
        }
    }

    func testADisconnectedBearerGetsAnLEConnect() {
        for connected in [true, false] {
            let objects = scenario(connected: connected, bearerState: .disconnected)
            XCTAssertEqual(BluezLinkPlan.step(objects: objects, device: base, scanned: false, seen: false),
                           .connectBearer)
        }
    }

    func testAConnectedBearerOnlyWaitsForCharacteristics() {
        let objects = scenario(connected: true, bearerState: .connected)
        XCTAssertEqual(BluezLinkPlan.step(objects: objects, device: base, scanned: false, seen: false),
                       .awaitCharacteristics)
    }

    func testAudioConnectedWithoutABearerScansThenConnectsTheDevice() {
        let objects = scenario(connected: true, bearerState: .unknown)
        XCTAssertEqual(BluezLinkPlan.step(objects: objects, device: base, scanned: false, seen: false),
                       .scanForLE)
        XCTAssertEqual(BluezLinkPlan.step(objects: objects, device: base, scanned: true, seen: false),
                       .connectDevice)
        let withBearer = scenario(connected: true, bearerState: .disconnected)
        XCTAssertEqual(BluezLinkPlan.step(objects: withBearer, device: base, scanned: true, seen: false),
                       .connectBearer)
    }

    func testAFullyDisconnectedDeviceScansFirstAndNeedsToBeSeen() {
        let objects = scenario(connected: false, bearerState: .unknown)
        XCTAssertEqual(BluezLinkPlan.step(objects: objects, device: base, scanned: false, seen: false),
                       .scanForLE)
        XCTAssertEqual(BluezLinkPlan.step(objects: objects, device: base, scanned: true, seen: true),
                       .connectDevice)
        XCTAssertEqual(BluezLinkPlan.step(objects: objects, device: base, scanned: true, seen: false),
                       .noLEAdvertisement)
    }

    func testNoStepEverPlansADeviceDisconnectForADeviceConnectedWhenFound() {
        XCTAssertEqual(BluezLinkPlan.stopAction(deviceConnectedWhenFound: true, calledDeviceConnect: true,
                                                calledBearerConnect: false), .none)
        XCTAssertEqual(BluezLinkPlan.stopAction(deviceConnectedWhenFound: true, calledDeviceConnect: true,
                                                calledBearerConnect: true), .disconnectBearer)
        XCTAssertEqual(BluezLinkPlan.stopAction(deviceConnectedWhenFound: true, calledDeviceConnect: false,
                                                calledBearerConnect: true), .disconnectBearer)
    }

    func testStopDisconnectsOnlyWhatWeConnected() {
        XCTAssertEqual(BluezLinkPlan.stopAction(deviceConnectedWhenFound: false, calledDeviceConnect: true,
                                                calledBearerConnect: false), .disconnectDevice)
        XCTAssertEqual(BluezLinkPlan.stopAction(deviceConnectedWhenFound: false, calledDeviceConnect: false,
                                                calledBearerConnect: true), .disconnectBearer)
        XCTAssertEqual(BluezLinkPlan.stopAction(deviceConnectedWhenFound: false, calledDeviceConnect: false,
                                                calledBearerConnect: false), .none)
        XCTAssertEqual(BluezLinkPlan.stopAction(deviceConnectedWhenFound: true, calledDeviceConnect: false,
                                                calledBearerConnect: false), .none)
    }

    func testAddressMaskingKeepsTheLastTwoBytes() {
        XCTAssertEqual(BluezMask.text("AA:BB:CC:DD:EE:FF"), "XX:XX:XX:XX:EE:FF")
        XCTAssertEqual(BluezMask.text("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF/service0010/char0011"),
                       "/org/bluez/hci0/dev_XX_XX_XX_XX_EE_FF/service0010/char0011")
        XCTAssertEqual(BluezMask.text("link on aa:bb:cc:dd:ee:ff failed"), "link on XX:XX:XX:XX:ee:ff failed")
        XCTAssertEqual(BluezMask.text("no address here"), "no address here")
    }

    func testFailureReasonIsOneLine() {
        let text = BluezLinkFailure.text(alias: "Qudelix-5K", connectedForAudio: true,
                                         detail: "no LE advertisement seen in 10 s")
        XCTAssertEqual(text, "found Qudelix-5K (connected for audio), but its Bluetooth LE control link "
            + "did not come up: no LE advertisement seen in 10 s")
        XCTAssertFalse(BluezLinkFailure.text(alias: "x", connectedForAudio: false, detail: "d")
            .contains("for audio"))
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
        XCTAssertEqual(report.devices[0].leBearer, .unknown)
        XCTAssertFalse(report.devices[0].gaiaCharacteristics)
        let lines = BluetoothProbe.lines(report)
        XCTAssertTrue(lines.contains { $0.contains("adapter /org/bluez/hci0: powered, not scanning") })
        XCTAssertTrue(lines.contains { $0.contains("LE bearer") && $0.contains("not known to BlueZ") })
        XCTAssertTrue(lines.contains { $0.contains("0000110b") && $0.contains("A2DP sink") })
        XCTAssertTrue(lines.contains { $0.contains("0000111e") && $0.contains("HFP") })
        XCTAssertFalse(lines.joined().contains("AA:BB:CC:DD"))
        let object = BluetoothProbe.object(report)
        let devices = object["devices"] as? [[String: Any]]
        XCTAssertEqual(devices?.first?["le_bearer"] as? String, "unknown")
        XCTAssertEqual(devices?.first?["connected"] as? Bool, true)
        XCTAssertEqual(object["powered"] as? Bool, true)
        XCTAssertFalse(QxFormat.json(object).isEmpty)
    }

    func testProbeReportForAFiveKWithAConnectedLEBearerAndCharacteristics() {
        var objects = scenario(connected: true, bearerState: .connected, characteristics: true)
        objects[base]?["org.bluez.Device1"]?["UUIDs"] = .strings([GaiaFraming.serviceUUID,
                                                                  "00001107-d102-11e1-9b23-00025b00a5a5"])
        let report = BluezLinkPlan.report(onBus: true, objects: objects)
        XCTAssertEqual(report.devices[0].leBearer, .connected)
        XCTAssertTrue(report.devices[0].gaiaCharacteristics)
        let lines = BluetoothProbe.lines(report)
        XCTAssertTrue(lines.contains { $0.contains("LE bearer") && $0.hasSuffix("connected") })
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
}
#endif
