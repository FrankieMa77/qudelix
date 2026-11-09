import XCTest
@testable import QudelixBar

final class EqTestDevice {
    let link = FakeLink()
    var group: QxEqGroup
    var bands: [QxEqBandValue]
    var preGain: Double
    var slotIndex: Int
    var enabled = true
    var graphic = false
    var names: [Int: String]
    var slots: [Int: (preGain: Double, bands: [QxEqBandValue])] = [:]

    init(group: QxEqGroup = .user, bands: [QxEqBandValue]? = nil, preGain: Double = -3,
         slot: Int = 2, names: [Int: String] = [:], graphic: Bool = false) {
        self.group = group
        self.bands = bands ?? group.defaultFreqs.map {
            QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1)
        }
        self.preGain = preGain
        self.slotIndex = slot
        self.names = names
        self.graphic = graphic
        link.autoConnectOnStart = true
        link.onSend = { [weak self] cmd, data in self?.handle(cmd, data) }
    }

    private func handle(_ cmd: QxCmd, _ data: [UInt8]) {
        switch cmd {
        case .reqInitData:
            link.deliver(.rspInitData, QxFixtures.initData)
        case .reqDevStatus:
            link.deliver(.rspDevStatus, QxFixtures.devStatus(volumeDb: -12))
        case .reqDevConfig:
            if data.first == (QxConfigMask.sys2 | QxConfigMask.eq) {
                var mask = 0
                for index in names.keys { mask |= 1 << index }
                link.deliver(.rspDevConfig,
                             QxDemoFrames.eqConfig(presetIndex: slotIndex, enabled: enabled,
                                                   nameMask: mask, group: group))
            } else {
                link.deliver(.rspDevConfig,
                             QxDemoFrames.sysAndDacConfig(filter: 3,
                                                          eqMode: group == .b20 ? 1 : 0))
            }
        case .reqEqPreset:
            var segments = QxDemoFrames.presetSegments(preGain: preGain, bands: bands, group: group)
            if graphic { segments[0][6] &= ~UInt8(1) }
            for segment in segments { link.deliver(.rspEqPreset, segment) }
        case .reqEqPresetName:
            let index = Int(data.count > 1 ? data[1] : 0)
            link.deliver(.rspEqPresetName,
                         QxDemoFrames.presetName(index: index, name: names[index] ?? "",
                                                 group: group))
        case .setEqBandParam:
            let index = Int(data[2])
            func word(_ at: Int) -> Int {
                Int(Int16(bitPattern: UInt16(data[at]) << 8 | UInt16(data[at + 1])))
            }
            bands[index] = QxEqBandValue(filter: QxFilter(rawValue: data[3]) ?? .bypass,
                                         freq: word(4), gain: Double(word(6)) / QxScale.gain,
                                         q: Double(word(8)) / QxScale.q)
        case .setEqPreGain:
            preGain = Double(Int16(bitPattern: UInt16(data[3]) << 8 | UInt16(data[4]))) / QxScale.gain
        case .setEqEnable:
            enabled = data.last != 0
        case .loadEqPreset:
            let index = Int(data[0])
            slotIndex = index
            if let slot = slots[index] {
                preGain = slot.preGain
                bands = slot.bands
            }
        case .saveEqPreset:
            slots[Int(data[0])] = (preGain, bands)
        case .setEqPresetName:
            let index = Int(data[1])
            let end = min(Int(data[2]), data.count)
            let text = String(bytes: end > 3 ? Array(data[3..<end]) : [], encoding: .utf8) ?? ""
            names[index] = text.isEmpty ? nil : text
        default:
            break
        }
    }

    func notifyPreset(slot: Int) {
        slotIndex = slot
        link.deliver(.notification, [129, group.rawValue, UInt8(slot)])
    }
}

enum EqTestSupport {
    static func shaped(_ group: QxEqGroup = .user) -> [QxEqBandValue] {
        group.defaultFreqs.enumerated().map { index, freq in
            QxEqBandValue(filter: .peak, freq: freq, gain: Double(index % 5) - 2, q: 1 + Double(index % 8) / 8)
        }
    }
}
