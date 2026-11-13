import Foundation

package struct PresetSlot: Equatable {
    package var index: Int
    package var name: String?
    package var isActive: Bool

    package var number: Int { index + 1 }
    package var label: String { QxFormat.presetLabel(index, name) }
}

package struct PresetSlotsState: Equatable {
    package var ready = false
    package var slots: [PresetSlot] = []
    package var activeIndex: Int?
    package var busy = false

    package init() {}
}

package struct SlotOverwritePrompt: Equatable {
    package var slot: Int
    package var title: String
    package var message: String
    package var confirmLabel: String
}

@MainActor
package final class PresetSlotsModel {
    nonisolated(unsafe) package static var confirmTimeout: TimeInterval = 3
    nonisolated(unsafe) package static var confirmRetryPause: TimeInterval = 0.3
    package static let saveUnconfirmed = "The 5K didn't confirm the save. Try again."
    package static let renameUnconfirmed = "The 5K didn't confirm the new name. Try again."
    package static let slotCount = QudelixController.presetCount

    private unowned let host: AppModel

    private var observers: [Int: (PresetSlotsState) -> Void] = [:]
    private var nextObserverID = 0
    package private(set) var state = PresetSlotsState()

    private var names: [Int: String] = [:]
    private var activeIndex: Int?
    private var ready = false
    private var busyCount = 0
    private var generation = 0

    init(host: AppModel) {
        self.host = host
    }

    @discardableResult
    package func addObserver(_ observer: @escaping (PresetSlotsState) -> Void) -> Int {
        nextObserverID += 1
        observers[nextObserverID] = observer
        observer(state)
        return nextObserverID
    }

    package func removeObserver(_ id: Int) {
        observers[id] = nil
    }

    package var canWrite: Bool { ready && host.state.connection.isConnected && host.session != nil }

    package func label(forSlot index: Int) -> String {
        QxFormat.presetLabel(index, names[index])
    }

    package func needsOverwriteConfirmation(slot index: Int) -> Bool {
        names[index] != nil
    }

    package static let customSettingNote = "Current EQ is a custom setting, not a saved slot."
    package static let noActiveSlotHelp = "No slot is active \u{2014} load or save one first."
    package static let overwriteTitle = "Replace the preset in this slot?"
    package static let saveHereLabel = "Save here"

    package static func overwriteMessage(slot: Int, name: String) -> String {
        "Slot \(slot + 1), \u{201C}" + name + "\u{201D}, holds a preset on the "
            + "device. Writing replaces it, and the device keeps no copy."
    }

    package var activeSlotIndex: Int? { activeIndex }

    package var canUpdateActive: Bool {
        canWrite && activeIndex != nil && !host.eq.sessionActive && !host.eq.following
    }

    package func updateHelp() -> String {
        if let busy = host.eq.writeRefusal(attempted: false), host.eq.state.ready { return busy }
        guard let active = activeIndex else { return Self.noActiveSlotHelp }
        return "Overwrite " + label(forSlot: active) + " with the current EQ"
    }

    package func updateActive() {
        guard let active = activeIndex, !host.eq.following else { return }
        save(slot: active)
    }

    package func requestSave(slot index: Int) -> SlotOverwritePrompt? {
        guard (0..<Self.slotCount).contains(index) else { return nil }
        guard needsOverwriteConfirmation(slot: index) else {
            save(slot: index)
            return nil
        }
        return overwritePrompt(slot: index)
    }

    package func overwritePrompt(slot index: Int) -> SlotOverwritePrompt {
        SlotOverwritePrompt(slot: index, title: Self.overwriteTitle,
                            message: Self.overwriteMessage(slot: index, name: label(forSlot: index)),
                            confirmLabel: Self.saveHereLabel)
    }

    package func waitForIdle() async {
        await host.eq.waitForIdle()
    }

    package func load(slot index: Int) {
        guard (0..<Self.slotCount).contains(index) else { return }
        let failure = "Could not load slot \(index + 1)."
        guard canWrite else { return refuse(failure) }
        guard !host.eq.sessionActive else { return host.notify(.failure, EqEditorModel.sessionRefusal) }
        let wasActive = activeIndex == index
        let before = (host.eq.liveBands, host.eq.livePreGain)
        host.eq.presetLoading(label(forSlot: index), slot: index)
        run(failure) { [weak self] session in
            guard let self else { return }
            do {
                let preset = try await session.loadPreset(index: index, recording: false)
                let snapshot = await session.snapshot()
                guard self.host.session === session else { return self.fail(failure) }
                self.host.eq.adopt(preset, snapshot: snapshot)
                self.activeIndex = index
                self.publish()
                let changed = before.0 != preset.bands || abs(before.1 - preset.preGain) > 0.001
                self.host.notify(.success, Self.loadMessage(slot: index, wasActive: wasActive, changed: changed))
                await self.host.refreshStatus()
            } catch {
                DebugLog.shared.log("preset load failed: \(QudelixCLI.describe(error))")
                self.host.eq.reloadFromDevice()
                self.fail(failure)
            }
        }
    }

    package static func loadMessage(slot index: Int, wasActive: Bool, changed: Bool) -> String {
        guard wasActive else { return "Loaded slot \(index + 1)." }
        return changed ? "Slot \(index + 1) reloaded \u{2014} unsaved changes discarded."
            : "Slot \(index + 1) is already loaded \u{2014} nothing changed."
    }

    package func save(slot index: Int) {
        guard (0..<Self.slotCount).contains(index) else { return }
        let failure = "Could not save to slot \(index + 1)."
        guard canWrite else { return refuse(failure) }
        guard !host.eq.sessionActive else { return host.notify(.failure, EqEditorModel.sessionRefusal) }
        run(failure) { [weak self] session in
            guard let self else { return }
            var saved = false
            var confirmed = false
            let committed = await self.host.eq.committingToFlash(session) {
                let held = await self.host.eq.writeRealShapes(session)
                let expected = self.expectedShapes(held: held)
                do {
                    try await session.savePreset(index: index)
                    saved = true
                } catch {
                    DebugLog.shared.log("preset save failed: \(QudelixCLI.describe(error))")
                }
                if saved {
                    var wantedName: String??
                    if let name = QudelixController.nameOnSave(source: self.host.eq.currentSourceName,
                                                               existing: self.names[index],
                                                               unchangedSinceSource: self.host.eq.curveMatchesSource) {
                        let stored = QxPacket.truncatingUTF8(QudelixController.displayName(name),
                                                             to: QxPacket.maxPresetNameBytes)
                        if (try? await session.renamePreset(index: index, name: name)) != nil {
                            wantedName = .some(stored.isEmpty ? nil : stored)
                        }
                    }
                    confirmed = await self.confirmSlot(session, index: index, expected: expected,
                                                       name: wantedName)
                }
                await self.host.eq.writeMutedShapes(held, session)
            }
            guard committed else {
                DebugLog.shared.log("slot save skipped: could not put the base EQ back first")
                return self.fail(failure)
            }
            guard saved else { return self.fail(failure) }
            try? await session.refreshStatus()
            if confirmed {
                self.host.notify(.success, "Saved to slot \(index + 1).")
            } else {
                self.host.notify(.failure, Self.saveUnconfirmed)
            }
            self.publish()
            await self.host.refreshStatus()
        }
    }

    package func rename(slot index: Int, to name: String) {
        guard (0..<Self.slotCount).contains(index) else { return }
        let failure = "Could not rename slot \(index + 1)."
        guard canWrite else { return refuse(failure) }
        let cleaned = QudelixController.displayName(name)
        let stored = QxPacket.truncatingUTF8(cleaned, to: QxPacket.maxPresetNameBytes)
        run(failure) { [weak self] session in
            guard let self else { return }
            do {
                try await session.renamePreset(index: index, name: name)
            } catch {
                DebugLog.shared.log("preset rename failed: \(QudelixCLI.describe(error))")
                return self.fail(failure)
            }
            let confirmed = await self.confirmName(session, index: index,
                                                   expected: stored.isEmpty ? nil : stored)
            self.publish()
            if confirmed {
                self.host.notify(.success, stored.isEmpty ? "Cleared the name of slot \(index + 1)."
                                 : "Renamed slot \(index + 1).")
            } else {
                self.host.notify(.failure, Self.renameUnconfirmed)
            }
            await self.host.refreshStatus()
        }
    }

    private struct ExpectedShapes {
        var bands: [QxEqBandValue]
        var preGain: Double
    }

    private final class ReadBack {
        var preset: QxUserEqPreset?
        var name: String??
    }

    private final class Gate<T> {
        private var continuation: CheckedContinuation<T?, Never>?
        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
        func finish(_ value: T?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    private func expectedShapes(held: [Int: QxFilter]) -> ExpectedShapes {
        var bands = host.eq.liveBands
        for (index, filter) in held where bands.indices.contains(index) && bands[index].filter == .bypass {
            bands[index].filter = filter
        }
        return ExpectedShapes(bands: bands.map(QxSession.clamped), preGain: host.eq.livePreGain)
    }

    private static func matches(_ read: QxUserEqPreset, _ expected: ExpectedShapes) -> Bool {
        guard read.bands.count == expected.bands.count,
              abs(read.preGain - EQHeadroom.clamp(expected.preGain)) < 0.15 else { return false }
        for (have, want) in zip(read.bands, expected.bands) where !matches(have, want) { return false }
        return true
    }

    private static func matches(_ have: QxEqBandValue, _ want: QxEqBandValue) -> Bool {
        guard have.filter == want.filter else { return false }
        guard want.filter != .bypass else { return true }
        return abs(have.freq - want.freq) <= 1
            && abs(have.gain - want.gain) < 0.15
            && abs(have.q - want.q) <= max(0.02, want.q * 0.01)
    }

    private func within<T>(_ seconds: TimeInterval, _ body: @escaping () async -> T?) async -> T? {
        await withCheckedContinuation { continuation in
            let gate = Gate<T>(continuation)
            let work = Task { gate.finish(await body()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                gate.finish(nil)
                work.cancel()
            }
        }
    }

    private func pause() async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, Self.confirmRetryPause) * 1_000_000_000))
    }

    private func confirmName(_ session: QxSession, index: Int, expected: String?) async -> Bool {
        let previous = names[index]
        let seen = ReadBack()
        let ok = await within(Self.confirmTimeout) {
            while !Task.isCancelled {
                do {
                    let read = try await session.presetName(index: index)
                    seen.name = .some(read)
                    if read == expected { return true }
                } catch {
                    DebugLog.shared.log("preset name read-back failed: \(QudelixCLI.describe(error))")
                }
                await self.pause()
            }
            return nil
        } ?? false
        if let read = seen.name { names[index] = read } else { names[index] = previous }
        return ok
    }

    private func confirmSlot(_ session: QxSession, index: Int, expected: ExpectedShapes,
                             name: String??) async -> Bool {
        let seen = ReadBack()
        let bandsOK = await within(Self.confirmTimeout) {
            while !Task.isCancelled {
                do {
                    let read = try await session.loadPreset(index: index, recording: false)
                    seen.preset = read
                    if Self.matches(read, expected) { return true }
                } catch {
                    DebugLog.shared.log("slot read-back failed: \(QudelixCLI.describe(error))")
                }
                await self.pause()
            }
            return nil
        } ?? false
        if !bandsOK, let read = seen.preset { await restore(session, from: read, to: expected) }
        var nameOK = true
        if let wanted = name { nameOK = await confirmName(session, index: index, expected: wanted) }
        return bandsOK && nameOK
    }

    private func restore(_ session: QxSession, from read: QxUserEqPreset, to expected: ExpectedShapes) async {
        for index in expected.bands.indices where read.bands.indices.contains(index)
            && !Self.matches(read.bands[index], expected.bands[index]) {
            try? await session.writeBand(index: index, expected.bands[index])
        }
        if abs(read.preGain - EQHeadroom.clamp(expected.preGain)) >= 0.15 {
            try? await session.writePreGain(db: EQHeadroom.clamp(expected.preGain))
        }
    }

    private func refuse(_ failure: String) {
        host.notify(.failure, failure + " Connect the 5K and try again.")
    }

    private func fail(_ failure: String) {
        host.notify(.failure, failure + AppModel.retryAdvice)
    }

    func run(_ failure: String? = nil, _ body: @escaping (QxSession) async -> Void) {
        busyCount += 1
        publish()
        let started = generation
        host.eq.enqueueOperation { [weak self] in
            guard let self else { return }
            if let session = self.host.session {
                await body(session)
            } else if let failure {
                self.refuse(failure)
            }
            guard self.generation == started else { return }
            self.busyCount -= 1
            self.publish()
        }
    }

    func sessionOpened(_ session: QxSession, snapshot: QxStatusSnapshot) {
        names = [:]
        activeIndex = snapshot.activePresetIndex
        if let index = snapshot.activePresetIndex, let name = snapshot.activePresetName {
            names[index] = name
        }
        ready = true
        generation += 1
        busyCount = 0
        publish()
        host.eq.enqueueOperation { [weak self] in
            guard let self else { return }
            if let fetched = try? await self.host.session?.namedPresets() {
                self.names = fetched
                self.publish()
            }
        }
    }

    func sessionClosed() {
        ready = false
        names = [:]
        activeIndex = nil
        generation += 1
        busyCount = 0
        publish()
    }

    func statusChanged(_ snapshot: QxStatusSnapshot?) {
        guard ready, let snapshot else { return }
        activeIndex = snapshot.activePresetIndex
        if let index = snapshot.activePresetIndex, let name = snapshot.activePresetName,
           names[index] != name {
            names[index] = name
        }
        publish()
    }

    private func publish() {
        var next = PresetSlotsState()
        next.ready = ready
        next.activeIndex = activeIndex
        next.busy = busyCount > 0
        next.slots = ready
            ? (0..<Self.slotCount).map {
                PresetSlot(index: $0, name: names[$0], isActive: $0 == activeIndex)
            }
            : []
        guard next != state else { return }
        state = next
        for observer in observers.values { observer(next) }
    }
}
