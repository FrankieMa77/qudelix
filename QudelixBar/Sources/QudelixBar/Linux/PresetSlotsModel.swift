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

    package static let overwriteTitle = "Replace the preset in this slot?"
    package static let saveHereLabel = "Save here"

    package static func overwriteMessage(slot: Int, name: String) -> String {
        "Slot \(slot + 1), \u{201C}" + name + "\u{201D}, holds a preset on the "
            + "device. Writing replaces it, and the device keeps no copy."
    }

    package func waitForIdle() async {
        await host.eq.waitForIdle()
    }

    package func load(slot index: Int) {
        guard (0..<Self.slotCount).contains(index) else { return }
        let failure = "Could not load slot \(index + 1)."
        guard canWrite else { return refuse(failure) }
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
                self.host.notify(.success, "Loaded slot \(index + 1).")
                await self.host.refreshStatus()
            } catch {
                DebugLog.shared.log("preset load failed: \(QudelixCLI.describe(error))")
                self.fail(failure)
            }
        }
    }

    package func save(slot index: Int) {
        guard (0..<Self.slotCount).contains(index) else { return }
        let failure = "Could not save to slot \(index + 1)."
        guard canWrite else { return refuse(failure) }
        run(failure) { [weak self] session in
            guard let self else { return }
            let held = await self.host.eq.writeRealShapes(session)
            var saved = false
            do {
                try await session.savePreset(index: index)
                saved = true
            } catch {
                DebugLog.shared.log("preset save failed: \(QudelixCLI.describe(error))")
            }
            await self.host.eq.writeMutedShapes(held, session)
            guard saved else { return self.fail(failure) }
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
