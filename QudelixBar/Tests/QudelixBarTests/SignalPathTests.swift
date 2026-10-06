import XCTest
@testable import QudelixBar

final class SignalPathTests: XCTestCase {
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

    func testInsertModeWithEveryControlNeutralSaysSo() {
        var stage = StageSettings()
        stage.enabled = true
        stage.width = 100
        stage.crossfeed = 0
        stage.dialogue = 0
        stage.room = 0
        stage.distance = 0
        stage.center = 0
        stage.night = 0
        let inert = row("app", .init(engineMode: .insert, stage: stage))
        XCTAssertEqual(inert.state, "Soundstage inserted — every control at neutral")

        stage.center = -2
        let shaping = row("app", .init(engineMode: .insert, stage: stage))
        XCTAssertNotEqual(shaping.state, "Soundstage inserted — every control at neutral")
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

    func testAHeldEngineSaysItIsPausedRatherThanOff() {
        let inputs = SignalPath.Inputs(deviceConnected: true, engineRunning: false,
                                       callHold: true)
        let source = row("source", inputs)
        XCTAssertTrue(source.state.contains("paused for a call"), source.state)
        XCTAssertFalse(source.state.contains("engine off"), source.state)
        let output = row("output", inputs)
        XCTAssertTrue(output.state.contains("paused for a call"), output.state)
        XCTAssertFalse(output.state.contains("engine off"), output.state)
    }

    func testWithoutAHoldTheRowsStillSayEngineOff() {
        let inputs = SignalPath.Inputs(deviceConnected: true, engineRunning: false)
        XCTAssertTrue(row("source", inputs).state.contains("engine off"))
        XCTAssertTrue(row("output", inputs).state.contains("engine off"))
    }

    func testAHoldLeavesTheThisAppRowClaimingNothing() {
        let row = row("app", .init(engineRunning: false, callHold: true, engineMode: nil))
        XCTAssertEqual(row.indicator, .passthrough)
    }

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

    func testNoDeviceConnectedGatesEqAndOutputRowsOnly() {
        let inputs = SignalPath.Inputs(deviceConnected: false, engineRunning: true,
                                       engineMode: .monitor)
        let rows = Dictionary(uniqueKeysWithValues: SignalPath.rows(inputs).map { ($0.id, $0) })
        XCTAssertEqual(rows["eq"]?.state, "no device connected")
        XCTAssertEqual(rows["eq"]?.indicator, .unknown)
        XCTAssertEqual(rows["output"]?.state, "no device connected")
        XCTAssertEqual(rows["output"]?.indicator, .unknown)
        XCTAssertNotEqual(rows["app"]?.state, "no device connected")
    }

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

    func testAFailedStartIsNamedRatherThanReadingAsAnIdleEngine() {
        let row = row("source", .init(detectQuality: true, engineRunning: false,
                                      engineProblem: "creating the system audio tap failed"))
        XCTAssertTrue(row.state.contains("creating the system audio tap failed"))
        XCTAssertFalse(row.state.contains("nothing to measure"))
        XCTAssertEqual(row.indicator, .unknown)
    }

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

    func testMixerRowNeverClaimsToKnowWhetherSourceMatchedRate() {
        let connected = row("mixer", .init(mixerRateHz: 96000))
        XCTAssertTrue(connected.state.contains("96"))
        XCTAssertEqual(connected.indicator, .unknown)

        let noDevice = row("mixer", .init(mixerRateHz: nil))
        XCTAssertEqual(noDevice.indicator, .unknown)
    }

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

    func testNoRowEverClaimsBitPerfect() {
        let verdicts: [QualityAnalyzer.Verdict?] = [
            nil, .tooQuiet, .noTreble,
            .lossy(cutoffKHz: 16.4), .lossyHigh(cutoffKHz: 19.8),
            .losslessLike(cutoffKHz: 21.9), .hiRes(cutoffKHz: 24.5),
            .natural(cutoffKHz: 18.0),
        ]
        let modes: [StageEngine.Mode?] = [nil, .monitor, .insert]
        let links: [QudelixController.Link] = [.none, .usb, .bluetooth]
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

    private func row(_ id: String, _ inputs: SignalPath.Inputs) -> SignalPath.Row {
        guard let found = SignalPath.rows(inputs).first(where: { $0.id == id }) else {
            XCTFail("no row with id \(id)")
            return SignalPath.Row(id: id, name: "", state: "", indicator: .unknown)
        }
        return found
    }
}
