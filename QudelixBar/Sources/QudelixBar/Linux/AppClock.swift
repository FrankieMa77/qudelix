import Foundation

package protocol AppTimer: AnyObject {
    func cancel()
}

package protocol AppClock: AnyObject {
    func now() -> Date
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> AppTimer
}

package final class SystemClock: AppClock {
    private final class Timer: AppTimer {
        let item: DispatchWorkItem

        init(_ item: DispatchWorkItem) { self.item = item }

        func cancel() { item.cancel() }
    }

    package init() {}

    package func now() -> Date { Date() }

    package func schedule(after seconds: TimeInterval,
                          _ work: @escaping @MainActor () -> Void) -> AppTimer {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return Timer(item)
    }
}
