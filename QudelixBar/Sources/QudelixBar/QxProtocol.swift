import Foundation

enum QxCmd: UInt16 {
    case reqInitData      = 0x0100
    case rspInitData      = 0x0101
    case disconnect       = 0x0107
    case reqDevStatus     = 0x0110
    case rspDevStatus     = 0x0111
    case reqDevConfig     = 0x0120
    case rspDevConfig     = 0x0121
    case reqEqPreset      = 0x0123
    case rspEqPresetL     = 0x0124
    case rspEqPresetH     = 0x0125
    case rspEqPreset      = 0x0128
    case reqDevData       = 0x0140
    case rspDevData       = 0x0141

    case setVolume        = 0x0200
    case setCharger       = 0x0201
    case setLedMode       = 0x0202
    case setUsbFsMode     = 0x0209
    case setBatteryCare   = 0x0213
    case setUsbDacMode    = 0x0217
    case setDacFilter     = 0x0501

    case setEqEnable      = 0x0700
    case setEqType        = 0x0701
    case setEqPreGain     = 0x0703
    case setEqGain        = 0x0704
    case setEqQ           = 0x0705
    case setEqFilter      = 0x0706
    case setEqFreq        = 0x0707
    case saveEqPreset     = 0x0708
    case loadEqPreset     = 0x0709
    case setEqPresetName  = 0x070A
    case reqEqPresetName  = 0x070B
    case rspEqPresetName  = 0x070C
    case setEqMode        = 0x070E
    case setEqBandParam   = 0x070F
    case setEqMute        = 0x0710
    case reqEqData        = 0x0750
    case rspEqData        = 0x0751

    case sysReboot        = 0x1000
    case playTestTone     = 0x1004
    case saveAll          = 0x1007
    case notification     = 0x2000
    case warning          = 0x2002
}

enum QxVolumeParam: UInt8 {
    case sink     = 1
    case call     = 2
    case source   = 4
    case sysTrimL = 8
    case sysTrimR = 16
    case sysLimit = 32
    case tone     = 64
    case mute     = 128
}

enum QxVolumeRange {
    static let trim: ClosedRange<Double> = -24...0
    static let limit: ClosedRange<Double> = -60...6
}

extension QxVolumeParam {
    var dbRange: ClosedRange<Double>? {
        switch self {
        case .sysTrimL, .sysTrimR: return QxVolumeRange.trim
        case .sysLimit: return QxVolumeRange.limit
        case .sink, .call, .source, .tone, .mute: return nil
        }
    }

    func clamp(_ db: Double) -> Double {
        guard let r = dbRange else { return db }
        return min(max(db, r.lowerBound), r.upperBound)
    }
}

enum QxInit {
    static let requestPayload: [UInt8] = [0x00, 0x00, 0x04]
}

enum QxStatusMask {
    static let audio: UInt8 = 0x01
    static let power: UInt8 = 0x02
    static let conn: UInt8 = 0x04
    static let runtimeInfo: UInt8 = 0x08
    static let runtimeRms: UInt8 = 0x10
    static let runtimeEq: UInt8 = 0x20
    static let vol: UInt8 = 0x40
    static let reserved: UInt8 = 0x80
}

enum QxConfigMask {
    static let sys: UInt8 = 0x01
    static let vol: UInt8 = 0x02
    static let playTime: UInt8 = 0x04
    static let dac: UInt8 = 0x08
    static let mic: UInt8 = 0x10
    static let batt: UInt8 = 0x20
    static let sys2: UInt8 = 0x40
    static let eq: UInt8 = 0x80
}

enum QxNotifyMask {
    static let status: UInt8 = 1
    static let config: UInt8 = 2
    static let data: UInt8 = 4
}

enum QxFilter: UInt8, CaseIterable, Identifiable, Codable {
    case bypass = 0
    case lpf    = 1
    case hpf    = 2
    case lowShelf  = 3
    case highShelf = 4
    case peak   = 5

    var id: UInt8 { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let raw = try? container.decode(UInt8.self),
              let known = QxFilter(rawValue: raw) else {
            self = .bypass
            return
        }
        self = known
    }

    var label: String {
        switch self {
        case .bypass: return "Bypass"
        case .lpf: return "LPF"
        case .hpf: return "HPF"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        case .peak: return "Peak"
        }
    }
    var hasGain: Bool {
        switch self {
        case .peak, .lowShelf, .highShelf: return true
        case .lpf, .hpf, .bypass: return false
        }
    }

    var shortLabel: String {
        switch self {
        case .bypass: return "Off"
        case .lpf: return "LP"
        case .hpf: return "HP"
        case .lowShelf: return "LShelf"
        case .highShelf: return "HShelf"
        case .peak: return "Peak"
        }
    }

