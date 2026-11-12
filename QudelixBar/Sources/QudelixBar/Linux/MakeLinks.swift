import Foundation

private func bluetoothLinks(locate: () -> String?) -> [QxLink] {
    if let binary = locate() {
        return [ServiceLink(spawner: LinkServiceSpawner.serviceSpawner(binary: binary))]
    }
    Trace.log("no qudelix binary found for the Bluetooth link service; using the Bluetooth link inside this process")
    return [BluezTransport()]
}

package func makeLinks(preferred: QxLinkKind?) -> [QxLink] {
    makeLinks(preferred: preferred, locateBinary: { LinkServiceSpawner.locateBinary() })
}

func makeLinks(preferred: QxLinkKind?, locateBinary: () -> String?) -> [QxLink] {
    switch preferred {
    case .usb: return [HidrawTransport()]
    case .bluetooth: return bluetoothLinks(locate: locateBinary)
    case nil: return [HidrawTransport()] + bluetoothLinks(locate: locateBinary)
    }
}
