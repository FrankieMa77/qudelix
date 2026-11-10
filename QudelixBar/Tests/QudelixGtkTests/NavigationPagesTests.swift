import XCTest
@testable import QudelixGtk

final class NavigationPagesTests: XCTestCase {
    func testTheSidebarListsEveryPageInOrder() {
        XCTAssertEqual(NavigationPages.entries.map(\.id),
                       ["device", "eq", "presets", "library", "tune", "stage", "level"])
        XCTAssertEqual(NavigationPages.entries.map(\.title),
                       ["Device", "EQ", "Presets", "Library", "Tune", "Stage", "Level"])
    }

    func testEveryEntryHasAnIconAndASummaryAndIdsAreUnique() {
        XCTAssertEqual(Set(NavigationPages.entries.map(\.id)).count, NavigationPages.entries.count)
        for entry in NavigationPages.entries {
            XCTAssertTrue(entry.icon.hasSuffix("-symbolic"), entry.id)
            XCTAssertFalse(entry.summary.isEmpty, entry.id)
        }
    }

    func testIndexAndNeighbourLookupsStayInRange() {
        XCTAssertEqual(NavigationPages.index(of: "presets"), 2)
        XCTAssertNil(NavigationPages.index(of: "missing"))
        XCTAssertEqual(NavigationPages.neighbour(of: "eq", offset: 1), "presets")
        XCTAssertEqual(NavigationPages.neighbour(of: "eq", offset: -1), "device")
        XCTAssertNil(NavigationPages.neighbour(of: "device", offset: -1))
        XCTAssertNil(NavigationPages.neighbour(of: "level", offset: 1))
        XCTAssertNil(NavigationPages.neighbour(of: "missing", offset: 1))
    }

    func testEveryPageHasAnAltNumberShortcutAndAnActionName() {
        XCTAssertEqual(NavigationPages.accelerator(at: 0), "<Alt>1")
        XCTAssertEqual(NavigationPages.accelerator(at: 6), "<Alt>7")
        XCTAssertNil(NavigationPages.accelerator(at: 7))
        XCTAssertEqual(NavigationPages.actionName(for: "tune"), "page-tune")
    }
}
