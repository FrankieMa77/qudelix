import XCTest
@testable import QudelixBar

final class WindowLifecycleTests: XCTestCase {
    func testAPlainLaunchShowsTheWindow() {
        var lifecycle = WindowLifecycle()
        XCTAssertEqual(lifecycle.launch(startHidden: false), .show)
        XCTAssertTrue(lifecycle.visible)
    }

    func testClosingHidesWhenAWatcherIsPresent() {
        var lifecycle = WindowLifecycle()
        _ = lifecycle.launch(startHidden: false)
        XCTAssertEqual(lifecycle.watcherChanged(true), .none)
        XCTAssertEqual(lifecycle.closeRequested(), .hide)
        XCTAssertFalse(lifecycle.visible)
    }

    func testClosingQuitsWithoutAWatcherOrBeforeOneIsKnown() {
        var lifecycle = WindowLifecycle()
        _ = lifecycle.launch(startHidden: false)
        XCTAssertEqual(lifecycle.closeRequested(), .quit)
        _ = lifecycle.watcherChanged(false)
        XCTAssertEqual(lifecycle.closeRequested(), .quit)
    }

    func testClosingQuitsAgainOnceTheWatcherDisappears() {
        var lifecycle = WindowLifecycle()
        _ = lifecycle.launch(startHidden: false)
        _ = lifecycle.watcherChanged(true)
        _ = lifecycle.watcherChanged(false)
        XCTAssertEqual(lifecycle.closeRequested(), .quit)
    }

    func testHiddenLaunchStaysHiddenOnceAWatcherAppears() {
        var lifecycle = WindowLifecycle()
        XCTAssertEqual(lifecycle.launch(startHidden: true), .none)
        XCTAssertFalse(lifecycle.visible)
        XCTAssertEqual(lifecycle.watcherChanged(true), .none)
        XCTAssertEqual(lifecycle.graceExpired(), .none)
        XCTAssertFalse(lifecycle.visible)
    }

    func testHiddenLaunchWithoutAWatcherShowsAfterTheGracePeriod() {
        var lifecycle = WindowLifecycle()
        _ = lifecycle.launch(startHidden: true)
        XCTAssertEqual(lifecycle.watcherChanged(false), .none)
        XCTAssertEqual(lifecycle.graceExpired(), .show)
        XCTAssertTrue(lifecycle.visible)
    }

    func testAWatcherThatAppearsDuringTheGraceKeepsTheWindowHidden() {
        var lifecycle = WindowLifecycle()
        _ = lifecycle.launch(startHidden: true)
        _ = lifecycle.watcherChanged(false)
        XCTAssertEqual(lifecycle.watcherChanged(true), .none)
        XCTAssertEqual(lifecycle.graceExpired(), .none)
        XCTAssertFalse(lifecycle.visible)
    }

    func testAHiddenWindowIsShownWhenTheWatcherVanishes() {
        var lifecycle = WindowLifecycle()
        _ = lifecycle.launch(startHidden: false)
        _ = lifecycle.watcherChanged(true)
        XCTAssertEqual(lifecycle.closeRequested(), .hide)
        XCTAssertEqual(lifecycle.watcherChanged(false), .show)
        XCTAssertTrue(lifecycle.visible)
    }

    func testAVisibleWindowStaysWhenTheWatcherVanishes() {
        var lifecycle = WindowLifecycle()
        _ = lifecycle.launch(startHidden: false)
        _ = lifecycle.watcherChanged(true)
        XCTAssertEqual(lifecycle.watcherChanged(false), .none)
    }

    func testPresentRaisesAHiddenWindowAndEndsTheWait() {
        var lifecycle = WindowLifecycle()
        _ = lifecycle.launch(startHidden: true)
        XCTAssertEqual(lifecycle.present(), .show)
        XCTAssertTrue(lifecycle.visible)
        XCTAssertEqual(lifecycle.graceExpired(), .none)
        _ = lifecycle.watcherChanged(true)
        XCTAssertEqual(lifecycle.closeRequested(), .hide)
        XCTAssertEqual(lifecycle.present(), .show)
    }
}
