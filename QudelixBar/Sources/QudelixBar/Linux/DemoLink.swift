import Foundation

package final class DemoLink: QxLink {
    package let kind: QxLinkKind = .usb
    package var isConnected: Bool { lock.withLock { connected } }
    package var onConnected: ((String) -> Void)?
    package var onDisconnected: (() -> Void)?
    package var onLinkUnusable: ((String) -> Void)?
    package var onPacket: (([UInt8]) -> Void)?

    static let deviceName = "Qudelix 5K"
    static let presetNames: [Int: String] = [
        0: "Flat", 1: "Warm", 2: "Bass boost", 3: "Vocal presence",
        4: "Late night", 5: "Harman target", 8: "Studio",
    ]
    static let bands: [QxEqBandValue] = {
        let shape: [(QxFilter, Double, Double)] = [
            (.lowShelf, 3.5, 0.7), (.peak, 2.8, 1.1), (.peak, 1.6, 1.0), (.peak, 0.4, 1.2),
            (.peak, -0.8, 1.4), (.peak, -1.6, 1.0), (.peak, -2.2, 0.9), (.peak, -1.4, 1.1),
            (.peak, -0.5, 1.3), (.peak, 0.6, 1.0), (.peak, 1.2, 0.9), (.peak, 1.8, 1.2),
            (.peak, 2.4, 1.5), (.peak, 1.9, 1.3), (.peak, 0.8, 1.1), (.peak, -0.6, 1.0),
            (.peak, -1.8, 1.6), (.peak, -2.6, 1.4), (.peak, -1.2, 1.0), (.highShelf, -2.0, 0.7),
        ]
        return zip(QxEqGroup.b20.defaultFreqs, shape).map {
            QxEqBandValue(filter: $1.0, freq: $0, gain: $1.1, q: $1.2)
        }
    }()
    static let preGain = -3.5

    static func initialSlots() -> [Int: (preGain: Double, bands: [QxEqBandValue])] {
        var slots: [Int: (preGain: Double, bands: [QxEqBandValue])] = [:]
        for index in presetNames.keys {
            let scales: [Int: Double] = [0: 0, 1: 0.6, 2: 1.4, 3: 0.9, 4: 0.4, 5: 1, 8: 0.7]
            let scale = scales[index] ?? 1
            let shaped = bands.map { band -> QxEqBandValue in
                var copy = band
                copy.gain = max(-12, min(12, (band.gain * scale * 10).rounded() / 10))
                return copy
            }
            slots[index] = (index == 5 ? preGain : -1.5, index == 5 ? bands : shaped)
        }
        return slots
    }

    private let lock = NSLock()
    private var connected = false
    private var volumeDb = -18.0
    private var muted = false
    private var dacFilter = 3
    private var eqEnabled = true
    private var presetIndex = 5
    private var liveBands = DemoLink.bands
    private var livePreGain = DemoLink.preGain
    private var names = DemoLink.presetNames
    private var slots: [Int: (preGain: Double, bands: [QxEqBandValue])] = DemoLink.initialSlots()

    package enum Power: String {
        case battery
        case charging
        case idle
    }

    private let power: Power

    package init(power: Power = .battery) {
        self.power = power
    }

    package func start() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
            lock.withLock { connected = true }
            onConnected?(Self.deviceName)
        }
    }

    package func stop() {
        lock.withLock { connected = false }
    }

    package func send(_ cmd: QxCmd, _ data: [UInt8]) {
        switch cmd {
        case .reqInitData:
            reply(.rspInitData, QxDemoFrames.initData())
        case .reqDevStatus:
            let state = lock.withLock { (volumeDb, muted) }
            reply(.rspDevStatus,
                  QxDemoFrames.devStatus(
                    volumeDb: state.0, limit: 0, muted: state.1,
                    power: QxDemoFrames.powerBlock(percent: 76, milliVolts: 3870,
                                                   chargerConnected: power != .battery,
                                                   charging: power == .charging)))
        case .reqDevConfig:
            if data.first == (QxConfigMask.sys2 | QxConfigMask.eq) {
                let enabled = lock.withLock { eqEnabled }
                var mask = 0
                let current = lock.withLock { (names, presetIndex) }
                for index in current.0.keys { mask |= 1 << index }
                reply(.rspDevConfig,
                      QxDemoFrames.eqConfig(presetIndex: current.1, enabled: enabled,
                                            nameMask: mask, group: .b20))
            } else {
                let filter = lock.withLock { dacFilter }
                reply(.rspDevConfig, QxDemoFrames.sysAndDacConfig(filter: filter, eqMode: 1))
            }
        case .reqEqPreset:
            let live = lock.withLock { (livePreGain, liveBands) }
            for segment in QxDemoFrames.presetSegments(preGain: live.0,
                                                       bands: live.1, group: .b20) {
                reply(.rspEqPreset, segment)
            }
        case .reqEqPresetName:
            let index = Int(data.count > 1 ? data[1] : 0)
            reply(.rspEqPresetName,
                  QxDemoFrames.presetName(index: index,
                                          name: lock.withLock { names[index] } ?? "",
                                          group: .b20))
        case .setVolume:
            apply(volume: data)
        case .setDacFilter:
            if let index = data.last { lock.withLock { dacFilter = Int(index) } }
        case .setEqEnable:
            if let flag = data.last { lock.withLock { eqEnabled = flag != 0 } }
        case .setEqBandParam:
            apply(band: data)
        case .setEqPreGain:
            apply(preGain: data)
        case .loadEqPreset:
            apply(load: data)
        case .saveEqPreset:
            if let index = data.first {
                lock.withLock { slots[Int(index)] = (livePreGain, liveBands) }
            }
        case .setEqPresetName:
            apply(name: data)
        default:
            break
        }
    }

    private func apply(band data: [UInt8]) {
        guard data.count >= 10 else { return }
        func word(_ at: Int) -> Int { Int(Int16(bitPattern: UInt16(data[at]) << 8 | UInt16(data[at + 1]))) }
        let index = Int(data[2])
        lock.withLock {
            guard liveBands.indices.contains(index) else { return }
            liveBands[index] = QxEqBandValue(filter: QxFilter(rawValue: data[3]) ?? .bypass,
                                             freq: word(4),
                                             gain: Double(word(6)) / QxScale.gain,
                                             q: Double(word(8)) / QxScale.q)
        }
    }

    private func apply(preGain data: [UInt8]) {
        guard data.count >= 5 else { return }
        let raw = Int16(bitPattern: UInt16(data[3]) << 8 | UInt16(data[4]))
        lock.withLock { livePreGain = Double(raw) / QxScale.gain }
    }

    private func apply(load data: [UInt8]) {
        guard let index = data.first.map(Int.init) else { return }
        lock.withLock {
            presetIndex = index
            if let slot = slots[index] {
                livePreGain = slot.preGain
                liveBands = slot.bands
            }
        }
    }

    private func apply(name data: [UInt8]) {
        guard data.count >= 3 else { return }
        let index = Int(data[1])
        let end = min(Int(data[2]), data.count)
        let bytes = end > 3 ? Array(data[3..<end].prefix { $0 != 0 }) : []
        let text = String(bytes: bytes, encoding: .utf8) ?? ""
        lock.withLock { names[index] = text.isEmpty ? nil : text }
    }

    private func apply(volume data: [UInt8]) {
        guard let param = data.first else { return }
        if param == QxVolumeParam.mute.rawValue, data.count >= 3 {
            lock.withLock { muted = data[2] != 0 }
        } else if param == QxVolumeParam.sink.rawValue, data.count >= 3 {
            let raw = Int16(bitPattern: UInt16(data[1]) << 8 | UInt16(data[2]))
            lock.withLock { volumeDb = Double(raw) / QxScale.volume }
        }
    }

    private func reply(_ cmd: QxCmd, _ data: [UInt8]) {
        onPacket?(QxDemoFrames.report(cmd, data))
    }
}

@MainActor
package extension AppModel {
    package static func demo(power: DemoLink.Power = .battery, clock: AppClock = SystemClock()) -> AppModel {
        let model = AppModel(makeLinks: { [DemoLink(power: power)] },
                             acquireLock: { QxInstanceLock.acquire(at: nil) },
                             probeDevice: { AppDeviceProbe(present: true) },
                             batteryStore: .demo,
                             clock: clock)
        model.libraryEnvironment = .demo()
        return model
    }

    package static func noDevice(clock: AppClock = SystemClock()) -> AppModel {
        let model = AppModel(makeLinks: { makeLinks(preferred: nil) },
                             acquireLock: { QxInstanceLock.acquire(at: nil) },
                             probeDevice: { AppDeviceProbe(present: false) },
                             clock: clock)
        model.libraryEnvironment = .demo()
        return model
    }
}
