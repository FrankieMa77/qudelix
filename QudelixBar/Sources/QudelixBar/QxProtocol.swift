import Foundation

/// Qudelix 5K command protocol.
///
/// Command ids and payload layouts, verified against firmware 3.1.8 and 3.2.7.
/// Where a command is declared but never sent, the declaration says why.
enum QxCmd: UInt16 {
    // Handshake / info
    case reqInitData      = 0x0100
    case rspInitData      = 0x0101
    case disconnect       = 0x0107
    case reqDevStatus     = 0x0110  // arg = bitmask (0x04 = conn)
    case rspDevStatus     = 0x0111
    case reqDevConfig     = 0x0120  // arg = bitmask (0x3C = playTime|batt|mic|dac, 0xC0 = sys2|eq)
    case rspDevConfig     = 0x0121
    case reqEqPreset      = 0x0123  // arg = group bitmask (1 = usr, 2 = spk, 4 = b20)
    case rspEqPresetL     = 0x0124
    case rspEqPresetH     = 0x0125
    case rspEqPreset      = 0x0128
    case reqDevData       = 0x0140
    case rspDevData       = 0x0141

    // Device settings
    case setVolume        = 0x0200  // [subParam, int16BE dB*60] (sink=1) / [subParam, ch, value] variants
    // Declared, never sent. The read side does now give this setting —
    // `dd.charger_enable`, one bit in the sys config block, parsed by
    // `QxStatusParser.parseDevConfig` — so its value domain is settled: on or
    // off, nothing in between. What it does not give is the shape of the
    // payload that writes it. A bare value byte is the obvious guess, and in
    // this command set the obvious guess is not safe: SetVolume, directly
    // above, leads with a sub-parameter selector before its value, and
    // nothing says which of the two patterns the charger commands follow.
    //
    // Guessing wrong here is not like guessing a filter index wrong. These
    // are the power path. A payload read at the wrong offset lands on
    // whatever the next byte happens to mean, and this hardware answers a
    // report it dislikes by dropping off the bus. The worst outcome is also
    // the quietest one: a 5K that has silently stopped charging while it
    // sits on a USB port all day is a 5K that is flat when it is unplugged.
    //
    // Reading the setting and showing it is worth having on its own, and
    // that is what shipped instead. Nothing here may send this until the
    // payload's shape is confirmed against hardware.
    case setCharger       = 0x0201
    case setLedMode       = 0x0202
    case setUsbFsMode     = 0x0209  // [idx], DESCENDING: 0=96, 1=88.2, 2=48, 3=44.1, 4=all, 5=48+mic, 6=44.1+mic; device re-enumerates USB
    // Declared, never sent, for the same reason as setCharger: the read side
    // establishes the setting (`dd.batt_care`) and its two-valued domain, and
    // says nothing about the payload that writes it. The consequence of a
    // wrong write is milder than the charger's — a charge ceiling that moves
    // is not a device that goes flat — but it is the same guess, on the same
    // subsystem, with the same absence of evidence behind it.
    case setBatteryCare   = 0x0213
    case setUsbDacMode    = 0x0217
    case setDacFilter     = 0x0501  // [idx] into QxStatusParser.dacFilters, no group byte

    // EQ (group 0 = usr/headphone, 10 bands, legacy 5K payloads)
    case setEqEnable      = 0x0700  // [group, 0|1]
    case setEqType        = 0x0701  // [group, 0=GEQ 1=PEQ]
    case setEqPreGain     = 0x0703  // sendEqParam
    case setEqGain        = 0x0704  // sendEqParam, dB*10
    case setEqQ           = 0x0705  // sendEqParam, Q*1024
    case setEqFilter      = 0x0706  // sendEqParam, app filter enum
    case setEqFreq        = 0x0707  // sendEqParam, Hz
    case saveEqPreset     = 0x0708  // [presetIndex]
    case loadEqPreset     = 0x0709  // [presetIndex]
    // [group, presetIndex, endOffset, utf8…] where endOffset is 3 + the byte
    // count of the text — the same offset the response reports, pointing one
    // past the last name byte. Confirmed against hardware, including the
    // failure that identifies it: sending the text with no offset byte makes
    // the device consume the first character as the offset and store the rest.
    case setEqPresetName  = 0x070A
    case reqEqPresetName  = 0x070B  // [group, presetIndex]
    case rspEqPresetName  = 0x070C  // [group, presetIndex, endOffset, utf8…]
    case setEqMode        = 0x070E  // [mode]: 0 = usr/spk (10-band), 1 = b20 (20-band)
    case setEqBandParam   = 0x070F  // [group, chMask, band, filter, freqHi, freqLo, gainHi, gainLo, qHi, qLo]
    // Declared, never sent: nothing the device reports carries a mute bit —
    // not the preset bitstream, not the EQ config block — so there is no
    // read side to take the payload's width or value domain from, and no way
    // to see afterwards whether a write landed. Per-band muting goes through
    // SetEqBandParam's filter field instead (`QudelixController.setBandMuted`).
    case setEqMute        = 0x0710
    case reqEqData        = 0x0750
    case rspEqData        = 0x0751

