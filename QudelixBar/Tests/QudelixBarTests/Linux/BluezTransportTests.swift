#if os(Linux)
import XCTest
import Glibc
@testable import QudelixBar

private let device = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
private let commandPath = device + "/service000c/char000d"
private let responsePath = device + "/service000c/char000f"

final class FakeBus: BluezBus {
    struct Call: Equatable {
        let path: String
        let interface: String
        let method: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var values: [[DBusValue]] = []
    private var handler: ((DBusSignal) -> Void)?
    var objects: BluezLinkPlan.Objects
    var failures: [String: [Error]] = [:]
    var replies: [String: [DBusValue]] = [:]
    private(set) var closed = false
    private(set) var listings = 0

    init(objects: BluezLinkPlan.Objects) {
        self.objects = objects
    }

    func managedObjects() throws -> BluezLinkPlan.Objects {
        lock.lock()
        defer { lock.unlock() }
        listings += 1
        return objects
    }

    func call(path: String, interface: String, method: String, arguments: [DBusValue],
              timeoutMs: Int32) throws -> [DBusValue] {
        lock.lock()
        recorded.append(Call(path: path, interface: interface, method: method,
                             arguments: arguments.map { "\($0)" }))
        values.append(arguments)
        var failure: Error?
        if var queued = failures[method], !queued.isEmpty {
            failure = queued.removeFirst()
            failures[method] = queued
        }
        let reply = replies[method] ?? []
        lock.unlock()
        if let failure { throw failure }
        return reply
    }

    func onSignal(_ handler: @escaping (DBusSignal) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func arguments(ofCall index: Int) -> [DBusValue] {
        lock.lock()
        defer { lock.unlock() }
        return values[index]
    }

    func emit(_ signal: DBusSignal) {
        lock.lock()
        let current = handler
        lock.unlock()
        current?(signal)
    }
}

final class FakeFiveKSocket: LEAttSocket {
    enum Behavior {
        case refuse(Int32)
        case silent
        case fiveK
    }

    private let condition = NSCondition()
    private var inbound: [LEAttRead] = []
    private var behavior: Behavior
    private var connected = false
    private var shut = false
    private(set) var writes: [[UInt8]] = []
    private(set) var closeCount = 0
    private(set) var connectAddress: String?
    private(set) var connectType: String?
    var failOnBegin: LEAttSocketError?
    var greetsOnConnect = false

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    private let service = LEAtt.uuidBytes(GaiaFraming.serviceUUID)
    private let command = LEAtt.uuidBytes(GaiaFraming.commandUUID)
    private let response = LEAtt.uuidBytes(GaiaFraming.responseUUID)

    func beginConnect(address: String, addressType: String?) throws -> LEAttConnectState {
        condition.lock()
        connectAddress = address
        connectType = addressType
        condition.unlock()
        if let failOnBegin { throw failOnBegin }
        return .pending
    }

    func pollConnect(timeoutMs: Int32) -> LEAttConnectState {
        Thread.sleep(forTimeInterval: 0.01)
        condition.lock()
        defer { condition.unlock() }
        if shut { return .failed(EBADF) }
        switch behavior {
        case .refuse(let code):
            return .failed(code)
        case .silent, .fiveK:
            connected = true
            if greetsOnConnect {
                inbound.append(.pdu([0x02, 0x40, 0x00]))
                condition.broadcast()
            }
            return .connected
        }
    }

    func read(timeoutMs: Int32) -> LEAttRead {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while inbound.isEmpty && !shut {
            if !condition.wait(until: deadline) { return .timeout }
        }
        if shut { return .closed("the link was closed") }
        return inbound.removeFirst()
    }

    func write(_ pdu: [UInt8]) -> Bool {
        condition.lock()
        guard !shut else {
            condition.unlock()
            return false
        }
        writes.append(pdu)
        let replies = behavior.isFiveK ? answer(pdu) : []
        for reply in replies { inbound.append(.pdu(reply)) }
        condition.broadcast()
        condition.unlock()
        return true
    }

