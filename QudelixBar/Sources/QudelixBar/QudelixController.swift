import Foundation
import SwiftUI

@MainActor
final class QudelixController: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connected(name: String)
    }

    enum Compatibility: Equatable {
        case checking
        case ok
        case unsupported(title: String, detail: String)

        var canWrite: Bool { self == .ok }
    }

    @Published var compatibility: Compatibility = .checking

    @Published var connection: ConnectionState = .disconnected
    @Published var usbWired = false
    @Published var firmwareVersion: String?
    @Published var batteryPercent: Int?
    @Published var charging = false
    @Published var chargerConnected = false
    @Published var batteryLow = false
    @Published var chargerState: Int?
    @Published var dacState: Int?
    @Published var chargerEnabled: Bool?
    @Published var batteryCare: Bool?
    @Published var sampleRate: String?
    @Published var inputSource: String?
    @Published var activeCall: Bool?
    @Published var receivingReports = false

    @Published var volumeDb: Double = -30
    @Published var volumeMax: Double = 0
    @Published var muted = false
    var volumeRange: ClosedRange<Double> { (volumeMax - 60)...volumeMax }

    @Published var trimLeftDb: Double = 0
    @Published var trimRightDb: Double = 0

    @Published var volumeLimitDb: Double = 0

    @Published var dacFilterType: Int?

    @Published var crossfeedLevel: Int?

    @Published var codecLabel: String?
    @Published var outputHighGain: Bool?

    var chargeSummary: String? {
        guard chargerState != nil else { return nil }
        if !chargerConnected { return "On battery" }
        if charging { return "Plugged in, charging" }
        if chargerEnabled == false { return "Plugged in — charging is switched off" }
        return "Plugged in, not charging"
    }

    nonisolated static func exportToken(for filter: QxFilter) -> String? {
        switch filter {
        case .peak: return "PK"
        case .lowShelf: return "LSC"
        case .highShelf: return "HSC"
        case .lpf: return "LPQ"
        case .hpf: return "HPQ"
        case .bypass: return nil
        }
    }

    var dacFilterLabel: String? {
        guard let i = dacFilterType,
              QxStatusParser.dacFilters.indices.contains(i) else { return nil }
        return QxStatusParser.dacFilters[i]
    }

    @Published var usbFsMode: Int?

    @Published var eqEnabled = true
    @Published var preGain: Double = 0
    @Published var bands: [QxEqBandValue] = QxEq.defaultFreqs.map {
        QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1.0)
    }
    @Published var presetNames: [Int: String] = [:]
    @Published var activePreset: Int?
    @Published var lastImportSummary: String?

    @Published private(set) var mutedBands: [Int: QxFilter] = [:]

    @Published private(set) var requestedCorrection: ParametricEQFile?

    var previewPane: PopoverView.Pane?
    private(set) var paneRequest: PopoverView.Pane?
    @Published private(set) var paneRequests = 0
    func requestPane(_ pane: PopoverView.Pane) {
        paneRequest = pane
        paneRequests &+= 1
    }
    var previewAutoEq: (entries: [AutoEqEntry], query: String)?
    static let presetCount = QxEq.presetCount

    @Published private(set) var eqGroup: QxEqGroup = .user
    var bandCount: Int { eqGroup.bandCount }

    @Published private(set) var byEarSessionActive = false

    func setByEarSessionActive(_ active: Bool) { byEarSessionActive = active }

    private let hid = HIDTransport()
    private let ble = BLETransport()

    enum Link: String { case none, usb, bluetooth }
    @Published private(set) var link: Link = .none

    private func transportSend(_ cmd: QxCmd, _ data: [UInt8] = []) {
        #if DEBUG
        trace("\(cmd)")
        #endif
        switch link {
        case .usb: hid.send(cmd, data)
        case .bluetooth: ble.send(cmd, data)
        case .none: DebugLog.shared.log("send dropped (no link): \(cmd)")
        }
    }

    private func transportSendCoalesced(_ cmd: QxCmd, _ data: [UInt8], key: String) {
        #if DEBUG
        trace("coalesced:\(cmd)")
        #endif
        switch link {
        case .usb: hid.sendCoalesced(cmd, data, key: key)
        case .bluetooth: ble.sendCoalesced(cmd, data, key: key)
        case .none: DebugLog.shared.log("coalesced send dropped (no link): \(cmd)")
        }
    }

    func flushPendingEqSends() {
        #if DEBUG
        trace("flush")
        #endif
        switch link {
        case .usb: hid.flushPending()
        case .bluetooth: ble.flushPending()
        case .none: break
        }
    }

    #if DEBUG
    private(set) var sendTrace: [String] = []
    private static let sendTraceDepth = 64
    private func trace(_ entry: String) {
        sendTrace.append(entry)
        if sendTrace.count > Self.sendTraceDepth { sendTrace.removeFirst() }
    }
    func clearSendTrace() { sendTrace.removeAll() }
    #endif

    private let batteryAlerts = BatteryAlerts()

    let batteryLog = BatteryLog()

    private var eqSnapshots: EqSnapshotStore
    private let eqSnapshotURL: URL

    init(eqSnapshotURL: URL = EqSnapshotFile.url) {
        self.eqSnapshotURL = eqSnapshotURL
        eqSnapshots = EqSnapshotFile.load(from: eqSnapshotURL)
    }

    private var eqSnapshot: EqSnapshot? { eqSnapshots[eqGroup.rawValue] }

    private var deviceIdentity: String? {
        switch link {
        case .bluetooth: return ble.pinnedIdentity.map { "ble:" + $0 }
        case .usb:
            if case .connected(let name) = connection {
                return "usb:" + A2dpGuard.deviceBaseName(name)
            }
            return nil
        default: return nil
        }
    }

    private static func canonicalIdentity(_ identity: String) -> String {
        guard identity.hasPrefix("usb:") else { return identity }
        return "usb:" + A2dpGuard.deviceBaseName(String(identity.dropFirst(4)))
    }

    struct EqEdit {
        var bands: [QxEqBandValue]
        var preGain: Double
        var mutedBands: [Int: QxFilter]
        var enabled: Bool
        var activePreset: Int?
        var sourceName: String?
        var requested: ParametricEQFile?
        var sourceCurve: [QxEqBandValue]?
        var sourcePreGain: Double?
        var label: String
    }

    @Published private(set) var undoStack: [EqEdit] = []
    @Published private(set) var redoStack: [EqEdit] = []
    private static let undoDepth = 40
    private var suppressUndo = false
    private var lastEditLabel = ""
    private var lastEditAt = Date.distantPast

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoLabel: String? { undoStack.last?.label }
    var redoLabel: String? { redoStack.last?.label }

    private var currentEqEdit: EqEdit {
        EqEdit(bands: bands, preGain: preGain, mutedBands: mutedBands,
               enabled: eqEnabled, activePreset: activePreset,
               sourceName: eqSourceName, requested: requestedCorrection,
               sourceCurve: sourceCurve, sourcePreGain: sourcePreGain, label: "")
    }

    private func checkpoint(_ label: String, discrete: Bool = false) {
        guard !suppressUndo else { return }
        let now = Date()
        let continuing = !discrete && label == lastEditLabel
            && now.timeIntervalSince(lastEditAt) < 0.7
        lastEditLabel = label
        lastEditAt = now
        guard !continuing else { return }

        var entry = currentEqEdit
        entry.label = label
        if let top = undoStack.last,
           top.bands == entry.bands, top.preGain == entry.preGain,
           top.mutedBands == entry.mutedBands, top.enabled == entry.enabled { return }
        undoStack.append(entry)
        if undoStack.count > Self.undoDepth { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func beginUndoStep(_ label: String) { checkpoint(label, discrete: true) }

    func undoEqEdit() { step(from: &undoStack, to: &redoStack) }
    func redoEqEdit() { step(from: &redoStack, to: &undoStack) }

    private func step(from source: inout [EqEdit], to destination: inout [EqEdit]) {
        guard canWriteEq, var entry = source.popLast() else { return }
        var here = currentEqEdit
        here.label = entry.label
        destination.append(here)
        if destination.count > Self.undoDepth { destination.removeFirst() }

        suppressUndo = true
        defer { suppressUndo = false; lastEditLabel = ""; lastEditAt = .distantPast }
        activePreset = entry.activePreset
        eqSourceName = entry.sourceName
        requestedCorrection = entry.requested
        sourceCurve = entry.sourceCurve
        sourcePreGain = entry.sourcePreGain
        mutedBands = entry.mutedBands
        if eqEnabled != entry.enabled {
            setEqEnabled(entry.enabled, persistToFlash: false)
        }
        setPreGain(entry.preGain, persistToFlash: false)
        for (i, band) in entry.bands.enumerated() where i < bandCount {
            guard bands.indices.contains(i), bands[i] != band else { continue }
            updateBand(i, band, persistToFlash: false)
        }
        mutedBands = entry.mutedBands
        entry.label = ""
    }

    private func reclaimMutedBands() {
        guard mutedBands.isEmpty, let snap = eqSnapshot, !snap.mutedBands.isEmpty
        else { return }
        let usable = snap.mutedBands.filter { index, shape in
            shape != .bypass && bands.indices.contains(index)
                && bands[index].filter == .bypass
        }
        guard !usable.isEmpty else { return }
        mutedBands = usable
        DebugLog.shared.log("reclaimed \(usable.count) muted band(s) from the last session")
    }
    private var snapshotWork: DispatchWorkItem?
    private var saveAllWork: DispatchWorkItem?
    private var restoreDecidedGroups: Set<UInt8> = []
    private var preGainRepaired = false
    private var presetRead = false
    @Published private(set) var sawEqMode = false
    private var volumeKnown = false
    private var slotReportSeen = false
    private var slotWaitExpired = false
    private var slotWaitTask: Task<Void, Never>?
    var slotReportWait: TimeInterval = 2
    private var eqSourceName: String?
    private var sourceCurve: [QxEqBandValue]?
    private var sourcePreGain: Double?

    var curveMatchesSource: Bool {
        guard let curve = sourceCurve, let gain = sourcePreGain,
              curve.count == bands.count, abs(gain - preGain) < 0.06 else { return false }
        for (a, b) in zip(curve, bands) {
            if a.filter != b.filter || a.freq != b.freq { return false }
            if abs(a.gain - b.gain) > 0.06 || abs(a.q - b.q) > 0.02 { return false }
        }
        return true
    }
    private var packetLogWindow = Date.distantPast
    private var packetsLoggedThisSecond = 0
    private var suppressedPackets = 0
    private var lastImplausibleDump = Date.distantPast
    private var lastStateLogLine = ""

    private func eqEdited(persistToFlash: Bool = true) {
        snapshotWork?.cancel()
        let snap = DispatchWorkItem { [weak self] in self?.snapshotNow() }
        snapshotWork = snap
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: snap)

        guard persistToFlash else { return }
        saveAllWork?.cancel()
        let persist = DispatchWorkItem { [weak self] in
            guard let self, self.canWrite else { return }
            DebugLog.shared.log("asking the device to persist settings")
            self.saveAllWork = nil
            self.transportSend(.saveAll)
        }
        saveAllWork = persist
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: persist)
    }

    private func eqObserved() {
        snapshotWork?.cancel()
        let snap = DispatchWorkItem { [weak self] in self?.snapshotNow() }
        snapshotWork = snap
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: snap)
    }

    private func flushPendingSnapshot() {
        guard let work = snapshotWork, !work.isCancelled else { return }
        work.cancel()
        snapshotWork = nil
        snapshotNow()
    }

    func flushEqSnapshot() {
        snapshotWork?.cancel()
        snapshotNow()
    }

    private func snapshotNow() {
        guard presetRead, case .connected = connection else { return }
        let snap = EqSnapshot(groupRaw: eqGroup.rawValue, bands: bands,
                              preGain: preGain, enabled: eqEnabled,
                              name: eqSourceName, mutedBands: mutedBands,
                              deviceIdentity: deviceIdentity,
                              activePreset: slotReportSeen ? activePreset
                                                           : eqSnapshot?.activePreset)
        guard snap != eqSnapshot else { return }
        eqSnapshots.set(snap)
        EqSnapshotFile.save(eqSnapshots, to: eqSnapshotURL)
    }

    @discardableResult
    private func restoreIfNeeded(readBackUnreadable: Bool = false) -> Bool {
        guard !restoreDecidedGroups.contains(eqGroup.rawValue),
              presetRead || readBackUnreadable,
              compatibility.canWrite,
              pendingGroup == nil, pendingEqMode == nil else { return false }
        if eqSnapshot == nil, !eqSnapshots.isEmpty, !sawEqMode {
            return false
        }
        if !slotReportSeen, !slotWaitExpired, !readBackUnreadable, eqSnapshot != nil {
            awaitSlotReport()
            return false
        }
        restoreDecidedGroups.insert(eqGroup.rawValue)
        if let snap = eqSnapshots[eqGroup.rawValue],
           snap.deviceIdentity == nil
               || snap.deviceIdentity.map(Self.canonicalIdentity) != deviceIdentity {
            DebugLog.shared.log("not restoring: that curve was saved from a different device")
            return false
        }
        guard let snap = eqSnapshot,
              snap.bands.count == bandCount,
              readBackUnreadable || !snap.matches(bands: bands, preGain: preGain)
        else { return false }
        if let saved = snap.activePreset, let now = activePreset, saved != now {
            DebugLog.shared.log("not restoring: the device is on slot \(now + 1) now, "
                + "the saved curve was on slot \(saved + 1)")
            return false
        }
        DebugLog.shared.log("device EQ differs from last seen — restoring")
        if !readBackUnreadable { checkpoint("restore last EQ", discrete: true) }
        suppressUndo = true
        defer { suppressUndo = false }
        transportSend(.setEqType, [eqGroup.rawValue, 1])
        setPreGain(snap.preGain, persistToFlash: false, force: readBackUnreadable)
        for (i, band) in snap.bands.enumerated() {
            updateBand(i, band, persistToFlash: false, force: readBackUnreadable)
        }
        if eqEnabled != snap.enabled { setEqEnabled(snap.enabled, persistToFlash: false) }
        lastImportSummary = "Restored your last EQ"
            + (snap.name.map { ": \($0)" } ?? "")
        return true
    }

    private func awaitSlotReport() {
        guard slotWaitTask == nil else { return }
        let generation = handshakeGeneration
        let group = eqGroup
        slotWaitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.slotReportWait ?? 0))
            guard let self, !Task.isCancelled, generation == self.handshakeGeneration,
                  group == self.eqGroup else { return }
            self.slotWaitTask = nil
            self.slotWaitExpired = true
            self.restoreIfNeeded()
        }
    }

    private var assembler = QxPresetAssembler()
    private var state = QxDeviceState()
    private var requestedNames = false
    private var handshakeAttempt = 0
    private var handshakeGeneration = 0

    private func installTransportHandlers() {
        hid.onDeviceConnected = { [weak self] name in
            Task { @MainActor in
                guard let self else { return }
                self.flushPendingSnapshot()
                self.usbWired = true
                self.link = .usb
                self.ble.setScanSuspended(true)
                self.ble.clearPending()
                self.deviceConnected(name)
            }
        }
        hid.onDeviceRemoved = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.usbWired = false
                self.ble.setScanSuspended(false)
                guard self.link == .usb else { return }
                self.flushPendingSnapshot()
                self.link = .none
                self.connection = .disconnected
                self.resetDeviceState()
                if self.ble.isConnected { self.adoptBluetooth() }
            }
        }
        hid.onLinkUnusable = { [weak self] in
            Task { @MainActor in
                guard let self, self.link == .usb else { return }
                DebugLog.shared.log("USB stopped accepting reports — releasing the link")
                self.ble.setScanSuspended(false)
                self.flushPendingSnapshot()
                self.link = .none
                self.connection = .disconnected
                self.resetDeviceState()
                if self.ble.isConnected { self.adoptBluetooth() }
            }
        }
        hid.onInputReport = { [weak self] _, bytes in
            Task { @MainActor in
                guard let self, self.link == .usb else { return }
                self.handlePacket(bytes)
            }
        }

        ble.onConnected = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshBluetoothPinState()
                guard self.link != .usb else { return }
                self.flushPendingSnapshot()
                self.adoptBluetooth()
            }
        }
        ble.onDisconnected = { [weak self] in
            Task { @MainActor in
                guard let self, self.link == .bluetooth else { return }
                self.flushPendingSnapshot()
                self.link = .none
                self.connection = .disconnected
                self.resetDeviceState()
            }
        }
        ble.onPacket = { [weak self] bytes in
            Task { @MainActor in
                guard let self, self.link == .bluetooth else { return }
                self.handlePacket(bytes)
            }
        }
    }

    func start() {
        installTransportHandlers()
        hid.start()
        ble.start()
        hasPinnedBluetoothDevice = ble.hasPinnedDevice
    }

    #if DEBUG
    func debugInstallHandlers() { installTransportHandlers() }
    func debugIngest(_ bytes: [UInt8]) { handlePacket(bytes) }
    func debugFireUSBAttached(_ name: String) { hid.onDeviceConnected?(name) }
    func debugFireUSBDetached() { hid.onDeviceRemoved?() }
    func debugFireUSBUnusable() { hid.onLinkUnusable?() }
    func debugFireBluetoothConnected() { ble.onConnected?("Qudelix-5K") }
    func debugFireBluetoothDisconnected() { ble.onDisconnected?() }
    var debugFlashSavePending: Bool { saveAllWork.map { !$0.isCancelled } ?? false }
    #endif

    private func resetDeviceState() {
        snapshotWork?.cancel()
        saveAllWork?.cancel()
        undoStack.removeAll()
        redoStack.removeAll()
        preGainRepaired = false
        compatibility = .checking
        receivingReports = false
        firmwareVersion = nil
        batteryLog.recordGap()
        batteryPercent = nil
        charging = false
        chargerConnected = false
        batteryLow = false
        chargerState = nil
        dacState = nil
        chargerEnabled = nil
        batteryCare = nil
        sampleRate = nil
        inputSource = nil
        activeCall = nil
        codecLabel = nil
        outputHighGain = nil
        muted = false
        activePreset = nil
        presetNames = [:]
        usbFsMode = nil
        lastImportSummary = nil
        requestedNames = false
        pendingGroup = nil
        pendingEqMode = nil
        restoreDecidedGroups = []
        presetRead = false
        if sawEqMode { sawEqMode = false }
        slotReportSeen = false
        slotWaitExpired = false
        slotWaitTask?.cancel()
        slotWaitTask = nil
        eqSourceName = nil
        sourceCurve = nil
        sourcePreGain = nil
        lastImportSummary = nil
        requestedCorrection = nil
        batteryAlerts.connectionReset()
        state = QxDeviceState()

        volumeDb = -30
        volumeKnown = false
        volumeMax = 0
        trimLeftDb = 0
        trimRightDb = 0
        volumeLimitDb = 0
        volumeFieldEditUntil = .distantPast
        levelEditUntil = .distantPast
        lastPresetRefresh = .distantPast
        eqEnableEditUntil = .distantPast
        dacFilterType = nil
        dacFilterEditUntil = .distantPast
        crossfeedLevel = nil
        eqGroup = .user
        assembler.group = .user
        assembler.reset()
        lastGroupSwitch = .distantPast
        bands = QxEq.defaultFreqs.map { QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1.0) }
        preGain = 0
        eqEnabled = true
        mutedBands = [:]
    }

    @Published private(set) var hasPinnedBluetoothDevice = false

    func refreshBluetoothPinState() {
        let pinned = ble.hasPinnedDevice
        if hasPinnedBluetoothDevice != pinned { hasPinnedBluetoothDevice = pinned }
    }

    func forgetBluetoothDevice() {
        ble.forgetPinnedDevice()
        hasPinnedBluetoothDevice = ble.hasPinnedDevice
        if link == .bluetooth {
            flushPendingSnapshot()
            link = .none
            connection = .disconnected
            resetDeviceState()
        }
        ble.disconnectAndRescan()
    }

    private func adoptBluetooth() {
        link = .bluetooth
        hasPinnedBluetoothDevice = ble.hasPinnedDevice
        DebugLog.shared.log("link → bluetooth (vendor \(ble.vendor.label))")
        deviceConnected("Qudelix 5K")
    }

    private func deviceConnected(_ name: String) {
        connection = .connected(name: name)
        handshakeAttempt = 0
        handshakeGeneration += 1
        resetDeviceState()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.sendHandshake()
        }
    }

    private func sendHandshake() {
        handshakeAttempt += 1
        let generation = handshakeGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, generation == self.handshakeGeneration,
                  !self.receivingReports, self.handshakeAttempt < 3,
                  case .connected = self.connection else { return }
            DebugLog.shared.log("no response — retrying handshake (\(self.handshakeAttempt + 1))")
            self.sendHandshake()
        }

        transportSend(.reqInitData, QxInit.requestPayload)
        transportSend(.reqDevConfig, [QxConfigMask.sys | QxConfigMask.playTime
                                 | QxConfigMask.dac | QxConfigMask.mic | QxConfigMask.batt])
        transportSend(.reqDevConfig, [0xC0])
        transportSend(.reqDevStatus, [QxStatusMask.audio | QxStatusMask.power
                                 | QxStatusMask.conn | QxStatusMask.vol])
        transportSend(.reqEqPreset, [eqGroup.requestMask])
    }

    private func handlePacket(_ bytes: [UInt8]) {
        guard bytes.count >= 3 else { return }
        guard let (cmdId, data) = QxPacket.parseRx(bytes) else { return }
        if !receivingReports { receivingReports = true }
        dispatch(cmdId, data)
    }

    private func dispatch(_ cmdId: UInt16, _ data: [UInt8]) {
        if packetLogWindow.timeIntervalSinceNow < -1 {
            if suppressedPackets > 0 {
                DebugLog.shared.log("… \(suppressedPackets) further packets not logged")
            }
            packetLogWindow = Date()
            packetsLoggedThisSecond = 0
            suppressedPackets = 0
        }
        if packetsLoggedThisSecond < 40 {
            packetsLoggedThisSecond += 1
            DebugLog.shared.rx(cmdId, data)
        } else {
            suppressedPackets += 1
        }

        switch QxCmd(rawValue: cmdId) {
        case .rspInitData:
            if QxStatusParser.parseInitData(data, into: &state) { applyState() }
        case .rspDevStatus:
            _ = QxStatusParser.parseDevStatus(data, into: &state)
            applyState()
        case .rspDevConfig:
            _ = QxStatusParser.parseDevConfig(data, into: &state)
            applyState()
        case .rspEqPreset, .rspEqPresetL, .rspEqPresetH:
            if assembler.ingest(data) {
                applyPreset(QxUserEqPreset.decode(assembler.buffer, group: eqGroup))
                assembler.reset()
            }
        case .rspEqPresetName:
            parsePresetName(data)
        case .notification:
            parseNotification(data)
        default:
            break
        }
    }

    private func parseNotification(_ data: [UInt8]) {
        guard data.count >= 2 else { return }
        if data[0] >= 128 {
            let group = data[1]
        guard group == eqGroup.rawValue else { return }
            switch data[0] {
            case 129: if data.count >= 3 { setActivePreset(Int(data[2])) }
            case 130:
                if data.count >= 3, Date() >= eqEnableEditUntil, eqEnabled != (data[2] != 0) {
                    eqEnabled = data[2] != 0
                }
            default: break
            }
        } else {
            let flags = data[1]
            var off = 2
            if flags & QxNotifyMask.status != 0 {
                off += QxStatusParser.parseDevStatus(data.tail(from: off), into: &state)
            }
            if flags & QxNotifyMask.config != 0 {
                _ = QxStatusParser.parseDevConfig(data.tail(from: off), into: &state)
            }
            applyState()
        }
    }

    private func parsePresetName(_ data: [UInt8]) {
        guard data.count >= 3, data[0] == eqGroup.rawValue else { return }
        let idx = Int(data[1])
        guard (0..<Self.presetCount).contains(idx) else { return }
        let end = min(Int(data[2]), data.count)
        guard end > 3 else {
            if presetNames[idx] != nil { presetNames[idx] = nil }
            return
        }
        let nameBytes = data[3..<end].prefix { $0 != 0 }
        guard let raw = String(bytes: nameBytes, encoding: .utf8) else { return }
        let name = Self.displayName(raw)
        let stored = name.isEmpty ? nil : name
        if presetNames[idx] != stored { presetNames[idx] = stored }
    }

    nonisolated static let maxPresetNameLength = 32

    nonisolated static func displayName(_ s: String,
                                        limit: Int = maxPresetNameLength) -> String {
        let s = SafeText.scrubbed(
            String(String.UnicodeScalarView(s.unicodeScalars.prefix(limit * 4))),
            limit: limit * 4)
        let kept = s.unicodeScalars.filter { u in
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }
        return String(String.UnicodeScalarView(kept))
            .trimmingCharacters(in: .whitespaces)
            .prefix(limit)
            .trimmingCharacters(in: .whitespaces)
    }

    private func evaluateCompatibility() {
        guard state.deviceId != 0, let major = state.fwMajor else { return }

        if state.deviceId != QxDeviceModel.qudelix5K {
            let known = QxDeviceModel.name(for: state.deviceId)
            setCompatibility(.unsupported(
                title: "\(known) isn't supported",
                detail: "This app implements the original Qudelix 5K protocol. "
                      + "\(known) uses a different EQ command set, so nothing will be written."))
            return
        }
        if major < 2 {
            setCompatibility(.unsupported(
                title: "Firmware \(state.fwVersion ?? "?") is too old",
                detail: "Update the 5K with the official Qudelix app, then reconnect."))
            return
        }
        if major == 2 {
            setCompatibility(.unsupported(
                title: "Firmware \(state.fwVersion ?? "2.x") uses a different protocol",
                detail: "Qudelix changed the EQ command format in firmware 3. "
                      + "Update with the official app, then reconnect."))
            return
        }
        setCompatibility(.ok)
    }

    private func setCompatibility(_ value: Compatibility) {
        if compatibility != value { compatibility = value }
    }

    private func applyState() {
        evaluateCompatibility()
        if compatibility.canWrite { restoreIfNeeded() }
        if let mode = state.eqMode {
            if !sawEqMode { sawEqMode = true }
            setEqGroup(mode == 1 ? .b20 : .user)
            state.eqMode = nil
        }
        if let fw = state.fwVersion, fw != firmwareVersion { firmwareVersion = fw }
        if let b = state.batteryPercent, b != batteryPercent { batteryPercent = b }
        if charging != state.charging { charging = state.charging }
        if chargerConnected != state.chargerConnected {
            chargerConnected = state.chargerConnected
        }
        if let low = state.batteryLow, low != batteryLow { batteryLow = low }
        if let cs = state.chargerState, cs != chargerState { chargerState = cs }
        if let ds = state.dacState, ds != dacState { dacState = ds }
        if let ce = state.chargerEnabled, ce != chargerEnabled { chargerEnabled = ce }
        if let bc = state.batteryCare, bc != batteryCare { batteryCare = bc }
        batteryAlerts.update(batteryPercent: batteryPercent, charging: charging,
                             deviceSaysLow: batteryLow ?? false)
        if let b = batteryPercent { batteryLog.record(percent: b, charging: charging) }
        if let sr = state.sampleRateLabel, sr != sampleRate { sampleRate = sr }
        if let src = state.inputSourceLabel, src != inputSource { inputSource = src }
        if let call = state.activeCall, call != activeCall { activeCall = call }
        let codec = link == .bluetooth ? state.codecLabel : nil
        if codec != codecLabel { codecLabel = codec }
        if let gain = state.outputHighGain, gain != outputHighGain {
            outputHighGain = gain
        }
        if let m = state.usbMute, m != muted, Date() >= levelEditUntil { muted = m }
        if let fs = state.usbFsMode, fs != usbFsMode { usbFsMode = fs }
        let eqCfgApplies = state.eqCfgGroup == Int(eqGroup.rawValue)
        if let en = state.eqEnabled, eqCfgApplies, Date() >= eqEnableEditUntil,
           en != eqEnabled {
            eqEnabled = en
        }
        if let idx = state.eqPresetIdx, eqCfgApplies { setActivePreset(idx) }
        if let f = state.dacFilterType, Date() >= dacFilterEditUntil, f != dacFilterType {
            dacFilterType = f
        }
        if Date() >= volumeFieldEditUntil {
            if let l = state.trimLeftDb, l != trimLeftDb { trimLeftDb = l }
            if let r = state.trimRightDb, r != trimRightDb { trimRightDb = r }
            if let lim = state.volumeLimitDb, lim != volumeLimitDb { volumeLimitDb = lim }
        } else {
            state.volumeLimitDb = volumeLimitDb
        }
        recomputeVolumeMax()
        if let v = state.volumeDb, Date() >= levelEditUntil {
            let level = min(max(v, volumeRange.lowerBound), volumeRange.upperBound)
            if level != volumeDb { volumeDb = level }
            volumeKnown = true
        }

        state.volumeDb = nil
        state.usbMute = nil
        state.eqEnabled = nil
        state.eqPresetIdx = nil
        state.trimLeftDb = nil
        state.trimRightDb = nil

        let compat: String
        switch compatibility {
        case .checking: compat = "checking"
        case .ok: compat = "ok"
        case .unsupported(let t, _): compat = "UNSUPPORTED(\(t))"
        }
        let stateLine = "compat=\(compat) model=\(state.deviceId)"
            + " | fw=\(firmwareVersion ?? "?") batt=\(batteryPercent.map { "\($0)%" } ?? "?")"
            + (batteryLow ? " LOW" : "")
            + " chg=\(chargerConnected ? (charging ? "on" : "idle") : "off")"
            + "/\(chargerState.map(String.init) ?? "?")"
            + " chgEn=\(chargerEnabled.map { $0 ? "1" : "0" } ?? "?")"
            + " care=\(batteryCare.map { $0 ? "1" : "0" } ?? "?")"
            + " dacState=\(dacState.map(String.init) ?? "?")"
            + " vol=\(String(format: "%.1fdB", volumeDb))"
            + " max=\(String(format: "%.0f", volumeMax)) sr=\(sampleRate ?? "?") src=\(inputSource ?? "?")"
            + " eq=\(eqEnabled ? "on" : "off") preset=\(activePreset.map(String.init) ?? "?")"
            + " nameMask=\(String(state.presetNameMask, radix: 2))"
        if stateLine != lastStateLogLine {
            lastStateLogLine = stateLine
            DebugLog.shared.log(stateLine)
        }

        if !requestedNames, pendingGroup == nil, eqCfgApplies, state.presetNameMask != 0 {
            requestedNames = true
            for i in 0..<Self.presetCount where state.presetNameMask & (1 << i) != 0 {
                transportSend(.reqEqPresetName, [eqGroup.rawValue, UInt8(i)])
            }
        }
    }

    func applyPreset(_ p: QxUserEqPreset) {
        guard p.bands.count == bandCount else { return }
        guard p.looksPlausible else {
            DebugLog.shared.log("preset decode implausible for group \(eqGroup) — ignoring")
            if restoreIfNeeded(readBackUnreadable: true) { presetRead = true }
            if Date().timeIntervalSince(lastImplausibleDump) > 10 {
                lastImplausibleDump = Date()
                let hex = assembler.buffer.map { String(format: "%02X", $0) }.joined(separator: " ")
                DebugLog.shared.log("raw preset buffer: \(hex)")
                let decoded = p.bands.map { String(format: "f%d g%.1f q%.2f %d",
                                                   $0.freq, $0.gain, $0.q, $0.filter.rawValue) }
                DebugLog.shared.log("decoded: preGain \(p.preGain) | " + decoded.joined(separator: " · "))
            }
            return
        }
        let readBackPreGain = EQHeadroom.clamp(p.preGain)
        if preGain != readBackPreGain { preGain = readBackPreGain }
        if abs(p.preGain - p.preGainCh1) > 0.06, canWriteEq, !preGainRepaired {
            preGainRepaired = true
            DebugLog.shared.log(String(
                format: "pre-gain channels disagree (%.1f / %.1f dB) — evening them up",
                p.preGain, p.preGainCh1))
            sendPreGain(Int((preGain * QxScale.gain).rounded()))
        }
        if crossfeedLevel != p.crossfeedLevel { crossfeedLevel = p.crossfeedLevel }
        let readBackBands = p.bands.map { band in
            var v = band
            v.freq = max(20, min(20000, v.freq))
            v.gain = v.gain.isFinite ? max(-12, min(12, v.gain)) : 0
            v.q = v.q.isFinite ? max(0.1, min(10, v.q)) : 1.0
            return v
        }
        if bands != readBackBands { bands = readBackBands }
        let surviving = mutedBands.filter { index, _ in
            bands.indices.contains(index) && bands[index].filter == .bypass
        }
        if surviving != mutedBands { mutedBands = surviving }
        reclaimMutedBands()
        presetRead = true
        restoreIfNeeded()
        eqObserved()
    }

    #if DEBUG
    func applyPreviewGroup(_ group: QxEqGroup) {
        eqGroup = group
        assembler.group = group
    }
    #endif

    private func setActivePreset(_ idx: Int) {
        let alreadyReported = slotReportSeen
        slotReportSeen = true
        defer { restoreIfNeeded() }
        if idx == 255 {
            if activePreset != nil { activePreset = nil }
            return
        }
        guard (0..<Self.presetCount).contains(idx) else { return }
        if activePreset != idx {
            activePreset = idx
            if alreadyReported, presetRead { refreshPresetFromDevice() }
        }
    }

    private var lastPresetRefresh = Date.distantPast

    private func refreshPresetFromDevice() {
        guard canWrite, pendingGroup == nil, pendingEqMode == nil,
              Date().timeIntervalSince(lastPresetRefresh) > 1 else { return }
        lastPresetRefresh = Date()
        assembler.reset()
        transportSend(.reqEqPreset, [eqGroup.requestMask])
    }

    private var lastGroupSwitch = Date.distantPast
    private var pendingGroup: QxEqGroup?
    private static let groupSwitchInterval: TimeInterval = 1

    private func setEqGroup(_ group: QxEqGroup) {
        pendingEqMode = nil
        guard group != eqGroup else { pendingGroup = nil; return }
        flushPendingSnapshot()
        let wait = Self.groupSwitchInterval - Date().timeIntervalSince(lastGroupSwitch)
        if wait > 0 {
            guard pendingGroup != group else { return }
            pendingGroup = group
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, let queued = self.pendingGroup else { return }
                self.pendingGroup = nil
                self.setEqGroup(queued)
            }
            return
        }
        pendingGroup = nil
        lastGroupSwitch = Date()
        DebugLog.shared.log("EQ group → \(group) (\(group.bandCount) bands)")
        undoStack.removeAll()
        redoStack.removeAll()
        eqGroup = group
        assembler.group = group
        assembler.reset()
        bands = group.defaultFreqs.map {
            QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1.0)
        }
        requestedNames = false
        presetNames = [:]
        activePreset = nil
        slotReportSeen = false
        slotWaitExpired = false
        slotWaitTask?.cancel()
        slotWaitTask = nil
        eqSourceName = nil
        sourceCurve = nil
        sourcePreGain = nil
        lastImportSummary = nil
        requestedCorrection = nil
        crossfeedLevel = nil
        mutedBands = [:]
        presetRead = false
        transportSend(.reqEqPreset, [group.requestMask])
        transportSend(.reqDevConfig, [0xC0])
    }

    var reportedVolumeDb: Double? {
        guard case .connected = connection, receivingReports, volumeKnown, !muted,
              volumeDb.isFinite else { return nil }
        return min(max(volumeDb, volumeRange.lowerBound), volumeRange.upperBound)
    }

    private var canWrite: Bool {
        if case .connected = connection { return compatibility.canWrite }
        return false
    }

    private var canWriteEq: Bool {
        guard canWrite else { return false }
        guard pendingGroup == nil, pendingEqMode == nil else {
            DebugLog.shared.log("EQ write dropped: group switch in progress")
            return false
        }
        return true
    }

    func setVolume(_ db: Double) {
        guard canWrite, db.isFinite else { return }
        let clamped = max(volumeMax - 60, min(volumeMax, db))
        volumeDb = clamped
        levelEditUntil = Date().addingTimeInterval(Self.volumeEchoWindow)
        let scaled = Int((clamped * QxScale.volume).rounded())
        transportSendCoalesced(.setVolume,
                          [QxVolumeParam.sink.rawValue] + QxPacket.int16BE(scaled),
                          key: "volume")
    }

    func setMute(_ on: Bool) {
        guard canWrite else { return }
        muted = on
        levelEditUntil = Date().addingTimeInterval(Self.volumeEchoWindow)
        transportSend(.setVolume, [QxVolumeParam.mute.rawValue, 0, on ? 1 : 0])
    }

    private static let volumeEchoWindow: TimeInterval = 1.5
    private var volumeFieldEditUntil = Date.distantPast
    private var levelEditUntil = Date.distantPast

    var canWriteNow: Bool { canWrite }

    var canEditEqNow: Bool { canWriteEq }

    var trimRange: ClosedRange<Double> { QxVolumeRange.trim }
    var volumeLimitRange: ClosedRange<Double> { QxVolumeRange.limit }

    func setTrimLeft(_ db: Double) { setTrim(.sysTrimL, db) }
    func setTrimRight(_ db: Double) { setTrim(.sysTrimR, db) }

    private func setTrim(_ param: QxVolumeParam, _ db: Double) {
        guard canWrite, let payload = QxPacket.volumePayload(param, db: db) else { return }
        let clamped = param.clamp(db)
        if param == .sysTrimL { trimLeftDb = clamped } else { trimRightDb = clamped }
        volumeFieldEditUntil = Date().addingTimeInterval(Self.volumeEchoWindow)
        transportSendCoalesced(.setVolume, payload, key: "trim\(param.rawValue)")
    }

    func setVolumeLimit(_ db: Double) {
        guard canWrite,
              let payload = QxPacket.volumePayload(.sysLimit, db: db) else { return }
        let clamped = QxVolumeParam.sysLimit.clamp(db)
        volumeLimitDb = clamped
        state.volumeLimitDb = clamped
        volumeFieldEditUntil = Date().addingTimeInterval(Self.volumeEchoWindow)
        recomputeVolumeMax()
        transportSendCoalesced(.setVolume, payload, key: "volumeLimit")
    }

    private func recomputeVolumeMax() {
        let ceiling = state.dacOutPwr2Vrms ? min(state.volumeLimitDb ?? 6, 6)
                                           : min(state.volumeLimitDb ?? 0, 0)
        if volumeMax != ceiling { volumeMax = ceiling }
        let level = min(max(volumeDb, volumeRange.lowerBound), volumeRange.upperBound)
        if level != volumeDb { volumeDb = level }
    }

    static let usbFsModeLabels = ["96 kHz only", "88.2 kHz only", "48 kHz only",
                                  "44.1 kHz only", "All rates",
                                  "48 kHz + mic", "44.1 kHz + mic"]

    func setUsbFsMode(_ idx: Int) {
        guard canWrite, (0...6).contains(idx), idx != usbFsMode else { return }
        DebugLog.shared.log("requesting USB FS mode → \(Self.usbFsModeLabels[idx])")
        usbFsMode = idx
        transportSend(.setUsbFsMode, [UInt8(idx)])
    }

    private var dacFilterEditUntil = Date.distantPast

    func setDacFilter(_ index: Int) {
        guard canWrite, let payload = QxPacket.dacFilterPayload(index) else { return }
        dacFilterType = index
        dacFilterEditUntil = Date().addingTimeInterval(1.5)
        transportSend(.setDacFilter, payload)
    }

    private var eqEnableEditUntil = Date.distantPast

    func setEqEnabled(_ on: Bool, persistToFlash: Bool = true) {
        guard canWriteEq else { return }
        eqEnabled = on
        eqEnableEditUntil = Date().addingTimeInterval(1.5)
        transportSend(.setEqEnable, [eqGroup.rawValue, on ? 1 : 0])
        eqEdited(persistToFlash: persistToFlash)
    }

    private var pendingEqMode: QxEqGroup?
    private var lastEqModeSend = Date.distantPast
    private var eqModeSerial = 0
    var eqModeRetryDelays: [TimeInterval] = [1, 2, 2]

    func setEqMode(twentyBand: Bool) {
        guard canWrite else { return }
        let desired: QxEqGroup = twentyBand ? .b20 : .user
        guard desired != (pendingEqMode ?? eqGroup) else { return }
        guard Date().timeIntervalSince(lastEqModeSend) > 0.3 else { return }
        lastEqModeSend = Date()
        flushPendingEqSends()
        eqModeSerial += 1
        let serial = eqModeSerial
        let delays = eqModeRetryDelays
        pendingEqMode = desired == eqGroup ? nil : desired
        DebugLog.shared.log("requesting EQ mode → \(twentyBand ? "20-band" : "10-band")")
        transportSend(.setEqMode, [twentyBand ? 1 : 0])
        Task { @MainActor [weak self] in
            for (index, delay) in delays.enumerated() {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.pendingEqMode != nil, self.eqModeSerial == serial else { return }
                if index < delays.count - 1 {
                    self.transportSend(.reqDevConfig, [QxConfigMask.sys])
                } else {
                    DebugLog.shared.log("EQ mode switch went unanswered — unlocking EQ writes")
                    self.pendingEqMode = nil
                }
            }
        }
    }

    @discardableResult
    func loadPreset(_ index: Int) -> Bool {
        guard canWriteEq, (0..<Self.presetCount).contains(index) else { return false }
        flushPendingEqSends()
        checkpoint("load \(presetLabel(index))", discrete: true)
        eqSourceName = presetLabel(index)
        requestedCorrection = nil
        sourceCurve = nil
        sourcePreGain = nil
        activePreset = index
        mutedBands = [:]
        assembler.reset()
        transportSend(.loadEqPreset, [UInt8(index)])
        transportSend(.reqEqPreset, [eqGroup.requestMask])
        return true
    }

    func presetLabel(_ index: Int) -> String {
        presetNames[index] ?? "Preset \(index + 1)"
    }

    func flatten() {
        guard canWriteEq else { return }
        checkpoint("flatten", discrete: true)
        suppressUndo = true
        defer { suppressUndo = false }
        forgetSource()
        setPreGain(0)
        for i in 0..<bandCount where bands.indices.contains(i) {
            var b = bands[i]
            guard b.gain != 0 else { continue }
            b.gain = 0
            updateBand(i, b)
        }
        lastImportSummary = "Band gains zeroed"
    }

    func resetBandLayout() {
        guard canWriteEq else { return }
        checkpoint("reset band layout", discrete: true)
        suppressUndo = true
        defer { suppressUndo = false }
        forgetSource()
        setPreGain(0)
        let defaults = eqGroup.defaultFreqs
        for i in 0..<bandCount where defaults.indices.contains(i) {
            updateBand(i, QxEqBandValue(filter: .peak, freq: defaults[i], gain: 0, q: 1.0))
        }
        lastImportSummary = "Band layout reset"
    }

    func zeroBand(_ index: Int) {
        guard canWriteEq, bands.indices.contains(index), index < bandCount else { return }
        var b = bands[index]
        if b.filter != .bypass, !b.filter.hasGain { b.filter = .peak }
        b.gain = 0
        guard b != bands[index] else { return }
        checkpoint("zero band \(index + 1)", discrete: true)
        suppressUndo = true
        defer { suppressUndo = false }
        updateBand(index, b)
    }

    private func forgetSource() {
        eqSourceName = nil
        sourceCurve = nil
        sourcePreGain = nil
        lastImportSummary = nil
        requestedCorrection = nil
    }

    func savePreset(_ index: Int) {
        guard canWriteEq, (0..<Self.presetCount).contains(index) else { return }
        flushPendingEqSends()
        transportSend(.saveEqPreset, [UInt8(index)])
        if let name = Self.nameOnSave(source: eqSourceName,
                                      existing: presetNames[index],
                                      unchangedSinceSource: curveMatchesSource) {
            setPresetName(index, name)
        }
    }

    nonisolated static func nameOnSave(source: String?, existing: String?,
                                       unchangedSinceSource: Bool) -> String? {
        guard unchangedSinceSource else { return nil }
        guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty else { return nil }
        guard source != existing else { return nil }
        return source
    }

    func setPresetName(_ index: Int, _ name: String) {
        guard canWriteEq,
              let payload = QxPacket.presetNamePayload(
                  group: eqGroup, index: index,
                  name: Self.displayName(name)) else { return }

        let stored = QxPacket.truncatingUTF8(Self.displayName(name),
                                             to: QxPacket.maxPresetNameBytes)
        if stored.isEmpty { presetNames[index] = nil } else { presetNames[index] = stored }

        transportSend(.setEqPresetName, payload)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.canWriteEq else { return }
            self.transportSend(.reqEqPresetName, [self.eqGroup.rawValue, UInt8(index)])
        }
    }

    func setPreGain(_ db: Double, persistToFlash: Bool = true, recordUndo: Bool = true,
                    force: Bool = false) {
        guard canWriteEq, db.isFinite else { return }
        let clamped = EQHeadroom.clamp(db)
        guard force || clamped != preGain else { return }
        if recordUndo { checkpoint("pre-gain") }
        preGain = clamped
        sendPreGain(Int((clamped * QxScale.gain).rounded()))
        eqEdited(persistToFlash: persistToFlash)
    }

    var eqHeadroom: EQHeadroom.Advice {
        if let memo = headroomMemo, memo.preGain == preGain, memo.bands == bands {
            return memo.advice
        }
        let advice = EQHeadroom.advice(for: bands, preGain: preGain)
        headroomComputations += 1
        headroomMemo = HeadroomMemo(bands: bands, preGain: preGain, advice: advice)
        return advice
    }

    private struct HeadroomMemo {
        var bands: [QxEqBandValue]
        var preGain: Double
        var advice: EQHeadroom.Advice
    }

    private var headroomMemo: HeadroomMemo?

    private(set) var headroomComputations = 0

    func applySuggestedPreGain() {
        guard let db = eqHeadroom.suggestion else { return }
        setPreGain(db)
    }

    func updateBand(_ index: Int, _ value: QxEqBandValue,
                    persistToFlash: Bool = true, recordUndo: Bool = true,
                    force: Bool = false) {
        guard canWriteEq, bands.indices.contains(index), index < bandCount else { return }
        var v = value
        v.freq = max(20, min(20000, v.freq))
        v.gain = v.gain.isFinite ? max(-12, min(12, v.gain)) : 0
        v.q = v.q.isFinite ? max(0.1, min(10, v.q)) : 1.0
        guard force || v != bands[index] else { return }
        guard let payload = QxPacket.bandParamPayload(group: eqGroup, band: index, v) else { return }
        if recordUndo { checkpoint("band \(index + 1)") }
        bands[index] = v
        if v.filter != .bypass, mutedBands[index] != nil { mutedBands[index] = nil }

        transportSendCoalesced(.setEqBandParam, payload, key: "band\(index)")
        eqEdited(persistToFlash: persistToFlash)
    }

    func isBandMuted(_ index: Int) -> Bool {
        guard mutedBands[index] != nil, bands.indices.contains(index) else { return false }
        return bands[index].filter == .bypass
    }

    func setBandMuted(_ index: Int, _ muted: Bool) {
        guard canWriteEq, bands.indices.contains(index), index < bandCount else { return }
        checkpoint(muted ? "mute band \(index + 1)" : "unmute band \(index + 1)",
                   discrete: true)
        suppressUndo = true
        defer { suppressUndo = false }
        if muted {
            let shape = bands[index].filter
            guard shape != .bypass else { return }
            var b = bands[index]
            b.filter = .bypass
            updateBand(index, b, persistToFlash: false)
            guard bands[index].filter == .bypass else { return }
            mutedBands[index] = shape
        } else {
            guard isBandMuted(index), let shape = mutedBands[index] else { return }
            var b = bands[index]
            b.filter = shape
            updateBand(index, b, persistToFlash: false)
        }
    }

    @discardableResult
    func apply(_ file: ParametricEQFile, named name: String? = nil,
               undoLabel: String = "import") -> Bool {
        guard canWriteEq else {
            if case .connected = connection {
                lastImportSummary = "Not applied — this device isn't supported."
            } else {
                lastImportSummary = "Connect the 5K first — nothing was applied."
            }
            return false
        }
        let fitted = file.fitted(toBandCount: bandCount)
        checkpoint(undoLabel, discrete: true)
        suppressUndo = true
        defer { suppressUndo = false }
        eqSourceName = name
        requestedCorrection = file
        mutedBands = [:]
        if !eqEnabled { setEqEnabled(true) }
        transportSend(.setEqType, [eqGroup.rawValue, 1])
        let preamp = max(-12, min(12, fitted.preamp))
        setPreGain(preamp)

        for i in 0..<bandCount {
            guard bands.indices.contains(i) else { break }
            if i < fitted.bands.count {
                var b = fitted.bands[i]
                b.gain = max(-12, min(12, b.gain))
                b.q = max(0.1, min(10, b.q))
                b.freq = max(20, min(20000, b.freq))
                updateBand(i, b)
            } else {
                var b = bands[i]
                b.filter = .bypass
                updateBand(i, b)
            }
        }
        let applied = fitted.bands.count
        let dropped = fitted.droppedBands
        lastImportSummary = (["Applied \(applied) band(s), pre-gain "
            + String(format: "%+.1f dB", preamp)
            + (dropped > 0 ? " · \(dropped) band(s) dropped"
                + (file.bands.count > bandCount && eqGroup != .b20
                   ? " (fit in 20-band mode)" : "") : "")]
            + fitted.notes).joined(separator: " · ")
        DebugLog.shared.log("import: \(lastImportSummary ?? "")")
        sourceCurve = bands
        sourcePreGain = preGain
        return true
    }

    @discardableResult
    func applyLibraryPreset(_ preset: LibraryPreset) -> Bool {
        guard preset.group == eqGroup else { return false }
        var file = ParametricEQFile()
        file.preamp = preset.preGain
        file.bands = preset.bands
        return apply(file, named: preset.name, undoLabel: "apply \(preset.name)")
    }

    var currentSourceName: String? { eqSourceName }

    static let maxImportBytes = 1_000_000

    func importText(_ text: String, named: String? = nil) {
        guard text.utf8.count <= Self.maxImportBytes else {
            lastImportSummary = "That is too much text to be an EQ preset."
            return
        }
        guard let parsed = ParametricEQFile.parse(text) else {
            lastImportSummary = "No EQ filters found in what was pasted."
            return
        }
        apply(parsed, named: named)
    }

    func importFile(at url: URL) {
        let name = SafeText.scrubbed(url.lastPathComponent, limit: 64)
        guard let data = SafeFile.read(url, cap: Self.maxImportBytes) else {
            lastImportSummary = "Couldn't read \(name) — an EQ preset is a plain "
                + "text file, and not a large one."
            return
        }
        guard let text = ParametricEQFile.decodeText(data) else {
            lastImportSummary = "Could not read \(name) as text."
            return
        }
        guard let parsed = ParametricEQFile.parse(text) else {
            lastImportSummary = "No filters found in \(name)"
            return
        }
        apply(parsed, named: url.deletingPathExtension().lastPathComponent)
    }

    func exportText() -> String {
        Self.exportText(bands: bands, preGain: preGain, mutedBands: mutedBands)
    }

    @discardableResult
    func exportFile(to url: URL) -> Bool {
        do {
            try exportText().write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            lastImportSummary = "Couldn't save \(Self.displayName(url.lastPathComponent)) — "
                + "check that the folder is writable and the disk has room."
            return false
        }
    }

    nonisolated static func exportText(bands: [QxEqBandValue], preGain: Double,
                                       mutedBands: [Int: QxFilter] = [:]) -> String {
        var lines = [String(format: "Preamp: %.1f dB", preGain)]
        for (i, b) in bands.enumerated() {
            let shape = b.filter == .bypass ? (mutedBands[i] ?? .bypass) : b.filter
            guard let token = exportToken(for: shape) else { continue }
            lines.append(String(format: "Filter %d: ON %@ Fc %d Hz Gain %.1f dB Q %.2f",
                                i + 1, token, b.freq, b.gain, b.q))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func refreshStatus() {
        guard case .connected = connection else { return }
        transportSend(.reqDevStatus, [QxStatusMask.audio | QxStatusMask.power
                                 | QxStatusMask.conn | QxStatusMask.vol])
    }

    func refresh() {
        guard case .connected = connection else { return }
        refreshStatus()
        transportSend(.reqEqPreset, [eqGroup.requestMask])
    }

    private func sendPreGain(_ scaled: Int) {
        for mask in [UInt8(1), UInt8(2)] {
            transportSendCoalesced(
                .setEqPreGain,
                [eqGroup.rawValue, mask, 0] + QxPacket.int16BE(scaled),
                key: "preGain-\(mask)")
        }
    }

    private func sendEqParam(_ cmd: QxCmd, band: Int, scaled: Int) {
        transportSendCoalesced(cmd,
                          [eqGroup.rawValue, eqGroup.writeChannelMask, UInt8(clamping: band)]
                            + QxPacket.int16BE(scaled),
                          key: "\(cmd)-\(band)")
    }
}
