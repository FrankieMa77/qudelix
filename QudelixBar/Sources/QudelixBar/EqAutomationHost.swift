import Foundation

enum EqBaseEvent: Equatable { case slotLoad, fit, group, restore, undoRedo, reset }

@MainActor
protocol EqAutomationHost: AnyObject {
    var eqGroup: QxEqGroup { get }
    var byEarSessionActive: Bool { get }
    var canWriteNow: Bool { get }
    var canEditEqNow: Bool { get }
    var eqSettling: Bool { get }
    var eqEnabled: Bool { get }
    var eqReadBack: Bool { get }
    var eqRestoreDecided: Bool { get }
    var inputSource: String? { get }
    var activeCall: Bool? { get }
    var bands: [QxEqBandValue] { get }
    var preGain: Double { get }
    var userBands: [QxEqBandValue] { get }

    var baseProvider: (() -> (bands: [QxEqBandValue], preGain: Double)?)? { get set }
    var onReadback: (([QxEqBandValue], Double) -> Void)? { get set }
    var onBaseEvent: ((EqBaseEvent) -> Void)? { get set }
    var onFlashCommitted: (() -> Void)? { get set }
    var onSessionBegin: (() -> Void)? { get set }
    var onSessionEnd: (() -> Void)? { get set }
    var onReferenceLanded: ((ReferenceCurve, QxEqGroup) -> Void)? { get set }

    @discardableResult
    func writeFollowed(bands target: [QxEqBandValue], preGain: Double,
                       persistToFlash: Bool, recordUndo: Bool) -> Int

    @discardableResult
    func keepFollowed(base: (bands: [QxEqBandValue], preGain: Double),
                      followed: (bands: [QxEqBandValue], preGain: Double),
                      undoLabel: String) -> Bool

    func flushPendingEqSends()
    func flushEqSendsBlockingNow()
}

@MainActor
protocol TuneHost: AnyObject {
    var isConnectedNow: Bool { get }
    var isCompatible: Bool { get }
    var isOnVoiceLink: Bool { get }
    var eqGroup: QxEqGroup { get }
    var eqEnabled: Bool { get }
    var bands: [QxEqBandValue] { get }
    var bandCount: Int { get }
    var preGain: Double { get }
    var userBands: [QxEqBandValue] { get }
    var userPreGain: Double { get }
    var byEarSessionActive: Bool { get }

    func setByEarSessionActive(_ active: Bool)
    func beginEqSession()
    func beginUndoStep(_ label: String)
    func setPreGain(_ db: Double, persistToFlash: Bool, recordUndo: Bool, force: Bool)
    func updateBand(_ index: Int, _ value: QxEqBandValue,
                    persistToFlash: Bool, recordUndo: Bool, force: Bool)
}