    var rendersGain: Bool {
        switch self {
        case .peak, .lowShelf, .highShelf: return true
        case .bypass, .lpf, .hpf: return false
        }
    }
}

enum QxScale {
    static let gain: Double = 10
    static let q: Double = 1024
    static let volume: Double = 60
}

enum QxDeviceModel {
    static let qudelix5K = 1
    static let qudelix5KPlus = 2
    static let t71 = 256
    static let auraVita = 512
    static let dongle = 768

    static func name(for id: Int) -> String {
        switch id {
        case qudelix5K: return "Qudelix 5K"
        case qudelix5KPlus: return "Qudelix 5K Plus"
        case t71: return "Qudelix T71"
        case auraVita: return "Qudelix Aura Vita"
        case dongle: return "Qudelix dongle"
        default: return "This device (id \(id))"
        }
    }
}

enum QxEqGroup: UInt8 {
    case user = 0
    case speaker = 1
    case b20 = 2

    var bandCount: Int { self == .b20 ? 20 : 10 }

    var paramChannels: Int { self == .speaker ? 2 : 1 }

    var freqChannels: Int { self == .b20 ? 1 : 2 }

    var presetBytes: Int {
        let bits = (1 + 14 + 11 + 6)
            + 2 * 16
            + freqChannels * bandCount * 16
            + paramChannels * bandCount * (4 + 10 + 14 + 4)
        return bits / 8
    }

    var requestMask: UInt8 { UInt8(1 << rawValue) }

    var writeChannelMask: UInt8 { self == .speaker ? 3 : 1 }

    var defaultFreqs: [Int] {
        self == .b20
            ? [31, 44, 63, 88, 125, 180, 250, 355, 500, 710,
               1000, 1400, 2000, 2800, 4000, 5600, 8000, 11300, 16000, 20000]
            : [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    }
}

enum QxEq {
    static let maxBandCount = 20
    static let presetCount = 20
    static let bandCount = 10
    static let defaultFreqs = QxEqGroup.user.defaultFreqs
}

enum QxPacket {
    static func payload(_ cmd: QxCmd, _ data: [UInt8] = []) -> [UInt8] {
        [UInt8(cmd.rawValue >> 8), UInt8(cmd.rawValue & 0xFF)] + data
    }

    static func txReport(_ cmd: QxCmd, _ data: [UInt8], reportSize: Int) -> [UInt8] {
        let p = payload(cmd, data)
        guard reportSize >= p.count + 2, reportSize >= 4 else { return [] }
        var report = [UInt8](repeating: 0, count: reportSize)
        report[0] = UInt8(clamping: p.count + 1)
        report[1] = 0x80
        for (i, b) in p.enumerated() where i + 2 < reportSize { report[i + 2] = b }
        return report
    }

    static func parseRx(_ buf: [UInt8]) -> (cmdId: UInt16, data: [UInt8])? {
        guard buf.count >= 3 else { return nil }
        let len = Int(buf[0])
        let cmdId = UInt16(buf[1]) << 8 | UInt16(buf[2])
        guard len >= 2 else { return nil }
        let end = min(len + 1, buf.count)
        return (cmdId, Array(buf[3..<max(3, end)]))
    }

    static func int16BE(_ v: Int) -> [UInt8] {
        let u = UInt16(bitPattern: Int16(clamping: v))
        return [UInt8(u >> 8), UInt8(u & 0xFF)]
    }

    static func volumePayload(_ param: QxVolumeParam, db: Double) -> [UInt8]? {
        guard db.isFinite else { return nil }
        let scaled = Int((param.clamp(db) * QxScale.volume).rounded())
        return [param.rawValue] + int16BE(scaled)
    }

    static func presetNamePayload(group: QxEqGroup, index: Int, name: String) -> [UInt8]? {
        guard (0..<QxEq.presetCount).contains(index) else { return nil }
        let text = truncatingUTF8(name, to: maxPresetNameBytes)
        let bytes = Array(text.utf8)
        guard 3 + bytes.count <= 3 + maxPresetNameBytes else { return nil }
        return [group.rawValue, UInt8(index), UInt8(3 + bytes.count)] + bytes
    }

    static let maxPresetNameBytes = 29

    static func truncatingUTF8(_ s: String, to max: Int) -> String {
        if s.utf8.count <= max { return s }
        var out = "", used = 0
        for ch in s {
            let n = String(ch).utf8.count
            if used + n > max { break }
            out.append(ch)
            used += n
        }
        return out
    }

    static func dacFilterPayload(_ index: Int) -> [UInt8]? {
        guard QxStatusParser.dacFilters.indices.contains(index) else { return nil }
        return [UInt8(index)]
    }

    enum BandLimit {
        static let freq = 20...20000
        static let gain: ClosedRange<Double> = -12...12
        static let q: ClosedRange<Double> = 0.1...10
    }

