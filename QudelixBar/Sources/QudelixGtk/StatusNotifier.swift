import CGtk
import Foundation
import QudelixBar

package final class StatusNotifier {
    package static let itemPath = "/StatusNotifierItem"
    package static let menuPath = "/MenuBar"
    package static let watcherName = "org.kde.StatusNotifierWatcher"
    package static let watcherPath = "/StatusNotifierWatcher"

    static let itemXML = """
    <node>
      <interface name="org.kde.StatusNotifierItem">
        <property name="Category" type="s" access="read"/>
        <property name="Id" type="s" access="read"/>
        <property name="Title" type="s" access="read"/>
        <property name="Status" type="s" access="read"/>
        <property name="WindowId" type="i" access="read"/>
        <property name="IconThemePath" type="s" access="read"/>
        <property name="Menu" type="o" access="read"/>
        <property name="ItemIsMenu" type="b" access="read"/>
        <property name="IconName" type="s" access="read"/>
        <property name="IconPixmap" type="a(iiay)" access="read"/>
        <property name="OverlayIconName" type="s" access="read"/>
        <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
        <property name="AttentionIconName" type="s" access="read"/>
        <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
        <property name="AttentionMovieName" type="s" access="read"/>
        <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
        <method name="ContextMenu">
          <arg type="i" name="x" direction="in"/>
          <arg type="i" name="y" direction="in"/>
        </method>
        <method name="Activate">
          <arg type="i" name="x" direction="in"/>
          <arg type="i" name="y" direction="in"/>
        </method>
        <method name="SecondaryActivate">
          <arg type="i" name="x" direction="in"/>
          <arg type="i" name="y" direction="in"/>
        </method>
        <method name="Scroll">
          <arg type="i" name="delta" direction="in"/>
          <arg type="s" name="orientation" direction="in"/>
        </method>
        <signal name="NewTitle"/>
        <signal name="NewIcon"/>
        <signal name="NewAttentionIcon"/>
        <signal name="NewOverlayIcon"/>
        <signal name="NewToolTip"/>
        <signal name="NewStatus">
          <arg type="s" name="status"/>
        </signal>
      </interface>
    </node>
    """

    static let menuXML = """
    <node>
      <interface name="com.canonical.dbusmenu">
        <property name="Version" type="u" access="read"/>
        <property name="TextDirection" type="s" access="read"/>
        <property name="Status" type="s" access="read"/>
        <property name="IconThemePath" type="as" access="read"/>
        <method name="GetLayout">
          <arg type="i" name="parentId" direction="in"/>
          <arg type="i" name="recursionDepth" direction="in"/>
          <arg type="as" name="propertyNames" direction="in"/>
          <arg type="u" name="revision" direction="out"/>
          <arg type="(ia{sv}av)" name="layout" direction="out"/>
        </method>
        <method name="GetGroupProperties">
          <arg type="ai" name="ids" direction="in"/>
          <arg type="as" name="propertyNames" direction="in"/>
          <arg type="a(ia{sv})" name="properties" direction="out"/>
        </method>
        <method name="GetProperty">
          <arg type="i" name="id" direction="in"/>
          <arg type="s" name="name" direction="in"/>
          <arg type="v" name="value" direction="out"/>
        </method>
        <method name="Event">
          <arg type="i" name="id" direction="in"/>
          <arg type="s" name="eventId" direction="in"/>
          <arg type="v" name="data" direction="in"/>
          <arg type="u" name="timestamp" direction="in"/>
        </method>
        <method name="EventGroup">
          <arg type="a(isvu)" name="events" direction="in"/>
          <arg type="ai" name="idErrors" direction="out"/>
        </method>
        <method name="AboutToShow">
          <arg type="i" name="id" direction="in"/>
          <arg type="b" name="needUpdate" direction="out"/>
        </method>
        <method name="AboutToShowGroup">
          <arg type="ai" name="ids" direction="in"/>
          <arg type="ai" name="updatesNeeded" direction="out"/>
          <arg type="ai" name="idErrors" direction="out"/>
        </method>
        <signal name="ItemsPropertiesUpdated">
          <arg type="a(ia{sv})" name="updatedProps"/>
          <arg type="a(ias)" name="removedProps"/>
        </signal>
        <signal name="LayoutUpdated">
          <arg type="u" name="revision"/>
          <arg type="i" name="parent"/>
        </signal>
        <signal name="ItemActivationRequested">
          <arg type="i" name="id"/>
          <arg type="u" name="timestamp"/>
        </signal>
      </interface>
    </node>
    """

    package var onActivate: () -> Void = {}
    package var onAction: (TrayAction) -> Void = { _ in }
    package var onWatcherChanged: (Bool) -> Void = { _ in }

    package private(set) var watcherPresent = false
    package private(set) var registrations = 0
    package private(set) var revision: UInt32 = 1
    package private(set) var menu = TrayMenu()
    package private(set) var appearance = TrayAppearance(iconName: TrayMenuBuilder.iconName, title: AppInfo.name,
                                                          toolTipTitle: AppInfo.name, toolTipText: "", status: "Active")
    package let serviceName: String

    private let connection: OpaquePointer
    private var item: DBusObject?
    private var menuObject: DBusObject?
    private var nameOwnerID: UInt32 = 0
    private var watchID: UInt32 = 0
    private var nameAcquired = false

    package init(connection: OpaquePointer, instance: Int = 1) {
        self.connection = connection
        serviceName = "org.kde.StatusNotifierItem-\(getpid())-\(instance)"
    }

    deinit { stop() }

    package func start() throws {
        item = try DBusObject(connection: connection, path: Self.itemPath, xml: Self.itemXML,
                              onMethod: { [unowned self] method, parameters, invocation in
                                  self.itemMethod(method, parameters, invocation)
                              },
                              onProperty: { [unowned self] name in self.itemProperty(name) })
        menuObject = try DBusObject(connection: connection, path: Self.menuPath, xml: Self.menuXML,
                                    onMethod: { [unowned self] method, parameters, invocation in
                                        self.menuMethod(method, parameters, invocation)
                                    },
                                    onProperty: { [unowned self] name in self.menuProperty(name) })
        let retained = Unmanaged.passUnretained(self).toOpaque()
        nameOwnerID = g_bus_own_name_on_connection(connection, serviceName, G_BUS_NAME_OWNER_FLAGS_NONE,
            { _, _, data in
                guard let data else { return }
                let notifier = Unmanaged<StatusNotifier>.fromOpaque(data).takeUnretainedValue()
                notifier.nameAcquired = true
                notifier.registerIfReady()
            },
            { _, _, data in
                guard let data else { return }
                Unmanaged<StatusNotifier>.fromOpaque(data).takeUnretainedValue().nameAcquired = false
            },
            retained, nil)
        watchID = g_bus_watch_name_on_connection(connection, Self.watcherName, G_BUS_NAME_WATCHER_FLAGS_NONE,
            { _, _, _, data in
                guard let data else { return }
                let notifier = Unmanaged<StatusNotifier>.fromOpaque(data).takeUnretainedValue()
                notifier.watcherPresent = true
                notifier.registerIfReady()
                notifier.onWatcherChanged(true)
            },
            { _, _, data in
                guard let data else { return }
                let notifier = Unmanaged<StatusNotifier>.fromOpaque(data).takeUnretainedValue()
                notifier.watcherPresent = false
                notifier.onWatcherChanged(false)
            },
            retained, nil)
    }

    package func stop() {
        if watchID != 0 { g_bus_unwatch_name(watchID); watchID = 0 }
        if nameOwnerID != 0 { g_bus_unown_name(nameOwnerID); nameOwnerID = 0 }
        item?.unregister()
        menuObject?.unregister()
        item = nil
        menuObject = nil
    }

    private func registerIfReady() {
        guard watcherPresent, nameAcquired else { return }
        registrations += 1
        g_dbus_connection_call(connection, Self.watcherName, Self.watcherPath, Self.watcherName,
                               "RegisterStatusNotifierItem", GV.tuple([GV.string(serviceName)]),
                               nil, G_DBUS_CALL_FLAGS_NONE, 5000, nil, nil, nil)
    }

    package func update(appearance next: TrayAppearance) {
        let previous = appearance
        appearance = next
        guard item != nil else { return }
        if previous.iconName != next.iconName { item?.emit("NewIcon", nil) }
        if previous.title != next.title { item?.emit("NewTitle", nil) }
        if previous.toolTipTitle != next.toolTipTitle || previous.toolTipText != next.toolTipText {
            item?.emit("NewToolTip", nil)
        }
        if previous.status != next.status {
            item?.emit("NewStatus", GV.tuple([GV.string(next.status)]))
        }
    }

    package func update(menu next: TrayMenu) {
        guard next != menu else { return }
        menu = next
        revision += 1
        menuObject?.emit("LayoutUpdated", GV.tuple([GV.uint32(revision), GV.int32(0)]))
    }

    private func itemProperty(_ name: String) -> OpaquePointer? {
        let emptyPixmap = { GV.array(of: "(iiay)", []) }
        switch name {
        case "Category": return GV.string("ApplicationStatus")
        case "Id": return GV.string(AppInfo.identifier)
        case "Title": return GV.string(appearance.title)
        case "Status": return GV.string(appearance.status)
        case "WindowId": return GV.int32(0)
        case "IconThemePath": return GV.string("")
        case "Menu": return GV.objectPath(Self.menuPath)
        case "ItemIsMenu": return GV.bool(false)
        case "IconName": return GV.string(appearance.iconName)
        case "IconPixmap", "OverlayIconPixmap", "AttentionIconPixmap": return emptyPixmap()
        case "OverlayIconName", "AttentionIconName", "AttentionMovieName": return GV.string("")
        case "ToolTip":
            return GV.tuple([GV.string(appearance.iconName), emptyPixmap(),
                             GV.string(appearance.toolTipTitle), GV.string(appearance.toolTipText)])
        default: return nil
        }
    }

    private func itemMethod(_ method: String, _ parameters: OpaquePointer, _ invocation: OpaquePointer) {
        switch method {
        case "Activate", "SecondaryActivate":
            DBusObject.reply(invocation, nil)
            onActivate()
        case "ContextMenu", "Scroll":
            DBusObject.reply(invocation, nil)
        default:
            DBusObject.fail(invocation, "unknown method \(method)")
        }
    }

    private func menuProperty(_ name: String) -> OpaquePointer? {
        switch name {
        case "Version": return GV.uint32(3)
        case "TextDirection": return GV.string("ltr")
        case "Status": return GV.string("normal")
        case "IconThemePath": return GV.stringArray([])
        default: return nil
        }
    }

    static func properties(of item: TrayMenuItem, filter: [String]) -> OpaquePointer {
        var pairs: [(String, OpaquePointer)] = []
        func add(_ name: String, _ value: @autoclosure () -> OpaquePointer) {
            if filter.isEmpty || filter.contains(name) { pairs.append((name, value())) }
        }
        if item.separator {
            add("type", GV.string("separator"))
        } else {
            add("label", GV.string(item.label.replacingOccurrences(of: "_", with: "__")))
        }
        if !item.enabled { add("enabled", GV.bool(false)) }
        switch item.check {
        case .none:
            break
        case .checkmark(let on):
            add("toggle-type", GV.string("checkmark"))
            add("toggle-state", GV.int32(on ? 1 : 0))
        case .radio(let on):
            add("toggle-type", GV.string("radio"))
            add("toggle-state", GV.int32(on ? 1 : 0))
        }
        if !item.children.isEmpty { add("children-display", GV.string("submenu")) }
        return GV.dict(pairs)
    }

    static func layout(of item: TrayMenuItem, depth: Int32, filter: [String]) -> OpaquePointer {
        let children: [OpaquePointer] = depth == 0 ? [] : item.children.map {
            GV.variant(layout(of: $0, depth: depth < 0 ? -1 : depth - 1, filter: filter))
        }
        return GV.tuple([GV.int32(item.id), properties(of: item, filter: filter),
                         GV.array(of: "v", children)])
    }

    private func rootItem() -> TrayMenuItem {
        TrayMenuItem(id: TrayMenu.rootID, label: "", children: menu.items)
    }

    private func lookup(_ id: Int32) -> TrayMenuItem? {
        id == TrayMenu.rootID ? rootItem() : menu.find(id)
    }

    private func handleEvent(id: Int32, eventID: String) -> Bool {
        guard let entry = menu.find(id) else { return false }
        if eventID == "clicked", entry.enabled, let action = entry.action { onAction(action) }
        return true
    }

    private func menuMethod(_ method: String, _ parameters: OpaquePointer, _ invocation: OpaquePointer) {
        switch method {
        case "GetLayout":
            let parent = GV.readInt32(parameters, 0) ?? 0
            let depth = GV.readInt32(parameters, 1) ?? -1
            let names = GV.child(parameters, 2).map { value -> [String] in
                defer { g_variant_unref(value) }
                return GV.strings(value)
            } ?? []
            guard let root = lookup(parent) else {
                DBusObject.fail(invocation, "no menu item \(parent)")
                return
            }
            DBusObject.reply(invocation, GV.tuple([GV.uint32(revision),
                                                   Self.layout(of: root, depth: depth, filter: names)]))
        case "GetGroupProperties":
            let ids = GV.child(parameters, 0).map { value -> [Int32] in
                defer { g_variant_unref(value) }
                return GV.int32s(value)
            } ?? []
            let names = GV.child(parameters, 1).map { value -> [String] in
                defer { g_variant_unref(value) }
                return GV.strings(value)
            } ?? []
            let wanted = ids.isEmpty ? [TrayMenu.rootID] + allIDs(menu.items) : ids
            let entries = wanted.compactMap { id -> OpaquePointer? in
                lookup(id).map { GV.tuple([GV.int32(id), Self.properties(of: $0, filter: names)]) }
            }
            DBusObject.reply(invocation, GV.tuple([GV.array(of: "(ia{sv})", entries)]))
        case "GetProperty":
            let id = GV.readInt32(parameters, 0) ?? -1
            let name = GV.readString(parameters, 1) ?? ""
            guard let entry = lookup(id) else {
                DBusObject.fail(invocation, "no menu item \(id)")
                return
            }
            let all = Self.properties(of: entry, filter: [name])
            defer { g_variant_unref(all) }
            guard g_variant_n_children(all) > 0, let pair = g_variant_get_child_value(all, 0) else {
                DBusObject.fail(invocation, "no property \(name)")
                return
            }
            defer { g_variant_unref(pair) }
            guard let inner = g_variant_get_child_value(pair, 1) else {
                DBusObject.fail(invocation, "no property \(name)")
                return
            }
            defer { g_variant_unref(inner) }
            DBusObject.reply(invocation, GV.tuple([inner]))
        case "Event":
            let id = GV.readInt32(parameters, 0) ?? -1
            let eventID = GV.readString(parameters, 1) ?? ""
            if handleEvent(id: id, eventID: eventID) {
                DBusObject.reply(invocation, nil)
            } else {
                DBusObject.fail(invocation, "no menu item \(id)")
            }
        case "EventGroup":
            var failed: [Int32] = []
            if let events = GV.child(parameters, 0) {
                defer { g_variant_unref(events) }
                for index in 0..<Int(g_variant_n_children(events)) {
                    guard let event = g_variant_get_child_value(events, gsize(index)) else { continue }
                    defer { g_variant_unref(event) }
                    let id = GV.readInt32(event, 0) ?? -1
                    if !handleEvent(id: id, eventID: GV.readString(event, 1) ?? "") { failed.append(id) }
                }
            }
            DBusObject.reply(invocation, GV.tuple([GV.array(of: "i", failed.map(GV.int32))]))
        case "AboutToShow":
            DBusObject.reply(invocation, GV.tuple([GV.bool(false)]))
        case "AboutToShowGroup":
            DBusObject.reply(invocation, GV.tuple([GV.array(of: "i", []), GV.array(of: "i", [])]))
        default:
            DBusObject.fail(invocation, "unknown method \(method)")
        }
    }

    private func allIDs(_ items: [TrayMenuItem]) -> [Int32] {
        items.flatMap { [$0.id] + allIDs($0.children) }
    }
}