    // System
    case sysReboot        = 0x1000
    case playTestTone     = 0x1004
    case saveAll          = 0x1007
    case notification     = 0x2000
    case warning          = 0x2002
}

/// Volume sub-parameter flags for the 5K (`ly` enum — NOT the `$y` enum,
/// which is T71/AuraVita only). First byte of SetVolume payload.
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

/// Fixed dB ranges the 5K accepts for the absolute volume settings.
enum QxVolumeRange {
    /// Per-channel output trim. Attenuation only — the trims exist to pull one
    /// channel down against the other, never to push one past the ceiling.
    static let trim: ClosedRange<Double> = -24...0
    /// The device's own volume ceiling. The top of the range is only reachable
    /// in 2 Vrms output mode; in 1 Vrms mode the hardware caps at 0 dB anyway.
    static let limit: ClosedRange<Double> = -60...6
}

extension QxVolumeParam {
    /// The fixed range this sub-parameter accepts, in dB, or nil when it has
    /// no fixed range.
    ///
    /// The master level (`sink`, and `call` during a call) deliberately has
    /// none: its ceiling is the volume limit combined with the DAC's
    /// output-power mode and is only known at runtime, and its floor is 60 dB
    /// below that ceiling. Those are clamped against the live window instead.
    /// `source` likewise depends on which input is active.
    var dbRange: ClosedRange<Double>? {
        switch self {
        case .sysTrimL, .sysTrimR: return QxVolumeRange.trim
        case .sysLimit: return QxVolumeRange.limit
        case .sink, .call, .source, .tone, .mute: return nil
        }
    }

    /// Clamp a dB value into this sub-parameter's range. Non-finite input is
    /// not clampable and is rejected by the callers, not folded to a boundary.
    func clamp(_ db: Double) -> Double {
        guard let r = dbRange else { return db }
        return min(max(db, r.lowerBound), r.upperBound)
    }
}

/// ReqInitData payload: [status_hi, status_lo, At.Req] — the firmware
/// requires this exact 3-byte payload (a bare request crashes its USB stack).
enum QxInit {
    static let requestPayload: [UInt8] = [0x00, 0x00, 0x04]
}

/// RspDevStatus / notification block flags (`Yc`).
enum QxStatusMask {
    static let audio: UInt8 = 0x01       // $c, 4 bytes
    static let power: UInt8 = 0x02       // td, 8 bytes — battery lives here
    static let conn: UInt8 = 0x04        // od, 16 bytes
    static let runtimeInfo: UInt8 = 0x08 // Jc, 4 bytes
    static let runtimeRms: UInt8 = 0x10  // ed, 16 bytes
    static let runtimeEq: UInt8 = 0x20   // never sent for x5k
    static let vol: UInt8 = 0x40         // cy, 16 bytes + 1 usbMute byte
}

/// RspDevConfig block flags (`hy`).
enum QxConfigMask {
    static let sys: UInt8 = 0x01         // dd, 12 bytes
    static let vol: UInt8 = 0x02         // cy, 16 bytes
    static let playTime: UInt8 = 0x04    // vy, 8 bytes
    static let dac: UInt8 = 0x08         // gd, 4 bytes
    static let mic: UInt8 = 0x10         // my, 4 bytes
    static let batt: UInt8 = 0x20        // fy, 8 bytes
    static let sys2: UInt8 = 0x40        // fd, 32 bytes
    static let eq: UInt8 = 0x80          // group cfg + preset-name cfg
}

