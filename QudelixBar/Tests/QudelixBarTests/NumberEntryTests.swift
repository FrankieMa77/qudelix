import SwiftUI
import XCTest
@testable import QudelixBar

final class NumberEntryTests: XCTestCase {
    private func assertQ(_ text: String, _ expected: Double?,
                         file: StaticString = #filePath, line: UInt = #line) {
        let got = NumberEntry.parseQ(text)
        switch (got, expected) {
        case (nil, nil): break
        case (let g?, let e?):
            XCTAssertEqual(g, e, accuracy: 1e-12, "Q \(text.debugDescription)", file: file, line: line)
        default:
            XCTFail("Q \(text.debugDescription): got \(String(describing: got)), "
                    + "expected \(String(describing: expected))", file: file, line: line)
        }
    }

    private func assertFc(_ text: String, _ expected: Int?,
                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(NumberEntry.parseFrequency(text), expected,
                       "Fc \(text.debugDescription)", file: file, line: line)
    }

    func testQAcceptsEitherDecimalMark() {
        assertQ("0.7", 0.7)
        assertQ("0,7", 0.7)
        assertQ("0.70", 0.7)
        assertQ("0,70", 0.7)
        assertQ("1.5", 1.5)
        assertQ("1,5", 1.5)
        assertQ(".7", 0.7)
        assertQ(",7", 0.7)
        assertQ("2.", 2)
        assertQ("2,", 2)
        assertQ("10", 10)
        assertQ("10.0", 10)
        assertQ("10,00", 10)
        assertQ("0.1", 0.1)
        assertQ("0,10", 0.1)
        assertQ("  0.7  ", 0.7)
        assertQ("\u{00A0}1,41\u{00A0}", 1.41)
        assertQ("+1.5", 1.5)
    }

    func testQNeverTreatsASeparatorAsThousands() {
        assertQ("1,000", 1)
        assertQ("1.000", 1)
        assertQ("0.70", 0.7)
        assertQ("0,707", 0.71)
        assertQ("7.0", 7)
        assertQ("1,0", 1)
    }

    func testQRoundsToTheHundredthsItDisplays() {
        assertQ("0.754", 0.75)
        assertQ("0.756", 0.76)
        assertQ("1.234567", 1.23)
        assertQ("9.996", 10)
        XCTAssertEqual(NumberEntry.formatQ(0.707), "0.71")
        XCTAssertEqual(NumberEntry.formatQ(0.7), "0.70")
        XCTAssertEqual(NumberEntry.formatQ(10), "10.00")
    }

    func testQRejectsWhatItCannotReadInsteadOfClamping() {
        for text in ["", " ", ".", ",", "abc", "0.7x", "x0.7", "1.2.3", "1,2,3",
                     "1,000.5", "1.000,5", "0.7 1", "1e1", "1E-1", "NaN", "nan", "inf",
                     "Infinity", "-", "+", "0x1", "\u{221E}", "0.7,", "7..0",
                     "\u{0660}.\u{0667}", "\u{FF11}.\u{FF15}"] {
            assertQ(text, nil)
        }
        for text in ["0", "0.0", "0.05", "0.099", "0.0999", "10.01", "10,01", "11", "100",
                     "1000", "-1", "-0.5", "\u{2212}1", "99999999999999999999",
                     String(repeating: "9", count: 400)] {
            assertQ(text, nil)
        }
    }

    func testQRoundTripsThroughItsOwnDisplay() {
        for hundredths in 10...1000 {
            let q = Double(hundredths) / 100
            let shown = NumberEntry.formatQ(q)
            assertQ(shown, q)
            assertQ(shown.replacingOccurrences(of: ".", with: ","), q)
        }
    }

    func testGainAcceptsEitherMarkAndASignInRange() {
        XCTAssertEqual(NumberEntry.parseGain("3.5"), 3.5)
        XCTAssertEqual(NumberEntry.parseGain("3,5"), 3.5)
        XCTAssertEqual(NumberEntry.parseGain("+3,5"), 3.5)
        XCTAssertEqual(NumberEntry.parseGain("-3.5"), -3.5)
        XCTAssertEqual(NumberEntry.parseGain("\u{2212}3,5"), -3.5)
        XCTAssertEqual(NumberEntry.parseGain("12"), 12)
        XCTAssertEqual(NumberEntry.parseGain("-12"), -12)
        XCTAssertEqual(NumberEntry.parseGain("-12,0"), -12)
        XCTAssertEqual(NumberEntry.parseGain("3.54"), 3.5)
        XCTAssertEqual(NumberEntry.parseGain("3.56"), 3.6)
        XCTAssertEqual(NumberEntry.parseGain("0"), 0)
        XCTAssertEqual(NumberEntry.parseGain(".5"), 0.5)
    }

