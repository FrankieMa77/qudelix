import Foundation
import QudelixAudio
@testable import QudelixBar
import XCTest

final class ZServerRestartHarnessTests: XCTestCase {
    private var backend: PipeWireAudioBackend!
    private var originalConfigured: String?

    override func setUpWithError() throws {
        try Harness.require()
        backend = try PipeWireAudioBackend()
        originalConfigured = backend.configuredDefaultSinkName
        XCTAssertTrue(backend.setDefaultSink(named: Harness.fiveK))
        XCTAssertTrue(waitFor { self.backend.defaultSinkName == Harness.fiveK })
    }

    override func tearDown() {
        if let backend {
            _ = backend.setDefaultSink(named: originalConfigured)
            backend.shutdown()
        }
        backend = nil
        super.tearDown()
    }

    func testTheMetadataIsRebuiltWhenWirePlumberRestarts() throws {
        XCTAssertEqual(backend.defaultSinkName, Harness.fiveK)
        XCTAssertEqual(runTool(["pkill", "-x", "wireplumber"]).status, 0)
        XCTAssertTrue(waitFor { self.backend.defaultSinkName == nil }, "stale default kept")
        XCTAssertFalse(backend.setDefaultSink(named: Harness.other))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["wireplumber"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        XCTAssertTrue(waitFor(30) { self.backend.defaultSinkName != nil }, "default metadata was not rebound")
        XCTAssertTrue(waitFor(30) { self.backend.setDefaultSink(named: Harness.other) })
        XCTAssertTrue(waitFor { self.backend.configuredDefaultSinkName == Harness.other })
        XCTAssertTrue(backend.setDefaultSink(named: Harness.fiveK))
        XCTAssertTrue(backend.connected)
    }
}
