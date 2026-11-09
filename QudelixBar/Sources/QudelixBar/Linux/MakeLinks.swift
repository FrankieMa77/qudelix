import Foundation

package func makeLinks(preferred: QxLinkKind?) -> [QxLink] {
    switch preferred {
    case .usb: return [HidrawTransport()]
    case .bluetooth: return [BluezTransport()]
    case nil: return [HidrawTransport(), BluezTransport()]
    }
}