    func testGainNegativeZeroIsPlainZero() throws {
        let zero = try XCTUnwrap(NumberEntry.parseGain("-0"))
        XCTAssertEqual(zero, 0)
        XCTAssertEqual(zero.sign, .plus)
        let tiny = try XCTUnwrap(NumberEntry.parseGain("-0.04"))
        XCTAssertEqual(tiny.sign, .plus)
    }

    func testGainRejectsOutOfRangeAndGarbage() {
        for text in ["12.1", "12,05", "-12.1", "13", "100", "", " ", "abc", "1.2.3",
                     "3,5,1", "1,000.5", "--3", "+-3", "3-", "1e1", "NaN", "inf"] {
            XCTAssertNil(NumberEntry.parseGain(text), text.debugDescription)
        }
    }

    func testFcAcceptsPlainIntegers() {
        assertFc("1000", 1000)
        assertFc("8800", 8800)
        assertFc("20", 20)
        assertFc("20000", 20000)
        assertFc("105", 105)
        assertFc("08800", 8800)
        assertFc("  1000  ", 1000)
    }

    func testFcAcceptsEveryThousandsConvention() {
        assertFc("1 000", 1000)
        assertFc("1,000", 1000)
        assertFc("1.000", 1000)
        assertFc("1\u{00A0}000", 1000)
        assertFc("1\u{202F}000", 1000)
        assertFc("1\u{2009}000", 1000)
        assertFc("1'000", 1000)
        assertFc("1\u{2019}000", 1000)
        assertFc("8.800", 8800)
        assertFc("12,500", 12500)
        assertFc("12.500", 12500)
        assertFc("12 500", 12500)
        assertFc("2,500", 2500)
        assertFc("20.000", 20000)
        assertFc("20,000", 20000)
        assertFc(" 1 000 ", 1000)
    }

    func testFcAcceptsAWholeNumberWrittenWithADecimalMark() {
        assertFc("1000.0", 1000)
        assertFc("1000,00", 1000)
        assertFc("440.", 440)
        assertFc("440.0", 440)
        assertFc("440,0", 440)
        assertFc("1000.000", 1000)
        assertFc("50.000", 50)
        assertFc("100.000", 100)
    }

    func testFcRejectsAFractionInsteadOfRounding() {
        for text in ["1.5", "1,5", "2.5", "440.5", "440,25", "100.500", "1000.5", ".5", ",5", "0.5"] {
            assertFc(text, nil)
        }
    }

    func testFcRejectsOutOfRangeInsteadOfClamping() {
        for text in ["0", "1", "19", "19.0", "20001", "25000", "100000", "1.000.000",
                     "1,000,000", "99999999999999999999", "0.020", "1.0000", "-100"] {
            assertFc(text, nil)
        }
    }

    func testFcRejectsAmbiguousOrMalformedGrouping() {
        for text in ["1 00", "1  000", "1,00", "1.00.0", "1,000.5", "1.000,5", "1.000 000",
                     "1,000 000", "1000,000,000", "12,34", "1,0000", "1, 000", "01.000x"] {
            assertFc(text, nil)
        }
    }

    func testFcRejectsText() {
        for text in ["", " ", ".", ",", "abc", "1k", "1000 Hz", "1000Hz", "1e3", "+1000",
                     "0x3E8", "1000x", "x1000", "\u{0663}\u{0660}\u{0660}",
                     "\u{FF11}\u{FF10}\u{FF10}\u{FF10}", "1000\n2000", "NaN", "inf"] {
            assertFc(text, nil)
        }
    }

    func testFcRoundTripsThroughItsOwnDisplay() {
        for hz in NumberEntry.frequencyRange {
            XCTAssertEqual(NumberEntry.parseFrequency(NumberEntry.formatFrequency(hz)), hz)
        }
    }

    func testFcRoundTripsThroughEveryGroupedSpelling() {
        for hz in 1000...20000 {
            let thousands = hz / 1000
            let rest = String(format: "%03d", hz % 1000)
            for separator in [".", ",", " ", "\u{00A0}", "\u{202F}", "'"] {
                let spelled = "\(thousands)\(separator)\(rest)"
                XCTAssertEqual(NumberEntry.parseFrequency(spelled), hz, spelled)
            }
        }
    }

