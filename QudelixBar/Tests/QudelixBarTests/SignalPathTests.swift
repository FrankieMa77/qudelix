import XCTest
@testable import QudelixBar

/// The signal-path inspector's honesty rules, checked directly against the
/// pure row derivation (`SignalPath.rows`) — no CoreAudio, no HID, no
/// `@MainActor` object required, which is the point of factoring it out.
///
/// The one rule every other test defers to: this view must never claim
/// bit-perfect playback. The tap that feeds it hands over audio already
/// converted to the device's rate, so whether the source matched that rate
/// is not something this app can observe — every row that doesn't know
/// something has to say so instead of guessing.
final class SignalPathTests: XCTestCase {

    // MARK: - This app / Soundstage (row 3)

    func testEngineOffMeansNothingInThisAppIsAltering() {
        let row = row("app", .init(engineMode: nil))
        XCTAssertEqual(row.state, "nothing in this app is altering the audio")
        XCTAssertEqual(row.indicator, .passthrough)
    }

    func testMonitorModeIsExplicitThatAudioIsUntouched() {
        let row = row("app", .init(engineMode: .monitor))
        XCTAssertTrue(row.state.contains("not in the path"))
        XCTAssertTrue(row.state.contains("untouched"))
        XCTAssertEqual(row.indicator, .passthrough)
    }

    func testInsertModeWithStageEnabledReportsProcessing() {
        var stage = StageSettings.music
        stage.enabled = true
        let row = row("app", .init(engineMode: .insert, stage: stage))
        XCTAssertTrue(row.state.hasPrefix("Soundstage inserted"))
        XCTAssertEqual(row.indicator, .altering)
    }

    func testInsertModeNamesWhichControlsAreActive() {
        var stage = StageSettings()
        stage.enabled = true
        stage.width = 150
        stage.crossfeed = 0.4
        let row = row("app", .init(engineMode: .insert, stage: stage))
        XCTAssertTrue(row.state.contains("width"))
        XCTAssertTrue(row.state.contains("crossfeed"))
        XCTAssertFalse(row.state.contains("dialogue"))
    }

    // MARK: - Qudelix EQ (row 4)

    func testEqOffReportsOffAndPassthrough() {
        let row = row("eq", .init(deviceConnected: true, eqEnabled: false))
        XCTAssertEqual(row.state, "off")
        XCTAssertEqual(row.indicator, .passthrough)
    }

    func testEqOnNamesBandCountPresetAndPreGain() {
        let row = row("eq", .init(deviceConnected: true, eqEnabled: true,
                                  bandCount: 20, activePresetName: "HD 650", preGain: -6.1))
        XCTAssertTrue(row.state.contains("20-band"))
        XCTAssertTrue(row.state.contains("HD 650"))
        XCTAssertTrue(row.state.contains("-6.1"))
        XCTAssertEqual(row.indicator, .altering)
    }

    func testEqWithNoActivePresetSlotReadsCustom() {
        let row = row("eq", .init(deviceConnected: true, eqEnabled: true, activePresetName: nil))
        XCTAssertTrue(row.state.contains("custom"))
    }

    func testEqWithMutedBandsDoesNotOverstateActiveBandCount() {
        let row = row("eq", .init(deviceConnected: true, eqEnabled: true,
                                  bandCount: 10, mutedBandCount: 3, activePresetName: "Harman"))
        XCTAssertTrue(row.state.contains("7 of 10 bands"))
        XCTAssertTrue(row.state.contains("3 muted"))
        XCTAssertFalse(row.state.contains("10-band"))
    }

    func testEqWithNoMutedBandsKeepsThePlainBandCountPhrasing() {
        let row = row("eq", .init(deviceConnected: true, eqEnabled: true,
                                  bandCount: 10, mutedBandCount: 0))
        XCTAssertTrue(row.state.contains("10-band"))
        XCTAssertFalse(row.state.contains("muted"))
    }

    // MARK: - No device connected

    func testNoDeviceConnectedGatesEqAndOutputRowsOnly() {
        let inputs = SignalPath.Inputs(deviceConnected: false, engineRunning: true,
                                       engineMode: .monitor)
        let rows = Dictionary(uniqueKeysWithValues: SignalPath.rows(inputs).map { ($0.id, $0) })
        XCTAssertEqual(rows["eq"]?.state, "no device connected")
        XCTAssertEqual(rows["eq"]?.indicator, .unknown)
        XCTAssertEqual(rows["output"]?.state, "no device connected")
        XCTAssertEqual(rows["output"]?.indicator, .unknown)
        // Source/mixer/this-app act on the Mac's default output, which the
        // 5K need not be — disconnecting the 5K must not blank them out.
        XCTAssertNotEqual(rows["app"]?.state, "no device connected")
    }

    // MARK: - Detection disabled (row 1)

    func testDetectionDisabledSaysSoRatherThanGuessing() {
        let row = row("source", .init(detectQuality: false, engineRunning: true,
                                      qualityVerdict: .losslessLike(cutoffKHz: 21.9)))
        XCTAssertEqual(row.state, "quality detection is off")
        XCTAssertEqual(row.indicator, .unknown)
    }

    func testEngineOffMeansSourceCannotBeJudged() {
        let row = row("source", .init(detectQuality: true, engineRunning: false))
        XCTAssertTrue(row.state.contains("engine off"))
        XCTAssertEqual(row.indicator, .unknown)
    }

