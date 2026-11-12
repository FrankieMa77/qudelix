import Foundation

package enum QxLinkKind: String {
    case usb
    case bluetooth
}

package protocol QxLink: AnyObject {
    var kind: QxLinkKind { get }
    var isConnected: Bool { get }
    var onConnected: ((String) -> Void)? { get set }
    var onDisconnected: (() -> Void)? { get set }
    var onLinkUnusable: ((String) -> Void)? { get set }
    var onLinkBusy: ((String) -> Void)? { get set }
    var onPacket: (([UInt8]) -> Void)? { get set }
    var failureReason: String? { get }
    var failureNeedsAttention: Bool { get }
    var keepsArmed: Bool { get }
    var attachedName: String? { get }
    func recycle()
    func start()
    func stop()
    func stopAndWait(timeout: TimeInterval)
    func send(_ cmd: QxCmd, _ data: [UInt8])
}

package extension QxLink {
    var failureReason: String? { nil }
    var failureNeedsAttention: Bool { false }
    var keepsArmed: Bool { false }
    var attachedName: String? { nil }
    func recycle() {}
    func stopAndWait(timeout: TimeInterval) { stop() }
}

package enum QxLinkTimeouts {
    package static let bluetoothAppearance: TimeInterval = 40
    package static let bluetoothSlice: TimeInterval = 5

    static func appearance(kind: QxLinkKind, explicit: TimeInterval?, fallback: TimeInterval,
                           bluetooth: TimeInterval = QxLinkTimeouts.bluetoothAppearance) -> TimeInterval {
        if let explicit { return explicit }
        return kind == .bluetooth ? bluetooth : fallback
    }
}