/// Notification (0x2000) second-byte flags (`St`), fw >= 3 default path.
enum QxNotifyMask {
    static let status: UInt8 = 1
    static let config: UInt8 = 2
    static let data: UInt8 = 4
}

/// App-side filter type enum (what Set/RspEq commands carry on the legacy 5K).
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

    /// Compact form for the band table.
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
}

enum QxScale {
    static let gain: Double = 10      // dB → int16
    static let q: Double = 1024       // Q → int16
    static let volume: Double = 60    // dB → int16 (dB60 units)
}

/// Device identifiers returned in RspInitData (`kt` enum).
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

/// EQ group (`by` enum). The 5K stores separate presets per group and only one
/// is active, selected by `dd.eq_mode`.
enum QxEqGroup: UInt8 {
    case user = 0     // 10 bands, 1 channel of filter params
    case speaker = 1  // 10 bands, 2 channels
    case b20 = 2      // 20 bands, 1 channel

    /// Bands the device exposes for this group (`nBand`).
    var bandCount: Int { self == .b20 ? 20 : 10 }

    /// Channels of *filter parameters* stored (`nCh` = [1, 2, 1][group]).
    var paramChannels: Int { self == .speaker ? 2 : 1 }

    /// Channels in the *frequency* table — b20 stores one, the others two.
    var freqChannels: Int { self == .b20 ? 1 : 2 }

    /// Preset bitstream size. Derived below and cross-checked against the
    /// firmware's own constants: USR_EQ_1CH_SZ = 88, B20_EQ_1CH_SZ = 128.
    var presetBytes: Int {
        let bits = (1 + 14 + 11 + 6)                    // type, impedance, sensitivity, xfeed
            + 2 * 16                                    // pre-gain, both channels
            + freqChannels * bandCount * 16             // frequency table
            + paramChannels * bandCount * (4 + 10 + 14 + 4)  // filter, gain, Q, reserved
        return bits / 8
    }

    /// Bitmask used with ReqEqPreset.
    var requestMask: UInt8 { UInt8(1 << rawValue) }

    /// Channel mask for EQ writes. Only the speaker group has two parameter
    /// channels; the official app sends the both-channels mask exclusively
    /// there. On the single-channel groups the extra bit makes the firmware
    /// write a phantom second channel over adjacent struct memory — read
    /// back from real hardware as a 20-band preset whose stored low bands
    /// were overwritten by frequency-table echoes, i.e. quietly destroyed.
    var writeChannelMask: UInt8 { self == .speaker ? 3 : 1 }

    /// The device's own default centre frequencies (`Ny.Fc`).
    var defaultFreqs: [Int] {
        self == .b20
            ? [31, 44, 63, 88, 125, 180, 250, 355, 500, 710,
               1000, 1400, 2000, 2800, 4000, 5600, 8000, 11300, 16000, 22000]
            : [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    }
}

enum QxEq {
    // NOTE: no both-channels write mask lives here on purpose. Sending it
    // on a single-channel group makes the firmware corrupt its own stored
    // preset struct; the per-group mask is QxEqGroup.writeChannelMask.
    /// Largest band count across groups — sizing only; use the group's own.
    static let maxBandCount = 20
    /// Preset slots the device stores per group.
    static let presetCount = 20
    static let bandCount = 10
    static let defaultFreqs = QxEqGroup.user.defaultFreqs
}

// MARK: - Packet building / parsing

enum QxPacket {
    /// Command payload: [cmdHi, cmdLo, data...]
    static func payload(_ cmd: QxCmd, _ data: [UInt8] = []) -> [UInt8] {
        [UInt8(cmd.rawValue >> 8), UInt8(cmd.rawValue & 0xFF)] + data
    }