    private func formatter(_ locale: String, fractionDigits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter
    }

    private static let locales = ["en_US", "en_GB", "en_IN", "de_DE", "de_CH", "de_AT", "fr_FR",
                                  "fr_CH", "pl_PL", "sv_SE", "it_IT", "es_ES", "pt_BR", "ru_RU",
                                  "nb_NO", "cs_CZ", "en_US@rg=plzzzz", "en_US@rg=dezzzz"]

    func testFcReadsWhatEveryLocaleWouldHaveFormatted() {
        for locale in Self.locales {
            let formatter = formatter(locale, fractionDigits: 0)
            for hz in [20, 105, 440, 1000, 2500, 8800, 12500, 16000, 20000] {
                guard let typed = formatter.string(from: NSNumber(value: hz)) else {
                    XCTFail("\(locale) could not format \(hz)")
                    continue
                }
                XCTAssertEqual(NumberEntry.parseFrequency(typed), hz,
                               "\(locale): \(typed.debugDescription)")
            }
        }
    }

    func testQReadsWhatEveryLocaleWouldHaveFormatted() {
        for locale in Self.locales {
            let formatter = formatter(locale, fractionDigits: 2)
            for q in [0.1, 0.25, 0.7, 1.0, 1.41, 4.32, 10.0] {
                guard let typed = formatter.string(from: NSNumber(value: q)) else {
                    XCTFail("\(locale) could not format \(q)")
                    continue
                }
                assertQ(typed, q)
            }
        }
    }

    func testTheCommaLocaleReallyFormatsWithAComma() {
        XCTAssertEqual(formatter("de_DE", fractionDigits: 2).string(from: NSNumber(value: 0.7)), "0,70")
        XCTAssertEqual(formatter("en_US", fractionDigits: 2).string(from: NSNumber(value: 0.7)), "0.70")
    }

    func testTheDisplayIsTheSameInEveryLocale() {
        XCTAssertEqual(NumberEntry.formatQ(0.7), "0.70")
        XCTAssertEqual(NumberEntry.formatFrequency(8800), "8800")
        XCTAssertEqual(NumberEntry.formatFrequency(20000), "20000")
    }

    private func resolveFc(_ typed: String, shown: String) -> NumberEntry.Resolution<Int> {
        NumberEntry.resolve(typed: typed, shown: shown,
                            parse: NumberEntry.parseFrequency,
                            format: NumberEntry.formatFrequency)
    }

    private func resolveQ(_ typed: String, shown: String) -> NumberEntry.Resolution<Double> {
        NumberEntry.resolve(typed: typed, shown: shown,
                            parse: NumberEntry.parseQ,
                            format: NumberEntry.formatQ)
    }

    func testLeavingAFieldUntouchedChangesNothing() {
        let fc = resolveFc("105", shown: "105")
        XCTAssertNil(fc.change)
        XCTAssertEqual(fc.display, "105")
        let q = resolveQ("0.70", shown: "0.70")
        XCTAssertNil(q.change)
        XCTAssertEqual(q.display, "0.70")
    }

    func testRetypingTheSameValueChangesNothing() {
        XCTAssertNil(resolveFc("105 ", shown: "105").change)
        XCTAssertNil(resolveFc("0105", shown: "105").change)
        XCTAssertNil(resolveQ("0.7", shown: "0.70").change)
        XCTAssertNil(resolveQ("0,7", shown: "0.70").change)
        XCTAssertNil(resolveQ("0.704", shown: "0.70").change)
        XCTAssertEqual(resolveQ("0,7", shown: "0.70").display, "0.70")
    }

    func testACommittedValueIsReportedOnceAndShownCanonically() {
        let fc = resolveFc("1,000", shown: "105")
        XCTAssertEqual(fc.change, 1000)
        XCTAssertEqual(fc.display, "1000")
        let q = resolveQ("1,5", shown: "0.70")
        XCTAssertEqual(q.change, 1.5)
        XCTAssertEqual(q.display, "1.50")
        let dot = resolveQ("0.7", shown: "1.00")
        XCTAssertEqual(dot.change, 0.7)
        XCTAssertEqual(dot.display, "0.70")
    }

    func testAnUnreadableEntryRevertsToTheOldValueAndWritesNothing() {
        for typed in ["", "abc", "1.2.3", "0", "20001", "1.5", "-5", "1e3"] {
            let fc = resolveFc(typed, shown: "105")
            XCTAssertNil(fc.change, typed)
            XCTAssertEqual(fc.display, "105", typed)
        }
        for typed in ["", "abc", "1.2.3", "0", "0.05", "10.5", "-1", "70", "1e1"] {
            let q = resolveQ(typed, shown: "0.70")
            XCTAssertNil(q.change, typed)
            XCTAssertEqual(q.display, "0.70", typed)
        }
    }

