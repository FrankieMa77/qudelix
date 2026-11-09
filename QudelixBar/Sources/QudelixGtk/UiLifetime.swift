package enum UiLifetime {
    package nonisolated(unsafe) static var windowDestroyed = false

    package static func ifAlive(_ body: () -> Void) {
        guard !windowDestroyed else { return }
        body()
    }
}
