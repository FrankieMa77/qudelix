#if !canImport(Combine)
import Foundation

protocol ObservableObject: AnyObject {}

final class AnyCancellable: Hashable {
    private var teardown: (() -> Void)?

    init(_ teardown: @escaping () -> Void) {
        self.teardown = teardown
    }

    deinit { teardown?() }

    func cancel() {
        teardown?()
        teardown = nil
    }

    func store(in set: inout Set<AnyCancellable>) {
        set.insert(self)
    }

    static func == (lhs: AnyCancellable, rhs: AnyCancellable) -> Bool { lhs === rhs }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

struct PublishedStream<Value> {
    fileprivate let source: Published<Value>
    fileprivate var isDuplicate: ((Value, Value) -> Bool)?

    func sink(_ receive: @escaping (Value) -> Void) -> AnyCancellable {
        let isDuplicate = self.isDuplicate
        var previous: Value?
        let deliver: (Value) -> Void = { value in
            if let isDuplicate, let previous, isDuplicate(previous, value) { return }
            previous = value
            receive(value)
        }
        let source = self.source
        deliver(source.currentValue)
        let token = source.addSubscriber(deliver)
        return AnyCancellable { source.removeSubscriber(token) }
    }
}

extension PublishedStream where Value: Equatable {
    func removeDuplicates() -> PublishedStream<Value> {
        var stream = self
        stream.isDuplicate = { $0 == $1 }
        return stream
    }
}

@propertyWrapper
final class Published<Value> {
    private var value: Value
    private var subscribers: [Int: (Value) -> Void] = [:]
    private var nextToken = 0

    init(wrappedValue: Value) {
        value = wrappedValue
    }

    var wrappedValue: Value {
        get { value }
        set {
            value = newValue
            for subscriber in subscribers.values { subscriber(newValue) }
        }
    }

    var projectedValue: PublishedStream<Value> {
        PublishedStream(source: self, isDuplicate: nil)
    }

    fileprivate var currentValue: Value { value }

    fileprivate func addSubscriber(_ subscriber: @escaping (Value) -> Void) -> Int {
        nextToken += 1
        subscribers[nextToken] = subscriber
        return nextToken
    }

    fileprivate func removeSubscriber(_ token: Int) {
        subscribers[token] = nil
    }
}
#endif
