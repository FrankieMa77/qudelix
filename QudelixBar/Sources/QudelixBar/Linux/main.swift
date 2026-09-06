import Foundation

func makeLinks(preferred: QxLinkKind?) -> [QxLink] {
    []
}

let status = await QudelixCLI.run(arguments: Array(CommandLine.arguments.dropFirst()),
                                  makeLinks: makeLinks)
exit(status)
