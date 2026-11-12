#if os(Linux)
import Foundation

enum BluezLinkPlan {
    typealias Objects = BluezPresence.Objects

    static let deviceInterface = "org.bluez.Device1"
    static let adapterInterface = "org.bluez.Adapter1"
    static let leBearerInterface = "org.bluez.Bearer.LE1"
    static let characteristicInterface = "org.bluez.GattCharacteristic1"
    static let nameMarker = "qudelix"
    static let presenceProperty = "RSSI"

    static func looksLikeQudelix(_ interfaces: [String: [String: DBusValue]]) -> Bool {
        guard let device = interfaces[deviceInterface] else { return false }
        return looksLikeQudelix(properties: device)
    }

    static func looksLikeQudelix(properties: [String: DBusValue]) -> Bool {
        let uuids = (properties["UUIDs"]?.stringArray ?? []).map { $0.lowercased() }
        if uuids.contains(GaiaFraming.serviceUUID) { return true }
        return ["Name", "Alias"].contains { key in
            (properties[key]?.stringValue ?? "").lowercased().contains(nameMarker)
        }
    }

    static func isPresent(_ interfaces: [String: [String: DBusValue]]) -> Bool {
        guard looksLikeQudelix(interfaces), let device = interfaces[deviceInterface] else { return false }
        if device["Connected"]?.boolValue == true { return true }
        if interfaces[leBearerInterface]?["Connected"]?.boolValue == true { return true }
        return device[presenceProperty] != nil
    }

    static func isConnected(_ path: String, in objects: Objects) -> Bool {
        objects[path]?[deviceInterface]?["Connected"]?.boolValue ?? false
    }

    static func pickDevice(in objects: Objects, pinned: String?) -> String? {
        let matches = objects.filter { _, interfaces in looksLikeQudelix(interfaces) }
        guard !matches.isEmpty else { return nil }
        if let pinned, matches[pinned] != nil { return pinned }
        func rank(_ path: String) -> Int {
            let paired = matches[path]?[deviceInterface]?["Paired"]?.boolValue == true
            return (paired ? 0 : 2) + (isConnected(path, in: objects) ? 0 : 1)
        }
        return matches.keys.sorted().min { lhs, rhs in
            let (left, right) = (rank(lhs), rank(rhs))
            return left != right ? left < right : lhs < rhs
        }
    }

    static func characteristics(under device: String,
                                in objects: Objects) -> (command: String, response: String)? {
        func find(_ uuid: String) -> String? {
            objects.keys.sorted().first { path in
                guard path.hasPrefix(device + "/"),
                      let props = objects[path]?[characteristicInterface] else { return false }
                return props["UUID"]?.stringValue?.lowercased() == uuid
            }
        }
        guard let command = find(GaiaFraming.commandUUID),
              let response = find(GaiaFraming.responseUUID) else { return nil }
        return (command, response)
    }

    static func servicesResolved(_ device: String, in objects: Objects) -> Bool {
        objects[device]?[deviceInterface]?["ServicesResolved"]?.boolValue ?? false
    }

    static func ready(_ device: String,
                      in objects: Objects) -> (command: String, response: String)? {
        guard servicesResolved(device, in: objects) else { return nil }
        return characteristics(under: device, in: objects)
    }

    static func parseDrop(interface: String, path: String, arguments: [DBusValue],
                          devicePath: String?) -> BluezDrop? {
        guard let devicePath, path == devicePath, arguments.count >= 2,
              let name = arguments[0].stringValue,
              let message = arguments[1].stringValue else { return nil }
        switch interface {
        case leBearerInterface: return BluezDrop(kind: .bearer, name: name, message: message)
        case "org.bluez.Device1": return BluezDrop(kind: .device, name: name, message: message)
        default: return nil
        }
    }

    static func isNotConnected(_ error: DBusCallError) -> Bool {
        isBenign(error, "NotConnected")
            || (error.name.hasSuffix("Failed") && error.message.contains("Not connected"))
    }

    static func isNotifyHeld(_ error: DBusCallError) -> Bool {
        error.name.hasSuffix("NotPermitted") && error.message.contains("Notify acquired")
    }

    static func adapterPath(in objects: Objects) -> String? {
        objects.keys.sorted().first { objects[$0]?[adapterInterface] != nil }
    }

    static func address(of device: String, in objects: Objects) -> String? {
        if let text = objects[device]?[deviceInterface]?["Address"]?.stringValue,
           LEAttAddress.parse(text) != nil { return text }
        guard let name = device.split(separator: "/").last, name.hasPrefix("dev_") else { return nil }
        let text = name.dropFirst(4).replacingOccurrences(of: "_", with: ":")
        return LEAttAddress.parse(text) != nil ? text : nil
    }

    static func addressType(of device: String, in objects: Objects) -> String? {
        objects[device]?[deviceInterface]?["AddressType"]?.stringValue
    }

    static func isBenign(_ error: DBusCallError, _ names: String...) -> Bool {
        names.contains { error.name.hasSuffix($0) }
    }

    static func report(onBus: Bool, objects: Objects, leSocket: Bool? = nil) -> BluetoothReport {
        guard onBus else { return .unavailable }
        let adapter = objects.keys.sorted().first { objects[$0]?[adapterInterface] != nil }
        let adapterProps = adapter.flatMap { objects[$0]?[adapterInterface] }
        let devices = objects.keys.sorted().compactMap { path -> BluetoothDeviceReport? in
            guard let interfaces = objects[path], looksLikeQudelix(interfaces),
                  let props = interfaces[deviceInterface] else { return nil }
            return BluetoothDeviceReport(
                name: props["Alias"]?.stringValue ?? props["Name"]?.stringValue ?? "(unnamed)",
                address: BluezMask.text(props["Address"]?.stringValue ?? path),
                paired: props["Paired"]?.boolValue ?? false,
                trusted: props["Trusted"]?.boolValue ?? false,
                connected: props["Connected"]?.boolValue ?? false,
                servicesResolved: props["ServicesResolved"]?.boolValue ?? false,
                uuids: props["UUIDs"]?.stringArray ?? [],
                gaiaCharacteristics: characteristics(under: path, in: objects) != nil)
        }
        return BluetoothReport(bluezOnBus: true, adapterPath: adapter,
                               powered: adapterProps?["Powered"]?.boolValue,
                               discovering: adapterProps?["Discovering"]?.boolValue,
                               devices: devices, leControlSocket: leSocket)
    }
}
#endif
