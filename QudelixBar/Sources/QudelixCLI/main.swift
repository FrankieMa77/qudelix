import Foundation
import QudelixBar

let status = await QudelixCLI.run(arguments: Array(CommandLine.arguments.dropFirst()),
                                  makeLinks: makeLinks)
exit(QudelixCLI.finish(status))