    func close() {
        condition.lock()
        closeCount += 1
        shut = true
        condition.broadcast()
        condition.unlock()
    }

    func push(_ pdu: [UInt8]) {
        condition.lock()
        inbound.append(.pdu(pdu))
        condition.broadcast()
        condition.unlock()
    }

    func dropLink(_ reason: String = "the 5K closed the link") {
        condition.lock()
        inbound.append(.closed(reason))
        condition.broadcast()
        condition.unlock()
    }

    var written: [[UInt8]] {
        condition.lock()
        defer { condition.unlock() }
        return writes
    }

    var closes: Int {
        condition.lock()
        defer { condition.unlock() }
        return closeCount
    }

    private func group(_ start: UInt16, _ end: UInt16, _ uuid: [UInt8]) -> [UInt8] {
        [0x11, UInt8(4 + uuid.count)] + LEAtt.le16(start) + LEAtt.le16(end) + uuid
    }

    private func decl(_ declaration: UInt16, _ props: UInt8, _ value: UInt16, _ uuid: [UInt8]) -> [UInt8] {
        [0x09, UInt8(5 + uuid.count)] + LEAtt.le16(declaration) + [props] + LEAtt.le16(value) + uuid
    }

    private func answer(_ pdu: [UInt8]) -> [[UInt8]] {
        guard let opcode = pdu.first else { return [] }
        switch opcode {
        case 0x02:
            return [[0x02, 0x40, 0x00], [0x03, 0x40, 0x00]]
        case 0x10:
            switch LEAtt.u16(pdu, 1) {
            case 0x0001: return [group(1, 6, [0x01, 0x18])]
            case 0x0007: return [group(7, 0x0B, [0x00, 0x18])]
            case 0x000C: return [group(0x0C, 0xFFFF, service)]
            default: return [[0x01, 0x10, pdu[1], pdu[2], 0x0A]]
            }
        case 0x08:
            switch LEAtt.u16(pdu, 1) {
            case 0x000C: return [decl(0x0D, 0x08, 0x0E, command)]
            case 0x000E: return [decl(0x0F, 0x12, 0x10, response)]
            default: return [[0x01, 0x08, pdu[1], pdu[2], 0x0A]]
            }
        case 0x04:
            return [[0x05, 0x01, 0x11, 0x00, 0x02, 0x29]]
        case 0x12:
            var out: [[UInt8]] = [[0x13]]
            if LEAtt.u16(pdu, 1) == 0x000E, pdu.count > 5, pdu[3] == 0xF0 {
                out.append([0x1B, 0x10, 0x00, 0xF0, 0x01, 0x81, pdu[5], 0x00, 0x01, 0x02])
            }
            return out
        default:
            return []
        }
    }
}

private extension FakeFiveKSocket.Behavior {
    var isFiveK: Bool {
        if case .fiveK = self { return true }
        return false
    }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var connectedNames: [String] = []
    private var disconnects = 0
    private var unusable: [String] = []
    private var packets: [[UInt8]] = []
    private var sockets: [FakeFiveKSocket] = []
    private var madeAt: [Date] = []
    private var pins: [String] = []

    func connected(_ name: String) { lock.lock(); connectedNames.append(name); lock.unlock() }
    func disconnected() { lock.lock(); disconnects += 1; lock.unlock() }
    func unusable(_ text: String) { lock.lock(); unusable.append(text); lock.unlock() }
    func packet(_ bytes: [UInt8]) { lock.lock(); packets.append(bytes); lock.unlock() }
    func made(_ socket: FakeFiveKSocket) { lock.lock(); sockets.append(socket); madeAt.append(Date()); lock.unlock() }
    var madeTimes: [Date] { lock.lock(); defer { lock.unlock() }; return madeAt }
    func pinned(_ path: String) { lock.lock(); pins.append(path); lock.unlock() }