    /// Detection is on out of the box, so the engine's first start happens
    /// before anyone has granted System Audio Recording. "engine off" alone
    /// made that denial look like a switch nobody flipped.
    func testAFailedStartIsNamedRatherThanReadingAsAnIdleEngine() {
        let row = row("source", .init(detectQuality: true, engineRunning: false,
                                      engineProblem: "creating the system audio tap failed"))
        XCTAssertTrue(row.state.contains("creating the system audio tap failed"))
        XCTAssertFalse(row.state.contains("nothing to measure"))
        XCTAssertEqual(row.indicator, .unknown)
    }

    /// A reason arrives only when there is one; an idle engine keeps the
    /// plain wording rather than inventing a fault.
    func testNoProblemMeansNoReasonIsInvented() {
        let row = row("source", .init(detectQuality: true, engineRunning: false,
                                      engineProblem: nil))
        XCTAssertEqual(row.state, "engine off — nothing to measure")
    }

    func testTooQuietReadsAsNothingPlaying() {
        let row = row("source", .init(detectQuality: true, engineRunning: true,
                                      qualityVerdict: .tooQuiet))
        XCTAssertEqual(row.state, "nothing playing")
    }

    // MARK: - macOS mixer (row 2): never claims to know what it can't

    func testMixerRowNeverClaimsToKnowWhetherSourceMatchedRate() {
        let connected = row("mixer", .init(mixerRateHz: 96000))
        XCTAssertTrue(connected.state.contains("96"))
        XCTAssertEqual(connected.indicator, .unknown)   // known rate, unknown history

        let noDevice = row("mixer", .init(mixerRateHz: nil))
        XCTAssertEqual(noDevice.indicator, .unknown)
    }

    /// This row describes the Mac's default output — the same chain as the
    /// rows above and below it. With the 5K attached but the Mac playing to
    /// its speakers, an unattributed "48 kHz" here reads as a claim about the
    /// 5K, whose real rate the Output row states separately.
    func testMixerRowNamesTheDeviceWhoseRateItIsReporting() {
        let row = row("mixer", .init(mixerRateHz: 48000,
                                     mixerDeviceName: "MacBook Pro Speakers"))
        XCTAssertTrue(row.state.hasPrefix("MacBook Pro Speakers"))
        XCTAssertTrue(row.state.contains("48 kHz"))
    }

    func testMixerRowWithADeviceNameLongerThanTheCapIsTruncated() {
        let row = row("mixer", .init(mixerRateHz: 48000,
                                     mixerDeviceName: String(repeating: "x", count: 300)))
        XCTAssertTrue(row.state.count < 200)
        XCTAssertTrue(row.state.contains("…"))
    }

    // MARK: - The honesty line, held across every combination

    /// No row string produced by any of these inputs may ever claim
    /// bit-perfect playback — the tap simply doesn't have the information
    /// that claim would require.
    func testNoRowEverClaimsBitPerfect() {
        let verdicts: [QualityAnalyzer.Verdict?] = [
            nil, .tooQuiet, .noTreble,
            .lossy(cutoffKHz: 16.4), .lossyHigh(cutoffKHz: 19.8),
            .losslessLike(cutoffKHz: 21.9), .hiRes(cutoffKHz: 24.5),
            .natural(cutoffKHz: 18.0),
        ]
        let modes: [StageEngine.Mode?] = [nil, .monitor, .insert]
        let links: [QudelixController.Link] = [.none, .usb, .bluetooth]
        // Both fields carry text from outside this file — the engine's own
        // failure summaries and a driver-supplied device name.
        let problems: [String?] = [nil, "creating the system audio tap failed",
                                   "needs macOS 14.2 or newer"]
        let deviceNames: [String?] = [nil, "MacBook Pro Speakers",
                                      String(repeating: "q", count: 300)]

        for verdict in verdicts {
        for detectOn in [true, false] {
        for engineRunning in [true, false] {
        for mode in modes {
        for eqOn in [true, false] {
        for connected in [true, false] {
        for link in links {
        for problem in problems {
        for deviceName in deviceNames {
            var stage = StageSettings.music
            stage.enabled = mode == .insert
            let inputs = SignalPath.Inputs(
                deviceConnected: connected,
                detectQuality: detectOn,
                engineRunning: engineRunning,
                qualityVerdict: verdict,
                engineProblem: problem,
                mixerRateHz: connected ? 96000 : nil,
                mixerDeviceName: deviceName,
                engineMode: mode,
                stage: stage,
                eqEnabled: eqOn,
                bandCount: 10,
                activePresetName: "Harman",
                preGain: -3,
                link: link,
                codecLabel: "LDAC",
                outputRateLabel: "96 kHz",
                outputHighGain: true,
                currentLevelDb: -20)
            for row in SignalPath.rows(inputs) {
                let lower = row.state.lowercased()
                XCTAssertFalse(lower.contains("bit-perfect"),
                               "row \(row.id): \(row.state)")
                XCTAssertFalse(lower.contains("bit perfect"),
                               "row \(row.id): \(row.state)")
            }
        }}}}}}}}}
    }

    // MARK: - Helpers

    private func row(_ id: String, _ inputs: SignalPath.Inputs) -> SignalPath.Row {
        guard let found = SignalPath.rows(inputs).first(where: { $0.id == id }) else {
            XCTFail("no row with id \(id)")
            return SignalPath.Row(id: id, name: "", state: "", indicator: .unknown)
        }
        return found
    }
}
