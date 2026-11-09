import CGtk
import Foundation
@testable import QudelixBar
import XCTest
@testable import QudelixGtk

private final class CallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var reply: OpaquePointer?
    var failure: String?

    func finish(reply: OpaquePointer?, failure: String?) {
        lock.lock()
        self.reply = reply
        self.failure = failure
        finished = true
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}

private final class SignalCounter {
    var count = 0
    var last: String?
}

private final class WatcherNameBox {
    var acquired = false
}

private final class FakeWatcher {
    static let xml = """
    <node>
      <interface name="org.kde.StatusNotifierWatcher">
        <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
        <property name="ProtocolVersion" type="i" access="read"/>
        <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
        <method name="RegisterStatusNotifierItem">
          <arg type="s" name="service" direction="in"/>
        </method>
        <method name="RegisterStatusNotifierHost">
          <arg type="s" name="service" direction="in"/>
        </method>
      </interface>
    </node>
    """

    private let connection: OpaquePointer
    private var object: DBusObject?
    private var ownerID: UInt32 = 0
    private let box = WatcherNameBox()
    private(set) var registered: [String] = []

    init(connection: OpaquePointer) {
        self.connection = connection
    }

    var hasName: Bool { box.acquired }

    func start() throws {
        object = try DBusObject(connection: connection, path: StatusNotifier.watcherPath, xml: Self.xml,
                                onMethod: { [unowned self] method, parameters, invocation in
                                    if method == "RegisterStatusNotifierItem",
                                       let service = GV.readString(parameters, 0) {
                                        self.registered.append(service)
                                    }
                                    DBusObject.reply(invocation, nil)
                                },
                                onProperty: { [unowned self] name in
                                    switch name {
                                    case "IsStatusNotifierHostRegistered": return GV.bool(true)
                                    case "ProtocolVersion": return GV.int32(0)
                                    case "RegisteredStatusNotifierItems": return GV.stringArray(self.registered)
                                    default: return nil
                                    }
                                })
        ownerID = g_bus_own_name_on_connection(connection, StatusNotifier.watcherName, G_BUS_NAME_OWNER_FLAGS_NONE,
            { _, _, data in
                Unmanaged<WatcherNameBox>.fromOpaque(data!).takeUnretainedValue().acquired = true
            }, nil, Unmanaged.passUnretained(box).toOpaque(), nil)
    }

    func stop() {
        if ownerID != 0 { g_bus_unown_name(ownerID); ownerID = 0 }
        object?.unregister()
        object = nil
        box.acquired = false
    }
}

private struct LayoutNode {
    var id: Int32
    var label: String?
    var type: String?
    var enabled: Bool
    var toggleType: String?
    var toggleState: Int32?
    var childrenDisplay: String?
    var propertyNames: [String]
    var children: [LayoutNode]
}

