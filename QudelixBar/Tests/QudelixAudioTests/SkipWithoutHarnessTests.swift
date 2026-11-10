import XCTest

final class SkipWithoutHarnessTests: XCTestCase {
    func testHarnessSwitchIsExplicit() {
        let value = ProcessInfo.processInfo.environment["QX_PIPEWIRE_HARNESS"]
        XCTAssertTrue(value == nil || value == "1")
    }
}
