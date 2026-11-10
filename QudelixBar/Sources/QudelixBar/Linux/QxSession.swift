import Foundation
import Dispatch

enum QxSessionError: Error, CustomStringConvertible, Equatable {
    case disallowedCommand(QxCmd)
    case rejectedValue(String)
    case timedOut(String)
    case linkClosed
    case linkUnusable(String)
    case deviceBusy(String)

    var description: String {
        switch self {
        case .disallowedCommand(let cmd):
            return "refusing to send \(cmd) — not a command this tool is allowed to write"
        case .rejectedValue(let why):
            return why
        case .timedOut(let what):
            return "timed out waiting for \(what)"
        case .linkClosed:
            return "the device disconnected"
        case .linkUnusable(let reason):
            return reason
        case .deviceBusy(let text):
            return text
        }
    }
}

final class QxSession {
    static let allowed: Set<QxCmd> = [
        .reqInitData,
        .reqDevConfig,
        .reqDevStatus,
        .reqEqPreset,
        .reqEqPresetName,
        .setVolume,
        .setDacFilter,
        .setEqEnable,
        .setEqType,
        .setEqPreGain,
        .setEqBandParam,
        .saveEqPreset,
        .loadEqPreset,
        .setEqPresetName,
        .saveAll,
    ]

    static let deviceAppearance = "the device to appear"

    let link: QxLink
    let timeout: TimeInterval

    private let queue = DispatchQueue(label: "qudelix.session")

    private var state = QxDeviceState()
    private var assembler = QxPresetAssembler()
    private var eqGroup: QxEqGroup = .user
    private var busyText: String?
    private var presetNames: [Int: String] = [:]
    private var answeredNames: Set<Int> = []
    private var lastPreset: QxUserEqPreset?
    private var lastPresetIsPEQ: Bool?
    private var lastPresetStale = false
    private var connectedName: String?
    private var initParsed = false
    private var started = false
    private var closed = false
    private var presetEpoch = 0
    private var statusEpoch = 0
    private var configEpoch = 0

    private var waiters: [Waiter] = []
    private var streams: [UUID: AsyncStream<String>.Continuation] = [:]

    private final class Waiter {
        let condition: () -> Bool
        let deliver: (Result<Void, Error>) -> Void
        var done = false

        init(condition: @escaping () -> Bool,
             deliver: @escaping (Result<Void, Error>) -> Void) {
            self.condition = condition
            self.deliver = deliver
        }
    }

