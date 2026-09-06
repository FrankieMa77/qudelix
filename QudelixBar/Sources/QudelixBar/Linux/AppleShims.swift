#if os(Linux)
import Foundation

enum QudelixController {}

enum AppAssignments {}

enum AudioOutputs {}

enum ImpulseLimits {}

enum IRLibrary {}

@MainActor
final class Notifier {
    static let shared = Notifier()

    func post(id: String, title: String, body: String) {}
}

final class OutputWatcher {
    struct Output {
        var uid: String
        var name: String
    }

    private(set) var defaultOutput: Output?

    var onChange: (() -> Void)?

    func start() {}

    func stop() {}
}
#endif