    func testTheOldBugInputsNowLandWhereThePersonMeant() {
        XCTAssertEqual(resolveQ("0.7", shown: "1.00").change, 0.7)
        XCTAssertEqual(resolveQ("0.70", shown: "1.00").change, 0.7)
        XCTAssertEqual(resolveQ("1.5", shown: "1.00").change, 1.5)
        XCTAssertEqual(resolveQ("0,7", shown: "1.00").change, 0.7)
        XCTAssertEqual(resolveQ("1,5", shown: "1.00").change, 1.5)
        XCTAssertEqual(resolveFc("1,000", shown: "105").change, 1000)
        XCTAssertEqual(resolveFc("1.000", shown: "105").change, 1000)
        XCTAssertEqual(resolveFc("1 000", shown: "105").change, 1000)
    }

    func testTheRangesAreTheDevicesOwn() {
        XCTAssertEqual(NumberEntry.frequencyRange, QxPacket.BandLimit.freq)
        XCTAssertEqual(NumberEntry.qRange, QxPacket.BandLimit.q)
        XCTAssertEqual(NumberEntry.gainRange, QxPacket.BandLimit.gain)
    }
}

final class PopoverShellTests: XCTestCase {
    @MainActor
    private func hostInWindow<V: View>(_ view: V, width: CGFloat = 400) -> (NSWindow, NSHostingController<AnyView>) {
        let controller = NSHostingController(rootView: AnyView(view.frame(width: width)))
        let window = NSWindow(contentViewController: controller)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        return (window, controller)
    }

    @MainActor
    private func settledHeight<V: View>(_ view: V) -> CGFloat {
        let (window, controller) = hostInWindow(view)
        let height = controller.view.frame.height
        window.close()
        return height
    }

    @MainActor
    private func stack(screen: CGFloat, shell: CGFloat, drawer: CGFloat?) -> some View {
        PopoverStackLayout(screenVisibleHeight: { screen }) {
            Color.blue.frame(height: shell)
            if let drawer {
                DrawerPanel(content: Color.red.frame(height: drawer))
            }
        }
    }

    func testTheDrawerCapLeavesRoomForThePopoverChrome() {
        XCTAssertEqual(PopoverStackLayout.drawerHeightCap(screenVisibleHeight: 950, shellHeight: 763),
                       950 - PopoverStackLayout.chrome - 763)
        XCTAssertEqual(PopoverStackLayout.drawerHeightCap(screenVisibleHeight: 1410, shellHeight: 763),
                       1410 - PopoverStackLayout.chrome - 763)
    }

    func testTheDrawerCapNeverDropsBelowAUsableMinimum() {
        XCTAssertEqual(PopoverStackLayout.drawerHeightCap(screenVisibleHeight: 950, shellHeight: 928),
                       PopoverStackLayout.minimumDrawerHeight)
        XCTAssertEqual(PopoverStackLayout.drawerHeightCap(screenVisibleHeight: 600, shellHeight: 900),
                       PopoverStackLayout.minimumDrawerHeight)
    }

    @MainActor
    func testWithoutADrawerThePopoverIsExactlyTheShell() {
        XCTAssertEqual(settledHeight(stack(screen: 950, shell: 763, drawer: nil)), 763, accuracy: 0.5)
    }

    @MainActor
    func testADrawerShorterThanTheRoomKeepsItsOwnHeight() {
        XCTAssertEqual(settledHeight(stack(screen: 950, shell: 763, drawer: 100)),
                       763 + 100 + 10 + 1, accuracy: 0.5)
    }

    @MainActor
    func testATallDrawerStopsWhereTheScreenEndsAndScrolls() {
        let height = settledHeight(stack(screen: 950, shell: 763, drawer: 414))
        XCTAssertEqual(height, 950 - PopoverStackLayout.chrome, accuracy: 0.5)
    }

    @MainActor
    func testATallDrawerKeepsItsFullHeightOnABigScreen() {
        XCTAssertEqual(settledHeight(stack(screen: 1410, shell: 763, drawer: 414)),
                       763 + 414 + 10 + 1, accuracy: 0.5)
    }