    /// TX report body (QCC framing): [payloadLen+1, 0x80, payload...] zero-padded to reportSize.
    /// Returns empty if the report is too small to hold the framing.
    static func txReport(_ cmd: QxCmd, _ data: [UInt8], reportSize: Int) -> [UInt8] {
        let p = payload(cmd, data)
        guard reportSize >= p.count + 2, reportSize >= 4 else { return [] }
        var report = [UInt8](repeating: 0, count: reportSize)
        report[0] = UInt8(clamping: p.count + 1)
        report[1] = 0x80
        for (i, b) in p.enumerated() where i + 2 < reportSize { report[i + 2] = b }
        return report
    }

    /// RX report body: [payloadLen, cmdHi, cmdLo, data...] → (cmdId, data)
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

    /// SetVolume payload for a dB-valued sub-parameter: `[param, int16 BE dB×60]`.
    ///
    /// Returns nil for non-finite input. There is no byte pattern that means
    /// NaN here, and converting one to an integer traps outright, so it is
    /// refused rather than turned into some arbitrary in-range value. Finite
    /// values are clamped to the sub-parameter's range *before* scaling, so a
    /// slider or a text field can never put an out-of-range setting on the
    /// wire — this hardware stops answering when it dislikes a report.
    static func volumePayload(_ param: QxVolumeParam, db: Double) -> [UInt8]? {
        guard db.isFinite else { return nil }
        let scaled = Int((param.clamp(db) * QxScale.volume).rounded())
        return [param.rawValue] + int16BE(scaled)
    }

    /// SetDacFilter payload: a single byte carrying the raw filter index,
    /// verbatim — the same index `QxStatusParser` reads back out of the dac
    /// config block's 4-bit field. Returns nil for anything outside
    /// `QxStatusParser.dacFilters`, rather than clamping: there is no boundary
    /// index that means "closest valid filter", only entries that name a real
    /// one and a lot of numbers that name nothing the device defines.
    /// Payload that writes a preset slot's name, or nil when it cannot be
    /// expressed safely.
    ///
    /// The text is capped at `maxPresetNameBytes` and cut on a character
    /// boundary, never mid-scalar: the field is a byte range, so a name of
    /// CJK or emoji runs out of room far sooner than it looks, and half a
    /// scalar would be stored as a byte sequence that is not text.
    static func presetNamePayload(group: QxEqGroup, index: Int, name: String) -> [UInt8]? {
        guard (0..<QxEq.presetCount).contains(index) else { return nil }
        let text = truncatingUTF8(name, to: maxPresetNameBytes)
        let bytes = Array(text.utf8)
        // endOffset has to stay inside the field the device reports.
        guard 3 + bytes.count <= 3 + maxPresetNameBytes else { return nil }
        return [group.rawValue, UInt8(index), UInt8(3 + bytes.count)] + bytes
    }

    /// The device reports the name field ending at offset 32, so 29 bytes sit
    /// between the three header bytes and that end. Staying at exactly what
    /// the device itself reports means the write cannot run past the field.
    static let maxPresetNameBytes = 29

    /// Longest prefix of `s` whose UTF-8 encoding fits in `max` bytes, cut
    /// between characters.
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

    /// Ranges a band parameter may hold on the wire. These are the editor's
    /// own limits, and the same window `applyPreset` clamps a device
    /// read-back into, so a value that came off the device can always be
    /// written straight back.
    enum BandLimit {
        static let freq = 20...20000
        static let gain: ClosedRange<Double> = -12...12
        static let q: ClosedRange<Double> = 0.1...10
    }

