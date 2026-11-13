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
    var listingDelay: TimeInterval = 0
    var listingFailures: [Error] = []
    var alive = true

    var isAlive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return alive
    }

    func setObjects(_ updated: BluezLinkPlan.Objects) {
        lock.lock()
        objects = updated
        lock.unlock()
    }

    func setListingDelay(_ delay: TimeInterval) {
        lock.lock()
        listingDelay = delay
        lock.unlock()
    }

    func setAlive(_ value: Bool) {
        lock.lock()
        alive = value
        lock.unlock()
    }

    func failNextListings(_ errors: [Error]) {
        lock.lock()
        listingFailures = errors
        lock.unlock()
    }

    init(objects: BluezLinkPlan.Objects) {
        self.objects = objects
    }

    func managedObjects() throws -> BluezLinkPlan.Objects {
        lock.lock()
        listings += 1
        let delay = listingDelay
        let failure = listingFailures.isEmpty ? nil : listingFailures.removeFirst()
        let current = objects
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if let failure { throw failure }
        return current
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
        case pending
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
    var rejectWrite: ((Int) -> Bool)?
    private var muteWrites = false
    private var commandWrites = 0
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
        case .pending:
            condition.unlock()
            Thread.sleep(forTimeInterval: 0.05)
            condition.lock()
            return shut ? .failed(EBADF) : .pending
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

    func setMute(_ value: Bool) {
        condition.lock()
        muteWrites = value
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
            if LEAtt.u16(pdu, 1) == 0x000E {
                commandWrites += 1
                if muteWrites { return [] }
                if rejectWrite?(commandWrites) == true { return [[0x01, 0x12, 0x0E, 0x00, 0x03]] }
            }
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
                         addressType: String = "public", searching: Bool? = nil) -> BluezLinkPlan.Objects {
        var out: BluezLinkPlan.Objects = [:]
        if adapter {
            var props: [String: DBusValue] = ["Powered": .boolean(true)]
            if let searching { props["Discovering"] = .boolean(searching) }
            out["/org/bluez/hci0"] = ["org.bluez.Adapter1": props]
        }
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
                      progress: TimeInterval = 0.05,
                      floor: TimeInterval = 0.05,
                      ceiling: TimeInterval = 0.2,
                      poweredOffDelay: TimeInterval = 30,
                      searchDelay: TimeInterval = 0.2,
                      busFactory: (() -> FakeBus)? = nil,
                      uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime })
        -> BluezTransport {
        var made = 0
        let lock = NSLock()
        let transport = BluezTransport(bus: { busFactory?() ?? bus },
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
                                       searchNoticeDelay: searchDelay,
                                       relistInterval: relist,
                                       noDeviceDelay: 0.05,
                                       poweredOffDelay: poweredOffDelay,
                                       progressSeconds: progress,
                                       backoffFloor: floor,
                                       backoffCeiling: ceiling,
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

    func testReleasingAStartedTransportWithoutStopClosesItsBus() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        var transport: BluezTransport? = make(bus: bus, events: events,
                                              sockets: { _ in FakeFiveKSocket(.silent) })
        transport?.start()
        until("bus used") { bus.listings > 0 }
        transport = nil
        until("bus closed") { bus.closed }
    }

    func testStopFollowedByAnImmediateReleaseClosesTheBus() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        var transport: BluezTransport? = make(bus: bus, events: events,
                                              sockets: { _ in FakeFiveKSocket(.silent) })
        transport?.start()
        until("bus used") { bus.listings > 0 }
        transport?.stop()
        transport = nil
        until("bus closed") { bus.closed }
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
            XCTAssertLessThan(times[index].timeIntervalSince(times[index - 1]), 1)
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
        XCTAssertLessThan(events.madeTimes[1].timeIntervalSince(dropped), 1.5)
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

    func testStartingTwiceArmsOnlyOneConnect() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.silent) })
        transport.start()
        transport.start()
        transport.start()
        defer { transport.stop() }
        until("armed") { events.socketList.count >= 1 }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(bus.listings, 1)
        XCTAssertTrue(transport.keepsArmed)
    }

    func testRecyclingAnUpLinkDropsOurSocketAndReArmsWithoutNotifying() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.fiveK) })
        transport.start()
        defer { transport.stop() }
        until("connected") { events.connectCount == 1 }
        XCTAssertEqual(transport.attachedName, "Qudelix-5K")
        transport.recycle()
        until("second socket") { events.socketList.count == 2 }
        XCTAssertGreaterThan(events.socketList[0].closes, 0)
        XCTAssertEqual(events.disconnectCount, 0)
        until("second link") { events.connectCount == 2 }
        XCTAssertEqual(bus.listings, 1)
    }

    func testRecyclingALinkThatIsNotUpDoesNothing() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.refuse(ECONNREFUSED)) })
        transport.start()
        defer { transport.stop() }
        until("armed") { events.socketList.count >= 2 }
        transport.recycle()
        XCTAssertNil(transport.attachedName)
        XCTAssertFalse(transport.isConnected)
    }

    func testAGenuineErrorIsAlsoTheFailureReason() {
        let bus = FakeBus(objects: objects(adapter: false))
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.fiveK) })
        transport.start()
        defer { transport.stop() }
        until("announced") { !events.unusableTexts.isEmpty }
        XCTAssertEqual(transport.failureReason, events.unusableTexts[0])
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
        XCTAssertTrue(BluezLinkFailure.waitingForLink.contains("wait two minutes"))
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
        XCTAssertLessThan(Date().timeIntervalSince(started), 4.5)
        let count = events.socketList.count
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(events.socketList.count, count)
        assertOnlyAllowedCalls(bus)
        XCTAssertEqual(bus.calls, [])
    }

    func testAStopFollowedByAStartWhileTheConnectIsPendingIsHonoredAndTheNewLinkSurvives() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events,
                             sockets: { $0 == 1 ? FakeFiveKSocket(.pending) : FakeFiveKSocket(.fiveK) })
        transport.start()
        defer { transport.stop() }
        until("armed") { events.socketList.count == 1 }
        transport.stop()
        transport.start()
        until("the first connect is closed") { events.socketList.first?.closes ?? 0 > 0 }
        until("connected") { events.connectCount == 1 }
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(transport.isConnected)
        XCTAssertEqual(events.disconnectCount, 0)
    }

    private let searchStartedLog = "BLE another program started searching for Bluetooth devices"
    private let searchStoppedLog = "BLE another program stopped searching for Bluetooth devices"
    private let audioUpLog = "BLE the 5K's audio link is up"
    private let audioDownLog = "BLE the 5K's audio link is down"

    private func audioLink(_ on: Bool, _ bus: FakeBus) {
        bus.emit(DBusSignal(path: device, interface: "org.freedesktop.DBus.Properties",
                            member: "PropertiesChanged",
                            arguments: [.string("org.bluez.Device1"),
                                        .dictionary([("Connected", .boolean(on))])]))
    }

    func testEverySearchChangeIsLoggedEvenWhenItIsTooShortToShowTheNotice() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.pending) },
                             searchDelay: 30)
        let startedBefore = logCount(searchStartedLog)
        let stoppedBefore = logCount(searchStoppedLog)
        transport.start()
        defer { transport.stop() }
        until("armed") { events.socketList.count == 1 }
        discovering(true, bus)
        discovering(false, bus)
        discovering(true, bus)
        until("three entries") {
            self.logCount(self.searchStartedLog) - startedBefore == 2
                && self.logCount(self.searchStoppedLog) - stoppedBefore == 1
        }
        XCTAssertEqual(transport.failureReason, BluezLinkFailure.waitingForLink)
    }

    func testTheFiveKsAudioLinkGoingUpAndDownIsLoggedAndOtherDevicesAreNot() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.pending) })
        let upBefore = logCount(audioUpLog)
        let downBefore = logCount(audioDownLog)
        transport.start()
        defer { transport.stop() }
        until("armed") { events.socketList.count == 1 }
        audioLink(true, bus)
        audioLink(false, bus)
        audioLink(true, bus)
        bus.emit(DBusSignal(path: "/org/bluez/hci0/dev_11_22_33_44_55_66",
                            interface: "org.freedesktop.DBus.Properties", member: "PropertiesChanged",
                            arguments: [.string("org.bluez.Device1"),
                                        .dictionary([("Connected", .boolean(true))])]))
        until("the entries") {
            self.logCount(self.audioUpLog) - upBefore == 2 && self.logCount(self.audioDownLog) - downBefore == 1
        }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(logCount(audioUpLog) - upBefore, 2)
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

    private func powered(_ on: Bool, _ base: BluezLinkPlan.Objects) -> BluezLinkPlan.Objects {
        var out = base
        out["/org/bluez/hci0"] = ["org.bluez.Adapter1": ["Powered": .boolean(on)]]
        return out
    }

    func testQueuedWritesAreDrainedBeforeStopAndWaitClosesTheSocket() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.fiveK) })
        transport.start()
        until("connected") { events.connectCount == 1 }
        transport.send(.setEqEnable, [1])
        transport.send(.saveAll, [])
        transport.stopAndWait(timeout: 3)
        let commandWrites = events.socketList[0].written.filter { $0.first == 0x12 && LEAtt.u16($0, 1) == 0x000E }
        XCTAssertEqual(commandWrites.count, 2)
        XCTAssertGreaterThan(events.socketList[0].closes, 0)
    }

    func testRejectedWritesInterleavedWithAcceptedOnesNeverEndTheLink() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in
            let socket = FakeFiveKSocket(.fiveK)
            socket.rejectWrite = { $0 % 2 == 0 }
            return socket
        })
        transport.start()
        defer { transport.stop() }
        until("connected") { events.connectCount == 1 }
        for _ in 0..<24 { transport.send(.setVolume, [0, 0]) }
        let socket = events.socketList[0]
        until("all writes sent") {
            socket.written.filter { $0.first == 0x12 && LEAtt.u16($0, 1) == 0x000E }.count == 24
        }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(events.disconnectCount, 0)
        XCTAssertTrue(events.unusableTexts.isEmpty)
        XCTAssertTrue(transport.isConnected)
    }

    func testFiveRejectionsInARowEndTheLinkAndTheAppSeesIt() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { index in
            let socket = FakeFiveKSocket(.fiveK)
            if index == 1 { socket.rejectWrite = { _ in true } }
            return socket
        })
        transport.start()
        defer { transport.stop() }
        until("connected") { events.connectCount == 1 }
        for _ in 0..<8 { transport.send(.setVolume, [0, 0]) }
        until("link ended") { events.disconnectCount == 1 }
        XCTAssertEqual(events.unusableTexts.count, 1)
        until("armed again") { events.socketList.count >= 2 }
        until("second link") { events.connectCount == 2 }
    }

    func testTimersStillRunWhileNotificationsKeepArriving() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.fiveK) })
        transport.start()
        defer { transport.stop() }
        until("connected") { events.connectCount == 1 }
        let socket = events.socketList[0]
        socket.setMute(true)
        transport.send(.setVolume, [0, 0])
        let deadline = Date().addingTimeInterval(7)
        while events.disconnectCount == 0, Date() < deadline {
            socket.push([0x1B, 0x10, 0x00, 0xAA, 0xBB])
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(events.disconnectCount, 1)
    }

    func testAnArmedConnectThatKeepsFailingAtOnceBacksOff() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events,
                             sockets: { _ in FakeFiveKSocket(.refuse(EHOSTUNREACH)) },
                             progress: 0.2, floor: 0.2, ceiling: 1)
        transport.start()
        defer { transport.stop() }
        Thread.sleep(forTimeInterval: 3)
        let count = events.socketList.count
        XCTAssertGreaterThanOrEqual(count, 3)
        XCTAssertLessThanOrEqual(count, 6)
        let times = events.madeTimes
        XCTAssertGreaterThan(times[3].timeIntervalSince(times[2]), times[2].timeIntervalSince(times[1]))
    }

    func testAPoweredOffAdapterGivesTheReasonOpensNoSocketAndPoweringOnArmsAtOnce() {
        let base = objects()
        let bus = FakeBus(objects: powered(false, base))
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.pending) })
        transport.start()
        defer { transport.stop() }
        until("reason") { transport.failureReason == BluezLinkFailure.adapterOff }
        XCTAssertEqual(BluezLinkFailure.adapterOff,
                       "Bluetooth is turned off on this computer. Turn it on and Qudelix finds the 5K again; "
                       + "if it doesn't within a minute, switch the 5K off and on.")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(events.socketList.isEmpty)
        bus.setObjects(powered(true, base))
        bus.emit(DBusSignal(path: "/org/bluez/hci0", interface: "org.freedesktop.DBus.Properties",
                            member: "PropertiesChanged",
                            arguments: [.string("org.bluez.Adapter1"),
                                        .dictionary([("Powered", .boolean(true))])]))
        until("armed", timeout: 2) { events.socketList.count == 1 }
        XCTAssertEqual(transport.failureReason, BluezLinkFailure.waitingForLink)
    }

    private let searchingLog = "BLE another program is searching for Bluetooth devices; "
        + "the 5K's connection window can be missed until it stops"
    private let stoppedLog = "BLE the other program stopped searching for Bluetooth devices"

    private func logCount(_ needle: String) -> Int {
        DebugLog.shared.flush()
        guard let url = DebugLog.shared.fileURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.components(separatedBy: needle).count - 1
    }

    private func discovering(_ on: Bool, _ bus: FakeBus) {
        bus.emit(DBusSignal(path: "/org/bluez/hci0", interface: "org.freedesktop.DBus.Properties",
                            member: "PropertiesChanged",
                            arguments: [.string("org.bluez.Adapter1"),
                                        .dictionary([("Discovering", .boolean(on))])]))
    }

    func testASearchLongerThanTheDebounceShowsTheNoticeOnceAndStoppingRestoresTheWaitingText() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.pending) })
        let searchingBefore = logCount(searchingLog)
        let stoppedBefore = logCount(stoppedLog)
        transport.start()
        defer { transport.stop() }
        until("armed") { events.socketList.count == 1 }
        XCTAssertEqual(transport.failureReason, BluezLinkFailure.waitingForLink)
        discovering(true, bus)
        until("the notice") { transport.failureReason == BluezLinkFailure.otherProgramSearching }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(transport.failureReason, BluezLinkFailure.otherProgramSearching)
        XCTAssertFalse(transport.failureNeedsAttention)
        XCTAssertEqual(logCount(searchingLog) - searchingBefore, 1)
        discovering(false, bus)
        until("the waiting text") { transport.failureReason == BluezLinkFailure.waitingForLink }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(logCount(stoppedLog) - stoppedBefore, 1)
        XCTAssertEqual(logCount(searchingLog) - searchingBefore, 1)
    }

    func testAListingThatAlreadySearchesShowsTheNoticeAfterTheDebounce() {
        let bus = FakeBus(objects: objects(searching: true))
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.pending) },
                             searchDelay: 0.4)
        transport.start()
        defer { transport.stop() }
        until("armed") { events.socketList.count == 1 }
        XCTAssertEqual(transport.failureReason, BluezLinkFailure.waitingForLink)
        until("the notice") { transport.failureReason == BluezLinkFailure.otherProgramSearching }
    }

    func testASearchChangeNeitherRelistsNorStartsANewConnect() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.pending) })
        transport.start()
        defer { transport.stop() }
        until("armed") { events.socketList.count == 1 }
        let listings = bus.listings
        discovering(true, bus)
        until("the notice") { transport.failureReason == BluezLinkFailure.otherProgramSearching }
        discovering(false, bus)
        until("the waiting text") { transport.failureReason == BluezLinkFailure.waitingForLink }
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(bus.listings, listings)
        XCTAssertEqual(events.socketList.count, 1)
        XCTAssertEqual(events.socketList[0].closes, 0)
    }

    func testASearchShorterThanTheDebounceNeverChangesTheText() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.pending) },
                             searchDelay: 1.0)
        let searchingBefore = logCount(searchingLog)
        let stoppedBefore = logCount(stoppedLog)
        transport.start()
        defer { transport.stop() }
        until("armed") { events.socketList.count == 1 }
        discovering(true, bus)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(transport.failureReason, BluezLinkFailure.waitingForLink)
        discovering(false, bus)
        Thread.sleep(forTimeInterval: 1.3)
        XCTAssertEqual(transport.failureReason, BluezLinkFailure.waitingForLink)
        XCTAssertEqual(logCount(searchingLog) - searchingBefore, 0)
        XCTAssertEqual(logCount(stoppedLog) - stoppedBefore, 0)
    }

    func testTheSearchNoticeNeverReplacesTheAdapterOffText() {
        let base = objects(searching: true)
        let bus = FakeBus(objects: powered(false, base))
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.pending) })
        transport.start()
        defer { transport.stop() }
        until("reason") { transport.failureReason == BluezLinkFailure.adapterOff }
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(transport.failureReason, BluezLinkFailure.adapterOff)
    }

    func testAnAdapterSwitchedOffWhilePendingClosesTheSocketAndShowsTheReason() {
        let base = objects()
        let bus = FakeBus(objects: base)
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.pending) })
        transport.start()
        defer { transport.stop() }
        until("armed") { events.socketList.count == 1 }
        bus.setObjects(powered(false, base))
        bus.emit(DBusSignal(path: "/org/bluez/hci0", interface: "org.freedesktop.DBus.Properties",
                            member: "PropertiesChanged",
                            arguments: [.string("org.bluez.Adapter1"),
                                        .dictionary([("Powered", .boolean(false))])]))
        until("reason") { transport.failureReason == BluezLinkFailure.adapterOff }
        XCTAssertGreaterThan(events.socketList[0].closes, 0)
    }

    func testADeadBusIsDroppedAndTheNextListingOpensANewOne() {
        let first = FakeBus(objects: objects())
        first.failNextListings([DBusCallError(name: "org.freedesktop.DBus.Error.Disconnected",
                                              message: "Connection is closed")])
        let second = FakeBus(objects: objects())
        let lock = NSLock()
        var opened = 0
        let events = Events()
        let transport = make(bus: first, events: events,
                             sockets: { _ in FakeFiveKSocket(.pending) },
                             busFactory: {
                                 lock.lock()
                                 defer { lock.unlock() }
                                 opened += 1
                                 return opened == 1 ? first : second
                             })
        transport.start()
        defer { transport.stop() }
        until("armed on the new bus", timeout: 15) { events.socketList.count == 1 }
        XCTAssertTrue(first.closed)
        XCTAssertGreaterThan(second.listings, 0)
    }

    func testABusThatReportsItselfDeadIsReplacedBeforeTheNextListing() {
        let first = FakeBus(objects: objects(qudelix: false))
        let second = FakeBus(objects: objects())
        let lock = NSLock()
        var opened = 0
        let events = Events()
        let transport = make(bus: first, events: events,
                             sockets: { _ in FakeFiveKSocket(.pending) },
                             busFactory: {
                                 lock.lock()
                                 defer { lock.unlock() }
                                 opened += 1
                                 return opened == 1 ? first : second
                             })
        transport.start()
        defer { transport.stop() }
        until("watching") { first.listings >= 2 }
        first.setAlive(false)
        until("armed on the new bus") { events.socketList.count == 1 }
        XCTAssertEqual(opened, 2)
        XCTAssertTrue(first.closed)
    }

    func testARelistLeavesThePendingConnectAloneWhileTheTargetIsUnchanged() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.pending) },
                             relist: 0.5)
        transport.start()
        defer { transport.stop() }
        until("armed") { events.socketList.count == 1 }
        bus.setListingDelay(0.6)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertGreaterThanOrEqual(bus.listings, 3)
        XCTAssertEqual(events.socketList.count, 1)
        XCTAssertEqual(events.socketList[0].closes, 0)
        bus.setListingDelay(0)
        var changed = objects()
        changed[device]?["org.bluez.Device1"]?["Paired"] = .boolean(false)
        bus.setObjects(changed)
        until("replaced", timeout: 5) { events.socketList.count == 2 }
        XCTAssertGreaterThan(events.socketList[0].closes, 0)
    }

    func testARelistThatFailsKeepsThePendingConnect() {
        let bus = FakeBus(objects: objects())
        let events = Events()
        let transport = make(bus: bus, events: events, sockets: { _ in FakeFiveKSocket(.pending) },
                             relist: 0.3)
        transport.start()
        defer { transport.stop() }
        until("armed") { events.socketList.count == 1 }
        bus.failNextListings([DBusCallError(name: "org.freedesktop.DBus.Error.NoReply", message: "timed out")])
        until("relisted") { bus.listings >= 3 }
        XCTAssertEqual(events.socketList.count, 1)
        XCTAssertEqual(events.socketList[0].closes, 0)
    }

    func testOnlyTheGattCharacteristicCallsAreAllowedOnTheSystemBus() {
        for method in ["AcquireNotify", "StopNotify", "WriteValue"] {
            XCTAssertNoThrow(try SystemBluezBus.requireAllowed("org.bluez.GattCharacteristic1", method))
        }
        let refused = [("org.bluez.Device1", "Connect"), ("org.bluez.Device1", "Disconnect"),
                       ("org.bluez.Device1", "Pair"), ("org.bluez.Adapter1", "StartDiscovery"),
                       ("org.freedesktop.DBus.Properties", "Set"),
                       ("org.bluez.GattCharacteristic1", "StartNotify"),
                       ("org.bluez.GattCharacteristic1", "ReadValue")]
        for (interface, method) in refused {
            XCTAssertThrowsError(try SystemBluezBus.requireAllowed(interface, method), "\(interface).\(method)")
        }
    }
}
#endif