final class StatusNotifierTests: XCTestCase {
    private var daemon: Process?
    private var address = ""
    private var directory: URL!
    private var appConnection: OpaquePointer!
    private var watcherConnection: OpaquePointer!
    private var clientConnection: OpaquePointer!
    private var notifiers: [StatusNotifier] = []
    private var watchers: [FakeWatcher] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        let binary = ["/usr/bin/dbus-daemon", "/bin/dbus-daemon"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let binary else { throw XCTSkip("dbus-daemon is not installed") }
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sni-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--session", "--nofork", "--print-address=1",
                             "--address=unix:path=\(directory.path)/bus"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        daemon = process
        var output = Data()
        while !output.contains(10) {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            output.append(chunk)
        }
        address = (String(data: output, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(address.hasPrefix("unix:"), address)
        appConnection = try connect()
        watcherConnection = try connect()
        clientConnection = try connect()
    }

    override func tearDown() {
        for notifier in notifiers { notifier.stop() }
        for watcher in watchers { watcher.stop() }
        notifiers = []
        watchers = []
        for connection in [appConnection, watcherConnection, clientConnection] {
            if let connection { g_object_unref(UnsafeMutableRawPointer(connection)) }
        }
        daemon?.terminate()
        daemon?.waitUntilExit()
        daemon = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func connect() throws -> OpaquePointer {
        var error: UnsafeMutablePointer<GError>?
        let flags = GDBusConnectionFlags(rawValue: G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT.rawValue
            | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION.rawValue)
        guard let connection = g_dbus_connection_new_for_address_sync(address, flags, nil, nil, &error) else {
            let message = error.map { String(cString: $0.pointee.message) } ?? "unknown"
            throw NSError(domain: "bus", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return connection
    }

    private func pump(timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            while g_main_context_iteration(nil, 0) != 0 {}
            usleep(2_000)
        }
        return true
    }

    private func settle(_ seconds: TimeInterval = 0.25) {
        let end = Date().addingTimeInterval(seconds)
        _ = pump(timeout: seconds + 1) { Date() >= end }
    }

    private func call(_ destination: String, _ path: String, _ interface: String, _ method: String,
                      _ parameters: OpaquePointer?) -> (reply: OpaquePointer?, failure: String?) {
        let box = CallBox()
        let client = clientConnection!
        let sent = parameters
        Thread.detachNewThread {
            var error: UnsafeMutablePointer<GError>?
            let reply = g_dbus_connection_call_sync(client, destination, path, interface, method, sent, nil,
                                                    G_DBUS_CALL_FLAGS_NONE, 5000, nil, &error)
            let failure = error.map { String(cString: $0.pointee.message) }
            if error != nil { g_clear_error(&error) }
            box.finish(reply: reply, failure: failure)
        }
        XCTAssertTrue(pump { box.isFinished }, "call to \(method) timed out")
        return (box.reply, box.failure)
    }

    private func startNotifier(menu: TrayMenu? = nil) throws -> StatusNotifier {
        let notifier = StatusNotifier(connection: appConnection)
        if let menu { notifier.update(menu: menu) }
        try notifier.start()
        notifiers.append(notifier)
        return notifier
    }

    private func startWatcher(on connection: OpaquePointer? = nil) throws -> FakeWatcher {
        let watcher = FakeWatcher(connection: connection ?? watcherConnection)
        try watcher.start()
        watchers.append(watcher)
        XCTAssertTrue(pump { watcher.hasName }, "watcher never acquired its name")
        return watcher
    }

    private func demoMenu() -> TrayMenu {
        var status = QxStatusSnapshot()
        status.modelName = "Qudelix 5K"
        status.batteryPercent = 76
        status.volumeDb = -18
        status.muted = false
        status.eqEnabled = true
        status.activePresetIndex = 5
        status.activePresetName = "Harman target"
        var slots = PresetSlotsState()
        slots.ready = true
        slots.slots = (0..<20).map { PresetSlot(index: $0, name: $0 == 5 ? "Harman target" : nil, isActive: $0 == 5) }
        return TrayMenuBuilder.menu(connection: .connected(.usb), status: status, presets: slots)
    }

    private func decode(_ node: OpaquePointer) -> LayoutNode {
        let id = GV.readInt32(node, 0) ?? -1
        let props = g_variant_get_child_value(node, 1)!
        defer { g_variant_unref(props) }
        func text(_ key: String) -> String? {
            guard let value = g_variant_lookup_value(props, key, nil) else { return nil }
            defer { g_variant_unref(value) }
            return GV.text(value)
        }
        func number(_ key: String) -> Int32? {
            guard let value = g_variant_lookup_value(props, key, nil) else { return nil }
            defer { g_variant_unref(value) }
            return g_variant_get_int32(value)
        }
        var enabled = true
        if let value = g_variant_lookup_value(props, "enabled", nil) {
            enabled = g_variant_get_boolean(value) != 0
            g_variant_unref(value)
        }
        var names: [String] = []
        for index in 0..<Int(g_variant_n_children(props)) {
            let entry = g_variant_get_child_value(props, gsize(index))!
            names.append(GV.readString(entry, 0) ?? "")
            g_variant_unref(entry)
        }
        var children: [LayoutNode] = []
        let list = g_variant_get_child_value(node, 2)!
        defer { g_variant_unref(list) }
        for index in 0..<Int(g_variant_n_children(list)) {
            let boxed = g_variant_get_child_value(list, gsize(index))!
            let inner = g_variant_get_variant(boxed)!
            children.append(decode(inner))
            g_variant_unref(inner)
            g_variant_unref(boxed)
        }
        return LayoutNode(id: id, label: text("label"), type: text("type"), enabled: enabled,
                          toggleType: text("toggle-type"), toggleState: number("toggle-state"),
                          childrenDisplay: text("children-display"), propertyNames: names.sorted(),
                          children: children)
    }

    private func layout(parent: Int32 = 0, depth: Int32 = -1, names: [String] = []) -> (UInt32, LayoutNode)? {
        let result = call(notifierService, StatusNotifier.menuPath, "com.canonical.dbusmenu", "GetLayout",
                          GV.tuple([GV.int32(parent), GV.int32(depth), GV.stringArray(names)]))
        guard let reply = result.reply else {
            XCTFail("GetLayout failed: \(result.failure ?? "?")")
            return nil
        }
        defer { g_variant_unref(reply) }
        let revision = GV.readUInt32(reply, 0) ?? 0
        let node = g_variant_get_child_value(reply, 1)!
        defer { g_variant_unref(node) }
        return (revision, decode(node))
    }

    private var notifierService: String { notifiers[0].serviceName }

    private func properties() -> String {
        let result = call(notifierService, StatusNotifier.itemPath, "org.freedesktop.DBus.Properties", "GetAll",
                          GV.tuple([GV.string("org.kde.StatusNotifierItem")]))
        guard let reply = result.reply else {
            XCTFail("GetAll failed: \(result.failure ?? "?")")
            return ""
        }
        defer { g_variant_unref(reply) }
        return GV.printed(reply)
    }

    private func fireEvent(_ id: Int32, _ event: String = "clicked") -> String? {
        let result = call(notifierService, StatusNotifier.menuPath, "com.canonical.dbusmenu", "Event",
                          GV.tuple([GV.int32(id), GV.string(event), GV.variant(GV.int32(0)), GV.uint32(0)]))
        if let reply = result.reply { g_variant_unref(reply) }
        return result.failure
    }

    func testRegistersWithTheWatcherAndExposesTheItemProperties() throws {
        let watcher = try startWatcher()
        let notifier = try startNotifier(menu: demoMenu())
        XCTAssertTrue(pump { !watcher.registered.isEmpty })
        XCTAssertEqual(watcher.registered, [notifier.serviceName])
        XCTAssertTrue(notifier.serviceName.hasPrefix("org.kde.StatusNotifierItem-"))
        XCTAssertTrue(notifier.watcherPresent)
        XCTAssertEqual(notifier.registrations, 1)

        let text = properties()
        XCTAssertTrue(text.contains("'Category': <'ApplicationStatus'>"), text)
        XCTAssertTrue(text.contains("'Id': <'io.github.FrankieMa77.Qudelix'>"), text)
        XCTAssertTrue(text.contains("'Status': <'Active'>"), text)
        XCTAssertTrue(text.contains("'IconName': <'audio-headphones-symbolic'>"), text)
        XCTAssertTrue(text.contains("'Menu': <objectpath '/MenuBar'>"), text)
        XCTAssertTrue(text.contains("'ItemIsMenu': <false>"), text)
        XCTAssertTrue(text.contains("'WindowId': <0>"), text)
        XCTAssertTrue(text.contains("'ToolTip'"), text)

        notifier.update(appearance: TrayAppearance(iconName: "audio-headphones-symbolic", title: "Qudelix",
                                                   toolTipTitle: "Qudelix 5K — 76%",
                                                   toolTipText: "Connected over USB", status: "Active"))
        let updated = properties()
        XCTAssertTrue(updated.contains("Qudelix 5K — 76%"), updated)
        XCTAssertTrue(updated.contains("Connected over USB"), updated)
    }

    func testAppearanceChangesEmitTheStatusNotifierSignals() throws {
        _ = try startWatcher()
        let notifier = try startNotifier()
        let counter = SignalCounter()
        let subscription = g_dbus_connection_signal_subscribe(
            clientConnection, nil, "org.kde.StatusNotifierItem", nil, StatusNotifier.itemPath, nil,
            G_DBUS_SIGNAL_FLAGS_NONE,
            { _, _, _, _, name, _, data in
                let counter = Unmanaged<SignalCounter>.fromOpaque(data!).takeUnretainedValue()
                counter.count += 1
                counter.last = name.map { String(cString: $0) }
            }, Unmanaged.passUnretained(counter).toOpaque(), nil)
        defer { g_dbus_connection_signal_unsubscribe(clientConnection, subscription) }
        settle()
        notifier.update(appearance: TrayAppearance(iconName: "audio-headphones-symbolic", title: "Qudelix",
                                                   toolTipTitle: "Qudelix 5K — 70%", toolTipText: "x",
                                                   status: "Active"))
        XCTAssertTrue(pump { counter.count >= 1 })
        XCTAssertEqual(counter.last, "NewToolTip")
        notifier.update(appearance: TrayAppearance(iconName: "battery-low-symbolic", title: "Qudelix",
                                                   toolTipTitle: "Qudelix 5K — 70%", toolTipText: "x",
                                                   status: "NeedsAttention"))
        XCTAssertTrue(pump { counter.count >= 3 })
    }

    func testTheDbusmenuLayoutMatchesTheMenuModel() throws {
        _ = try startWatcher()
        let notifier = try startNotifier(menu: demoMenu())
        _ = notifier
        guard let (revision, root) = layout() else { return }
        XCTAssertGreaterThanOrEqual(revision, 1)
        XCTAssertEqual(root.id, 0)
        XCTAssertEqual(root.children.map(\.id), [1, 20, 2, 3, 4, 5, 6, 21, 30, 31])
        XCTAssertEqual(root.children.map { $0.label ?? "-" },
                       ["Battery: 76%", "-", "Volume up", "Volume down", "Mute", "Equalizer", "Preset", "-",
                        "Open Qudelix", "Quit"])
        XCTAssertEqual(root.children[0].enabled, false)
        XCTAssertEqual(root.children[1].type, "separator")
        XCTAssertEqual(root.children[4].toggleType, "checkmark")
        XCTAssertEqual(root.children[4].toggleState, 0)
        XCTAssertEqual(root.children[5].toggleState, 1)
        let presets = root.children[6]
        XCTAssertEqual(presets.childrenDisplay, "submenu")
        XCTAssertEqual(presets.children.count, 20)
        XCTAssertEqual(presets.children.map(\.id), (100..<120).map { Int32($0) })
        XCTAssertEqual(presets.children[5].label, "6. Harman target")
        XCTAssertEqual(presets.children.filter { $0.toggleState == 1 }.map(\.id), [105])
        XCTAssertTrue(presets.children.allSatisfy { $0.toggleType == "radio" })
    }

    func testLayoutSubtreesDepthAndPropertyFilters() throws {
        _ = try startWatcher()
        _ = try startNotifier(menu: demoMenu())
        guard let (_, shallow) = layout(depth: 1) else { return }
        XCTAssertEqual(shallow.children.count, 10)
        XCTAssertTrue(shallow.children.allSatisfy { $0.children.isEmpty })
        guard let (_, sub) = layout(parent: 6) else { return }
        XCTAssertEqual(sub.id, 6)
        XCTAssertEqual(sub.children.count, 20)
        guard let (_, filtered) = layout(parent: 0, depth: 1, names: ["label"]) else { return }
        XCTAssertTrue(filtered.children.allSatisfy { $0.propertyNames.allSatisfy { $0 == "label" } })
        XCTAssertEqual(filtered.children[2].propertyNames, ["label"])
        XCTAssertEqual(call(notifierService, StatusNotifier.menuPath, "com.canonical.dbusmenu", "GetLayout",
                            GV.tuple([GV.int32(4242), GV.int32(-1), GV.stringArray([])])).reply, nil)
    }

    func testGroupPropertiesSinglePropertyAndAboutToShow() throws {
        _ = try startWatcher()
        _ = try startNotifier(menu: demoMenu())
        let group = call(notifierService, StatusNotifier.menuPath, "com.canonical.dbusmenu", "GetGroupProperties",
                         GV.tuple([GV.array(of: "i", [GV.int32(2), GV.int32(4)]), GV.stringArray(["label"])]))
        let text = group.reply.map(GV.printed) ?? ""
        XCTAssertTrue(text.contains("'Volume up'") && text.contains("'Mute'"), text)
        let single = call(notifierService, StatusNotifier.menuPath, "com.canonical.dbusmenu", "GetProperty",
                          GV.tuple([GV.int32(31), GV.string("label")]))
        XCTAssertEqual(single.reply.map(GV.printed), "(<'Quit'>,)")
        let show = call(notifierService, StatusNotifier.menuPath, "com.canonical.dbusmenu", "AboutToShow",
                        GV.tuple([GV.int32(0)]))
        XCTAssertEqual(show.reply.map(GV.printed), "(false,)")
        let props = call(notifierService, StatusNotifier.menuPath, "org.freedesktop.DBus.Properties", "GetAll",
                         GV.tuple([GV.string("com.canonical.dbusmenu")]))
        let printed = props.reply.map(GV.printed) ?? ""
        XCTAssertTrue(printed.contains("'Version': <uint32 3>"), printed)
        XCTAssertTrue(printed.contains("'Status': <'normal'>"), printed)
    }

    func testMenuChangesBumpTheRevisionAndEmitLayoutUpdated() throws {
        _ = try startWatcher()
        let notifier = try startNotifier(menu: demoMenu())
        let counter = SignalCounter()
        let subscription = g_dbus_connection_signal_subscribe(
            clientConnection, nil, "com.canonical.dbusmenu", "LayoutUpdated", StatusNotifier.menuPath, nil,
            G_DBUS_SIGNAL_FLAGS_NONE,
            { _, _, _, _, _, parameters, data in
                let counter = Unmanaged<SignalCounter>.fromOpaque(data!).takeUnretainedValue()
                counter.count += 1
                counter.last = parameters.map(GV.printed)
            }, Unmanaged.passUnretained(counter).toOpaque(), nil)
        defer { g_dbus_connection_signal_unsubscribe(clientConnection, subscription) }
        guard let (before, _) = layout() else { return }
        notifier.update(menu: demoMenu())
        settle()
        XCTAssertEqual(counter.count, 0)
        notifier.update(menu: TrayMenuBuilder.menu(connection: .searching, status: nil, presets: PresetSlotsState()))
        XCTAssertTrue(pump { counter.count == 1 })
        guard let (after, root) = layout() else { return }
        XCTAssertEqual(after, before + 1)
        XCTAssertEqual(counter.last, "(\(after), 0)")
        XCTAssertEqual(root.children.map { $0.label ?? "-" }, ["Looking for your Qudelix 5K", "-", "Open Qudelix", "Quit"])
    }

    func testEventsTriggerTheMatchingActions() throws {
        _ = try startWatcher()
        let notifier = try startNotifier(menu: demoMenu())
        var actions: [TrayAction] = []
        notifier.onAction = { actions.append($0) }
        XCTAssertNil(fireEvent(TrayMenu.quitID))
        XCTAssertNil(fireEvent(TrayMenu.openID))
        XCTAssertNil(fireEvent(TrayMenu.volumeUpID))
        XCTAssertNil(fireEvent(TrayMenu.volumeDownID))
        XCTAssertNil(fireEvent(TrayMenu.muteID))
        XCTAssertNil(fireEvent(TrayMenu.eqID))
        XCTAssertNil(fireEvent(106))
        XCTAssertEqual(actions, [.quit, .open, .volumeUp, .volumeDown, .toggleMute, .toggleEq, .loadPreset(6)])
        actions = []
        XCTAssertNil(fireEvent(TrayMenu.presetsID, "opened"))
        XCTAssertNil(fireEvent(TrayMenu.quitID, "hovered"))
        XCTAssertNil(fireEvent(TrayMenu.statusID))
        XCTAssertEqual(actions, [])
        XCTAssertNotNil(fireEvent(4242))
        let group = call(notifierService, StatusNotifier.menuPath, "com.canonical.dbusmenu", "EventGroup",
                         GV.tuple([GV.array(of: "(isvu)", [
                             GV.tuple([GV.int32(TrayMenu.openID), GV.string("clicked"), GV.variant(GV.int32(0)), GV.uint32(0)]),
                             GV.tuple([GV.int32(4242), GV.string("clicked"), GV.variant(GV.int32(0)), GV.uint32(0)])
                         ])]))
        XCTAssertEqual(group.reply.map(GV.printed), "([4242],)")
        XCTAssertEqual(actions, [.open])
    }

    func testPrimaryActivationOpensTheWindow() throws {
        _ = try startWatcher()
        let notifier = try startNotifier(menu: demoMenu())
        var activations = 0
        notifier.onActivate = { activations += 1 }
        let activate = call(notifierService, StatusNotifier.itemPath, "org.kde.StatusNotifierItem", "Activate",
                            GV.tuple([GV.int32(10), GV.int32(20)]))
        XCTAssertNotNil(activate.reply)
        XCTAssertEqual(activations, 1)
        let secondary = call(notifierService, StatusNotifier.itemPath, "org.kde.StatusNotifierItem",
                             "SecondaryActivate", GV.tuple([GV.int32(0), GV.int32(0)]))
        XCTAssertNotNil(secondary.reply)
        XCTAssertEqual(activations, 2)
        let context = call(notifierService, StatusNotifier.itemPath, "org.kde.StatusNotifierItem", "ContextMenu",
                           GV.tuple([GV.int32(0), GV.int32(0)]))
        XCTAssertNotNil(context.reply)
        XCTAssertEqual(activations, 2)
    }

    func testWithoutAWatcherNothingRegistersUntilOneAppears() throws {
        let notifier = try startNotifier(menu: demoMenu())
        var changes: [Bool] = []
        notifier.onWatcherChanged = { changes.append($0) }
        settle(0.4)
        XCTAssertFalse(notifier.watcherPresent)
        XCTAssertEqual(notifier.registrations, 0)
        let watcher = try startWatcher()
        XCTAssertTrue(pump { !watcher.registered.isEmpty })
        XCTAssertTrue(notifier.watcherPresent)
        XCTAssertEqual(watcher.registered, [notifier.serviceName])
        XCTAssertEqual(changes, [false, true])
    }

    func testTheWatcherVanishingAndReturningReRegisters() throws {
        let first = try startWatcher()
        let notifier = try startNotifier(menu: demoMenu())
        var changes: [Bool] = []
        notifier.onWatcherChanged = { changes.append($0) }
        XCTAssertTrue(pump { !first.registered.isEmpty })
        first.stop()
        XCTAssertTrue(pump { !notifier.watcherPresent }, "vanish was not noticed")
        XCTAssertEqual(changes.last, false)
        let second = try startWatcher()
        XCTAssertTrue(pump { !second.registered.isEmpty }, "did not re-register")
        XCTAssertEqual(second.registered, [notifier.serviceName])
        XCTAssertTrue(notifier.watcherPresent)
        XCTAssertEqual(notifier.registrations, 2)
        XCTAssertEqual(changes, [true, false, true])
        XCTAssertTrue(properties().contains("'Id'"))
    }

    func testStoppingRemovesTheObjects() throws {
        _ = try startWatcher()
        let notifier = try startNotifier(menu: demoMenu())
        let service = notifier.serviceName
        XCTAssertTrue(properties().contains("'Category'"))
        notifier.stop()
        let result = call(service, StatusNotifier.itemPath, "org.freedesktop.DBus.Properties", "GetAll",
                          GV.tuple([GV.string("org.kde.StatusNotifierItem")]))
        XCTAssertNil(result.reply)
        XCTAssertNotNil(result.failure)
    }
}
