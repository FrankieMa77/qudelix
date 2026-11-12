import XCTest
@testable import QudelixBar

final class FakeLink: QxLink {
    let kind: QxLinkKind
    private(set) var isConnected = false
    var onConnected: ((String) -> Void)?
    var onDisconnected: (() -> Void)?
    var onLinkUnusable: ((String) -> Void)?
    var onLinkBusy: ((String) -> Void)?
    var busyText: String?
    var onPacket: (([UInt8]) -> Void)?

    private let lock = NSLock()
    private var sends: [(cmd: QxCmd, data: [UInt8])] = []

    var onSend: ((QxCmd, [UInt8]) -> Void)?
    var autoConnectOnStart = false
    var started = false
    var stopped = false
    var keepsArmed = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var recycles = 0
    var attachedName: String? { isConnected ? "Qudelix 5K" : nil }

    init(kind: QxLinkKind = .usb) {
        self.kind = kind
    }

    func recycle() {
        recycles += 1
        isConnected = false
    }

    func start() {
        started = true
        startCount += 1
        if let busyText {
            onLinkBusy?(busyText)
            return
        }
        if autoConnectOnStart { bringUp() }
    }

    var failureReason: String?
    var failureNeedsAttention = false
    private(set) var stopWaits: [TimeInterval] = []

    func stop() {
        stopped = true
        stopCount += 1
    }

    func stopAndWait(timeout: TimeInterval) {
        stopWaits.append(timeout)
        stopped = true
        stopCount += 1
    }

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

    func declareUnusable(_ reason: String) {
        isConnected = false
        onLinkUnusable?(reason)
    }

    func deliver(_ cmd: QxCmd, _ data: [UInt8]) {
        deliverRaw(QxFixtures.report(cmd, data))
    }

    func deliverRaw(_ bytes: [UInt8]) {
        onPacket?(bytes)
    }
}

final class StdIOCapture {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }

    var text: String { all.joined(separator: "\n") }

    var object: [String: Any] {
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else { return [:] }
        return object
    }
}

enum QxFixtures {
    static func report(_ cmd: QxCmd, _ data: [UInt8]) -> [UInt8] {
        QxDemoFrames.report(cmd, data)
    }

    static let initData: [UInt8] = QxDemoFrames.initData()

    static let audioBlock: [UInt8] = QxDemoFrames.audioBlock

    static var powerBlock: [UInt8] { QxDemoFrames.powerBlock() }

    static func volumeBlock(db: Double, limit: Double) -> [UInt8] {
        QxDemoFrames.volumeBlock(db: db, limit: limit)
    }

    static func devStatus(volumeDb: Double = -12, limit: Double = 0,
                          muted: Bool = false) -> [UInt8] {
        QxDemoFrames.devStatus(volumeDb: volumeDb, limit: limit, muted: muted)
    }

    static func eqConfig(presetIndex: Int, enabled: Bool, nameMask: Int) -> [UInt8] {
        QxDemoFrames.eqConfig(presetIndex: presetIndex, enabled: enabled, nameMask: nameMask)
    }

    static func dacConfig(filter: Int) -> [UInt8] {
        QxDemoFrames.dacConfig(filter: filter)
    }

    static func presetName(index: Int, name: String) -> [UInt8] {
        QxDemoFrames.presetName(index: index, name: name)
    }

    static func presetSegments(preGain: Double, bands: [QxEqBandValue]) -> [[UInt8]] {
        QxDemoFrames.presetSegments(preGain: preGain, bands: bands)
    }

    static let tenBands: [QxEqBandValue] = QxEqGroup.user.defaultFreqs.map {
        QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1.0)
    }
}

