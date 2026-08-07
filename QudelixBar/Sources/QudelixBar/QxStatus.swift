import Foundation

/// Parsers for the 5K's status/config structs. All structs are LSB-first
/// bitfields, with multi-byte fields little-endian.
struct QxDeviceState {
    /// `kt` enum: 1 = original 5K, 2 = 5K Plus, 256 = T71, 512 = AuraVita…
    var deviceId: Int = 0
    var fwVersion: String?
    var fwMajor: Int?
    var fwMinor: Int?
    /// `dd.eq_mode`: 0 = 10-band user/speaker EQ, 1 = 20-band (b20) mode.
    ///
    /// On firmware 3.x the *command encoding* is identical for both — the
    /// official app picks its encoding on `isV2` (firmware 2.x), not on band
    /// count. 20-band differs only in EQ group (2 = b20), band count (20), the
    /// default frequency table, and the preset read-back layout.
    var eqMode: Int?
    /// `dd.usb_fs_mode`: which sample rates the USB descriptor offers the
    /// host. DESCENDING, verified against real re-enumeration: 0…3 pin a
    /// single rate (96/88.2/48/44.1), 4 offers all four, 5/6 are the
    /// mic-enabled 48/44.1 modes.
    var usbFsMode: Int?
    var batteryPercent: Int?
    var batteryMilliVolts: Int?
    var charging = false
    var chargerConnected = false
    /// `td.batt_low`: the device's own opinion of a low battery, rather than a
    /// threshold this app picks off the percentage. Worth keeping separate —
    /// the two can disagree, and when they do the device is the one that will
    /// act on it.
    var batteryLow: Bool?
    /// `td.charger_state`: a 3-bit state machine the charger reports on every
    /// power block. Carried as its raw value: the states are observably real
    /// (the value changes when a charge cycle starts and again when it ends)
    /// but nothing establishes what each number is called, so naming them here
    /// would be invention.
    var chargerState: Int?
    /// `td.dac_state`: a 3-bit state for the output path, in the same
    /// position of the same block. Also raw, for the same reason — though it
    /// tracks the audio-running flag closely enough to be a second opinion on
    /// whether the DAC is actually doing anything.
    var dacState: Int?
    /// `dd.charger_enable`: whether the 5K charges at all while a charger is
    /// connected. Off means it will run the battery down on a live USB port.
    var chargerEnabled: Bool?
    /// `dd.batt_care`: whether the 5K stops charging short of full.
    var batteryCare: Bool?
    var sampleRateLabel: String?
    var inputSourceLabel: String?
    /// a2dp_codec label (SBC/AAC/aptX/…/LDAC). Only meaningful over A2DP;
    /// the separate hfp_codec field isn't surfaced here.
    var codecLabel: String?
    /// out_unbalanced status bit: which output jack is currently active.
    var outputJackUnbalanced: Bool?
    /// out_power status bit: current headphone-amp gain/power state.
    var outputHighGain: Bool?
    var audioMuted: Bool?
    var audioRunning: Bool?        // true while audio is actively playing
    var activeCall: Bool?          // true during an HFP call
    var volumeDb: Double?          // cy.sink_dB60 / 60
    var volumeLimitDb: Double?
    var trimLeftDb: Double?
    var trimRightDb: Double?
    var usbMute: Bool?
    var eqEnabled: Bool?
    var eqPresetIdx: Int?
    var presetNameMask: Int = 0    // 20 bits — slots with saved names
    /// Which EQ group the three fields above describe (the eq config block
    /// carries the active group's byte: 0 = usr, 2 = b20). Consumers must
    /// check it — a 10-band mask read against 20-band mode names the wrong
    /// slots.
    var eqCfgGroup: Int?
    var dacOutPwr2Vrms = false     // +6 dB headroom when true
    var dacFilterType: Int?
    /// Raw device play-time counters (32-bit each, no documented unit —
    /// kept unconverted rather than guessing seconds).
    var totalPlayTime: Int?
    var totalPlayTimeAtLastCharge: Int?
}

extension Array where Element == UInt8 {
    /// Bytes from `offset` to the end, or empty if the offset is out of range.
    ///
    /// Device payloads are untrusted: block lengths come from mask bytes the
    /// firmware sends, so an offset can legitimately run past a truncated
    /// packet. Plain `Array(d[off...])` traps in that case.
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

    /// RspInitData — device id, status byte, and the firmware version.
    ///
    /// The reply also carries status and config blocks after the version, but
    /// they are deliberately not read here. Finding where they start depends on a
    /// length the reply reports about itself, and when that disagrees with the
    /// bytes actually sent, every field after it is read from the wrong place —
    /// quietly, with plausible-looking results rather than an error.
    ///
    /// Nothing is lost by skipping them: the handshake requests the same data
    /// explicitly a moment later, and each of those replies carries a single
    /// block whose layout is unambiguous.
    static func parseInitData(_ d: [UInt8], into state: inout QxDeviceState) -> Bool {
        guard d.count >= 11 else { return false }
        let devId = Int(d[0]) << 8 | Int(d[1])
        guard d[2] == 3 else { return false }  // At.Success
        state.deviceId = devId

        var r = QxBitReader(Array(d[3..<11]))
        let major = r.read(6), minor = r.read(6), rev = r.read(4)
        state.fwVersion = "\(major).\(minor).\(rev)"
        state.fwMajor = major
        state.fwMinor = minor
        return true
    }

