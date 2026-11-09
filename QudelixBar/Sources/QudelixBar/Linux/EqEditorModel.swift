import Foundation

package enum EqLoadState: Equatable {
    case loading
    case ready
    case failed
}

package struct EqEditorState: Equatable {
    package var ready = false
    package var loadState = EqLoadState.loading
    package var groupLabel = ""
    package var bands: [EqBand] = []
    package var preGain = 0.0
    package var enabled = true
    package var muted: [Int: EqFilterKind] = [:]
    package var selected: Int?
    package var isGraphic = false
    package var canEdit = false
    package var canUndo = false
    package var canRedo = false
    package var undoLabel: String?
    package var redoLabel: String?

    package init() {}

    package var bandCount: Int { bands.count }

    package func isMuted(_ index: Int) -> Bool {
        guard muted[index] != nil, bands.indices.contains(index) else { return false }
        return bands[index].filter == .bypass
    }
}

package struct EqImportResult: Equatable {
    package var accepted: Bool
    package var summary: String

    package init(accepted: Bool, summary: String) {
        self.accepted = accepted
        self.summary = summary
    }
}

@MainActor
package final class EqEditorModel {
    package static let undoDepth = 40
    package static let burstWindow: TimeInterval = 0.7

    private enum WriteKey: Hashable {
        case band(Int)
        case preGain
    }

    private enum WriteValue {
        case band(QxEqBandValue)
        case preGain(Double)
    }

    private unowned let host: AppModel

    private var observers: [Int: (EqEditorState) -> Void] = [:]
    private var nextObserverID = 0
    package private(set) var state = EqEditorState()

    private var group: QxEqGroup = .user
    private var identity: String?
    private var activeSlot: Int?
    private var activeName: String?
    private var bands: [QxEqBandValue] = []
    private var preGain = 0.0
    private var enabled = true
    private var muted: [Int: QxFilter] = [:] {
        didSet {
            if muted.isEmpty, !oldValue.isEmpty {
                host.mutesCleared()
            } else if oldValue.isEmpty, !muted.isEmpty {
                host.parkSaveForMute()
            }
        }
    }
    private var selected: Int?
    private var isGraphic = false
    private var ready = false
    private var readFailed = false
    private var recheck = false
    private var sourceName: String?

    private var undoStack: [EqHistoryEntry] = []
    private var redoStack: [EqHistoryEntry] = []
    private var suppressUndo = false
    private var lastEditLabel = ""
    private var lastEditAt = Date.distantPast

    private var pending: [WriteKey: WriteValue] = [:]
    private var order: [WriteKey] = []
    private var operations: [() async -> Void] = []
    private var worker: Task<Void, Never>?
    private var running = false
    private var generation = 0

    init(host: AppModel) {
        self.host = host
    }

    @discardableResult
    package func addObserver(_ observer: @escaping (EqEditorState) -> Void) -> Int {
        nextObserverID += 1
        observers[nextObserverID] = observer
        observer(state)
        return nextObserverID
    }

    package func removeObserver(_ id: Int) {
        observers[id] = nil
    }

    var hasMutes: Bool { !muted.isEmpty }

    func writeRealShapes(_ session: QxSession) async -> [Int: QxFilter] {
        let held = muted
        for index in held.keys.sorted() where bands.indices.contains(index) && bands[index].filter == .bypass {
            var real = bands[index]
            real.filter = held[index] ?? .peak
            try? await session.writeBand(index: index, real)
        }
        return held
    }

    func writeMutedShapes(_ held: [Int: QxFilter], _ session: QxSession) async {
        for index in held.keys.sorted() where bands.indices.contains(index) && muted[index] != nil {
            try? await session.writeBand(index: index, bands[index])
        }
    }

    private var linkedAndRead: Bool { ready && host.state.connection.isConnected && host.session != nil }

    package var canEdit: Bool { linkedAndRead && !operationInFlight }

    private var operationInFlight: Bool { running || !operations.isEmpty }

    package var bandCapacity: Int { group.bandCount }

    var currentGroup: QxEqGroup { group }

    package var writeRefusal: String? { writeRefusal(attempted: true) }

    package func writeRefusal(attempted: Bool) -> String? {
        if canEdit { return nil }
        switch host.state.connection {
        case .connected:
            return "The 5K is busy \u{2014} try again in a moment."
        case .unsupported:
            return attempted ? "Not applied \u{2014} this device isn\u{2019}t supported."
                : "This device isn\u{2019}t supported."
        default:
            return attempted ? "Connect the 5K first \u{2014} nothing was applied." : "Connect the 5K to apply."
        }
    }

    func liveCurve() -> PresetLibrary.LiveCurve? {
        guard linkedAndRead else { return nil }
        var live = bands
        for (index, shape) in muted where live.indices.contains(index) && live[index].filter == .bypass {
            live[index].filter = shape
        }
        return PresetLibrary.LiveCurve(bands: live, preGain: preGain, group: group,
                                       sourceName: sourceName)
    }

    @discardableResult
    func apply(_ file: ParametricEQFile, named name: String? = nil,
               undoLabel: String = "import") -> EqImportResult {
        if let refusal = writeRefusal {
            return EqImportResult(accepted: false, summary: refusal)
        }
        let capacity = group.bandCount
        let fitted = file.fitted(toBandCount: capacity)
        checkpoint(undoLabel, discrete: true)
        muted = [:]
        sourceName = name
        let preamp = max(-12, min(12, fitted.preamp))
        var request = ParametricEQFile()
        request.preamp = preamp
        request.bands = fitted.bands
        let dropped = fitted.droppedBands
        let summary = (["Applied \(fitted.bands.count) band(s), pre-gain "
            + DisplayFormat.decibels(preamp)
            + (dropped > 0 ? " \u{00B7} \(dropped) band(s) dropped"
                + (file.bands.count > capacity && group != .b20 ? " (fit in 20-band mode)" : "")
                : "")] + fitted.notes).joined(separator: " \u{00B7} ")
        DebugLog.shared.log("import: \(summary)")
        host.armSave()
        enqueueOperation { [weak self] in
            guard let self, let session = self.host.session else { return }
            do {
                let applied = try await session.applyParametric(request, expecting: self.group,
                                                                recording: nil)
                let snapshot = await session.snapshot()
                self.adoptDeviceState(applied, snapshot: snapshot)
                self.publish()
                await self.host.refreshStatus()
            } catch {
                DebugLog.shared.log("import failed: \(QudelixCLI.describe(error))")
                self.reloadFromDevice()
            }
        }
        return EqImportResult(accepted: true, summary: summary)
    }

    package func response(count: Int = 220) -> [Double] {
        EqCurveGeometry.response(bands: state.bands, count: count)
    }

    package func waitForIdle() async {
        if let current = worker { await current.value }
    }

    func flushWrites() async {
        await waitForIdle()
    }

    package func select(_ index: Int?) {
        if let index, !bands.indices.contains(index) { return }
        guard selected != index else { return }
        selected = index
        publish()
    }

    package func setBand(_ index: Int, _ band: EqBand) {
        commitBand(index, band.raw, persist: true, record: true, force: false)
    }

    package func setPreGain(_ db: Double) {
        commitPreGain(db, persist: true, record: true, force: false)
    }

    package func zeroBand(_ index: Int) {
        guard canEdit, bands.indices.contains(index) else { return }
        var band = bands[index]
        if band.filter != .bypass, !band.filter.hasGain { band.filter = .peak }
        band.gain = 0
        guard band != bands[index] else { return }
        checkpoint("zero band \(index + 1)", discrete: true)
        suppressUndo = true
        defer { suppressUndo = false }
        commitBand(index, band, persist: true, record: false, force: false)
    }

    package func setBandMuted(_ index: Int, _ on: Bool) {
        guard canEdit, bands.indices.contains(index) else { return }
        checkpoint(on ? "mute band \(index + 1)" : "unmute band \(index + 1)", discrete: true)
        suppressUndo = true
        defer { suppressUndo = false }
        if on {
            let shape = bands[index].filter
            guard shape != .bypass else { return }
            var band = bands[index]
            band.filter = .bypass
            commitBand(index, band, persist: false, record: false, force: false)
            guard bands[index].filter == .bypass else { return }
            muted[index] = shape
        } else {
            guard state.isMuted(index), let shape = muted[index] else { return }
            var band = bands[index]
            band.filter = shape
            commitBand(index, band, persist: false, record: false, force: false)
        }
        publish()
    }

    package func flatten() {
        guard canEdit else { return }
        checkpoint("flatten", discrete: true)
        suppressUndo = true
        defer { suppressUndo = false }
        commitPreGain(0, persist: true, record: false, force: false)
        for index in bands.indices {
            var band = bands[index]
            guard band.gain != 0 else { continue }
            band.gain = 0
            commitBand(index, band, persist: true, record: false, force: false)
        }
    }

    package func resetLayout() {
        guard canEdit else { return }
        checkpoint("reset band layout", discrete: true)
        suppressUndo = true
        defer { suppressUndo = false }
        commitPreGain(0, persist: true, record: false, force: false)
        let defaults = group.defaultFreqs
        for index in bands.indices where defaults.indices.contains(index) {
            commitBand(index, QxEqBandValue(filter: .peak, freq: defaults[index], gain: 0, q: 1),
                       persist: true, record: false, force: false)
        }
    }

    package func setEnabled(_ on: Bool) {
        host.setEqEnabled(on)
    }

    package func undo() { step(undo: true) }
    package func redo() { step(undo: false) }

    private func step(undo: Bool) {
        guard canEdit else { return }
        guard let entry = undo ? undoStack.popLast() : redoStack.popLast() else { return }
        let here = makeEntry(entry.label)
        if undo {
            redoStack.append(here)
            if redoStack.count > Self.undoDepth { redoStack.removeFirst() }
            removeFromFile(entry)
        } else {
            undoStack.append(here)
            if undoStack.count > Self.undoDepth { undoStack.removeFirst() }
            EqHistoryFile.append(here)
        }
        suppressUndo = true
        defer {
            suppressUndo = false
            lastEditLabel = ""
            lastEditAt = .distantPast
        }
        let target = entry.snapshot
        muted = target.mutedBands
        if enabled != target.enabled {
            enabled = target.enabled
            host.setEqEnabled(target.enabled, persist: false)
        }
        commitPreGain(target.preGain, persist: false, record: false, force: false)
        for (index, band) in target.bands.enumerated()
        where index < bands.count && bands[index] != band {
            commitBand(index, band, persist: false, record: false, force: false)
        }
        muted = target.mutedBands
        host.armSave()
        publish()
    }

    private func commitBand(_ index: Int, _ value: QxEqBandValue, persist: Bool,
                            record: Bool, force: Bool) {
        guard canEdit, bands.indices.contains(index) else { return }
        let band = QxSession.clamped(value)
        guard force || band != bands[index] else { return }
        guard QxPacket.bandParamPayload(group: group, band: index, band) != nil else { return }
        if record { checkpoint("band \(index + 1)") }
        bands[index] = band
        if band.filter != .bypass, muted[index] != nil { muted[index] = nil }
        enqueue(.band(index), .band(band))
        if persist { host.armSave() }
        publish()
    }

    private func commitPreGain(_ db: Double, persist: Bool, record: Bool, force: Bool) {
        guard canEdit, db.isFinite else { return }
        let clamped = EQHeadroom.clamp(db)
        guard force || clamped != preGain else { return }
        if record { checkpoint("pre-gain") }
        preGain = clamped
        enqueue(.preGain, .preGain(clamped))
        if persist { host.armSave() }
        publish()
    }

    private func checkpoint(_ label: String, discrete: Bool = false) {
        guard !suppressUndo else { return }
        let now = host.clock.now()
        let continuing = !discrete && label == lastEditLabel
            && now.timeIntervalSince(lastEditAt) < Self.burstWindow
        lastEditLabel = label
        lastEditAt = now
        guard !continuing else { return }
        let entry = makeEntry(label)
        if let top = undoStack.last,
           top.snapshot.bands == entry.snapshot.bands,
           top.snapshot.preGain == entry.snapshot.preGain,
           top.snapshot.mutedBands == entry.snapshot.mutedBands,
           top.snapshot.enabled == entry.snapshot.enabled { return }
        undoStack.append(entry)
        if undoStack.count > Self.undoDepth { undoStack.removeFirst() }
        redoStack.removeAll()
        EqHistoryFile.append(entry)
    }

    private func makeEntry(_ label: String) -> EqHistoryEntry {
        let snapshot = EqSnapshot(groupRaw: group.rawValue, bands: bands, preGain: preGain,
                                  enabled: enabled, name: activeName, mutedBands: muted,
                                  deviceIdentity: identity, activePreset: activeSlot)
        return EqHistoryEntry(recordedAt: host.clock.now(), label: label, snapshot: snapshot)
    }

    private func removeFromFile(_ entry: EqHistoryEntry) {
        var history = EqHistoryFile.load()
        guard let position = history.entries.lastIndex(where: {
            $0.label == entry.label && $0.snapshot.bands == entry.snapshot.bands
                && $0.snapshot.preGain == entry.snapshot.preGain
                && $0.snapshot.groupRaw == entry.snapshot.groupRaw
        }) else { return }
        history.entries.remove(at: position)
        EqHistoryFile.save(history)
    }

    private func enqueue(_ key: WriteKey, _ value: WriteValue) {
        if pending[key] == nil { order.append(key) }
        pending[key] = value
        kick()
    }

    func enqueueOperation(_ operation: @escaping () async -> Void) {
        operations.append(operation)
        publish()
        kick()
    }

    private func kick() {
        guard worker == nil else { return }
        let current = generation
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.generation == current, await self.runNext() {}
            guard self.generation == current else { return }
            self.worker = nil
            if self.recheck {
                self.recheck = false
                self.statusChanged(self.host.state.status)
            }
        }
    }

    private func runNext() async -> Bool {
        guard let session = host.session else {
            pending.removeAll()
            order.removeAll()
            operations.removeAll()
            return false
        }
        if let key = order.first {
            order.removeFirst()
            guard let value = pending.removeValue(forKey: key) else { return true }
            do {
                switch value {
                case .band(let band):
                    if case .band(let index) = key { try await session.writeBand(index: index, band) }
                case .preGain(let db):
                    try await session.writePreGain(db: db)
                }
            } catch {
                DebugLog.shared.log("EQ write failed: \(QudelixCLI.describe(error))")
            }
            return true
        }
        if !operations.isEmpty {
            let operation = operations.removeFirst()
            running = true
            let started = generation
            await operation()
            if generation == started {
                running = false
                publish()
            }
            return true
        }
        return false
    }

    var isBusy: Bool { running || !pending.isEmpty || !operations.isEmpty }

    func sessionOpened(_ session: QxSession, snapshot: QxStatusSnapshot) async {
        generation += 1
        worker = nil
        pending.removeAll()
        order.removeAll()
        operations.removeAll()
        running = false
        recheck = false
        undoStack = []
        redoStack = []
        lastEditLabel = ""
        lastEditAt = .distantPast
        selected = nil
        muted = [:]
        sourceName = nil
        group = snapshot.eqGroup
        identity = snapshot.deviceIdentity
        activeSlot = snapshot.activePresetIndex
        activeName = snapshot.activePresetName
        enabled = snapshot.eqEnabled ?? true
        isGraphic = snapshot.eqType == "GEQ"
        ready = false
        readFailed = false
        bands = []
        preGain = 0
        publish()
        let opening = generation
        let live = await session.livePreset()
        guard generation == opening else { return }
        if let preset = live {
            bands = preset.bands
            preGain = EQHeadroom.clamp(preset.preGain)
            ready = true
        } else {
            readFailed = true
        }
        seedHistory()
        publish()
    }

    func sessionClosed() {
        generation += 1
        worker = nil
        pending.removeAll()
        order.removeAll()
        operations.removeAll()
        running = false
        recheck = false
        ready = false
        readFailed = false
        bands = []
        undoStack = []
        redoStack = []
        selected = nil
        muted = [:]
        sourceName = nil
        publish()
    }

    private func seedHistory() {
        let wanted = bands.count
        let entries = EqHistoryFile.load().entries.filter {
            $0.snapshot.groupRaw == group.rawValue && $0.snapshot.bands.count == wanted
                && ($0.snapshot.deviceIdentity == nil || $0.snapshot.deviceIdentity == identity)
        }
        undoStack = Array(entries.suffix(Self.undoDepth))
    }

    func statusChanged(_ snapshot: QxStatusSnapshot?) {
        guard let snapshot, ready || snapshot.eqGroup != group else { return }
        var changed = false
        if let on = snapshot.eqEnabled, on != enabled {
            enabled = on
            changed = true
        }
        let graphic = snapshot.eqType == "GEQ"
        if graphic != isGraphic {
            isGraphic = graphic
            changed = true
        }
        activeName = snapshot.activePresetName
        let slotMoved = snapshot.activePresetIndex != activeSlot
        let groupMoved = snapshot.eqGroup != group
        if slotMoved || groupMoved {
            if isBusy {
                recheck = true
            } else {
                if groupMoved { group = snapshot.eqGroup }
                activeSlot = snapshot.activePresetIndex
                reloadFromDevice()
            }
        }
        if changed { publish() }
    }

    private func reloadFromDevice() {
        enqueueOperation { [weak self] in
            guard let self, let session = self.host.session else { return }
            guard let preset = try? await session.readPreset() else { return }
            let snapshot = await session.snapshot()
            self.adoptDeviceState(preset, snapshot: snapshot)
            self.seedHistory()
            self.publish()
        }
    }

    package func retryRead() {
        guard readFailed, host.state.connection.isConnected, host.session != nil else { return }
        readFailed = false
        publish()
        enqueueOperation { [weak self] in
            guard let self, let session = self.host.session else { return }
            do {
                let preset = try await session.readPreset()
                let snapshot = await session.snapshot()
                guard self.host.session === session else { return }
                self.adoptDeviceState(preset, snapshot: snapshot)
                self.seedHistory()
            } catch {
                DebugLog.shared.log("EQ read failed: \(QudelixCLI.describe(error))")
                if self.host.session === session { self.readFailed = true }
            }
            self.publish()
        }
    }

    func adopt(_ preset: QxUserEqPreset, snapshot: QxStatusSnapshot) {
        adoptDeviceState(preset, snapshot: snapshot)
        publish()
    }

    private func adoptDeviceState(_ preset: QxUserEqPreset, snapshot: QxStatusSnapshot) {
        group = snapshot.eqGroup
        activeSlot = snapshot.activePresetIndex
        activeName = snapshot.activePresetName
        bands = preset.bands
        preGain = EQHeadroom.clamp(preset.preGain)
        enabled = snapshot.eqEnabled ?? enabled
        isGraphic = snapshot.eqType == "GEQ"
        ready = true
        readFailed = false
        muted = muted.filter { bands.indices.contains($0.key) && bands[$0.key].filter == .bypass }
        if let selected, !bands.indices.contains(selected) { self.selected = nil }
    }

    func presetLoading(_ label: String, slot: Int) {
        checkpoint("load " + label, discrete: true)
        muted = [:]
        sourceName = nil
        activeSlot = slot
    }

    func checkpointForImport(_ label: String) {
        checkpoint(label, discrete: true)
    }

    private func publish() {
        var next = EqEditorState()
        next.ready = ready
        next.loadState = ready ? .ready : (readFailed ? .failed : .loading)
        next.groupLabel = QxFormat.groupLabel(group)
        next.bands = bands.map(EqBand.init)
        next.preGain = preGain
        next.enabled = enabled
        next.muted = muted.mapValues(EqFilterKind.init)
        next.selected = selected
        next.isGraphic = isGraphic
        next.canEdit = canEdit
        next.canUndo = !undoStack.isEmpty
        next.canRedo = !redoStack.isEmpty
        next.undoLabel = undoStack.last?.label
        next.redoLabel = redoStack.last?.label
        guard next != state else { return }
        state = next
        for observer in observers.values { observer(next) }
    }
}
