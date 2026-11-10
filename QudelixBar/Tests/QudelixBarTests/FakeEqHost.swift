import Foundation
@testable import QudelixBar

@MainActor
final class FakeEqHost: EqAutomationHost, TuneHost {
    var eqGroup: QxEqGroup = .user
    var byEarSessionActive = false
    var canWriteNow = true
    var canEditEqNow = true
    var eqSettling = false
    var eqEnabled = true
    var eqReadBack = true
    var eqRestoreDecided = true
    var inputSource: String?
    var activeCall: Bool?
    var bands: [QxEqBandValue]
    var preGain: Double = 0
    var isConnectedNow = true
    var isCompatible = true
    var isOnVoiceLink = false

    var baseProvider: (() -> (bands: [QxEqBandValue], preGain: Double)?)?
    var onReadback: (([QxEqBandValue], Double) -> Void)?
    var onBaseEvent: ((EqBaseEvent) -> Void)?
    var onFlashCommitted: (() -> Void)?
    var onSessionBegin: (() -> Void)?
    var onSessionEnd: (() -> Void)?
    var onReferenceLanded: ((ReferenceCurve, QxEqGroup) -> Void)?

    private(set) var writes: [(bands: [QxEqBandValue], preGain: Double)] = []
    private(set) var bandUpdates = 0
    private(set) var preGainWrites: [Double] = []
    private(set) var undoLabels: [String] = []
    private(set) var flushes = 0
    private(set) var blockingFlushes = 0
    private(set) var keeps = 0

    init(bands: [QxEqBandValue]) {
        self.bands = bands
    }

    var bandCount: Int { eqGroup.bandCount }
    var userBands: [QxEqBandValue] { baseProvider?()?.bands ?? bands }
    var userPreGain: Double { baseProvider?()?.preGain ?? preGain }

    @discardableResult
    func writeFollowed(bands target: [QxEqBandValue], preGain: Double,
                       persistToFlash: Bool, recordUndo: Bool) -> Int {
        guard canWriteNow, target.count == bands.count else { return 0 }
        var changed = 0
        for i in target.indices where target[i] != bands[i] {
            bands[i] = target[i]
            changed += 1
        }
        self.preGain = preGain
        writes.append((target, preGain))
        return changed
    }

    @discardableResult
    func keepFollowed(base: (bands: [QxEqBandValue], preGain: Double),
                      followed: (bands: [QxEqBandValue], preGain: Double),
                      undoLabel: String) -> Bool {
        keeps += 1
        undoLabels.append(undoLabel)
        bands = followed.bands
        preGain = followed.preGain
        return true
    }

    func flushPendingEqSends() { flushes += 1 }

    func flushEqSendsBlockingNow() { blockingFlushes += 1 }

    func setByEarSessionActive(_ active: Bool) {
        if active { beginEqSession() } else { endEqSession() }
    }

    func beginEqSession() {
        guard !byEarSessionActive else { return }
        byEarSessionActive = true
        onSessionBegin?()
    }

    func endEqSession() {
        guard byEarSessionActive else { return }
        byEarSessionActive = false
        onSessionEnd?()
    }

    func beginUndoStep(_ label: String) { undoLabels.append(label) }

    func setPreGain(_ db: Double, persistToFlash: Bool, recordUndo: Bool, force: Bool) {
        guard canWriteNow, db.isFinite else { return }
        preGain = EQHeadroom.clamp(db)
        preGainWrites.append(preGain)
    }

    func updateBand(_ index: Int, _ value: QxEqBandValue,
                    persistToFlash: Bool, recordUndo: Bool, force: Bool) {
        guard canWriteNow, bands.indices.contains(index), index < bandCount else { return }
        bands[index] = value
        bandUpdates += 1
    }
}
