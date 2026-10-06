import AppKit
import SwiftUI
import XCTest
@testable import QudelixBar

final class CautionContrastTests: XCTestCase {
    private func linear(_ v: CGFloat) -> Double {
        let c = Double(v)
        return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB)!
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent)
            + 0.0722 * linear(c.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let hi = max(luminance(a), luminance(b))
        let lo = min(luminance(a), luminance(b))
        return (hi + 0.05) / (lo + 0.05)
    }

    private func grey(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(v) / 255, green: CGFloat(v) / 255, blue: CGFloat(v) / 255, alpha: 1)
    }

    private let aqua = NSAppearance(named: .aqua)!
    private let darkAqua = NSAppearance(named: .darkAqua)!

    private func shipped(_ appearance: NSAppearance) -> NSColor {
        var resolved = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(Color.cautionText).usingColorSpace(.sRGB) ?? .clear
        }
        return resolved
    }

    private func system(_ appearance: NSAppearance) -> NSColor {
        var resolved = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.systemYellow.usingColorSpace(.sRGB) ?? .clear
        }
        return resolved
    }

    func testTheOldYellowWasUnreadableOnTheLightPopover() {
        XCTAssertLessThan(contrast(system(aqua), grey(209)), 1.5)
    }

    func testCautionTextReachesAAOnTheLightPopoverBackgrounds() {
        let text = shipped(aqua)
        for background in [200, 209, 220, 237, 255] {
            XCTAssertGreaterThanOrEqual(contrast(text, grey(background)), 4.5,
                                        "caution text on grey \(background)")
        }
    }

    func testTheShippedColourIsTheOneTheTintResolvesToInLightMode() {
        let expected = CautionTint.resolved(for: aqua).usingColorSpace(.sRGB)!
        let actual = shipped(aqua)
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.002)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.002)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.002)
    }

    func testDarkModeKeepsTheSystemYellow() {
        let expected = system(darkAqua)
        let actual = shipped(darkAqua)
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.002)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.002)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.002)
    }

    func testTheLightTintStillReadsAsAmberNotGrey() {
        let c = shipped(aqua)
        XCTAssertGreaterThan(c.redComponent, c.greenComponent)
        XCTAssertGreaterThan(c.greenComponent, c.blueComponent + 0.15)
    }
}
