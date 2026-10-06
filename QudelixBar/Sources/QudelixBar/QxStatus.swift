import Foundation

struct QxDeviceState {
    var deviceId: Int = 0
    var fwVersion: String?
    var fwMajor: Int?
    var fwMinor: Int?
    var eqMode: Int?
    var usbFsMode: Int?
    var batteryPercent: Int?
    var batteryMilliVolts: Int?
    var charging = false
    var chargerConnected = false
    var batteryLow: Bool?
    var chargerState: Int?
    var dacState: Int?
    var chargerEnabled: Bool?
    var batteryCare: Bool?
    var sampleRateLabel: String?
    var inputSourceLabel: String?
    var codecLabel: String?
    var outputJackUnbalanced: Bool?
    var outputHighGain: Bool?
    var audioMuted: Bool?
    var audioRunning: Bool?
    var activeCall: Bool?
    var volumeDb: Double?
    var volumeLimitDb: Double?
    var trimLeftDb: Double?
    var trimRightDb: Double?
    var usbMute: Bool?
    var eqEnabled: Bool?
    var eqPresetIdx: Int?
    var presetNameMask: Int = 0
    var eqCfgGroup: Int?
    var dacOutPwr2Vrms = false
    var dacFilterType: Int?
    var totalPlayTime: Int?
    var totalPlayTimeAtLastCharge: Int?
}

extension Array where Element == UInt8 {
    func tail(from offset: Int) -> [UInt8] {
        guard offset >= 0, offset < count else { return [] }
        return Array(self[offset...])
    }
}

enum QxStatusParser {
    static let sampleRates = ["8 kHz", "16 kHz", "32 kHz", "44.1 kHz", "48 kHz", "88.2 kHz", "96 kHz"]
    static let inputSources = ["None", "USB", "A2DP 1", "A2DP 2", "HFP 1", "HFP 2"]
    static let codecs = ["None", "SBC", "AAC", "aptX", "aptX HD", "aptX Adaptive", "LDAC"]
    static let dacFilters = [
        "Linear phase fast roll-off", "Linear phase slow roll-off",
        "Linear phase super slow roll-off", "Minimum phase fast roll-off",
        "Minimum phase slow roll-off", "Minimum phase super slow roll-off",
        "Hybrid fast roll-off", "NOS (88.2/96 kHz only)",
    ]

    static func parseInitData(_ d: [UInt8], into state: inout QxDeviceState) -> Bool {
        guard d.count >= 11 else { return false }
        let devId = Int(d[0]) << 8 | Int(d[1])
        guard d[2] == 3 else { return false }
        state.deviceId = devId

        var r = QxBitReader(Array(d[3..<11]))
        let major = r.read(6), minor = r.read(6), rev = r.read(4)
        state.fwVersion = "\(major).\(minor).\(rev)"
        state.fwMajor = major
        state.fwMinor = minor
        return true
    }

    static func parseDevStatus(_ d: [UInt8], into state: inout QxDeviceState) -> Int {
        guard !d.isEmpty else { return 0 }
        let mask = d[0]
        var off = 1

        if mask & QxStatusMask.audio != 0 {
            guard d.count >= off + 4 else { return d.count }
            var r = QxBitReader(Array(d[off..<off + 4]))
            state.audioMuted = r.read(1) == 1
            state.audioRunning = r.read(1) == 1
            state.activeCall = r.read(1) == 1
            r.skip(2)
            let codecIdx = r.read(4)
            if codecIdx < codecs.count { state.codecLabel = codecs[codecIdx] }
            let inSource = r.read(3)
            r.skip(2)
            state.outputJackUnbalanced = r.read(1) == 1
            state.outputHighGain = r.read(1) == 1
            let srIdx = r.read(4)
            if srIdx < sampleRates.count { state.sampleRateLabel = sampleRates[srIdx] }
            if inSource < inputSources.count { state.inputSourceLabel = inputSources[inSource] }
            off += 4
        }
        if mask & QxStatusMask.power != 0 {
            guard d.count >= off + 8 else { return d.count }
            var r = QxBitReader(Array(d[off..<off + 8]))
            state.chargerConnected = r.read(1) == 1
            state.charging = r.read(1) == 1
            state.chargerState = r.read(3)
            state.dacState = r.read(3)
            state.batteryLow = r.read(1) == 1
            state.batteryPercent = min(r.read(7), 100)
            state.batteryMilliVolts = r.read(13)
            off += 8
        }
        if mask & QxStatusMask.conn != 0 { off += 16 }
        if mask & QxStatusMask.runtimeInfo != 0 { off += 4 }
        if mask & QxStatusMask.runtimeRms != 0 { off += 16 }
        if mask & QxStatusMask.runtimeEq != 0 { return d.count }
        if mask & QxStatusMask.vol != 0 {
            guard d.count >= off + 17 else { return d.count }
            parseVolBlock(Array(d[off..<off + 16]), into: &state)
            state.usbMute = d[off + 16] != 0
            off += 17
        }
        if mask & QxStatusMask.reserved != 0 { return d.count }
        return min(off, d.count)
    }

