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
    package static let renameReadbackDelay: TimeInterval = 0.4
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
    private var readbackTimers: [Int: AppTimer] = [:]

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
        return SlotOverwritePrompt(slot: index, title: Self.overwriteTitle,
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
            let committed = await self.host.eq.committingToFlash(session) {
                let held = await self.host.eq.writeRealShapes(session)
                do {
                    try await session.savePreset(index: index)
                    saved = true
                } catch {
                    DebugLog.shared.log("preset save failed: \(QudelixCLI.describe(error))")
                }
                await self.host.eq.writeMutedShapes(held, session)
            }
            guard committed else {
                DebugLog.shared.log("slot save skipped: could not put the base EQ back first")
                return self.fail(failure)
            }
            guard saved else { return self.fail(failure) }
            if let name = QudelixController.nameOnSave(source: self.host.eq.currentSourceName,
                                                       existing: self.names[index],
                                                       unchangedSinceSource: self.host.eq.curveMatchesSource) {
                let stored = QxPacket.truncatingUTF8(QudelixController.displayName(name),
                                                     to: QxPacket.maxPresetNameBytes)
                if (try? await session.renamePreset(index: index, name: name)) != nil {
                    self.names[index] = stored.isEmpty ? nil : stored
                    self.scheduleReadback(index)
                }
            }
            try? await session.refreshStatus()
            self.host.notify(.success, "Saved to slot \(index + 1).")
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
                self.names[index] = stored.isEmpty ? nil : stored
                self.publish()
                self.host.notify(.success, stored.isEmpty ? "Cleared the name of slot \(index + 1)."
                                 : "Renamed slot \(index + 1).")
                self.scheduleReadback(index)
            } catch {
                DebugLog.shared.log("preset rename failed: \(QudelixCLI.describe(error))")
                self.fail(failure)
            }
        }
    }

    private func refuse(_ failure: String) {
        host.notify(.failure, failure + " Connect the 5K and try again.")
    }

    private func fail(_ failure: String) {
        host.notify(.failure, failure + AppModel.retryAdvice)
    }

    private func scheduleReadback(_ index: Int) {
        readbackTimers[index]?.cancel()
        readbackTimers[index] = host.clock.schedule(after: Self.renameReadbackDelay) { [weak self] in
            guard let self else { return }
            self.readbackTimers[index] = nil
            self.run { [weak self] session in
                guard let self else { return }
                if let read = try? await session.presetName(index: index) {
                    self.names[index] = read
                } else {
                    self.names[index] = nil
                }
                self.publish()
                await self.host.refreshStatus()
            }
        }
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
        for timer in readbackTimers.values { timer.cancel() }
        readbackTimers = [:]
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
           names[index] != name, readbackTimers[index] == nil {
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