    static func bandParamPayload(group: QxEqGroup, band: Int,
                                 _ v: QxEqBandValue) -> [UInt8]? {
        guard (0..<group.bandCount).contains(band) else { return nil }
        guard v.gain.isFinite, v.q.isFinite else { return nil }
        guard BandLimit.freq.contains(v.freq),
              BandLimit.gain.contains(v.gain),
              BandLimit.q.contains(v.q) else { return nil }
        return [group.rawValue, group.writeChannelMask, UInt8(band), v.filter.rawValue]
            + int16BE(v.freq)
            + int16BE(Int((v.gain * QxScale.gain).rounded()))
            + int16BE(Int((v.q * QxScale.q).rounded()))
    }
}

struct QxBitReader {
    let buf: [UInt8]
    var bitOffset = 0

    init(_ buf: [UInt8]) { self.buf = buf }

    mutating func read(_ numBits: Int) -> Int {
        var value = 0
        for i in 0..<numBits {
            let bit = bitOffset + i
            let byteIdx = bit >> 3
            guard byteIdx < buf.count else { break }
            if (buf[byteIdx] >> (bit & 7)) & 1 == 1 { value |= 1 << i }
        }
        bitOffset += numBits
        return value
    }

    mutating func skip(_ numBits: Int) { bitOffset += numBits }

    static func signExtend(_ v: Int, bits: Int) -> Int {
        let shift = 64 - bits
        return (v << shift) >> shift
    }
}

struct QxUserEqPreset {
    var preGain: Double = 0
    var preGainCh1: Double = 0
    var crossfeedLevel: Int = 0
    var bands: [QxEqBandValue] = []

    static func decode(_ buf: [UInt8], group: QxEqGroup = .user) -> QxUserEqPreset {
        var r = QxBitReader(buf)
        var preset = QxUserEqPreset()
        r.skip(1 + 14 + 11)
        preset.crossfeedLevel = r.read(6)
        preset.preGain = Double(QxBitReader.signExtend(r.read(16), bits: 16)) / QxScale.gain
        preset.preGainCh1 = Double(QxBitReader.signExtend(r.read(16), bits: 16)) / QxScale.gain

        let bandCount = group.bandCount
        var freqs = [[Int]](repeating: [Int](repeating: 0, count: bandCount),
                            count: group.freqChannels)
        for ch in 0..<group.freqChannels {
            for b in 0..<bandCount { freqs[ch][b] = r.read(16) }
        }

        let defaults = group.defaultFreqs
        for b in 0..<bandCount {
            let typeRaw = r.read(4)
            let gainRaw = r.read(10)
            let qRaw = r.read(14)
            r.skip(4)
            let stored = freqs.first?[b] ?? 0
            preset.bands.append(QxEqBandValue(
                filter: QxFilter(rawValue: UInt8(typeRaw)) ?? .peak,
                freq: stored > 0 ? stored : defaults[b],
                gain: Double(QxBitReader.signExtend(gainRaw, bits: 10)) / QxScale.gain,
                q: qRaw > 0 ? Double(qRaw) / QxScale.q : 1.0
            ))
        }
        return preset
    }

    var looksPlausible: Bool {
        guard !bands.isEmpty, abs(preGain) <= 24 else { return false }
        return bands.allSatisfy { b in
            b.freq >= 10 && b.freq <= 24000 && abs(b.gain) <= 24 && b.q > 0 && b.q <= 20
        }
    }
}

struct QxEqBandValue: Equatable, Codable {
    var filter: QxFilter = .peak
    var freq: Int = 1000
    var gain: Double = 0
    var q: Double = 1.0
}

struct QxPresetAssembler {
    private(set) var buffer = [UInt8](repeating: 0, count: 128)
    private(set) var complete = false
    var group: QxEqGroup = .user

    private var covered = [Bool](repeating: false, count: 128)

    mutating func ingest(_ data: [UInt8]) -> Bool {
        guard data.count >= 7, data[0] == group.rawValue else { return false }
        let totalPkts = Int(data[1] >> 4)
        let pktIdx = Int(data[1] & 0x0F)
        guard totalPkts >= 1, pktIdx <= totalPkts else { return false }
        if pktIdx == 0 { reset() }
        let offset = Int(data[4]) << 8 | Int(data[5])
        let chunk = Array(data[6...])
        if offset + chunk.count <= buffer.count {
            for (i, b) in chunk.enumerated() {
                buffer[offset + i] = b
                covered[offset + i] = true
            }
        }
        complete = covered.prefix(group.presetBytes).allSatisfy { $0 }
        return complete
    }

    mutating func reset() {
        buffer = [UInt8](repeating: 0, count: 128)
        covered = [Bool](repeating: false, count: 128)
        complete = false
    }
}
