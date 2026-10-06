import CoreAudio
import XCTest
@testable import QudelixBar

final class OutputVolumeCacheTests: XCTestCase {
    private var now: TimeInterval = 100
    private var reads = 0
    private var level: Float? = -20

    private func makeCache() -> OutputVolumeCache {
        OutputVolumeCache(maxAge: 30, missMaxAge: 5, now: { self.now })
    }

    private func read(_ id: AudioDeviceID) -> Float? {
        reads += 1
        return level
    }

    func testTheDeviceIsAskedOnceNotOnEveryMeteringSecond() {
        let cache = makeCache()
        for second in 0..<20 {
            now = 100 + TimeInterval(second)
            XCTAssertEqual(cache.value(for: 7, read: read), -20)
        }
        XCTAssertEqual(reads, 1, "twenty ticks inside the window cost one query")
    }

    func testAChangeNotificationMakesTheNextReadFresh() {
        let cache = makeCache()
        XCTAssertEqual(cache.value(for: 7, read: read), -20)
        level = -12
        XCTAssertEqual(cache.value(for: 7, read: read), -20,
                       "nothing has told the cache the volume moved")
        cache.invalidate()
        XCTAssertEqual(cache.value(for: 7, read: read), -12)
        XCTAssertEqual(reads, 2)
    }

    func testADeviceThatNeverNotifiesIsStillReReadAfterTheSafetyWindow() {
        let cache = makeCache()
        _ = cache.value(for: 7, read: read)
        level = -6
        now += 29.9
        XCTAssertEqual(cache.value(for: 7, read: read), -20)
        now += 0.2
        XCTAssertEqual(cache.value(for: 7, read: read), -6)
        XCTAssertEqual(reads, 2)
    }

    func testAnotherDeviceNeverSeesTheFirstOnesLevel() {
        let cache = makeCache()
        XCTAssertEqual(cache.value(for: 7, read: read), -20)
        level = -3
        XCTAssertEqual(cache.value(for: 8, read: read), -3)
        XCTAssertEqual(reads, 2)
    }

    func testADeviceWithNoVolumeControlIsRetriedSoonerThanAKnownOne() {
        level = nil
        let cache = makeCache()
        XCTAssertNil(cache.value(for: 7, read: read))
        now += 2
        XCTAssertNil(cache.value(for: 7, read: read))
        XCTAssertEqual(reads, 1, "a missing control is not queried every second either")
        level = -9
        now += 3.1
        XCTAssertEqual(cache.value(for: 7, read: read), -9)
        XCTAssertEqual(reads, 2)
    }

    func testAClockThatMovesBackwardsReadsAgainInsteadOfTrustingTheCache() {
        let cache = makeCache()
        _ = cache.value(for: 7, read: read)
        now = 10
        _ = cache.value(for: 7, read: read)
        XCTAssertEqual(reads, 2)
    }
}
