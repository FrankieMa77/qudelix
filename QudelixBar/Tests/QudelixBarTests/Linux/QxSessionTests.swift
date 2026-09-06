import XCTest
@testable import QudelixBar

final class FakeLink: QxLink {
    let kind: QxLinkKind
    private(set) var isConnected = false
    var onConnected: ((String) -> Void)?
    var onDisconnected: (() -> Void)?
    var onLinkUnusable: (() -> Void)?
    var onPacket: (([UInt8]) -> Void)?

    private let lock = NSLock()
    private var sends: [(cmd: QxCmd, data: [UInt8])] = []

    var onSend: ((QxCmd, [UInt8]) -> Void)?
    var autoConnectOnStart = false
    var started = false
    var stopped = false

    init(kind: QxLinkKind = .usb) {
        self.kind = kind
    }

    func start() {
        started = true
        if autoConnectOnStart { bringUp() }
    }

    func stop() { stopped = true }

    func send(_ cmd: QxCmd, _ data: [UInt8]) {
        lock.lock()
        sends.append((cmd, data))
        lock.unlock()
        onSend?(cmd, data)
    }

    var sent: [(cmd: QxCmd, data: [UInt8])] {
        lock.lock()
        defer { lock.unlock() }
        return sends
    }

    var sentCommands: [QxCmd] { sent.map(\.cmd) }

    func payload(for cmd: QxCmd) -> [UInt8]? { sent.first { $0.cmd == cmd }?.data }

    func payloads(for cmd: QxCmd) -> [[UInt8]] { sent.filter { $0.cmd == cmd }.map(\.data) }

    func clearSends() {
        lock.lock()
        sends.removeAll()
        lock.unlock()
    }

    func bringUp(_ name: String = "Qudelix 5K") {
        isConnected = true
        onConnected?(name)
    }

    func drop() {
        isConnected = false
        onDisconnected?()
    }

    func deliver(_ cmd: QxCmd, _ data: [UInt8]) {
        deliverRaw(QxFixtures.report(cmd, data))
    }

    func deliverRaw(_ bytes: [UInt8]) {
        onPacket?(bytes)
    }
}

enum QxFixtures {
    static func report(_ cmd: QxCmd, _ data: [UInt8]) -> [UInt8] {
        [UInt8(clamping: data.count + 2),
         UInt8(cmd.rawValue >> 8),
         UInt8(cmd.rawValue & 0xFF)] + data
    }

    static let initData: [UInt8] = {
        var bits = [UInt8](repeating: 0, count: 8)
        bits[0] = UInt8(3 | (2 << 6))
        bits[1] = UInt8((2 >> 2) | (7 << 4))
        return [0x00, 0x01, 0x03] + bits
    }()

    static let audioBlock: [UInt8] = [0xC2, 0x42, 0x04, 0x00]

    static var powerBlock: [UInt8] {
        var block = [UInt8](repeating: 0, count: 8)
        var value: UInt64 = 0
        value |= 1 << 0
        value |= 1 << 1
        value |= UInt64(77) << 9
        value |= UInt64(3900) << 16
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
                          muted: Bool = false) -> [UInt8] {
        [QxStatusMask.audio | QxStatusMask.power | QxStatusMask.vol]
            + audioBlock + powerBlock
            + volumeBlock(db: volumeDb, limit: limit) + [muted ? 1 : 0]
    }

    static func eqConfig(presetIndex: Int, enabled: Bool, nameMask: Int) -> [UInt8] {
        var groupCfg = [UInt8](repeating: 0, count: 4)
        groupCfg[1] = UInt8(presetIndex)
        groupCfg[2] = enabled ? 1 : 0
        var names = [UInt8](repeating: 0, count: 4)
        names[0] = UInt8(nameMask & 0xFF)
        names[1] = UInt8((nameMask >> 8) & 0xFF)
        names[2] = UInt8((nameMask >> 16) & 0x0F)
        return [QxConfigMask.eq, 0] + groupCfg + names
    }

