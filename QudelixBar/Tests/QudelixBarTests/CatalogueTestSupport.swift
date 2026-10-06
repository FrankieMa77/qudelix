import XCTest
@testable import QudelixBar

final class PathTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: Result<Data, Error>] = [:]
    private var counts: [String: Int] = [:]
    private var posted: [Data] = []

    func set(_ path: String, _ result: Result<Data, Error>) {
        lock.withLock { responses[path] = result }
    }

    func count(_ path: String) -> Int { lock.withLock { counts[path] ?? 0 } }

    var postedBodies: [Data] { lock.withLock { posted } }

    func send(_ request: URLRequest, limit: Int) async throws -> Data {
        let path = request.url?.path ?? ""
        let next: Result<Data, Error>? = lock.withLock {
            counts[path, default: 0] += 1
            if let body = request.httpBody { posted.append(body) }
            return responses[path]
        }
        guard let next else { throw URLError(.resourceUnavailable) }
        return try next.get()
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var value: Int { lock.withLock { calls } }
    func bump() { lock.withLock { calls += 1 } }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isOn: Bool { lock.withLock { raised } }
    func set(_ on: Bool) { lock.withLock { raised = on } }
}

func catalogueJSON(_ object: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

func equalizeResponse(filterCount: Int = 10) -> Data {
    var filters = [#"{"type":"LOW_SHELF","fc":105.0,"q":0.7,"gain":5.5}"#]
    for i in 1..<(filterCount - 1) {
        filters.append(#"{"type":"PEAKING","fc":\#(200 * i).5,"q":1.2,"gain":-1.25}"#)
    }
    filters.append(#"{"type":"HIGH_SHELF","fc":10000.0,"q":0.7,"gain":-6.3}"#)
    return Data("""
        {"fr":{"frequency":[20.0,24.0]},
         "parametric_eq":{"fs":44100,"filters":[\(filters.joined(separator: ","))],"preamp":-6.7}}
        """.utf8)
}