    /// SetEqBandParam payload — every parameter of one band in a single
    /// packet: `[group, channelMask, band, filter, freq BE, gain BE, Q BE]`.
    ///
    /// Each field mirrors the one the preset bitstream hands back on the way
    /// in: the filter is the 4-bit type field's value, the gain the same
    /// dB×10 the 10-bit field carries, the Q the same ×1024. The channel mask
    /// is the group's own — the both-channels mask on a single-channel group
    /// is what makes the firmware write over its neighbouring struct.
    ///
    /// Returns nil rather than a nearest-legal packet for anything outside
    /// that domain: a band index the group doesn't have, a non-finite gain or
    /// Q (which has no boundary that means anything, and traps on conversion),
    /// or a value the editor's own limits exclude. Callers clamp first; this
    /// is the backstop that keeps an unclamped path from reaching the wire.
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

// MARK: - Bitstream reader (RspEqPreset payload is a packed LSB-first bitstream)

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

/// Decoded user-EQ preset (88-byte v3 bitstream, nCh=1, 10 bands).
struct QxUserEqPreset {
    var preGain: Double = 0
    /// The second stored pre-gain channel. Normally equal to `preGain`.
    var preGainCh1: Double = 0
    /// Crossfeed level stored with this preset, in the device's own 6-bit
    /// field (0…63, 0 = off). Read only: the device does its crossfeed in
    /// hardware and keeps one setting per preset, but the step size and the
    /// shape of the write command are not established here, so nothing sends
    /// this back — it is decoded so the value can be shown, not changed.
    var crossfeedLevel: Int = 0
    var bands: [QxEqBandValue] = []

    /// Layout (`fromArray_v3`, verbatim from the firmware's own parser):
    ///
    ///     [1]  type          [14] impedance     [11] sensitivity   [6] crossfeed
    ///     [16] preGain ch0   [16] preGain ch1                      (int16, dB×10)
    ///     freq table:  freqChannels × bandCount × [16] uint16 Hz
    ///     per band:    paramChannels × bandCount ×
    ///                    ([4] filter, [10] gain dB×10 signed, [14] Q ×1024, [4] reserved)
    ///
    /// The 20-band (b20) group stores one channel of frequencies where the
    /// 10-band groups store two — that difference is the whole reason its
    /// buffer is 128 bytes rather than 88.
    static func decode(_ buf: [UInt8], group: QxEqGroup = .user) -> QxUserEqPreset {
        var r = QxBitReader(buf)
        var preset = QxUserEqPreset()
        r.skip(1 + 14 + 11)                 // type, impedance, sensitivity
        preset.crossfeedLevel = r.read(6)   // crossfeed is stored per preset
        preset.preGain = Double(QxBitReader.signExtend(r.read(16), bits: 16)) / QxScale.gain
        // Read, not skipped. The two are meant to agree, and while this app
        // wrote only the first they could silently drift apart into a left/right
        // imbalance nothing could observe. Kept so a disagreement can be seen
        // and corrected rather than lived with.
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

    /// Sanity check for a decoded preset. The 20-band layout is derived from
    /// the firmware's parser but has never been run against real hardware, so
    /// an implausible result is treated as a decode failure rather than being
    /// shown as if it were the device's actual curve.
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

/// Reassembles segmented RspEqPreset packets into the preset buffer.
/// Segment data: [group, (totalPkts<<4)|pktIdx, res, res, offsetBE16, chunk...]
struct QxPresetAssembler {
    private(set) var buffer = [UInt8](repeating: 0, count: 128)
    private(set) var complete = false
    /// Only segments for this group are accepted; the device also streams the
    /// groups we aren't editing.
    var group: QxEqGroup = .user

    /// Which bytes of `buffer` have actually been filled by a segment.
    ///
    /// The segment header alone can't be trusted to say the preset is done:
    /// `pktIdx == totalPkts` is satisfied by a single segment claiming
    /// `totalPkts = 0`, which would hand `decode` a buffer that is still mostly
    /// zeroes and present it as the device's real curve. Completion is decided
    /// by coverage instead — every byte the group's bitstream occupies must
    /// have been written. Repeated segments are harmless, and order doesn't
    /// matter except for segment 0, which restarts the stream (below).
    private var covered = [Bool](repeating: false, count: 128)

    mutating func ingest(_ data: [UInt8]) -> Bool {
        guard data.count >= 7, data[0] == group.rawValue else { return false }
        let totalPkts = Int(data[1] >> 4)
        let pktIdx = Int(data[1] & 0x0F)
        // A preset never fits in one segment, so totalPkts (the index of the
        // last segment) is at least 1 for anything genuine.
        guard totalPkts >= 1, pktIdx <= totalPkts else { return false }
        // Segment 0 starts a fresh stream: drop whatever a previous, incomplete
        // one left behind rather than completing on a mix of the two. HID
        // interrupt reports arrive in order, so a segment 0 after the stream has
        // begun means the device restarted it, not that packets overtook.
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