    static func dacConfig(filter: Int) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 4)
        var value: UInt32 = 0
        value |= UInt32(filter & 0x0F) << 18
        for i in 0..<4 { block[i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) }
        return [QxConfigMask.dac] + block
    }

    static func presetName(index: Int, name: String) -> [UInt8] {
        let bytes = Array(name.utf8)
        return [0, UInt8(index), UInt8(3 + bytes.count)] + bytes
    }

    static func presetSegments(preGain: Double, bands: [QxEqBandValue]) -> [[UInt8]] {
        var bits = [Bool](repeating: false, count: 88 * 8)
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
        for _ in 0..<2 {
            for band in bands { write(band.freq, 16) }
        }
        for band in bands {
            write(Int(band.filter.rawValue), 4)
            write(Int(UInt16(bitPattern: Int16(clamping:
                Int((band.gain * QxScale.gain).rounded())))) & 0x3FF, 10)
            write(Int((band.q * QxScale.q).rounded()), 14)
            write(0, 4)
        }
        var buffer = [UInt8](repeating: 0, count: 88)
        for (index, bit) in bits.enumerated() where bit {
            buffer[index >> 3] |= 1 << UInt8(index & 7)
        }
        var segments: [[UInt8]] = []
        let chunkSize = 44
        let total = (buffer.count + chunkSize - 1) / chunkSize
        for index in 0..<total {
            let start = index * chunkSize
            let end = min(start + chunkSize, buffer.count)
            segments.append([0, UInt8((total - 1) << 4 | index), 0, 0,
                             UInt8(start >> 8), UInt8(start & 0xFF)]
                            + Array(buffer[start..<end]))
        }
        return segments
    }

    static let tenBands: [QxEqBandValue] = QxEqGroup.user.defaultFreqs.map {
        QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1.0)
    }
}

extension QxFixtures {
    static func answeringLink(volumeDb: Double = -12,
                              presetIndex: Int = 2,
                              nameMask: Int = 0,
                              preGain: Double = -3,
                              bands: [QxEqBandValue] = QxFixtures.tenBands,
                              dacFilter: Int = 3) -> FakeLink {
        let link = FakeLink()
        link.onSend = { [weak link] cmd, data in
            guard let link else { return }
            switch cmd {
            case .reqInitData:
                link.deliver(.rspInitData, QxFixtures.initData)
            case .reqDevStatus:
                link.deliver(.rspDevStatus, QxFixtures.devStatus(volumeDb: volumeDb))
            case .reqDevConfig:
                if data.first == (QxConfigMask.sys2 | QxConfigMask.eq) {
                    link.deliver(.rspDevConfig,
                                 QxFixtures.eqConfig(presetIndex: presetIndex,
                                                     enabled: true,
                                                     nameMask: nameMask))
                } else {
                    link.deliver(.rspDevConfig, QxFixtures.dacConfig(filter: dacFilter))
                }
            case .reqEqPreset:
                for segment in QxFixtures.presetSegments(preGain: preGain, bands: bands) {
                    link.deliver(.rspEqPreset, segment)
                }
            case .reqEqPresetName:
                let index = Int(data.count > 1 ? data[1] : 0)
                link.deliver(.rspEqPresetName,
                             QxFixtures.presetName(index: index, name: "Slot \(index + 1)"))
            default:
                break
            }
        }
        return link
    }
}

final class QxSessionTests: XCTestCase {
    private func answeringLink(volumeDb: Double = -12,
                               presetIndex: Int = 2,
                               nameMask: Int = 0,
                               preGain: Double = -3,
                               bands: [QxEqBandValue] = QxFixtures.tenBands,
                               dacFilter: Int = 3) -> FakeLink {
        QxFixtures.answeringLink(volumeDb: volumeDb, presetIndex: presetIndex,
                                 nameMask: nameMask, preGain: preGain,
                                 bands: bands, dacFilter: dacFilter)
    }

    private func connected(_ link: FakeLink, timeout: TimeInterval = 2) async throws -> QxSession {
        let session = QxSession(link: link, timeout: timeout)
        async let connecting: Void = session.connect(timeout: timeout)
        link.bringUp()
        try await connecting
        return session
    }

    func testAllowedCommandsAreExactlyTheOnesTheControllerSends() {
        XCTAssertEqual(QxSession.allowed, [
            .reqInitData, .reqDevConfig, .reqDevStatus, .reqEqPreset, .reqEqPresetName,
            .setVolume, .setDacFilter, .setEqEnable, .setEqType, .setEqPreGain,
            .setEqBandParam, .saveEqPreset, .loadEqPreset, .setEqPresetName, .saveAll,
        ])
        for forbidden in [QxCmd.setEqMode, .setUsbFsMode, .sysReboot, .disconnect,
                          .setCharger, .setBatteryCare, .setLedMode, .setEqMute,
                          .playTestTone, .setUsbDacMode] {
            XCTAssertFalse(QxSession.allowed.contains(forbidden), "\(forbidden)")
        }
    }

