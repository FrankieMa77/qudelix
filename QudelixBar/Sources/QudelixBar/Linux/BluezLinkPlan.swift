#if os(Linux)
import Foundation

enum BluezLinkStep: Equatable {
    case useCharacteristics
    case awaitCharacteristics
    case connectBearer
    case scanForLE
    case connectDevice
    case noLEAdvertisement
}

enum BluezStopAction: Equatable {
    case none
    case disconnectBearer
    case disconnectDevice
}

enum BluezLinkPlan {
    typealias Objects = BluezPresence.Objects

    static let deviceInterface = "org.bluez.Device1"
    static let adapterInterface = "org.bluez.Adapter1"
    static let leBearerInterface = "org.bluez.Bearer.LE1"
    static let characteristicInterface = "org.bluez.GattCharacteristic1"
    static let nameMarker = "qudelix"
    static let scanSeconds: TimeInterval = 10

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

    static func bearerState(of device: String, in objects: Objects) -> BluezBearerState {
        guard let bearer = objects[device]?[leBearerInterface] else { return .unknown }
        return bearer["Connected"]?.boolValue == true ? .connected : .disconnected
    }

    static func step(objects: Objects, device: String, scanned: Bool, seen: Bool) -> BluezLinkStep {
        if characteristics(under: device, in: objects) != nil { return .useCharacteristics }
        switch bearerState(of: device, in: objects) {
        case .connected: return .awaitCharacteristics
        case .disconnected: return .connectBearer
        case .unknown:
            guard scanned else { return .scanForLE }
            return seen || isConnected(device, in: objects) ? .connectDevice : .noLEAdvertisement
        }
    }

    static func stopAction(deviceConnectedWhenFound: Bool, calledDeviceConnect: Bool,
                           calledBearerConnect: Bool) -> BluezStopAction {
        if calledDeviceConnect, !deviceConnectedWhenFound { return .disconnectDevice }
        if calledBearerConnect { return .disconnectBearer }
        return .none
    }

    static func report(onBus: Bool, objects: Objects) -> BluetoothReport {
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
                leBearer: bearerState(of: path, in: objects),
                uuids: props["UUIDs"]?.stringArray ?? [],
                gaiaCharacteristics: characteristics(under: path, in: objects) != nil)
        }
        return BluetoothReport(bluezOnBus: true, adapterPath: adapter,
                               powered: adapterProps?["Powered"]?.boolValue,
                               discovering: adapterProps?["Discovering"]?.boolValue,
                               devices: devices)
    }
}
#endif
