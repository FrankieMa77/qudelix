import XCTest
@testable import QudelixBar

enum Wire {
    static func packet(_ cmd: QxCmd, _ data: [UInt8]) -> [UInt8] {
        [UInt8(data.count + 2), UInt8(cmd.rawValue >> 8), UInt8(cmd.rawValue & 0xFF)] + data
    }

    static func notification(_ data: [UInt8]) -> [UInt8] { packet(.notification, data) }

    struct Bits {
        private(set) var bytes: [UInt8]
        private var offset = 0

        init(byteCount: Int) { bytes = [UInt8](repeating: 0, count: byteCount) }

        mutating func put(_ value: Int, _ width: Int) {
            for i in 0..<width {
                if (value >> i) & 1 == 1 { bytes[(offset + i) >> 3] |= UInt8(1 << ((offset + i) & 7)) }
            }
            offset += width
        }

        mutating func skip(_ width: Int) { offset += width }
    }

    static func initData(deviceId: Int = QxDeviceModel.qudelix5K,
                         major: Int = 3, minor: Int = 2, rev: Int = 7) -> [UInt8] {
        var bits = Bits(byteCount: 8)
        bits.put(major, 6)
        bits.put(minor, 6)
        bits.put(rev, 4)
        return packet(.rspInitData,
                      [UInt8(deviceId >> 8), UInt8(deviceId & 0xFF), 3] + bits.bytes)
    }

    static func sysBlock(eqMode: Int, usbFs: Int = 4) -> [UInt8] {
        var bits = Bits(byteCount: 12)
        bits.skip(4 + 1 + 1 + 30)
        bits.put(eqMode, 1)
        bits.put(usbFs, 3)
        return bits.bytes
    }

    static func eqConfigBlock(group: UInt8, slot: Int, enabled: Bool = true,
                              nameMask: Int = 0) -> [UInt8] {
        var cfg = Bits(byteCount: 4)
        cfg.put(0, 8)
        cfg.put(slot, 8)
        cfg.put(enabled ? 1 : 0, 1)
        var names = Bits(byteCount: 4)
        names.put(nameMask, 20)
        return [group] + cfg.bytes + names.bytes
    }

    static func deviceConfig(eqMode: Int, group: UInt8, slot: Int,
                             enabled: Bool = true, nameMask: Int = 0) -> [UInt8] {
        packet(.rspDevConfig,
               [QxConfigMask.sys | QxConfigMask.eq] + sysBlock(eqMode: eqMode)
               + eqConfigBlock(group: group, slot: slot, enabled: enabled, nameMask: nameMask))
    }

    static func eqConfigOnly(group: UInt8, slot: Int, enabled: Bool = true) -> [UInt8] {
        packet(.rspDevConfig,
               [QxConfigMask.eq] + eqConfigBlock(group: group, slot: slot, enabled: enabled))
    }

    static func presetBuffer(group: QxEqGroup, bands: [QxEqBandValue],
                             preGain: Double) -> [UInt8] {
        var bits = Bits(byteCount: 128)
        bits.put(1, 1)
        bits.put(0, 14)
        bits.put(0, 11)
        bits.put(0, 6)
        let gain = Int((preGain * QxScale.gain).rounded()) & 0xFFFF
        bits.put(gain, 16)
        bits.put(gain, 16)
        for _ in 0..<group.freqChannels {
            for b in bands { bits.put(b.freq, 16) }
        }
        for b in bands {
            bits.put(Int(b.filter.rawValue), 4)
            bits.put(Int((b.gain * QxScale.gain).rounded()) & 0x3FF, 10)
            bits.put(Int((b.q * QxScale.q).rounded()), 14)
            bits.put(0, 4)
        }
        return bits.bytes
    }

    static func presetPackets(group: QxEqGroup, bands: [QxEqBandValue],
                              preGain: Double) -> [[UInt8]] {
        let buffer = Array(presetBuffer(group: group, bands: bands, preGain: preGain)
            .prefix(group.presetBytes))
        let chunk = 50
        let total = (buffer.count + chunk - 1) / chunk - 1
        return stride(from: 0, to: buffer.count, by: chunk).enumerated().map { index, start in
            let part = Array(buffer[start..<min(start + chunk, buffer.count)])
            return packet(.rspEqPreset,
                          [group.rawValue, UInt8(total << 4 | index), 0, 0,
                           UInt8(start >> 8), UInt8(start & 0xFF)] + part)
        }
    }

    static func powerBlock(percent: Int, charging: Bool = false,
                           chargerConnected: Bool = false) -> [UInt8] {
        var bits = Bits(byteCount: 8)
        bits.put(chargerConnected ? 1 : 0, 1)
        bits.put(charging ? 1 : 0, 1)
        bits.put(0, 3)
        bits.put(0, 3)
        bits.put(0, 1)
        bits.put(percent, 7)
        bits.put(4000, 13)
        return bits.bytes
    }

    static func audioBlock(highGain: Bool = false, codec: Int = 0, sampleRate: Int = 6) -> [UInt8] {
        var bits = Bits(byteCount: 4)
        bits.put(0, 1)
        bits.put(1, 1)
        bits.put(0, 1)
        bits.skip(2)
        bits.put(codec, 4)
        bits.put(1, 3)
        bits.skip(2)
        bits.put(0, 1)
        bits.put(highGain ? 1 : 0, 1)
        bits.put(sampleRate, 4)
        return bits.bytes
    }