    func testHandshakeSendsTheFiveRequestsInOrder() async throws {
        let link = answeringLink()
        let session = try await connected(link)
        defer { session.close() }
        XCTAssertEqual(Array(link.sentCommands.prefix(5)),
                       [.reqInitData, .reqDevConfig, .reqDevConfig,
                        .reqDevStatus, .reqEqPreset])
        let sent = link.sent
        XCTAssertEqual(sent[0].data, QxInit.requestPayload)
        XCTAssertEqual(sent[1].data, [QxConfigMask.sys | QxConfigMask.playTime
                                      | QxConfigMask.dac | QxConfigMask.mic
                                      | QxConfigMask.batt])
        XCTAssertEqual(sent[2].data, [0xC0])
        XCTAssertEqual(sent[3].data, [QxStatusMask.audio | QxStatusMask.power
                                      | QxStatusMask.conn | QxStatusMask.vol])
        XCTAssertEqual(sent[4].data, [QxEqGroup.user.requestMask])
    }

    func testConnectTimesOutWhenNothingAnswers() async throws {
        let link = FakeLink()
        let session = QxSession(link: link, timeout: 0.2)
        async let connecting: Void = session.connect(timeout: 0.3)
        link.bringUp()
        do {
            try await connecting
            XCTFail("connect should not have resolved")
        } catch let error as QxSessionError {
            guard case .timedOut = error else {
                return XCTFail("expected a timeout, got \(error)")
            }
        }
        session.close()
        XCTAssertTrue(link.stopped)
    }

    func testConnectTimesOutWhenTheLinkNeverComesUp() async {
        let link = FakeLink()
        let session = QxSession(link: link, timeout: 0.2)
        do {
            try await session.connect(timeout: 0.2)
            XCTFail("connect should not have resolved")
        } catch let error as QxSessionError {
            guard case .timedOut = error else {
                return XCTFail("expected a timeout, got \(error)")
            }
        } catch {
            XCTFail("expected a QxSessionError, got \(error)")
        }
        XCTAssertTrue(link.started)
        session.close()
    }

    func testDisconnectFailsPendingWaits() async throws {
        let link = FakeLink()
        link.onSend = { [weak link] cmd, _ in
            guard let link, cmd == .reqInitData else { return }
            link.deliver(.rspInitData, QxFixtures.initData)
        }
        let session = QxSession(link: link, timeout: 2)
        async let connecting: Void = session.connect(timeout: 2)
        link.bringUp()
        try await Task.sleep(nanoseconds: 100_000_000)
        link.drop()
        do {
            try await connecting
            XCTFail("connect should not have resolved")
        } catch let error as QxSessionError {
            XCTAssertEqual(error, .linkClosed)
        }
        session.close()
    }

