import Foundation

enum QxLinkKind: String {
    case usb
    case bluetooth
}

protocol QxLink: AnyObject {
    var kind: QxLinkKind { get }
    var isConnected: Bool { get }
    var onConnected: ((String) -> Void)? { get set }
    var onDisconnected: (() -> Void)? { get set }
    var onLinkUnusable: ((String) -> Void)? { get set }
    var onPacket: (([UInt8]) -> Void)? { get set }
    func start()
    func stop()
    func send(_ cmd: QxCmd, _ data: [UInt8])
}