    var connectCount: Int { lock.lock(); defer { lock.unlock() }; return connectedNames.count }
    var disconnectCount: Int { lock.lock(); defer { lock.unlock() }; return disconnects }
    var unusableTexts: [String] { lock.lock(); defer { lock.unlock() }; return unusable }
    var packetList: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return packets }
    var socketList: [FakeFiveKSocket] { lock.lock(); defer { lock.unlock() }; return sockets }
    var pinList: [String] { lock.lock(); defer { lock.unlock() }; return pins }
}

final class BluezTransportTests: XCTestCase {
    private func objects(connected: Bool = false, resolved: Bool = false, characteristics: Bool = false,
                         adapter: Bool = true, qudelix: Bool = true,
                         addressType: String = "public") -> BluezLinkPlan.Objects {
        var out: BluezLinkPlan.Objects = [:]
        if adapter { out["/org/bluez/hci0"] = ["org.bluez.Adapter1": ["Powered": .boolean(true)]] }
        if qudelix {
            out[device] = ["org.bluez.Device1": [
                "Name": .string("Qudelix-5K"), "Alias": .string("Qudelix-5K"),
                "Address": .string("AA:BB:CC:DD:EE:FF"), "AddressType": .string(addressType),
                "Paired": .boolean(true), "Connected": .boolean(connected),
                "ServicesResolved": .boolean(resolved),
                "UUIDs": .strings(["0000110b-0000-1000-8000-00805f9b34fb"]),
            ]]
        }
        if characteristics {
            out[commandPath] = ["org.bluez.GattCharacteristic1": ["UUID": .string(GaiaFraming.commandUUID)]]
            out[responsePath] = ["org.bluez.GattCharacteristic1": ["UUID": .string(GaiaFraming.responseUUID)]]
        }
        return out
    }

    private func make(bus: FakeBus, events: Events,
                      sockets: @escaping (Int) -> FakeFiveKSocket,
                      relist: TimeInterval = 60,
                      uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime })
        -> BluezTransport {
        var made = 0
        let lock = NSLock()
        let transport = BluezTransport(bus: { bus },
                                       socket: {
                                           lock.lock()
                                           made += 1
                                           let index = made
                                           lock.unlock()
                                           let socket = sockets(index)
                                           events.made(socket)
                                           return socket
                                       },
                                       pinnedPath: { nil },
                                       savePin: { events.pinned($0) },
                                       armedDelay: 0.05,
                                       relistInterval: relist,
                                       noDeviceDelay: 0.05,
                                       uptime: uptime)
        transport.onConnected = { events.connected($0) }
        transport.onDisconnected = { events.disconnected() }
        transport.onLinkUnusable = { events.unusable($0) }
        transport.onPacket = { events.packet($0) }
        return transport
    }

