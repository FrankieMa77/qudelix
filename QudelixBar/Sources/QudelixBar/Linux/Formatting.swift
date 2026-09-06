import Foundation

enum Trace {
    static var verbose = false

    static func log(_ msg: String) {
        DebugLog.shared.log(msg)
        guard verbose else { return }
        StdIO.error("[log] " + DebugLog.sanitized(msg))
    }

    static func rx(_ cmdId: UInt16, _ data: [UInt8]) {
        let name = QxCmd(rawValue: cmdId).map { "\($0)" } ?? String(format: "0x%04X", cmdId)
        log("← \(name) \(hex(data))")
    }

    private static func hex(_ b: [UInt8]) -> String {
        b.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
            + (b.count > 24 ? "…(\(b.count))" : "")
    }
}

enum StdIO {
    static func out(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    static func error(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

struct QxStatusSnapshot {
    var linkKind: QxLinkKind = .usb
    var deviceIdentity: String?
    var deviceId: Int = 0
    var modelName: String = "unknown"
    var firmware: String?
    var batteryPercent: Int?
    var batteryMilliVolts: Int?
    var charging = false
    var chargerConnected = false
    var volumeDb: Double?
    var volumeLimitDb: Double?
    var muted: Bool?
    var dacFilterIndex: Int?
    var dacFilterName: String?
    var eqEnabled: Bool?
    var eqType: String?
    var eqGroup: QxEqGroup = .user
    var activePresetIndex: Int?
    var activePresetName: String?
    var sampleRate: String?
    var inputSource: String?
    var codec: String?
}

enum QxFormat {
    static func db(_ v: Double) -> String { String(format: "%+.1f dB", v) }

    static func gain(_ v: Double) -> String { String(format: "%+.1f", v) }

    static func q(_ v: Double) -> String { String(format: "%.2f", v) }

    static func onOff(_ v: Bool?) -> String {
        guard let v else { return "unknown" }
        return v ? "on" : "off"
    }

    static func presetLabel(_ index: Int, _ name: String?) -> String {
        guard let name, !name.isEmpty else { return "Preset \(index + 1)" }
        return name
    }

    static func groupLabel(_ g: QxEqGroup) -> String {
        switch g {
        case .user: return "user (10-band)"
        case .speaker: return "speaker (10-band)"
        case .b20: return "b20 (20-band)"
        }
    }

    static func statusLines(_ s: QxStatusSnapshot) -> [String] {
        var rows: [(String, String)] = []
        rows.append(("link", s.linkKind.rawValue))
        rows.append(("model", s.modelName))
        rows.append(("firmware", s.firmware ?? "unknown"))
        rows.append(("battery", s.batteryPercent.map { "\($0)%" } ?? "unknown"))
        rows.append(("charging", s.chargerConnected
            ? (s.charging ? "yes" : "connected, idle")
            : "no"))
        rows.append(("volume", s.volumeDb.map(db) ?? "unknown"))
        rows.append(("mute", onOff(s.muted)))
        rows.append(("dac filter", s.dacFilterName
            ?? s.dacFilterIndex.map { "index \($0)" } ?? "unknown"))
        rows.append(("eq", onOff(s.eqEnabled)))
        rows.append(("eq type", s.eqType ?? "unknown"))
        rows.append(("eq group", groupLabel(s.eqGroup)))
        rows.append(("preset", s.activePresetIndex.map {
            "\($0 + 1) — \(presetLabel($0, s.activePresetName))"
        } ?? "unknown"))
        rows.append(("sample rate", s.sampleRate ?? "unknown"))
        rows.append(("input", s.inputSource ?? "unknown"))
        if let codec = s.codec, s.linkKind == .bluetooth {
            rows.append(("codec", codec))
        }
        let width = rows.map { $0.0.count }.max() ?? 0
        return rows.map { pad($0.0, width) + "  " + $0.1 }
    }

    static func statusObject(_ s: QxStatusSnapshot) -> [String: Any] {
        var o: [String: Any] = [
            "link": s.linkKind.rawValue,
            "device_id": s.deviceId,
            "model": s.modelName,
            "charging": s.charging,
            "charger_connected": s.chargerConnected,
            "eq_group": Int(s.eqGroup.rawValue),
            "eq_group_label": groupLabel(s.eqGroup),
            "eq_bands": s.eqGroup.bandCount,
        ]
        put(&o, "firmware", s.firmware)
        put(&o, "battery_percent", s.batteryPercent)
        put(&o, "battery_millivolts", s.batteryMilliVolts)
        put(&o, "volume_db", s.volumeDb)
        put(&o, "volume_limit_db", s.volumeLimitDb)
        put(&o, "mute", s.muted)
        put(&o, "dac_filter_index", s.dacFilterIndex)
        put(&o, "dac_filter", s.dacFilterName)
        put(&o, "eq_enabled", s.eqEnabled)
        put(&o, "eq_type", s.eqType)
        put(&o, "preset_index", s.activePresetIndex)
        put(&o, "preset_name", s.activePresetName)
        put(&o, "sample_rate", s.sampleRate)
        put(&o, "input_source", s.inputSource)
        put(&o, "device_identity", s.deviceIdentity)
        if s.linkKind == .bluetooth { put(&o, "codec", s.codec) }
        return o
    }

    static func put(_ object: inout [String: Any], _ key: String, _ value: Int?) {
        if let value { object[key] = value }
    }

    static func put(_ object: inout [String: Any], _ key: String, _ value: Double?) {
        if let value, value.isFinite { object[key] = value }
    }

    static func put(_ object: inout [String: Any], _ key: String, _ value: Bool?) {
        if let value { object[key] = value }
    }

    static func put(_ object: inout [String: Any], _ key: String, _ value: String?) {
        if let value { object[key] = value }
    }

    static func eqLines(preGain: Double, bands: [QxEqBandValue]) -> [String] {
        var lines = ["pre-gain  " + db(preGain)]
        lines.append("")
        lines.append(pad("band", 5) + pad("freq", 9) + pad("filter", 9)
            + pad("gain", 8) + "Q")
        for (i, b) in bands.enumerated() {
            lines.append(pad("\(i + 1)", 5)
                + pad("\(b.freq) Hz", 9)
                + pad(b.filter.shortLabel, 9)
                + pad(gain(b.gain), 8)
                + q(b.q))
        }
        return lines
    }

    static func eqObject(preGain: Double, bands: [QxEqBandValue],
                         enabled: Bool?, group: QxEqGroup) -> [String: Any] {
        var o: [String: Any] = [
            "pre_gain_db": preGain,
            "eq_group": Int(group.rawValue),
            "bands": bands.map { b -> [String: Any] in
                [
                    "filter": b.filter.rawValue,
                    "filter_label": b.filter.shortLabel,
                    "freq_hz": b.freq,
                    "gain_db": b.gain,
                    "q": b.q,
                ]
            },
        ]
        if let enabled { o["enabled"] = enabled }
        return o
    }

    static func filterLines(current: Int? = nil) -> [String] {
        QxStatusParser.dacFilters.enumerated().map { entry in
            (entry.offset == current ? "* " : "  ") + "\(entry.offset)  \(entry.element)"
        }
    }

    static func presetLines(_ names: [Int: String], count: Int,
                            active: Int? = nil) -> [String] {
        (0..<count).map { index in
            (index == active ? "* " : "  ")
                + pad("\(index + 1)", 4) + presetLabel(index, names[index])
        }
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
}
