import CGtk
import XCTest
@testable import QudelixBar
@testable import QudelixGtk

private nonisolated(unsafe) var toolkitStarted = false

final class DeviceTextTests: XCTestCase {
    override func setUpWithError() throws {
        if !toolkitStarted {
            try XCTSkipUnless(gtk_init_check() != 0, "no display")
            adw_init()
            toolkitStarted = true
        }
    }

    func testSubtitleWithMarkupCharactersShowsTheRawText() {
        let row = adw_action_row_new()!
        let hostile = "Rock & Roll <b>loud</b> <a href=\"x\">x</a>"
        DeviceText.setSubtitle(row, hostile)
        let stored = String(cString: adw_action_row_get_subtitle(row.typed(AdwActionRow.self)))
        XCTAssertEqual(stored, hostile)
        XCTAssertEqual(DeviceText.escaped("A & <b>"), "A &amp; &lt;b&gt;")
        let raw = adw_action_row_new()!
        adw_action_row_set_subtitle(raw.typed(AdwActionRow.self), hostile)
        XCTAssertNotEqual(String(cString: adw_action_row_get_subtitle(raw.typed(AdwActionRow.self))), hostile)
    }

    func testMissingValueReadsUnknown() {
        let row = adw_action_row_new()!
        DeviceText.setSubtitle(row, nil)
        XCTAssertEqual(String(cString: adw_action_row_get_subtitle(row.typed(AdwActionRow.self))), "Unknown")
    }

    func testVolumeUsesTheSharedDecibelFormat() {
        XCTAssertEqual(DeviceText.volume(-18), EqFormat.decibels(-18))
        XCTAssertTrue(DeviceText.volume(-18).hasPrefix("\u{2212}"))
        XCTAssertFalse(DeviceText.volume(-18).contains("-"))
        XCTAssertEqual(DeviceText.volume(-3.5), EqFormat.decibels(-3.5))
    }

    func testBlankNames() {
        XCTAssertTrue(DeviceText.isBlank(""))
        XCTAssertTrue(DeviceText.isBlank("  \n "))
        XCTAssertFalse(DeviceText.isBlank(" a "))
    }

    func testDrawingAreaKeepsRequestedRoleAndLabel() {
        let area = Accessible.drawingArea(role: GTK_ACCESSIBLE_ROLE_IMG)
        XCTAssertEqual(Accessible.role(of: area), GTK_ACCESSIBLE_ROLE_IMG)
        Accessible.setLabel(area, "Chart")
        Accessible.setDescription(area, "Rising line")
        Accessible.setSelected(area, true)
    }

    func testLifetimeGuardSkipsWorkAfterDestroy() {
        var ran = 0
        UiLifetime.windowDestroyed = false
        UiLifetime.ifAlive { ran += 1 }
        UiLifetime.windowDestroyed = true
        UiLifetime.ifAlive { ran += 1 }
        UiLifetime.windowDestroyed = false
        XCTAssertEqual(ran, 1)
    }
}