    private func until(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private let allowedMethods: Set<String> = [
        "org.bluez.GattCharacteristic1.AcquireNotify", "org.bluez.GattCharacteristic1.StartNotify",
        "org.bluez.GattCharacteristic1.StopNotify", "org.bluez.GattCharacteristic1.WriteValue",
    ]

    private func assertOnlyAllowedCalls(_ bus: FakeBus, file: StaticString = #filePath, line: UInt = #line) {
        for call in bus.calls {
            XCTAssertTrue(allowedMethods.contains("\(call.interface).\(call.method)"),
                          "forbidden call \(call.interface).\(call.method)", file: file, line: line)
        }
    }

    func testTheLinkComesUpOverOurOwnSocketAndReportsConnected() {
        let bus = FakeBus(objects: objects(connected: true))
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.fiveK) })
        transport.start()
        defer { transport.stop() }
        until("connected") { events.connectCount == 1 }
        XCTAssertTrue(transport.isConnected)
        XCTAssertNil(transport.failureReason)
        let socket = events.socketList[0]
        XCTAssertEqual(socket.connectAddress, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(socket.connectType, "public")
        XCTAssertEqual(socket.written.first, [0x02, 0xF7, 0x00])
        XCTAssertEqual(bus.calls, [])
    }

    func testAnEarlyMTURequestFromTheFiveKIsAnsweredBeforeAnythingElse() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in
            let socket = FakeFiveKSocket(.fiveK)
            socket.greetsOnConnect = true
            return socket
        })
        transport.start()
        defer { transport.stop() }
        until("connected") { events.connectCount == 1 }
        let writes = events.socketList[0].written
        XCTAssertEqual(writes.first, [0x02, 0xF7, 0x00])
        XCTAssertTrue(writes.contains([0x03, 0xF7, 0x00]))
    }

    func testConsecutiveArmedFailuresNeitherListBlueZNorWaitLong() {
        let bus = FakeBus(objects: objects(connected: true))
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.refuse(ECONNREFUSED)) })
        transport.start()
        until("several attempts") { events.socketList.count >= 6 }
        transport.stop()
        XCTAssertEqual(bus.listings, 1)
        let times = events.madeTimes
        for index in 1..<times.count {
            XCTAssertLessThan(times[index].timeIntervalSince(times[index - 1]), 0.3)
        }
    }

    func testALinkEndReArmsAtOnceFromTheCachedAddressWithoutListing() {
        let bus = FakeBus(objects: objects(connected: true))
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.fiveK) })
        transport.start()
        defer { transport.stop() }
        until("connected") { events.connectCount == 1 }
        let dropped = Date()
        events.socketList[0].dropLink()
        until("second socket") { events.socketList.count == 2 }
        XCTAssertLessThan(events.madeTimes[1].timeIntervalSince(dropped), 0.5)
        XCTAssertEqual(bus.listings, 1)
        until("second link") { events.connectCount == 2 }
    }

    func testBlueZIsListedAgainAfterTheIntervalWhileArmed() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events,
                             sockets: { _ in FakeFiveKSocket(.refuse(ECONNREFUSED)) }, relist: 0.3)
        transport.start()
        defer { transport.stop() }
        until("a second listing") { bus.listings >= 2 }
        until("still arming afterwards") { events.socketList.count >= 8 }
    }

    func testASignalForOurDeviceTriggersAListingAndOthersDoNot() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.refuse(ECONNREFUSED)) })
        transport.start()
        defer { transport.stop() }
        until("armed") { events.socketList.count >= 2 }
        XCTAssertEqual(bus.listings, 1)
        bus.emit(DBusSignal(path: device, interface: "org.freedesktop.DBus.Properties",
                            member: "PropertiesChanged",
                            arguments: [.string("org.bluez.Device1"),
                                        .dictionary([("RSSI", .int16(-50))])]))
        bus.emit(DBusSignal(path: device, interface: "org.freedesktop.DBus.Properties",
                            member: "PropertiesChanged",
                            arguments: [.string("org.bluez.Device1"),
                                        .dictionary([("Connected", .boolean(true)),
                                                     ("ServicesResolved", .boolean(true))])]))
        bus.emit(DBusSignal(path: "/org/bluez/hci0", interface: "org.freedesktop.DBus.ObjectManager",
                            member: "InterfacesAdded",
                            arguments: [.objectPath(device + "/fd0"),
                                        .dictionary([("org.bluez.MediaTransport1", .dictionary([]))])]))
        bus.emit(DBusSignal(path: "/org/bluez/hci0/dev_11_22_33_44_55_66",
                            interface: "org.freedesktop.DBus.Properties", member: "PropertiesChanged",
                            arguments: [.string("org.bluez.Device1"),
                                        .dictionary([("Paired", .boolean(true))])]))
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(bus.listings, 1)
        bus.emit(DBusSignal(path: device, interface: "org.freedesktop.DBus.Properties",
                            member: "PropertiesChanged",
                            arguments: [.string("org.bluez.Device1"),
                                        .dictionary([("Paired", .boolean(true))])]))
        until("a second listing") { bus.listings >= 2 }
        bus.emit(DBusSignal(path: "/org/bluez/hci0", interface: "org.freedesktop.DBus.ObjectManager",
                            member: "InterfacesAdded",
                            arguments: [.objectPath(device + "/service000c"),
                                        .dictionary([("org.bluez.GattService1", .dictionary([]))])]))
        until("a third listing") { bus.listings >= 3 }
    }

    func testARandomAddressTypeIsPassedThrough() {
        let bus = FakeBus(objects: objects(addressType: "random"))
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.fiveK) })
        transport.start()
        defer { transport.stop() }
        until("socket") { events.socketList.first?.connectType != nil }
        XCTAssertEqual(events.socketList[0].connectType, "random")
    }

    func testCommandsAreWrittenAsATTRequestsAndRepliesArrive() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.fiveK) })
        transport.start()
        defer { transport.stop() }
        until("connected") { events.connectCount == 1 }
        transport.send(.reqInitData, [])
        until("reply") { !events.packetList.isEmpty }
        let write = events.socketList[0].written.last { $0.first == 0x12 && $0.count > 3 && $0[1] == 0x0E }
        XCTAssertEqual(Array(write?.prefix(5) ?? []), [0x12, 0x0E, 0x00, 0xF0, 0x01])
        XCTAssertEqual(events.pinList, [device])
    }

    func testWhileArmedTheReasonIsTheWaitingTextAndAFailedAttemptReArms() {
        let bus = FakeBus(objects: objects(connected: true))
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { index in
            index < 3 ? FakeFiveKSocket(.refuse(ECONNREFUSED)) : FakeFiveKSocket(.fiveK)
        })
        transport.start()
        defer { transport.stop() }
        until("a second attempt") { events.socketList.count >= 2 }
        XCTAssertEqual(transport.failureReason, BluezLinkFailure.waitingForLink)
        XCTAssertFalse(transport.failureNeedsAttention)
        XCTAssertTrue(BluezLinkFailure.waitingForLink.contains("switch it off and on again"))
        until("connected") { events.connectCount == 1 }
        XCTAssertGreaterThanOrEqual(events.socketList.count, 3)
        XCTAssertNil(transport.failureReason)
        XCTAssertTrue(events.unusableTexts.isEmpty)
    }

    func testEveryListedFailureCodeKeepsTheLinkArmed() {
        for code in [ECONNREFUSED, ENOSYS, EHOSTDOWN, ETIMEDOUT, EBUSY] {
            let bus = FakeBus(objects: objects())
            let events = Events()
            let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.refuse(code)) })
            transport.start()
            until("re-arm after \(code)") { events.socketList.count >= 3 }
            transport.stop()
            XCTAssertTrue(events.unusableTexts.isEmpty)
            XCTAssertEqual(transport.reconnectBackoff, 0.5)
        }
    }

    func testLosingTheLinkReArmsAndConnectsAgain() {
        let bus = FakeBus(objects: objects(connected: true))
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.fiveK) })
        transport.start()
        defer { transport.stop() }
        until("connected") { events.connectCount == 1 }
        events.socketList[0].dropLink()
        until("disconnect") { events.disconnectCount == 1 }
        until("second link") { events.connectCount == 2 }
        XCTAssertEqual(events.socketList.count, 2)
        XCTAssertTrue(transport.isConnected)
    }

    func testTheAudioLinkDroppingDoesNotTearDownOurLEControlLink() {
        let bus = FakeBus(objects: objects(connected: true))
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.fiveK) })
        transport.start()
        defer { transport.stop() }
        until("connected") { events.connectCount == 1 }
        bus.emit(DBusSignal(path: device, interface: "org.freedesktop.DBus.Properties",
                            member: "PropertiesChanged",
                            arguments: [.string("org.bluez.Device1"),
                                        .dictionary([("Connected", .boolean(false))])]))
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(transport.isConnected)
        XCTAssertEqual(events.disconnectCount, 0)
    }

    func testStoppingClosesOurSocketAndNeverTouchesBlueZ() {
        let bus = FakeBus(objects: objects(connected: true))
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.fiveK) })
        transport.start()
        until("connected") { events.connectCount == 1 }
        transport.stopAndWait(timeout: 2)
        XCTAssertGreaterThan(events.socketList[0].closes, 0)
        XCTAssertFalse(transport.isConnected)
        XCTAssertTrue(bus.closed)
        XCTAssertEqual(bus.calls, [])
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(events.socketList.count, 1)
    }

    func testStoppingWhileWaitingIsHonoredQuicklyAndNothingRearms() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.refuse(ECONNREFUSED)) })
        transport.start()
        until("armed") { events.socketList.count >= 1 }
        let started = Date()
        transport.stopAndWait(timeout: 2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        let count = events.socketList.count
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(events.socketList.count, count)
        assertOnlyAllowedCalls(bus)
        XCTAssertEqual(bus.calls, [])
    }

    func testNoDeviceCallsAreEverMadeWhileWaiting() {
        let bus = FakeBus(objects: objects(connected: true))
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.refuse(ECONNREFUSED)) })
        transport.start()
        until("several attempts") { events.socketList.count >= 4 }
        transport.stop()
        XCTAssertEqual(bus.calls, [])
    }

    func testASilentFiveKFailsDiscoveryAndTheLinkIsReArmed() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let started = Date()
        let transport = make(bus: bus, events: events,
                             sockets: { index in index == 1 ? FakeFiveKSocket(.silent) : FakeFiveKSocket(.fiveK) },
                             uptime: { Date().timeIntervalSince(started) * 100 })
        transport.start()
        defer { transport.stop() }
        until("a second socket") { events.socketList.count >= 2 }
        until("connected") { events.connectCount == 1 }
        XCTAssertGreaterThan(events.socketList[0].closes, 0)
        XCTAssertEqual(events.disconnectCount, 0)
    }

    func testNoKnownDeviceWaitsWithoutOpeningASocket() {
        let bus = FakeBus(objects: objects(qudelix: false))
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.fiveK) })
        transport.start()
        defer { transport.stop() }
        until("listings") { bus.listings >= 3 }
        XCTAssertEqual(events.socketList.count, 0)
        XCTAssertEqual(transport.failureReason, BluezLinkFailure.noDeviceKnown)
        bus.objects = objects()
        until("connected once the device is known") { events.connectCount == 1 }
    }

    func testNoAdapterIsAGenuineErrorAnnouncedOnceWithBackoff() {
        let bus = FakeBus(objects: objects(adapter: false))
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.fiveK) })
        transport.start()
        defer { transport.stop() }
        until("backoff") { transport.reconnectBackoff >= 2 }
        XCTAssertEqual(events.unusableTexts.count, 1)
        XCTAssertEqual(events.socketList.count, 0)
    }

    func testABusOutageIsAnnouncedOnceAndKeepsRetrying() {
        struct Down: Error {}
        let events = Events()
        let transport = BluezTransport(bus: { throw Down() },
                                       socket: { FakeFiveKSocket(.fiveK) },
                                       pinnedPath: { nil }, savePin: { _ in })
        transport.onLinkUnusable = { events.unusable($0) }
        transport.start()
        defer { transport.stop() }
        until("backoff", timeout: 10) { transport.reconnectBackoff >= 2 }
        XCTAssertEqual(events.unusableTexts.count, 1)
        XCTAssertFalse(transport.isConnected)
    }

    func testAnUnsupportedBluetoothSocketIsAGenuineErrorWithBackoff() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in
            let socket = FakeFiveKSocket(.fiveK)
            socket.failOnBegin = LEAttSocketError(code: EAFNOSUPPORT, what: "cannot open a Bluetooth LE socket")
            return socket
        })
        transport.start()
        defer { transport.stop() }
        until("backoff") { transport.reconnectBackoff >= 2 }
        XCTAssertEqual(events.unusableTexts.count, 1)
        XCTAssertTrue(events.unusableTexts[0].contains("Use the USB link"))
    }

    private func socketPair() -> (ours: Int32, theirs: Int32) {
        var fds: [Int32] = [0, 0]
        let result = socketpair(AF_UNIX, Int32(SOCK_SEQPACKET.rawValue), 0, &fds)
        XCTAssertEqual(result, 0)
        return (fds[0], fds[1])
    }

    private func adoptionBus(_ pair: (ours: Int32, theirs: Int32)) -> FakeBus {
        let bus = FakeBus(objects: objects(connected: true, resolved: true, characteristics: true))
        bus.replies["AcquireNotify"] = [.unixFD(pair.ours), .uint16(64)]
        return bus
    }

    func testABlueZOwnedLinkIsAdoptedThroughNotifyAndWriteValue() {
        let pair = socketPair()
        defer { close(pair.theirs) }
        let bus = adoptionBus(pair)
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.fiveK) })
        transport.start()
        defer { transport.stop() }
        until("connected") { events.connectCount == 1 }
        XCTAssertEqual(events.socketList.count, 0)
        XCTAssertEqual(bus.calls.map(\.method), ["AcquireNotify"])
        XCTAssertEqual(bus.calls[0].path, responsePath)

        transport.send(.reqInitData, [])
        until("write") { bus.calls.count == 2 }
        let write = bus.calls[1]
        XCTAssertEqual(write.method, "WriteValue")
        XCTAssertEqual(write.interface, "org.bluez.GattCharacteristic1")
        XCTAssertEqual(write.path, commandPath)
        let arguments = bus.arguments(ofCall: 1)
        let bytes = arguments[0].items?.compactMap { item -> UInt8? in
            if case .byte(let value) = item { return value }
            return nil
        }
        XCTAssertEqual(Array(bytes?.prefix(2) ?? []), [0xF0, 0x01])
        let options = arguments[1].dictionaryValue
        XCTAssertEqual(options?["type"]?.stringValue, "request")

        let frame: [UInt8] = [0xF0, 0x01, 0x81, 0x01, 0x00, 0xAB]
        XCTAssertEqual(Glibc.write(pair.theirs, frame, frame.count), frame.count)
        until("packet") { !events.packetList.isEmpty }
        assertOnlyAllowedCalls(bus)
        XCTAssertFalse(bus.calls.contains { $0.method == "AcquireWrite" })
    }

    func testAHeldNotifyChannelIsReleasedAndRetried() {
        let pair = socketPair()
        defer { close(pair.theirs) }
        let bus = adoptionBus(pair)
        bus.failures["AcquireNotify"] = [DBusCallError(name: "org.bluez.Error.NotPermitted",
                                                       message: "Notify acquired")]
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.fiveK) })
        transport.start()
        defer { transport.stop() }
        until("connected") { events.connectCount == 1 }
        XCTAssertEqual(bus.calls.map(\.method), ["AcquireNotify", "StopNotify", "AcquireNotify"])
        assertOnlyAllowedCalls(bus)
    }

    func testAStaleBlueZLinkFallsBackToOurOwnSocket() {
        let bus = FakeBus(objects: objects(connected: true, resolved: true, characteristics: true))
        bus.failures["AcquireNotify"] = [DBusCallError(name: "org.bluez.Error.Failed", message: "Not connected")]
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.fiveK) })
        transport.start()
        defer { transport.stop() }
        until("connected through the socket", timeout: 8) { events.connectCount == 1 }
        XCTAssertEqual(events.socketList.count, 1)
        assertOnlyAllowedCalls(bus)
    }

    func testTheBlueZLinkLossIsDetectedAndTheLinkIsReArmed() {
        let pair = socketPair()
        defer { close(pair.theirs) }
        let bus = adoptionBus(pair)
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.fiveK) })
        transport.start()
        defer { transport.stop() }
        until("connected") { events.connectCount == 1 }
        bus.objects = objects(connected: false)
        bus.emit(DBusSignal(path: device, interface: "org.freedesktop.DBus.Properties",
                            member: "PropertiesChanged",
                            arguments: [.string("org.bluez.Device1"),
                                        .dictionary([("Connected", .boolean(false))])]))
        until("disconnect") { events.disconnectCount == 1 }
        until("armed own socket") { events.socketList.count >= 1 }
        until("connected again") { events.connectCount == 2 }
    }
}
#endif
