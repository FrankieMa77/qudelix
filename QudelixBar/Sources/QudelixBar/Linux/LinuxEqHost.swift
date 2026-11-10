import Foundation

@MainActor
final class LinuxEqHost: EqAutomationHost, TuneHost {
    unowned let app: AppModel

    var baseProvider: (() -> (bands: [QxEqBandValue], preGain: Double)?)?
    var onReadback: (([QxEqBandValue], Double) -> Void)?
    var onBaseEvent: ((EqBaseEvent) -> Void)?
    var onFlashCommitted: (() -> Void)?
    var onSessionBegin: (() -> Void)?
    var onSessionEnd: (() -> Void)?
    var onReferenceLanded: ((ReferenceCurve, QxEqGroup) -> Void)?
    var onTuneShutdown: (() -> Void)?
    var onQuit: (() -> Void)?

    private var sessionObservers: [Int: (Bool) -> Void] = [:]
    private var nextSessionObserverID = 0

    init(app: AppModel) {
        self.app = app
    }

    @discardableResult
    func addSessionObserver(_ observer: @escaping (Bool) -> Void) -> Int {
        nextSessionObserverID += 1
        sessionObservers[nextSessionObserverID] = observer
        return nextSessionObserverID
    }

    func removeSessionObserver(_ id: Int) {
        sessionObservers[id] = nil
    }

    var eqGroup: QxEqGroup { app.eq.currentGroup }

    var byEarSessionActive: Bool { app.eq.sessionActive }

    var canWriteNow: Bool { app.state.connection.isConnected && app.session != nil }

    var canEditEqNow: Bool { app.eq.canWriteBands && !app.eq.isFlashing }

    var eqSettling: Bool { app.eq.isSettling }

    var eqEnabled: Bool { app.eq.liveEnabled }

    var eqReadBack: Bool { app.eq.isReady }

    var eqRestoreDecided: Bool { true }

    var inputSource: String? { app.state.status?.inputSource }

    var activeCall: Bool? { app.state.status?.activeCall }

    var bands: [QxEqBandValue] { app.eq.liveBands }

    var preGain: Double { app.eq.livePreGain }

    var bandCount: Int { app.eq.currentGroup.bandCount }

    var userBands: [QxEqBandValue] { baseProvider?()?.bands ?? bands }

    var userPreGain: Double { baseProvider?()?.preGain ?? preGain }

    var isConnectedNow: Bool { app.state.connection.isConnected }

    var isCompatible: Bool { app.state.connection.isConnected }

    var isOnVoiceLink: Bool {
        (inputSource?.hasPrefix("HFP") ?? false) || app.state.status?.sampleRate == "16 kHz"
    }

    func beginEqSession() {
        guard !app.eq.sessionActive else { return }
        app.parkSaveForSession()
        app.eq.setSessionActive(true)
        onSessionBegin?()
        for observer in sessionObservers.values { observer(true) }
    }

    func endEqSession() {
        guard app.eq.sessionActive else { return }
        app.eq.setSessionActive(false)
        app.releaseParkedSave()
        onSessionEnd?()
        for observer in sessionObservers.values { observer(false) }
    }

    func setByEarSessionActive(_ active: Bool) {
        if active { beginEqSession() } else { endEqSession() }
    }

    func beginUndoStep(_ label: String) {
        app.eq.checkpoint(label, discrete: true)
    }

    func setPreGain(_ db: Double, persistToFlash: Bool, recordUndo: Bool, force: Bool) {
        app.eq.commitPreGain(db, persist: persistToFlash, record: recordUndo, force: force)
    }

    func updateBand(_ index: Int, _ value: QxEqBandValue,
                    persistToFlash: Bool, recordUndo: Bool, force: Bool) {
        app.eq.commitBand(index, value, persist: persistToFlash, record: recordUndo, force: force)
    }

    func setEqEnabled(_ on: Bool, persistToFlash: Bool) {
        app.setEqEnabled(on, persist: persistToFlash)
    }

    @discardableResult
    func writeFollowed(bands target: [QxEqBandValue], preGain: Double,
                       persistToFlash: Bool, recordUndo: Bool) -> Int {
        let editor = app.eq
        guard editor.canWriteBands, !editor.isFlashing,
              target.count == editor.liveBands.count else { return 0 }
        let diff = editor.followedDiff(target, preGain: preGain)
        let preFirst = diff.pre < editor.livePreGain
        if preFirst {
            editor.commitPreGain(diff.pre, persist: persistToFlash, record: recordUndo, force: false)
        }
        for (index, want) in diff.changed {
            editor.commitBand(index, want, persist: persistToFlash, record: recordUndo, force: false)
        }
        if !preFirst {
            editor.commitPreGain(diff.pre, persist: persistToFlash, record: recordUndo, force: false)
        }
        return diff.changed.count
    }

    @discardableResult
    func keepFollowed(base: (bands: [QxEqBandValue], preGain: Double),
                      followed: (bands: [QxEqBandValue], preGain: Double),
                      undoLabel: String) -> Bool {
        guard canEditEqNow else { return false }
        writeFollowed(bands: base.bands, preGain: base.preGain,
                      persistToFlash: false, recordUndo: false)
        app.eq.checkpoint(undoLabel, discrete: true)
        writeFollowed(bands: followed.bands, preGain: followed.preGain,
                      persistToFlash: true, recordUndo: false)
        return true
    }

    func flushPendingEqSends() {}

    func flushEqSendsBlockingNow() {}
}
