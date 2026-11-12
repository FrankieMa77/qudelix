import Foundation

struct BluetoothDeviceReport: Equatable {
    var name: String
    var address: String
    var paired: Bool
    var trusted: Bool
    var connected: Bool
    var servicesResolved: Bool
    var uuids: [String]
    var gaiaCharacteristics: Bool
}

struct BluetoothReport: Equatable {
    var bluezOnBus: Bool
    var adapterPath: String?
    var powered: Bool?
    var discovering: Bool?
    var devices: [BluetoothDeviceReport]
    var leControlSocket: Bool? = nil

    static let unavailable = BluetoothReport(bluezOnBus: false, adapterPath: nil, powered: nil,
                                             discovering: nil, devices: [])
}

enum BluezMask {
    static func text(_ text: String) -> String {
        var out = text
        for (separator, replacement) in [(":", "XX:XX:XX:XX:$1:$2"), ("_", "XX_XX_XX_XX_$1_$2")] {
            let pair = "[0-9A-Fa-f]{2}"
            let pattern = "(?:\(pair)\(separator)){4}(\(pair))\(separator)(\(pair))"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            out = regex.stringByReplacingMatches(in: out,
                                                 range: NSRange(out.startIndex..., in: out),
                                                 withTemplate: replacement)
        }
        return out
    }
}

enum BluetoothProbe {
    static let labels: [String: String] = [
        "0000110b": "A2DP sink",
        "0000110c": "AVRCP target",
        "0000110e": "AVRCP controller",
        "0000111e": "HFP",
        "00001108": "HSP",
        "00001100-d102-11e1-9b23-00025b00a5a5": "GAIA over LE",
        "00001107-d102-11e1-9b23-00025b00a5a5": "GAIA over RFCOMM",
    ]

    static func label(_ uuid: String) -> String? {
        let lowered = uuid.lowercased()
        if let exact = labels[lowered] { return exact }
        let suffix = "-0000-1000-8000-00805f9b34fb"
        guard lowered.hasSuffix(suffix) else { return nil }
        return labels[String(lowered.prefix(8))]
    }

    static func lines(_ report: BluetoothReport) -> [String] {
        guard report.bluezOnBus else {
            return ["bluetooth     BlueZ is not reachable on the system bus"]
        }
        var out: [String] = []
        if let adapter = report.adapterPath {
            out.append("bluetooth     adapter \(adapter): "
                + (report.powered == true ? "powered" : "not powered")
                + ", " + (report.discovering == true ? "scanning" : "not scanning"))
        } else {
            out.append("bluetooth     no Bluetooth adapter known to BlueZ")
        }
        out.append("bluetooth     LE control socket: " + leSocketText(report.leControlSocket))
        guard !report.devices.isEmpty else {
            out.append("bluetooth     no Qudelix known to BlueZ — pair the 5K in your Bluetooth settings")
            return out
        }
        for device in report.devices {
            out.append("bluetooth     device \(DebugLog.sanitized(device.name)) (\(device.address))")
            out.append("  paired      \(yesNo(device.paired))")
            out.append("  trusted     \(yesNo(device.trusted))")
            out.append("  connected   \(yesNo(device.connected))")
            out.append("  resolved    \(yesNo(device.servicesResolved))")
            out.append("  GAIA chars  \(device.gaiaCharacteristics ? "present" : "not present")")
            for uuid in device.uuids {
                out.append("  uuid        \(uuid)" + (label(uuid).map { "  [\($0)]" } ?? ""))
            }
        }
        return out
    }

    static func object(_ report: BluetoothReport) -> [String: Any] {
        var object: [String: Any] = [
            "bluez_on_bus": report.bluezOnBus,
            "devices": report.devices.map { device -> [String: Any] in
                [
                    "name": device.name,
                    "address": device.address,
                    "paired": device.paired,
                    "trusted": device.trusted,
                    "connected": device.connected,
                    "services_resolved": device.servicesResolved,
                    "gaia_characteristics": device.gaiaCharacteristics,
                    "uuids": device.uuids.map { uuid -> [String: Any] in
                        var entry: [String: Any] = ["uuid": uuid]
                        if let text = label(uuid) { entry["label"] = text }
                        return entry
                    },
                ]
            },
        ]
        QxFormat.put(&object, "adapter_path", report.adapterPath)
        QxFormat.put(&object, "powered", report.powered)
        QxFormat.put(&object, "discovering", report.discovering)
        QxFormat.put(&object, "le_control_socket", report.leControlSocket)
        return object
    }

    static func leSocketText(_ available: Bool?) -> String {
        switch available {
        case true?: return "this machine can open one"
        case false?: return "this machine cannot open one (no AF_BLUETOOTH L2CAP support or permission)"
        case nil: return "not checked"
        }
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
}

enum BluezDropKind: Equatable {
    case bearer
    case device
}

struct BluezDrop: Equatable {
    let kind: BluezDropKind
    let name: String
    let message: String
}

enum BluezLinkFailure {
    static let waitingForLink = "Waiting for the Qudelix 5K's Bluetooth control link. "
        + "The 5K offers it for a few seconds after it is switched on. "
        + "If it is already on, switch it off, wait two minutes, switch it on again and let it reconnect by itself."

    static let noDeviceKnown = "No Qudelix 5K is known to Bluetooth yet. "
        + "Pair it once in your Bluetooth settings, then it will be found."

    static func waitLog(_ detail: String) -> String {
        "BLE waiting for the 5K to offer its control link (\(detail))"
    }

    static func dropReason(name: String, message: String) -> String {
        switch name.split(separator: ".").last.map(String.init) ?? name {
        case "Timeout": return "connection timeout"
        case "Remote": return "the 5K closed it"
        case "Local": return "this computer closed it"
        case "Authentication": return "authentication failure"
        case "Suspend": return "this computer was going to sleep"
        default: return message.isEmpty ? "no reason given" : message
        }
    }

    static func dropSentence(_ drop: BluezDrop) -> String {
        let reason = dropReason(name: drop.name, message: drop.message)
        switch drop.kind {
        case .bearer: return "the LE link dropped (\(reason))"
        case .device: return "the 5K disconnected (\(reason))"
        }
    }

    static func detail(_ detail: String, drop: BluezDrop?) -> String {
        guard let drop else { return detail }
        return detail + "; " + dropSentence(drop)
    }
}
