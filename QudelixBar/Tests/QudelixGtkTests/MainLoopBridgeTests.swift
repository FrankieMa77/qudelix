import CGtk
import XCTest
@testable import QudelixGtk

final class LoopProbe: @unchecked Sendable {
    let loop: OpaquePointer
    private let lock = NSLock()
    private var completed = Set<String>()
    private(set) var timedOut = false

    init() {
        loop = g_main_loop_new(nil, 0)!
    }

    func complete(_ name: String) {
        lock.lock()
        completed.insert(name)
        let all = completed.count == 3
        lock.unlock()
        if all { g_main_loop_quit(loop) }
    }

    func expire() {
        timedOut = true
        g_main_loop_quit(loop)
    }

    var names: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }
}

final class MainLoopBridgeTests: XCTestCase {
    func testMainQueueWorkCompletesWhileGLibLoopRuns() {
        MainLoopBridge.install()
        XCTAssertTrue(MainLoopBridge.isInstalled)
        XCTAssertTrue(Thread.isMainThread)

        let probe = LoopProbe()
        let watchdog = g_timeout_add_seconds(10, { data in
            Unmanaged<LoopProbe>.fromOpaque(data!).takeUnretainedValue().expire()
            return 0
        }, Unmanaged.passUnretained(probe).toOpaque())

        Task { @MainActor in
            XCTAssertTrue(Thread.isMainThread)
            probe.complete("task")
        }

        Task.detached {
            await MainActor.run {
                XCTAssertTrue(Thread.isMainThread)
                probe.complete("mainActorRun")
            }
        }

        DispatchQueue.main.async {
            XCTAssertTrue(Thread.isMainThread)
            probe.complete("dispatchMain")
        }

        g_main_loop_run(probe.loop)
        g_source_remove(watchdog)
        g_main_loop_unref(probe.loop)

        XCTAssertFalse(probe.timedOut)
        XCTAssertEqual(probe.names, ["task", "mainActorRun", "dispatchMain"])
    }

    func testSleepingMainActorTaskResumesOnMainThread() {
        MainLoopBridge.install()
        let probe = LoopProbe()
        let watchdog = g_timeout_add_seconds(10, { data in
            Unmanaged<LoopProbe>.fromOpaque(data!).takeUnretainedValue().expire()
            return 0
        }, Unmanaged.passUnretained(probe).toOpaque())

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertTrue(Thread.isMainThread)
            probe.complete("a")
            probe.complete("b")
            probe.complete("c")
        }

        g_main_loop_run(probe.loop)
        g_source_remove(watchdog)
        g_main_loop_unref(probe.loop)
        XCTAssertFalse(probe.timedOut)
    }

    func testIdleLoopDoesNotSpin() {
        MainLoopBridge.install()
        let probe = LoopProbe()
        DispatchQueue.main.async {}
        Task { @MainActor in }
        let before = MainLoopBridge.callbackCount
        let timer = g_timeout_add(300, { data in
            Unmanaged<LoopProbe>.fromOpaque(data!).takeUnretainedValue().expire()
            return 0
        }, Unmanaged.passUnretained(probe).toOpaque())
        _ = timer
        g_main_loop_run(probe.loop)
        g_main_loop_unref(probe.loop)
        XCTAssertLessThan(MainLoopBridge.callbackCount - before, 20)
    }
}
