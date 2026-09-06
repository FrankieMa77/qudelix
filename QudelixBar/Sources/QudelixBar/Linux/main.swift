import Foundation

func makeLinks(preferred: QxLinkKind?) -> [QxLink] {
    switch preferred {
    case .usb: return [HidrawTransport()]
    case .bluetooth: return [BluezTransport()]
    case nil: return [HidrawTransport(), BluezTransport()]
    }
}

let status = await QudelixCLI.run(arguments: Array(CommandLine.arguments.dropFirst()),
                                  makeLinks: makeLinks)
exit(status)