    @MainActor
    func testADrawerOnASmallScreenStillGetsItsMinimum() {
        XCTAssertEqual(settledHeight(stack(screen: 700, shell: 763, drawer: 414)),
                       763 + PopoverStackLayout.minimumDrawerHeight, accuracy: 0.5)
    }

    @MainActor
    private func glyphButtons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        func walk(_ v: NSView) {
            if let b = v as? NSButton, !(b is NSPopUpButton), b.bounds.width > 0 { found.append(b) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    @MainActor
    func testTheVolumeMuteButtonIsATwentyPointTarget() {
        let controller = QudelixController()
        controller.connection = .connected(name: "Qudelix-5K USB DAC")
        let (window, host) = hostInWindow(VolumeControl().environmentObject(controller))
        defer { window.close() }
        let buttons = glyphButtons(in: host.view)
        XCTAssertFalse(buttons.isEmpty)
        for button in buttons {
            XCTAssertGreaterThanOrEqual(button.frame.width, 20)
            XCTAssertGreaterThanOrEqual(button.frame.height, 20)
        }
    }

    @MainActor
    private func footer(connected: Bool) -> some View {
        let controller = QudelixController()
        controller.connection = connected ? .connected(name: "Qudelix-5K USB DAC") : .disconnected
        return FooterBar(showDiagnostics: .constant(false), showDeviceSettings: .constant(false),
                         showAbout: .constant(false), showBattery: .constant(false))
            .environmentObject(controller)
            .environmentObject(A2dpGuard())
    }

    @MainActor
    func testEveryFooterButtonIsATwentyPointTarget() {
        let (window, host) = hostInWindow(footer(connected: true))
        defer { window.close() }
        let buttons = glyphButtons(in: host.view)
        XCTAssertGreaterThanOrEqual(buttons.count, 4)
        for button in buttons {
            XCTAssertGreaterThanOrEqual(button.frame.height, 20, button.toolTip ?? "")
            XCTAssertGreaterThanOrEqual(button.frame.width, 20, button.toolTip ?? "")
        }
    }

    @MainActor
    func testTheFooterIsTheSameHeightConnectedOrNot() {
        let connected = settledHeight(footer(connected: true))
        let away = settledHeight(footer(connected: false))
        XCTAssertEqual(connected, away, accuracy: 0.5)
        XCTAssertLessThan(away, 40)
    }

    func testTheStatusLineNamesTheLinkOnlyOnce() {
        let line = DeviceHeader.statusLine(connected: true, firmware: "3.1.8", codec: nil,
                                           sampleRate: "96 kHz", inputSource: "USB",
                                           battery: 81, charging: true)
        XCTAssertEqual(line, "FW 3.1.8 \u{00B7} charging \u{00B7} 96 kHz \u{00B7} USB")
        XCTAssertEqual(line.components(separatedBy: "USB").count - 1, 1)
    }

    func testABatteryWarningComesBeforeTheCodecDetailsThatWouldPushItOut() {
        let low = DeviceHeader.statusLine(connected: true, firmware: "3.1.8", codec: "aptX Adaptive",
                                          sampleRate: "48 kHz", inputSource: "A2DP 1",
                                          battery: 15, charging: false)
        XCTAssertEqual(low, "FW 3.1.8 \u{00B7} battery low \u{00B7} aptX Adaptive \u{00B7} 48 kHz \u{00B7} A2DP 1")
        let veryLow = DeviceHeader.statusLine(connected: true, firmware: nil, codec: "aptX",
                                              sampleRate: "48 kHz", inputSource: "A2DP 1",
                                              battery: 7, charging: false)
        XCTAssertTrue(veryLow.hasPrefix("battery very low"), veryLow)
        let healthy = DeviceHeader.statusLine(connected: true, firmware: nil, codec: nil,
                                              sampleRate: nil, inputSource: nil,
                                              battery: 80, charging: false)
        XCTAssertEqual(healthy, "idle")
    }

    func testAnIdleInputDropsTheRateAndSaysIdle() {
        let line = DeviceHeader.statusLine(connected: true, firmware: "3.1.8", codec: "None",
                                           sampleRate: "96 kHz", inputSource: "None",
                                           battery: nil, charging: false)
        XCTAssertEqual(line, "FW 3.1.8 \u{00B7} idle")
    }

    func testNotConnectedSaysSoWhateverElseIsKnown() {
        XCTAssertEqual(DeviceHeader.statusLine(connected: false, firmware: "3.1.8", codec: "aptX",
                                               sampleRate: "48 kHz", inputSource: "USB",
                                               battery: 5, charging: false),
                       "Not connected")
    }
}