extension QxFixtures {
    static func answeringLink(initData: [UInt8] = QxFixtures.initData,
                              volumeDb: Double = -12,
                              presetIndex: Int = 2,
                              nameMask: Int = 0,
                              preGain: Double = -3,
                              bands: [QxEqBandValue] = QxFixtures.tenBands,
                              dacFilter: Int = 3,
                              eqEnabled: Bool = true,
                              kind: QxLinkKind = .usb) -> FakeLink {
        let link = FakeLink(kind: kind)
        link.onSend = { [weak link] cmd, data in
            guard let link else { return }
            switch cmd {
            case .reqInitData:
                link.deliver(.rspInitData, initData)
            case .reqDevStatus:
                link.deliver(.rspDevStatus, QxFixtures.devStatus(volumeDb: volumeDb))
            case .reqDevConfig:
                if data.first == (QxConfigMask.sys2 | QxConfigMask.eq) {
                    link.deliver(.rspDevConfig,
                                 QxFixtures.eqConfig(presetIndex: presetIndex,
                                                     enabled: eqEnabled,
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
    private var historyDirectory: URL!

    override func setUp() {
        super.setUp()
        historyDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qx-session-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: historyDirectory,
                                                 withIntermediateDirectories: true)
        EqHistoryFile.directoryOverride = historyDirectory
    }

    override func tearDown() {
        EqHistoryFile.directoryOverride = nil
        try? FileManager.default.removeItem(at: historyDirectory)
        historyDirectory = nil
        super.tearDown()
    }

    private func answeringLink(volumeDb: Double = -12,
                               presetIndex: Int = 2,
                               nameMask: Int = 0,
                               preGain: Double = -3,
                               bands: [QxEqBandValue] = QxFixtures.tenBands,
                               dacFilter: Int = 3,
                               eqEnabled: Bool = true) -> FakeLink {
        QxFixtures.answeringLink(volumeDb: volumeDb, presetIndex: presetIndex,
                                 nameMask: nameMask, preGain: preGain,
                                 bands: bands, dacFilter: dacFilter,
                                 eqEnabled: eqEnabled)
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
            .setVolume, .setDacFilter, .setEqEnable, .setEqMode, .setEqType, .setEqPreGain,
            .setEqBandParam, .saveEqPreset, .loadEqPreset, .setEqPresetName, .saveAll,
        ])
        for forbidden in [QxCmd.setUsbFsMode, .sysReboot, .disconnect,
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
        let link = answeringLink(eqEnabled: false)
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

    func testApplyParametricLeavesAnAlreadyEnabledEqAlone() async throws {
        let link = answeringLink(eqEnabled: true)
        let session = try await connected(link)
        defer { session.close() }
        link.clearSends()

        var file = ParametricEQFile()
        file.preamp = -3
        file.bands = [QxEqBandValue(filter: .peak, freq: 1000, gain: 2, q: 1)]
        _ = try await session.applyParametric(file)

        XCTAssertTrue(link.payloads(for: .setEqEnable).isEmpty)
        XCTAssertEqual(link.sentCommands.first, .setEqType)
        XCTAssertEqual(link.payloads(for: .setEqBandParam).count, 10)
    }

    func testApplyParametricRefusesWhenTheGroupChangedUnderIt() async throws {
        let link = answeringLink()
        let session = try await connected(link)
        defer { session.close() }
        link.clearSends()

        var file = ParametricEQFile()
        file.preamp = 0
        file.bands = [QxEqBandValue(filter: .peak, freq: 1000, gain: 2, q: 1)]
        do {
            _ = try await session.applyParametric(file, expecting: .b20)
            XCTFail("a group change should have refused the write")
        } catch let error as QxSessionError {
            guard case .rejectedValue(let why) = error else {
                return XCTFail("expected a rejection, got \(error)")
            }
            XCTAssertTrue(why.contains("nothing was written"), why)
        }
        XCTAssertTrue(link.sent.isEmpty)
    }

    func testAnUnusableLinkFailsPendingWaitsWithItsOwnReason() async throws {
        let link = FakeLink()
        let session = QxSession(link: link, timeout: 2)
        async let connecting: Void = session.connect(timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        link.declareUnusable("BlueZ is not on the system bus")
        do {
            try await connecting
            XCTFail("connect should not have resolved")
        } catch let error as QxSessionError {
            XCTAssertEqual(error, .linkUnusable("BlueZ is not on the system bus"))
            XCTAssertEqual(error.description, "BlueZ is not on the system bus")
        }
        session.close()
    }

    func testABusyDeviceFailsConnectAtOnce() async {
        let link = FakeLink()
        link.busyText = "held elsewhere"
        let session = QxSession(link: link, timeout: 30)
        let began = Date()
        do {
            try await session.connect(timeout: 30)
            XCTFail("connect should not have resolved")
        } catch let error as QxSessionError {
            XCTAssertEqual(error, .deviceBusy("held elsewhere"))
            XCTAssertEqual(error.description, "held elsewhere")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
        session.close()
    }

    func testABusyReportDuringAPendingWaitFailsIt() async throws {
        let link = FakeLink()
        let session = QxSession(link: link, timeout: 30)
        async let connecting: Void = session.connect(timeout: 30)
        try await Task.sleep(nanoseconds: 100_000_000)
        link.onLinkBusy?("held elsewhere")
        do {
            try await connecting
            XCTFail("connect should not have resolved")
        } catch let error as QxSessionError {
            XCTAssertEqual(error, .deviceBusy("held elsewhere"))
        }
        session.close()
    }

    func testWaitingForTheDeviceUsesTheSharedLabel() async {
        let link = FakeLink()
        let session = QxSession(link: link, timeout: 0.2)
        do {
            try await session.connect(timeout: 0.2)
            XCTFail("connect should not have resolved")
        } catch let error as QxSessionError {
            XCTAssertEqual(error, .timedOut(QxSession.deviceAppearance))
        } catch {
            XCTFail("expected a QxSessionError, got \(error)")
        }
        session.close()
    }

    func testDisallowedCommandThrowsBeforeReachingTheLink() async throws {
        let link = answeringLink()
        let session = try await connected(link)
        defer { session.close() }
        link.clearSends()
        for forbidden in [QxCmd.setUsbFsMode, .sysReboot, .disconnect,
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

    func testWritesAreRefusedWhenTheInitFormatIsUnknown() async throws {
        var init4 = QxFixtures.initData
        init4[2] = 4
        let link = QxFixtures.answeringLink(initData: init4)
        let session = try await connected(link)
        defer { session.close() }
        link.clearSends()
        do {
            try await session.setVolume(db: -20)
            XCTFail("a device in an unknown data format must not be written")
        } catch let error as QxSessionError {
            guard case .rejectedValue(let why) = error else {
                return XCTFail("expected a rejection, got \(error)")
            }
            XCTAssertTrue(why.contains("unknown data format"))
        }
        XCTAssertTrue(link.sent.isEmpty)
    }

    func testWritesAreRefusedOnAnotherDeviceModel() async throws {
        var other = QxFixtures.initData
        other[1] = UInt8(QxDeviceModel.qudelix5KPlus)
        let link = QxFixtures.answeringLink(initData: other)
        let session = try await connected(link)
        defer { session.close() }
        link.clearSends()
        do {
            try await session.setDacFilter(index: 1)
            XCTFail("another model must not be written")
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

    func testVerboseMirrorsOneStderrLinePerTransmittedCommand() async throws {
        let capture = StdIOCapture()
        StdIO.errorSink = { capture.append($0) }
        Trace.verbose = true
        defer {
            Trace.verbose = false
            StdIO.errorSink = nil
        }

        let link = answeringLink()
        let session = try await connected(link)
        defer { session.close() }

        let handshake = capture.all.filter { $0.hasPrefix("[log] →") }
        XCTAssertEqual(handshake.count, link.sentCommands.count)
        XCTAssertEqual(handshake.count, 5)
        XCTAssertTrue(handshake[0].contains("reqInitData"), handshake[0])

        capture.clear()
        link.clearSends()
        try await session.setDacFilter(index: 2)
        let one = capture.all.filter { $0.hasPrefix("[log] →") }
        XCTAssertEqual(link.sentCommands, [.setDacFilter])
        XCTAssertEqual(one.count, 1)
        XCTAssertTrue(one[0].contains("setDacFilter"), one[0])
    }

    func testQuietDoesNotMirrorTransmittedCommands() async throws {
        let capture = StdIOCapture()
        StdIO.errorSink = { capture.append($0) }
        Trace.verbose = false
        defer { StdIO.errorSink = nil }

        let link = answeringLink()
        let session = try await connected(link)
        defer { session.close() }
        XCTAssertFalse(link.sentCommands.isEmpty)
        XCTAssertTrue(capture.all.isEmpty, capture.text)
    }

    func testTheModeSwitchSendsOneCommandAndWaitsForTheGroupToChange() async throws {
        let device = EqTestDevice()
        let session = try await connected(device.link)
        defer { session.close() }
        device.link.clearSends()
        try await session.setEqMode(twentyBand: true, retryDelays: [0.05, 0.05, 1])
        XCTAssertEqual(device.link.payloads(for: .setEqMode), [[1]])
        XCTAssertTrue(device.link.sentCommands.contains(.reqDevConfig))
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.eqGroup, .b20)
    }

    func testAnUnansweredModeSwitchTimesOutAfterAskingForTheConfigurationAgain() async throws {
        let device = EqTestDevice()
        device.acceptsModeSwitch = false
        let session = try await connected(device.link)
        defer { session.close() }
        device.link.clearSends()
        do {
            try await session.setEqMode(twentyBand: true, retryDelays: [0.05, 0.05])
            XCTFail("expected a timeout")
        } catch let error as QxSessionError {
            XCTAssertEqual(error, .timedOut("the EQ mode switch"))
        }
        XCTAssertEqual(device.link.payloads(for: .setEqMode), [[1]])
        XCTAssertEqual(device.link.payloads(for: .reqDevConfig).count, 1)
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = true
        private var stamps: [QxCmd: Date] = [:]

        var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
        func set(_ value: Bool) { lock.lock(); open = value; lock.unlock() }
        func stamp(_ cmd: QxCmd) { lock.lock(); stamps[cmd] = Date(); lock.unlock() }
        func stamped(_ cmd: QxCmd) -> Date? { lock.lock(); defer { lock.unlock() }; return stamps[cmd] }
    }

    private func gated(_ link: FakeLink, _ gate: Gate) {
        let original = link.onSend
        link.onSend = { cmd, data in
            gate.stamp(cmd)
            if cmd == .reqEqPreset, !gate.isOpen { return }
            original?(cmd, data)
        }
    }

    private func logText() -> String {
        guard let url = DebugLog.shared.fileURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    func testABluetoothLoadWaitsBeforeReadingTheSlotBack() async throws {
        let link = answeringLink()
        let bluetooth = QxFixtures.answeringLink(kind: .bluetooth)
        let gate = Gate()
        gated(bluetooth, gate)
        let session = try await connected(bluetooth)
        defer { session.close() }
        _ = try await session.loadPreset(index: 4)
        let load = try XCTUnwrap(gate.stamped(.loadEqPreset))
        let read = try XCTUnwrap(gate.stamped(.reqEqPreset))
        XCTAssertGreaterThanOrEqual(read.timeIntervalSince(load), 0.14)
        let usbGate = Gate()
        gated(link, usbGate)
        let usb = try await connected(link)
        defer { usb.close() }
        _ = try await usb.loadPreset(index: 4)
        let usbLoad = try XCTUnwrap(usbGate.stamped(.loadEqPreset))
        let usbRead = try XCTUnwrap(usbGate.stamped(.reqEqPreset))
        XCTAssertLessThan(usbRead.timeIntervalSince(usbLoad), 0.1)
    }

    func testAnImplausiblePresetLogsTheRawBufferAndTheDecodedValues() async throws {
        let wild = QxFixtures.tenBands.map { QxEqBandValue(filter: .peak, freq: $0.freq, gain: 40, q: 1.0) }
        let link = answeringLink(bands: wild)
        let session = try await connected(link)
        defer { session.close() }
        do {
            _ = try await session.readPreset()
            XCTFail("an implausible preset should not decode")
        } catch let error as QxSessionError {
            guard case .rejectedValue = error else { return XCTFail("\(error)") }
        }
        let text = logText()
        XCTAssertTrue(text.contains("preset decode implausible for group"))
        XCTAssertTrue(text.contains("raw "))
        XCTAssertTrue(text.contains("decoded preGain"))
    }

    func testAPresetReadTimeoutLogsThePartialBuffer() async throws {
        let link = answeringLink()
        let gate = Gate()
        gated(link, gate)
        let session = try await connected(link, timeout: 0.3)
        defer { session.close() }
        gate.set(false)
        do {
            _ = try await session.readPreset()
            XCTFail("nothing answered")
        } catch let error as QxSessionError {
            XCTAssertEqual(error, .timedOut("the EQ preset"))
        }
        XCTAssertTrue(logText().contains("preset read timed out; partial buffer"))
    }

    func testBluetoothSegmentsOfAnOlderRequestAreIgnored() async throws {
        let link = QxFixtures.answeringLink(kind: .bluetooth)
        let gate = Gate()
        gated(link, gate)
        let session = try await connected(link, timeout: 0.4)
        defer { session.close() }
        gate.set(false)
        let segments = QxFixtures.presetSegments(preGain: -3, bands: QxFixtures.tenBands)
        XCTAssertGreaterThan(segments.count, 1)
        let before = gate.stamped(.reqEqPreset)
        async let reading = session.readPreset()
        let deadline = Date().addingTimeInterval(2)
        while gate.stamped(.reqEqPreset) == before, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        for segment in segments.dropFirst() { link.deliver(.rspEqPreset, segment) }
        do {
            _ = try await reading
            XCTFail("a read answered only by stale segments must not complete")
        } catch let error as QxSessionError {
            XCTAssertEqual(error, .timedOut("the EQ preset"))
        }
        XCTAssertTrue(logText().contains("preset segment ignored: it answers an older request"))
        gate.set(true)
        let preset = try await session.readPreset()
        XCTAssertEqual(preset.bands.count, QxFixtures.tenBands.count)
    }
}