    static func parseDevConfig(_ d: [UInt8], into state: inout QxDeviceState) -> Int {
        guard !d.isEmpty else { return 0 }
        let mask = d[0]
        var off = 1

        if mask & QxConfigMask.sys != 0 {
            guard d.count >= off + 12 else { return d.count }
            var r = QxBitReader(Array(d[off..<off + 12]))
            r.skip(4)
            state.chargerEnabled = r.read(1) == 1
            state.batteryCare = r.read(1) == 1
            r.skip(30)
            state.eqMode = r.read(1)
            let fs = r.read(3)
            state.usbFsMode = fs <= 6 ? fs : nil
            off += 12
        }
        if mask & QxConfigMask.vol != 0 {
            guard d.count >= off + 16 else { return d.count }
            parseVolBlock(Array(d[off..<off + 16]), into: &state)
            off += 16
        }
        if mask & QxConfigMask.playTime != 0 {
            guard d.count >= off + 8 else { return d.count }
            var r = QxBitReader(Array(d[off..<off + 8]))
            state.totalPlayTime = r.read(32)
            state.totalPlayTimeAtLastCharge = r.read(32)
            off += 8
        }
        if mask & QxConfigMask.dac != 0 {
            guard d.count >= off + 4 else { return d.count }
            var r = QxBitReader(Array(d[off..<off + 4]))
            r.skip(5)
            state.dacOutPwr2Vrms = r.read(1) == 1
            r.skip(12)
            state.dacFilterType = r.read(4)
            off += 4
        }
        if mask & QxConfigMask.mic != 0 { off += 4 }
        if mask & QxConfigMask.batt != 0 { off += 8 }
        if mask & QxConfigMask.sys2 != 0 { off += 32 }
        if mask & QxConfigMask.eq != 0, d.count > off {
            let group = d[off]; off += 1
            let applies = group == 0 || group == 2
            if applies { state.eqCfgGroup = Int(group) }
            off += parseEqGroupCfg(d, at: off, into: &state, applies: applies)
            if group == 0, d.count > off {
                off += 1
                off += parseEqGroupCfg(d, at: off, into: &state, applies: false)
            }
        }
        return min(off, d.count)
    }

    private static func parseEqGroupCfg(_ d: [UInt8], at start: Int,
                                        into state: inout QxDeviceState, applies: Bool) -> Int {
        guard d.count >= start + 8 else { return max(0, d.count - start) }
        if applies {
            var r = QxBitReader(Array(d[start..<start + 4]))
            r.skip(8)
            state.eqPresetIdx = r.read(8)
            state.eqEnabled = r.read(1) == 1
            var n = QxBitReader(Array(d[start + 4..<start + 8]))
            state.presetNameMask = n.read(20)
        }
        return 8
    }

    private static let dbRange = -120.0...24.0

    private static func parseVolBlock(_ d: [UInt8], into state: inout QxDeviceState) {
        func int16LE(_ i: Int) -> Double {
            let raw = Double(Int16(bitPattern: UInt16(d[i]) | UInt16(d[i + 1]) << 8)) / QxScale.volume
            return min(max(raw, dbRange.lowerBound), dbRange.upperBound)
        }
        state.volumeDb = int16LE(0)
        state.volumeLimitDb = int16LE(2)
        state.trimLeftDb = int16LE(6)
        state.trimRightDb = int16LE(8)
    }
}
