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
    func start()
    func stop()
    func send(_ cmd: QxCmd, _ data: [UInt8])
}

package extension QxLink {
    var failureReason: String? { nil }
}

package enum QxLinkTimeouts {
    package static let bluetoothAppearance: TimeInterval = 30

    static func appearance(kind: QxLinkKind, explicit: TimeInterval?, fallback: TimeInterval,
                           bluetooth: TimeInterval = QxLinkTimeouts.bluetoothAppearance) -> TimeInterval {
        if let explicit { return explicit }
        return kind == .bluetooth ? bluetooth : fallback
    }
}