    /// devStatus block: [Yc mask][sub-blocks in ascending bit order].
    /// Returns bytes consumed (including the mask byte).
    ///
    /// A block whose size guard fails means the packet is truncated or the
    /// mask lies — either way every offset after it is garbage, so the whole
    /// remainder is consumed rather than letting a caller parse the next
    /// section (a config block, say) from a misaligned position.
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
            r.skip(2)                       // hfp_codec
            let codecIdx = r.read(4)        // a2dp_codec
            if codecIdx < codecs.count { state.codecLabel = codecs[codecIdx] }
            let inSource = r.read(3)
            r.skip(2)                       // in_bits
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
            // These three arrive on every power block. They used to be
            // stepped over; reading them shifts nothing after them, which the
            // battery percentage immediately below proves — it only lands on
            // a sane number if all nine leading bits are accounted for.
            state.chargerState = r.read(3)
            state.dacState = r.read(3)
            state.batteryLow = r.read(1) == 1
            state.batteryPercent = min(r.read(7), 100)   // 7 bits carries up to 127
            state.batteryMilliVolts = r.read(13)
            off += 8
        }
        if mask & QxStatusMask.conn != 0 { off += 16 }
        if mask & QxStatusMask.runtimeInfo != 0 { off += 4 }
        if mask & QxStatusMask.runtimeRms != 0 { off += 16 }
        if mask & QxStatusMask.vol != 0 {
            guard d.count >= off + 17 else { return d.count }
            parseVolBlock(Array(d[off..<off + 16]), into: &state)
            state.usbMute = d[off + 16] != 0
            off += 17
        }
        return min(off, d.count)
    }

    /// devConfig block: [hy mask][sub-blocks in ascending bit order].
    /// Same truncation rule as parseDevStatus: a failed size guard poisons
    /// every later offset, so the remainder is consumed, not misparsed —
    /// eq_mode read from a misaligned position flips the whole EQ layout.
    static func parseDevConfig(_ d: [UInt8], into state: inout QxDeviceState) -> Int {
        guard !d.isEmpty else { return 0 }
        let mask = d[0]
        var off = 1

        if mask & QxConfigMask.sys != 0 {
            // `dd`, 12 bytes. Three fields are taken from it.
            //
            // The two battery ones live at bits 4 and 5, near the front of a
            // run of single-bit flags. They are the *settings* — what the
            // device has been told to do — as opposed to the power block's
            // charging/charger_state, which is what it is doing right now.
            // Nothing else in the config reports them: the sys2 block is
            // buttons, LED level, preset-name mask and crossfeed, and the
            // batt block is the history log the battery chart is drawn from.
            //
            // Their position is only trustworthy because eq_mode below is:
            // the same walk that puts eq_mode at bit 36 puts these two here,
            // and eq_mode landing wrong is immediately visible as the whole
            // EQ layout flipping.
            guard d.count >= off + 12 else { return d.count }
            var r = QxBitReader(Array(d[off..<off + 12]))
            r.skip(4)   // need_factory_reset, need_power_on, reserved, button_lock
            state.chargerEnabled = r.read(1) == 1
            state.batteryCare = r.read(1) == 1
            r.skip(30)  // through the profile/codec/latency fields to eq_mode
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
            r.skip(5)                       // outMode(2), outSel(3)  — v3 layout
            state.dacOutPwr2Vrms = r.read(1) == 1
            r.skip(12)                      // bits 6..17
            state.dacFilterType = r.read(4)
            off += 4
        }
        if mask & QxConfigMask.mic != 0 { off += 4 }
        // Not the battery-care setting despite the name: this block is the
        // rolling battery history the device keeps for its own chart.
        if mask & QxConfigMask.batt != 0 { off += 8 }
        if mask & QxConfigMask.sys2 != 0 { off += 32 }
        if mask & QxConfigMask.eq != 0, d.count > off {
            // fw >= 3: [group byte] + groupCfg(4) + presetNameCfg(4);
            // if group == usr(0), the spk group follows in the same block.
            // The device sends the block for whichever group its eq_mode
            // makes active — usr(0) in 10-band mode, b20(2) in 20-band —
            // so both are taken, tagged with eqCfgGroup for the consumer.
            let group = d[off]; off += 1
            let applies = group == 0 || group == 2
            if applies { state.eqCfgGroup = Int(group) }
            off += parseEqGroupCfg(d, at: off, into: &state, applies: applies)
            if group == 0, d.count > off {
                off += 1  // spk group byte
                off += parseEqGroupCfg(d, at: off, into: &state, applies: false)
            }
        }
        return min(off, d.count)
    }

    /// groupCfg (4B: headroom int8, presetIdx u8, enable:1, auto_headroom:1)
    /// + presetNameCfg (4B: nameMask:20). Returns bytes consumed.
    private static func parseEqGroupCfg(_ d: [UInt8], at start: Int,
                                        into state: inout QxDeviceState, applies: Bool) -> Int {
        guard d.count >= start + 8 else { return max(0, d.count - start) }
        if applies {
            var r = QxBitReader(Array(d[start..<start + 4]))
            r.skip(8)  // headroom
            state.eqPresetIdx = r.read(8)
            state.eqEnabled = r.read(1) == 1
            var n = QxBitReader(Array(d[start + 4..<start + 8]))
            state.presetNameMask = n.read(20)
        }
        return 8
    }

    /// Widest dB window any of these fields can legitimately report. An int16 at
    /// dB×60 spans ±546 dB, and a value out at that end makes the volume slider's
    /// range nonsense; the app's own writes are clamped separately.
    private static let dbRange = -120.0...24.0

    /// cy volume struct (16B): 8 × int16 LE, unit dB*60.
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