    func testStatusDecodesInitDataAndDevStatus() async throws {
        let link = answeringLink(volumeDb: -18.5, presetIndex: 4, dacFilter: 5)
        let session = try await connected(link)
        defer { session.close() }
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.deviceId, QxDeviceModel.qudelix5K)
        XCTAssertEqual(snapshot.modelName, "Qudelix 5K")
        XCTAssertEqual(snapshot.firmware, "3.2.7")
        XCTAssertEqual(snapshot.batteryPercent, 77)
        XCTAssertEqual(snapshot.batteryMilliVolts, 3900)
        XCTAssertTrue(snapshot.chargerConnected)
        XCTAssertTrue(snapshot.charging)
        XCTAssertEqual(snapshot.volumeDb ?? 0, -18.5, accuracy: 0.02)
        XCTAssertEqual(snapshot.muted, false)
        XCTAssertEqual(snapshot.sampleRate, "48 kHz")
        XCTAssertEqual(snapshot.inputSource, "USB")
        XCTAssertEqual(snapshot.eqEnabled, true)
        XCTAssertEqual(snapshot.activePresetIndex, 4)
        XCTAssertEqual(snapshot.eqGroup, .user)
        XCTAssertEqual(snapshot.eqType, "PEQ")
        XCTAssertEqual(snapshot.dacFilterIndex, 5)
        XCTAssertEqual(snapshot.dacFilterName, QxStatusParser.dacFilters[5])
        XCTAssertEqual(snapshot.deviceIdentity, "usb:Qudelix 5K")
    }

    func testReadPresetDecodesTheAssembledBitstream() async throws {
        var bands = QxFixtures.tenBands
        bands[0] = QxEqBandValue(filter: .lowShelf, freq: 105, gain: 6.4, q: 0.7)
        bands[9] = QxEqBandValue(filter: .peak, freq: 8800, gain: -5.1, q: 1.42)
        let link = answeringLink(preGain: -6.1, bands: bands)
        let session = try await connected(link)
        defer { session.close() }
        let preset = try await session.readPreset()
        XCTAssertEqual(preset.preGain, -6.1, accuracy: 0.05)
        XCTAssertEqual(preset.bands.count, 10)
        XCTAssertEqual(preset.bands[0].filter, .lowShelf)
        XCTAssertEqual(preset.bands[0].freq, 105)
        XCTAssertEqual(preset.bands[0].gain, 6.4, accuracy: 0.05)
        XCTAssertEqual(preset.bands[0].q, 0.7, accuracy: 0.005)
        XCTAssertEqual(preset.bands[9].gain, -5.1, accuracy: 0.05)
        XCTAssertEqual(preset.bands[9].q, 1.42, accuracy: 0.005)
    }

    func testApplyParametricSendsEnableTypePreGainAndOneWritePerBand() async throws {
        let link = answeringLink()
        let session = try await connected(link)
        defer { session.close() }
        link.clearSends()

        var file = ParametricEQFile()
        file.preamp = -40
        file.bands = [
            QxEqBandValue(filter: .peak, freq: 5, gain: 99, q: 50),
            QxEqBandValue(filter: .highShelf, freq: 90000, gain: -99, q: 0.001),
        ]
        _ = try await session.applyParametric(file)

        let commands = link.sentCommands
        XCTAssertEqual(commands[0], .setEqEnable)
        XCTAssertEqual(commands[1], .setEqType)
        XCTAssertEqual(commands[2], .setEqPreGain)
        XCTAssertEqual(commands[3], .setEqPreGain)
        XCTAssertEqual(link.payloads(for: .setEqBandParam).count, 10)
        XCTAssertEqual(commands.filter { $0 == .setEqPreGain }.count, 2)
        for command in commands {
            XCTAssertTrue(QxSession.allowed.contains(command), "\(command)")
        }

        XCTAssertEqual(link.payload(for: .setEqEnable), [0, 1])
        XCTAssertEqual(link.payload(for: .setEqType), [0, 1])
        let preGains = link.payloads(for: .setEqPreGain)
        XCTAssertEqual(preGains[0], [0, 1, 0] + QxPacket.int16BE(-120))
        XCTAssertEqual(preGains[1], [0, 2, 0] + QxPacket.int16BE(-120))

        let bandWrites = link.payloads(for: .setEqBandParam)
        XCTAssertEqual(Set(bandWrites.map { $0[2] }).count, 10)
        XCTAssertEqual(bandWrites[0],
                       [0, 1, 0, QxFilter.peak.rawValue]
                        + QxPacket.int16BE(20)
                        + QxPacket.int16BE(120)
                        + QxPacket.int16BE(Int((10.0 * QxScale.q).rounded())))
        XCTAssertEqual(bandWrites[1],
                       [0, 1, 1, QxFilter.highShelf.rawValue]
                        + QxPacket.int16BE(20000)
                        + QxPacket.int16BE(-120)
                        + QxPacket.int16BE(Int((0.1 * QxScale.q).rounded())))
        for write in bandWrites.dropFirst(2) {
            XCTAssertEqual(write[3], QxFilter.bypass.rawValue)
        }
    }

    func testDisallowedCommandThrowsBeforeReachingTheLink() async throws {
        let link = answeringLink()
        let session = try await connected(link)
        defer { session.close() }
        link.clearSends()
        for forbidden in [QxCmd.setEqMode, .setUsbFsMode, .sysReboot, .disconnect,
                          .setCharger, .setBatteryCare] {
            do {
                try await session.send(forbidden, [0])
                XCTFail("\(forbidden) should have been refused")
            } catch let error as QxSessionError {
                XCTAssertEqual(error, .disallowedCommand(forbidden))
            }
        }
        XCTAssertTrue(link.sent.isEmpty)
    }

    func testVolumeIsClampedToTheDeviceWindowAndBuiltLikeTheController() async throws {
        let link = answeringLink()
        let session = try await connected(link)
        defer { session.close() }
        link.clearSends()
        try await session.setVolume(db: 40)
        XCTAssertEqual(link.payload(for: .setVolume),
                       [QxVolumeParam.sink.rawValue] + QxPacket.int16BE(0))
        link.clearSends()
        try await session.setVolume(db: -400)
        XCTAssertEqual(link.payload(for: .setVolume),
                       [QxVolumeParam.sink.rawValue] + QxPacket.int16BE(-3600))
        link.clearSends()
        do {
            try await session.setVolume(db: .nan)
            XCTFail("a non-finite volume should have been refused")
        } catch let error as QxSessionError {
            guard case .rejectedValue = error else {
                return XCTFail("expected a rejection, got \(error)")
            }
        }
        XCTAssertTrue(link.sent.isEmpty)
    }

    func testMuteAndDacFilterPayloads() async throws {
        let link = answeringLink()
        let session = try await connected(link)
        defer { session.close() }
        link.clearSends()
        try await session.setMute(true)
        XCTAssertEqual(link.payload(for: .setVolume), [QxVolumeParam.mute.rawValue, 0, 1])
        link.clearSends()
        try await session.setDacFilter(index: 6)
        XCTAssertEqual(link.payload(for: .setDacFilter), [6])
        link.clearSends()
        do {
            try await session.setDacFilter(index: 99)
            XCTFail("an undefined DAC filter should have been refused")
        } catch let error as QxSessionError {
            guard case .rejectedValue = error else {
                return XCTFail("expected a rejection, got \(error)")
            }
        }
        XCTAssertTrue(link.sent.isEmpty)
    }

    func testEqEnableSaveLoadAndSaveAllPayloads() async throws {
        let link = answeringLink()
        let session = try await connected(link)
        defer { session.close() }
        link.clearSends()
        try await session.setEqEnabled(false)
        XCTAssertEqual(link.payload(for: .setEqEnable), [0, 0])
        link.clearSends()
        try await session.savePreset(index: 7)
        XCTAssertEqual(link.payload(for: .saveEqPreset), [7])
        link.clearSends()
        _ = try await session.loadPreset(index: 11)
        XCTAssertEqual(link.payload(for: .loadEqPreset), [11])
        XCTAssertEqual(link.payload(for: .reqEqPreset), [QxEqGroup.user.requestMask])
        link.clearSends()
        try await session.saveAll()
        XCTAssertEqual(link.payload(for: .saveAll), [])
    }

    func testPresetSlotOutsideTheDeviceIsRefused() async throws {
        let link = answeringLink()
        let session = try await connected(link)
        defer { session.close() }
        link.clearSends()
        for slot in [-1, QudelixController.presetCount] {
            do {
                try await session.savePreset(index: slot)
                XCTFail("slot \(slot) should have been refused")
            } catch let error as QxSessionError {
                guard case .rejectedValue = error else {
                    return XCTFail("expected a rejection, got \(error)")
                }
            }
        }
        XCTAssertTrue(link.sent.isEmpty)
    }

    func testRenamePresetSendsTheOffsetPrefixedPayload() async throws {
        let link = answeringLink()
        let session = try await connected(link)
        defer { session.close() }
        link.clearSends()
        try await session.renamePreset(index: 3, name: "Bass\nLift")
        XCTAssertEqual(link.payload(for: .setEqPresetName),
                       [0, 3, UInt8(3 + "BassLift".utf8.count)] + Array("BassLift".utf8))
    }

    func testPresetNamesAreReadForEverySlotTheMaskClaims() async throws {
        let link = answeringLink(nameMask: 0b1001)
        let session = try await connected(link)
        defer { session.close() }
        link.clearSends()
        let names = try await session.namedPresets()
        XCTAssertEqual(names[0], "Slot 1")
        XCTAssertEqual(names[3], "Slot 4")
        XCTAssertNil(names[1])
        XCTAssertEqual(link.payloads(for: .reqEqPresetName), [[0, 0], [0, 3]])
    }

    func testNotificationStreamCarriesDeviceLines() async throws {
        let link = answeringLink()
        let session = try await connected(link)
        defer { session.close() }
        let stream = session.notifications()
        var iterator = stream.makeAsyncIterator()
        try await Task.sleep(nanoseconds: 50_000_000)
        link.deliver(.notification, [129, 0, 6])
        let line = await iterator.next()
        XCTAssertEqual(line, "preset 7 is now active")
    }

    func testTwentyBandModeRetargetsTheGroup() async throws {
        let link = answeringLink()
        let session = try await connected(link)
        defer { session.close() }
        var sysBlock = [UInt8](repeating: 0, count: 12)
        sysBlock[4] = 1 << 4
        link.deliver(.rspDevConfig, [QxConfigMask.sys] + sysBlock)
        try await Task.sleep(nanoseconds: 50_000_000)
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.eqGroup, .b20)
    }
}
