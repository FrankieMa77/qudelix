import Foundation

enum QxDemoFrames {
    static func report(_ cmd: QxCmd, _ data: [UInt8]) -> [UInt8] {
        [UInt8(clamping: data.count + 2),
         UInt8(cmd.rawValue >> 8),
         UInt8(cmd.rawValue & 0xFF)] + data
    }

    static func initData(major: Int = 3, minor: Int = 2, revision: Int = 7) -> [UInt8] {
        var bits = [UInt8](repeating: 0, count: 8)
        bits[0] = UInt8(major | ((minor & 3) << 6))
        bits[1] = UInt8((minor >> 2) | (revision << 4))
        return [0x00, 0x01, 0x03] + bits
    }

    static let audioBlock: [UInt8] = [0xC2, 0x42, 0x04, 0x00]

    static func powerBlock(percent: Int = 77, milliVolts: Int = 3900,
                           chargerConnected: Bool = true,
                           charging: Bool = true) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 8)
        var value: UInt64 = 0
        if chargerConnected { value |= 1 << 0 }
        if charging { value |= 1 << 1 }
        value |= UInt64(percent) << 9
        value |= UInt64(milliVolts) << 16
        for i in 0..<8 { block[i] = UInt8((value >> (8 * UInt64(i))) & 0xFF) }
        return block
    }

    static func volumeBlock(db: Double, limit: Double) -> [UInt8] {
        func le(_ v: Double) -> [UInt8] {
            let raw = UInt16(bitPattern: Int16(clamping: Int((v * QxScale.volume).rounded())))
            return [UInt8(raw & 0xFF), UInt8(raw >> 8)]
        }
        return le(db) + le(limit) + [0, 0] + le(0) + le(0) + [0, 0, 0, 0, 0, 0]
    }

    static func devStatus(volumeDb: Double = -12, limit: Double = 0,
                          muted: Bool = false, power: [UInt8]? = nil) -> [UInt8] {
        [QxStatusMask.audio | QxStatusMask.power | QxStatusMask.vol]
            + audioBlock + (power ?? powerBlock())
            + volumeBlock(db: volumeDb, limit: limit) + [muted ? 1 : 0]
    }

    static func eqConfig(presetIndex: Int, enabled: Bool, nameMask: Int,
                         group: QxEqGroup = .user) -> [UInt8] {
        var groupCfg = [UInt8](repeating: 0, count: 4)
        groupCfg[1] = UInt8(presetIndex)
        groupCfg[2] = enabled ? 1 : 0
        var names = [UInt8](repeating: 0, count: 4)
        names[0] = UInt8(nameMask & 0xFF)
        names[1] = UInt8((nameMask >> 8) & 0xFF)
        names[2] = UInt8((nameMask >> 16) & 0x0F)
        return [QxConfigMask.eq, group.rawValue] + groupCfg + names
    }

    static func dacConfig(filter: Int) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 4)
        var value: UInt32 = 0
        value |= UInt32(filter & 0x0F) << 18
        for i in 0..<4 { block[i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) }
        return [QxConfigMask.dac] + block
    }

    static func sysAndDacConfig(filter: Int, eqMode: Int) -> [UInt8] {
        var sys = [UInt8](repeating: 0, count: 12)
        let modeBit = 4 + 1 + 1 + 30
        sys[modeBit >> 3] |= UInt8(eqMode << (modeBit & 7))
        return [QxConfigMask.sys | QxConfigMask.dac] + sys + Array(dacConfig(filter: filter).dropFirst())
    }

    static func presetName(index: Int, name: String, group: QxEqGroup = .user) -> [UInt8] {
        let bytes = Array(name.utf8)
        return [group.rawValue, UInt8(index), UInt8(3 + bytes.count)] + bytes
    }

    static func presetSegments(preGain: Double, bands: [QxEqBandValue],
                               group: QxEqGroup = .user) -> [[UInt8]] {
        var bits = [Bool](repeating: false, count: 128 * 8)
        var cursor = 0
        func write(_ value: Int, _ width: Int) {
            for i in 0..<width {
                if cursor + i < bits.count { bits[cursor + i] = (value >> i) & 1 == 1 }
            }
            cursor += width
        }
        write(1, 1)
        write(0, 14)
        write(0, 11)
        write(0, 6)
        let scaledPreGain = Int((preGain * QxScale.gain).rounded())
        write(Int(UInt16(bitPattern: Int16(clamping: scaledPreGain))), 16)
        write(Int(UInt16(bitPattern: Int16(clamping: scaledPreGain))), 16)
        for _ in 0..<group.freqChannels {
            for band in bands { write(band.freq, 16) }
        }
        for band in bands {
            write(Int(band.filter.rawValue), 4)
            write(Int(UInt16(bitPattern: Int16(clamping:
                Int((band.gain * QxScale.gain).rounded())))) & 0x3FF, 10)
            write(Int((band.q * QxScale.q).rounded()), 14)
            write(0, 4)
        }
        var buffer = [UInt8](repeating: 0, count: group.presetBytes)
        for (index, bit) in bits.enumerated() where bit && (index >> 3) < buffer.count {
            buffer[index >> 3] |= 1 << UInt8(index & 7)
        }
        var segments: [[UInt8]] = []
        let chunkSize = 44
        let total = (buffer.count + chunkSize - 1) / chunkSize
        for index in 0..<total {
            let start = index * chunkSize
            let end = min(start + chunkSize, buffer.count)
            segments.append([group.rawValue, UInt8((total - 1) << 4 | index), 0, 0,
                             UInt8(start >> 8), UInt8(start & 0xFF)]
                            + Array(buffer[start..<end]))
        }
        return segments
    }
}