    static func volumeBlock(volume: Double, limit: Double = 0,
                            trimLeft: Double = 0, trimRight: Double = 0) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        func put(_ index: Int, _ db: Double) {
            let raw = UInt16(bitPattern: Int16((db * QxScale.volume).rounded()))
            out[index] = UInt8(raw & 0xFF)
            out[index + 1] = UInt8(raw >> 8)
        }
        put(0, volume)
        put(2, limit)
        put(6, trimLeft)
        put(8, trimRight)
        return out
    }

    static func statusNotification(percent: Int? = nil, volume: Double? = nil,
                                   muted: Bool = false, limit: Double = 0,
                                   trimLeft: Double = 0, trimRight: Double = 0,
                                   audio: [UInt8]? = nil) -> [UInt8] {
        var mask: UInt8 = 0
        var blocks: [UInt8] = []
        if let audio {
            mask |= QxStatusMask.audio
            blocks += audio
        }
        if let percent {
            mask |= QxStatusMask.power
            blocks += powerBlock(percent: percent)
        }
        if let volume {
            mask |= QxStatusMask.vol
            blocks += volumeBlock(volume: volume, limit: limit, trimLeft: trimLeft,
                                  trimRight: trimRight) + [muted ? 1 : 0]
        }
        return notification([0, QxNotifyMask.status, mask] + blocks)
    }

    static func presetChanged(group: UInt8, slot: Int) -> [UInt8] {
        notification([129, group, UInt8(slot)])
    }
}

@MainActor
final class DeviceRig {
    let controller: QudelixController
    let snapshotURL: URL

    private static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("qa-rig", isDirectory: true)
    }

    static func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    init(seed: EqSnapshotStore? = nil, file: URL? = nil) {
        try? FileManager.default.createDirectory(at: Self.directory,
                                                 withIntermediateDirectories: true)
        snapshotURL = file ?? Self.directory
            .appendingPathComponent("last-eq-\(UUID().uuidString).json")
        if let seed { EqSnapshotFile.save(seed, to: snapshotURL) }
        controller = QudelixController(eqSnapshotURL: snapshotURL)
        controller.debugInstallHandlers()
    }

    func restarted() -> DeviceRig { DeviceRig(file: snapshotURL) }

    static func snapshot(_ identity: String?, group: QxEqGroup = .user,
                         bands: [QxEqBandValue], preGain: Double = 0,
                         enabled: Bool = true, slot: Int? = nil) -> EqSnapshotStore {
        var store = EqSnapshotStore()
        store.set(EqSnapshot(groupRaw: group.rawValue, bands: bands, preGain: preGain,
                             enabled: enabled, deviceIdentity: identity,
                             activePreset: slot))
        return store
    }

    static func curve(_ group: QxEqGroup = .user, gain: Double = 0,
                      first: Double? = nil) -> [QxEqBandValue] {
        group.defaultFreqs.enumerated().map { index, hz in
            QxEqBandValue(filter: .peak, freq: min(hz, 20000),
                          gain: index == 0 ? (first ?? gain) : gain, q: 1.0)
        }
    }

    func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    func ingest(_ packets: [[UInt8]]) {
        for p in packets { controller.debugIngest(p) }
    }

    func attachUSB(_ name: String = "Qudelix-5K USB DAC 96KHz") async {
        controller.debugFireUSBAttached(name)
        await settle()
    }

    func detachUSB() async {
        controller.debugFireUSBDetached()
        await settle()
    }

    func attachBluetooth() async {
        controller.debugFireBluetoothConnected()
        await settle()
    }

    func detachBluetooth() async {
        controller.debugFireBluetoothDisconnected()
        await settle()
    }

    func connect(_ name: String = "Qudelix-5K USB DAC 96KHz",
                 group: QxEqGroup = .user, bands: [QxEqBandValue]? = nil,
                 preGain: Double = 0, slot: Int = 255, enabled: Bool = true) async {
        await attachUSB(name)
        handshake(group: group, bands: bands, preGain: preGain, slot: slot, enabled: enabled)
    }

    func connectBluetooth(group: QxEqGroup = .user, bands: [QxEqBandValue]? = nil,
                          preGain: Double = 0, slot: Int = 255) async {
        await attachBluetooth()
        handshake(group: group, bands: bands, preGain: preGain, slot: slot, enabled: true)
    }

    func handshake(group: QxEqGroup, bands: [QxEqBandValue]?, preGain: Double,
                   slot: Int, enabled: Bool) {
        controller.debugIngest(Wire.initData())
        controller.debugIngest(Wire.deviceConfig(eqMode: group == .b20 ? 1 : 0,
                                                 group: group.rawValue, slot: slot,
                                                 enabled: enabled))
        ingest(Wire.presetPackets(group: group, bands: bands ?? Self.curve(group),
                                  preGain: preGain))
    }

    var savedSnapshots: EqSnapshotStore { EqSnapshotFile.load(from: snapshotURL) }
}