    init(link: QxLink, timeout: TimeInterval = 5) {
        self.link = link
        self.timeout = timeout
        link.onConnected = { [weak self] name in
            guard let self else { return }
            self.queue.async { self.linkCameUp(name) }
        }
        link.onDisconnected = { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.linkWentDown("the device disconnected", failingWith: .linkClosed)
            }
        }
        link.onLinkUnusable = { [weak self] reason in
            guard let self else { return }
            self.queue.async {
                self.linkWentDown(reason, failingWith: .linkUnusable(reason))
            }
        }
        link.onLinkBusy = { [weak self] text in
            guard let self else { return }
            self.queue.async {
                self.busyText = text
                self.linkWentDown(text, failingWith: .deviceBusy(text))
            }
        }
        link.onPacket = { [weak self] bytes in
            guard let self else { return }
            self.queue.async { self.handlePacket(bytes) }
        }
    }

    func connect(timeout: TimeInterval) async throws {
        try await perform {
            guard !self.started else { return }
            self.started = true
            self.link.start()
        }
        let deadline = Date().addingTimeInterval(timeout)
        try await wait(Self.deviceAppearance, timeout: timeout) {
            self.connectedName != nil
        }
        var attempt = 0
        while attempt < 3 {
            attempt += 1
            try await perform { try self.sendHandshake() }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            do {
                try await wait("the handshake reply", timeout: min(2, remaining)) {
                    self.initParsed && self.statusEpoch > 0
                }
                let settle = max(0.05, min(1, deadline.timeIntervalSinceNow))
                try? await wait("the device config", timeout: settle) {
                    self.configEpoch > 0
                }
                return
            } catch let error as QxSessionError {
                guard case .timedOut = error else { throw error }
                Trace.log("no response — retrying handshake (\(attempt + 1))")
                continue
            }
        }
        throw QxSessionError.timedOut("the handshake reply")
    }

    func close(waitForLink: Bool = false) {
        queue.sync {
            guard !self.closed else { return }
            self.closed = true
            self.failPending(QxSessionError.linkClosed)
            for continuation in self.streams.values { continuation.finish() }
            self.streams.removeAll()
        }
        if waitForLink {
            link.stopAndWait(timeout: Self.linkStopWait)
        } else {
            link.stop()
        }
    }

    static let linkStopWait: TimeInterval = 2

    var isConnected: Bool { link.isConnected }

    func compatibilityRefusal() async -> String? {
        await read { QxCompatibility.refusal(for: self.state) }
    }

    func snapshot() async -> QxStatusSnapshot {
        await read { self.makeSnapshot() }
    }

    func refreshStatus() async throws {
        let start = try await perform { () -> Int in
            let seen = self.statusEpoch
            try self.transmit(.reqDevStatus, [QxStatusMask.audio | QxStatusMask.power
                                              | QxStatusMask.conn | QxStatusMask.vol])
            try self.transmit(.reqDevConfig, [QxConfigMask.sys | QxConfigMask.playTime
                                              | QxConfigMask.dac | QxConfigMask.mic
                                              | QxConfigMask.batt])
            try self.transmit(.reqDevConfig, [QxConfigMask.sys2 | QxConfigMask.eq])
            return seen
        }
        try await wait("a status reply", timeout: timeout) { self.statusEpoch > start }
    }

    func readPreset() async throws -> QxUserEqPreset {
        let start = try await perform { () -> Int in
            self.assembler.reset()
            try self.transmit(.reqEqPreset, [self.eqGroup.requestMask])
            return self.presetEpoch
        }
        try await wait("the EQ preset", timeout: timeout) { self.presetEpoch > start }
        return try await perform {
            guard let preset = self.lastPreset else {
                throw QxSessionError.rejectedValue(
                    "the device sent an EQ preset this build cannot read")
            }
            return preset
        }
    }

    func presetName(index: Int) async throws -> String? {
        try await perform {
            try self.checkSlot(index)
            self.answeredNames.remove(index)
            try self.transmit(.reqEqPresetName, [self.eqGroup.rawValue, UInt8(index)])
        }
        try await wait("the name of preset \(index + 1)", timeout: timeout) {
            self.answeredNames.contains(index)
        }
        return await read { self.presetNames[index] }
    }

    func namedPresets() async throws -> [Int: String] {
        let mask = await read { self.state.presetNameMask }
        let wanted = (0..<QudelixController.presetCount).filter { mask & (1 << $0) != 0 }
        guard !wanted.isEmpty else { return [:] }
        try await perform {
            for index in wanted {
                self.answeredNames.remove(index)
                try self.transmit(.reqEqPresetName, [self.eqGroup.rawValue, UInt8(index)])
            }
        }
        try await wait("the saved preset names", timeout: timeout) {
            wanted.allSatisfy { self.answeredNames.contains($0) }
        }
        return await read { self.presetNames }
    }

    func notifications() -> AsyncStream<String> {
        AsyncStream { continuation in
            let id = UUID()
            queue.async {
                if self.closed {
                    continuation.finish()
                } else {
                    self.streams[id] = continuation
                }
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.streams[id] = nil }
            }
        }
    }

    func send(_ cmd: QxCmd, _ data: [UInt8] = []) async throws {
        try await perform { try self.transmit(cmd, data) }
    }

    func setVolume(db: Double) async throws {
        try await perform {
            guard db.isFinite else {
                throw QxSessionError.rejectedValue("a volume has to be a number of dB")
            }
            let ceiling = self.volumeCeiling()
            let clamped = Swift.max(ceiling - 60, Swift.min(ceiling, db))
            guard let payload = QxPacket.volumePayload(.sink, db: clamped) else {
                throw QxSessionError.rejectedValue("\(db) dB cannot be written to this device")
            }
            try self.transmit(.setVolume, payload)
            self.state.volumeDb = clamped
        }
    }

    func setMute(_ on: Bool) async throws {
        try await perform {
            try self.transmit(.setVolume, [QxVolumeParam.mute.rawValue, 0, on ? 1 : 0])
            self.state.usbMute = on
        }
    }

    func setDacFilter(index: Int) async throws {
        try await perform {
            guard let payload = QxPacket.dacFilterPayload(index) else {
                throw QxSessionError.rejectedValue(
                    "\(index) is not a DAC filter this device defines")
            }
            try self.transmit(.setDacFilter, payload)
            self.state.dacFilterType = index
        }
    }

    func setEqEnabled(_ on: Bool) async throws {
        try await perform {
            try self.transmit(.setEqEnable, [self.eqGroup.rawValue, on ? 1 : 0])
            self.state.eqEnabled = on
        }
    }

    @discardableResult
    func applyParametric(_ file: ParametricEQFile,
                         expecting expected: QxEqGroup? = nil,
                         recording label: String? = "import") async throws -> QxUserEqPreset {
        try await perform {
            let group = self.eqGroup
            if let expected, expected != group {
                throw QxSessionError.rejectedValue(
                    "the device switched to the " + QxFormat.groupLabel(group)
                        + " EQ group while this was being prepared — nothing was written")
            }
            if let label { self.recordEqHistory(label) }
            let existing = self.lastPreset?.bands ?? []
            let bandCount = group.bandCount
            var writes: [Int: QxEqBandValue] = [:]
            for index in 0..<bandCount {
                if index < file.bands.count {
                    writes[index] = Self.clamped(file.bands[index])
                } else if existing.indices.contains(index) {
                    var band = existing[index]
                    band.filter = .bypass
                    writes[index] = Self.clamped(band)
                } else {
                    writes[index] = QxEqBandValue(filter: .bypass,
                                                  freq: group.defaultFreqs[index],
                                                  gain: 0, q: 1)
                }
            }
            let preGain = EQHeadroom.clamp(file.preamp)
            let scaledPreGain = Int((preGain * QxScale.gain).rounded())
            guard self.eqGroup == group else {
                throw QxSessionError.rejectedValue(
                    "the device switched EQ group while this was being prepared "
                        + "— nothing was written")
            }
            if self.state.eqEnabled != true {
                try self.transmit(.setEqEnable, [group.rawValue, 1])
                self.state.eqEnabled = true
            }
            try self.transmit(.setEqType, [group.rawValue, 1])
            for mask in [UInt8(1), UInt8(2)] {
                try self.transmit(.setEqPreGain,
                                  [group.rawValue, mask, 0]
                                    + QxPacket.int16BE(scaledPreGain))
            }
            for index in 0..<bandCount {
                guard let value = writes[index],
                      let payload = QxPacket.bandParamPayload(group: group,
                                                              band: index, value) else {
                    throw QxSessionError.rejectedValue(
                        "band \(index + 1) is outside what the device accepts")
                }
                try self.transmit(.setEqBandParam, payload)
            }
        }
        return try await readPreset()
    }

    func livePreset() async -> QxUserEqPreset? {
        await read { self.lastPreset }
    }

    func writeBand(index: Int, _ value: QxEqBandValue) async throws {
        try await perform {
            let group = self.eqGroup
            let band = Self.clamped(value)
            guard let payload = QxPacket.bandParamPayload(group: group, band: index, band) else {
                throw QxSessionError.rejectedValue(
                    "band \(index + 1) is outside what the device accepts")
            }
            try self.transmit(.setEqBandParam, payload)
            if var preset = self.lastPreset, preset.bands.indices.contains(index) {
                preset.bands[index] = band
                self.lastPreset = preset
            }
        }
    }

    func writePreGain(db: Double) async throws {
        try await perform {
            let group = self.eqGroup
            let clamped = EQHeadroom.clamp(db)
            let scaled = Int((clamped * QxScale.gain).rounded())
            for mask in [UInt8(1), UInt8(2)] {
                try self.transmit(.setEqPreGain,
                                  [group.rawValue, mask, 0] + QxPacket.int16BE(scaled))
            }
            if var preset = self.lastPreset {
                preset.preGain = clamped
                preset.preGainCh1 = clamped
                self.lastPreset = preset
            }
        }
    }

    func savePreset(index: Int) async throws {
        try await perform {
            try self.checkSlot(index)
            try self.transmit(.saveEqPreset, [UInt8(index)])
        }
    }

    @discardableResult
    func loadPreset(index: Int, recording: Bool = true) async throws -> QxUserEqPreset {
        try await perform {
            try self.checkSlot(index)
            if recording {
                self.recordEqHistory(
                    "load " + QxFormat.presetLabel(index, self.presetNames[index]))
            }
            self.assembler.reset()
            try self.transmit(.loadEqPreset, [UInt8(index)])
            self.state.eqPresetIdx = index
        }
        let preset = try await readPreset()
        await read {
            ActiveSlotFile.record(slot: index, group: self.eqGroup, preset: preset,
                                  identity: self.deviceIdentity)
        }
        return preset
    }

    func renamePreset(index: Int, name: String) async throws {
        try await perform {
            try self.checkSlot(index)
            let cleaned = QudelixController.displayName(name)
            guard let payload = QxPacket.presetNamePayload(group: self.eqGroup,
                                                           index: index,
                                                           name: cleaned) else {
                throw QxSessionError.rejectedValue("that name cannot be written to slot \(index + 1)")
            }
            let stored = QxPacket.truncatingUTF8(cleaned, to: QxPacket.maxPresetNameBytes)
            self.presetNames[index] = stored.isEmpty ? nil : stored
            self.answeredNames.remove(index)
            try self.transmit(.setEqPresetName, payload)
        }
    }

    func saveAll() async throws {
        try await perform { try self.transmit(.saveAll) }
    }

    private func transmit(_ cmd: QxCmd, _ data: [UInt8] = []) throws {
        guard Self.allowed.contains(cmd) else {
            throw QxSessionError.disallowedCommand(cmd)
        }
        if !QxCompatibility.isRequest(cmd), let reason = QxCompatibility.refusal(for: state) {
            throw QxSessionError.rejectedValue(reason)
        }
        Trace.tx(cmd, data)
        link.send(cmd, data)
    }

    private var deviceIdentity: String? {
        connectedName.map { (link.kind == .usb ? "usb:" : "ble:") + $0 }
    }

    private func recordEqHistory(_ label: String) {
        guard let preset = lastPreset, connectedName != nil else { return }
        let snapshot = EqSnapshot(groupRaw: eqGroup.rawValue,
                                  bands: preset.bands,
                                  preGain: preset.preGain,
                                  enabled: state.eqEnabled ?? true,
                                  name: state.eqPresetIdx.flatMap { presetNames[$0] },
                                  mutedBands: [:],
                                  deviceIdentity: deviceIdentity)
        EqHistoryFile.append(EqHistoryEntry(recordedAt: Date(),
                                            label: label,
                                            snapshot: snapshot))
    }

    private func sendHandshake() throws {
        try transmit(.reqInitData, QxInit.requestPayload)
        try transmit(.reqDevConfig, [QxConfigMask.sys | QxConfigMask.playTime
                                     | QxConfigMask.dac | QxConfigMask.mic
                                     | QxConfigMask.batt])
        try transmit(.reqDevConfig, [QxConfigMask.sys2 | QxConfigMask.eq])
        try transmit(.reqDevStatus, [QxStatusMask.audio | QxStatusMask.power
                                     | QxStatusMask.conn | QxStatusMask.vol])
        try transmit(.reqEqPreset, [eqGroup.requestMask])
    }

    private func checkSlot(_ index: Int) throws {
        guard (0..<QudelixController.presetCount).contains(index) else {
            throw QxSessionError.rejectedValue(
                "preset \(index + 1) is not a slot this device has")
        }
    }

    static func clamped(_ value: QxEqBandValue) -> QxEqBandValue {
        var band = value
        band.freq = max(20, min(20000, band.freq))
        band.gain = band.gain.isFinite ? max(-12, min(12, band.gain)) : 0
        band.q = band.q.isFinite ? max(0.1, min(10, band.q)) : 1.0
        return band
    }

    private func handlePacket(_ bytes: [UInt8]) {
        guard let (cmdId, data) = QxPacket.parseRx(bytes) else { return }
        Trace.rx(cmdId, data)
        dispatch(cmdId, data)
        wake()
    }

    private func dispatch(_ cmdId: UInt16, _ data: [UInt8]) {
        switch QxCmd(rawValue: cmdId) {
        case .rspInitData:
            if QxStatusParser.parseInitData(data, into: &state) {
                initParsed = true
                emit("init " + (state.fwVersion.map { "firmware \($0)" } ?? "")
                     + " " + QxDeviceModel.name(for: state.deviceId))
            }
        case .rspDevStatus:
            _ = QxStatusParser.parseDevStatus(data, into: &state)
            statusEpoch += 1
            consumeEqMode()
            emit(stateLine("status"))
        case .rspDevConfig:
            _ = QxStatusParser.parseDevConfig(data, into: &state)
            configEpoch += 1
            consumeEqMode()
            emit(stateLine("config"))
        case .rspEqPreset, .rspEqPresetL, .rspEqPresetH:
            ingestPresetSegment(data)
        case .rspEqPresetName:
            parsePresetName(data)
            emit(stateLine("name"))
        case .notification:
            parseNotification(data)
        default:
            break
        }
    }

    private func ingestPresetSegment(_ data: [UInt8]) {
        guard assembler.ingest(data) else { return }
        let buffer = assembler.buffer
        assembler.reset()
        let decoded = QxUserEqPreset.decode(buffer, group: eqGroup)
        if decoded.looksPlausible {
            var clampedPreset = decoded
            clampedPreset.preGain = EQHeadroom.clamp(decoded.preGain)
            clampedPreset.bands = decoded.bands.map(Self.clamped)
            lastPreset = clampedPreset
            lastPresetStale = false
            lastPresetIsPEQ = buffer.first.map { $0 & 1 == 1 }
        } else {
            lastPreset = nil
            lastPresetIsPEQ = nil
            Trace.log("preset decode implausible for group \(eqGroup)")
        }
        presetEpoch += 1
        emit(stateLine("preset"))
    }

    private func parsePresetName(_ data: [UInt8]) {
        guard data.count >= 3, data[0] == eqGroup.rawValue else { return }
        let index = Int(data[1])
        guard (0..<QudelixController.presetCount).contains(index) else { return }
        answeredNames.insert(index)
        let end = min(Int(data[2]), data.count)
        guard end > 3 else { presetNames[index] = nil; return }
        let nameBytes = data[3..<end].prefix { $0 != 0 }
        guard let raw = String(bytes: nameBytes, encoding: .utf8) else { return }
        let name = QudelixController.displayName(raw)
        presetNames[index] = name.isEmpty ? nil : name
    }

    private func parseNotification(_ data: [UInt8]) {
        guard data.count >= 2 else { return }
        if data[0] >= 128 {
            let group = data[1]
            guard group == eqGroup.rawValue else { return }
            switch data[0] {
            case 129:
                if data.count >= 3 {
                    state.eqPresetIdx = Int(data[2])
                    lastPresetStale = true
                    emit(Self.slotIndex(Int(data[2])).map { "preset \($0 + 1) is now active" }
                         ?? "no preset slot is active")
                }
            case 130:
                if data.count >= 3 {
                    state.eqEnabled = data[2] != 0
                    emit("eq \(data[2] != 0 ? "on" : "off")")
                }
            default:
                break
            }
            return
        }
        let flags = data[1]
        var off = 2
        if flags & QxNotifyMask.status != 0 {
            off += QxStatusParser.parseDevStatus(data.tail(from: off), into: &state)
            statusEpoch += 1
        }
        if flags & QxNotifyMask.config != 0 {
            _ = QxStatusParser.parseDevConfig(data.tail(from: off), into: &state)
            configEpoch += 1
        }
        consumeEqMode()
        emit(stateLine("notify"))
    }

    private func consumeEqMode() {
        guard let mode = state.eqMode else { return }
        state.eqMode = nil
        setGroup(mode == 1 ? .b20 : .user)
    }

    private func setGroup(_ group: QxEqGroup) {
        guard group != eqGroup else { return }
        eqGroup = group
        assembler.group = group
        assembler.reset()
        lastPreset = nil
        lastPresetStale = false
        lastPresetIsPEQ = nil
        presetNames.removeAll()
        answeredNames.removeAll()
    }

    private func linkCameUp(_ name: String) {
        busyText = nil
        connectedName = name
        emit("connected to \(DebugLog.sanitized(name))")
        wake()
    }

    private func linkWentDown(_ why: String, failingWith error: QxSessionError) {
        connectedName = nil
        initParsed = false
        state.deviceId = 0
        state.fwMajor = nil
        state.fwVersion = nil
        state.initFormat = nil
        emit(why)
        failPending(error)
    }

    private func volumeCeiling() -> Double {
        state.dacOutPwr2Vrms ? min(state.volumeLimitDb ?? 6, 6)
                             : min(state.volumeLimitDb ?? 0, 0)
    }

    private func makeSnapshot() -> QxStatusSnapshot {
        var snapshot = QxStatusSnapshot()
        snapshot.linkKind = link.kind
        snapshot.deviceIdentity = deviceIdentity
        snapshot.deviceId = state.deviceId
        snapshot.modelName = QxDeviceModel.name(for: state.deviceId)
        snapshot.firmware = state.fwVersion
        snapshot.batteryPercent = state.batteryPercent
        snapshot.batteryMilliVolts = state.batteryMilliVolts
        snapshot.charging = state.charging
        snapshot.chargerConnected = state.chargerConnected
        snapshot.volumeDb = state.volumeDb
        snapshot.volumeLimitDb = state.volumeLimitDb
        snapshot.volumeCeilingDb = volumeCeiling()
        snapshot.muted = state.usbMute
        snapshot.dacFilterIndex = state.dacFilterType
        snapshot.dacFilterName = state.dacFilterType.flatMap {
            QxStatusParser.dacFilters.indices.contains($0)
                ? QxStatusParser.dacFilters[$0] : nil
        }
        snapshot.eqEnabled = state.eqEnabled
        snapshot.eqType = lastPresetIsPEQ.map { $0 ? "PEQ" : "GEQ" }
        snapshot.eqGroup = eqGroup
        snapshot.activePresetIndex = resolvedActiveSlot()
        snapshot.activePresetName = snapshot.activePresetIndex.flatMap { presetNames[$0] }
        snapshot.sampleRate = state.sampleRateLabel
        snapshot.inputSource = state.inputSourceLabel
        snapshot.activeCall = state.activeCall
        snapshot.codec = state.codecLabel
        return snapshot
    }

    private func resolvedActiveSlot() -> Int? {
        guard state.eqCfgGroup == Int(eqGroup.rawValue) else { return nil }
        if let slot = state.eqPresetIdx.flatMap(Self.slotIndex) { return slot }
        guard let preset = lastPreset, !lastPresetStale else { return nil }
        return ActiveSlotFile.slot(matching: preset, group: eqGroup, identity: deviceIdentity)
    }

    static func slotIndex(_ raw: Int) -> Int? {
        (0..<QudelixController.presetCount).contains(raw) ? raw : nil
    }

    private func stateLine(_ tag: String) -> String {
        var parts = [tag]
        if let battery = state.batteryPercent { parts.append("batt=\(battery)%") }
        parts.append("chg=\(state.chargerConnected ? (state.charging ? "on" : "idle") : "off")")
        if let volume = state.volumeDb { parts.append("vol=\(QxFormat.db(volume))") }
        if let mute = state.usbMute { parts.append("mute=\(mute ? 1 : 0)") }
        if let rate = state.sampleRateLabel { parts.append("sr=\(rate)") }
        if let source = state.inputSourceLabel { parts.append("src=\(source)") }
        if let enabled = state.eqEnabled { parts.append("eq=\(enabled ? "on" : "off")") }
        if state.eqPresetIdx != nil {
            parts.append("preset=" + (resolvedActiveSlot().map { String($0 + 1) } ?? "none"))
        }
        if let filter = state.dacFilterType { parts.append("dacFilter=\(filter)") }
        parts.append("group=\(eqGroup.rawValue)")
        return parts.joined(separator: " ")
    }

    private func emit(_ line: String) {
        for continuation in streams.values { continuation.yield(line) }
    }

    private func wake() {
        guard !waiters.isEmpty else { return }
        var remaining: [Waiter] = []
        var ready: [Waiter] = []
        for waiter in waiters {
            if waiter.done { continue }
            if waiter.condition() {
                waiter.done = true
                ready.append(waiter)
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
        for waiter in ready { waiter.deliver(.success(())) }
    }

    private func failPending(_ error: Error) {
        let pending = waiters
        waiters = []
        for waiter in pending where !waiter.done {
            waiter.done = true
            waiter.deliver(.failure(error))
        }
    }

    private func wait(_ what: String, timeout: TimeInterval,
                      until condition: @escaping () -> Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if condition() { continuation.resume(); return }
                if let text = self.busyText {
                    continuation.resume(throwing: QxSessionError.deviceBusy(text))
                    return
                }
                if self.closed {
                    continuation.resume(throwing: QxSessionError.linkClosed)
                    return
                }
                let waiter = Waiter(condition: condition) { continuation.resume(with: $0) }
                self.waiters.append(waiter)
                self.queue.asyncAfter(deadline: .now() + timeout) { [weak waiter] in
                    guard let waiter, !waiter.done else { return }
                    waiter.done = true
                    self.waiters.removeAll { $0 === waiter }
                    waiter.deliver(.failure(QxSessionError.timedOut(what)))
                }
            }
        }
    }

    @discardableResult
    private func perform<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func read<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}
