import AppKit
import CoreAudio
import SwiftUI
import XCTest
@testable import QudelixBar

final class PerAppEqTests: XCTestCase {
    func testTheAssignmentListIsBoundedAtTheNumberOfChainsThatExist() {
        let raw = (0..<40).map { AppAssignment(bundleID: "app.\($0)", presetID: UUID()) }
        let kept = AppAssignments.sanitized(raw)
        XCTAssertEqual(kept.count, AppAssignments.maxAssignments)
        XCTAssertEqual(kept.first?.bundleID, "app.0")
        XCTAssertLessThanOrEqual(kept.count, StageProcessor.maxAssignedApps)
    }

    func testDuplicateAndEmptyBundleIdsAreDroppedAndOrderIsKept() {
        let raw = [
            AppAssignment(bundleID: "com.b.app"),
            AppAssignment(bundleID: ""),
            AppAssignment(bundleID: "com.a.app"),
            AppAssignment(bundleID: "com.b.app", displayName: "again"),
        ]
        let kept = AppAssignments.sanitized(raw)
        XCTAssertEqual(kept.map(\.bundleID), ["com.b.app", "com.a.app"])
    }

    func testABundleIdFromAFileIsScrubbedAndLengthCapped() {
        let hostile = "com.evil\u{202E}.app" + String(repeating: "x", count: 4000)
        let clean = AppAssignments.clampedBundleID(hostile)
        XCTAssertFalse(clean.contains("\u{202E}"))
        XCTAssertLessThanOrEqual(clean.count, AppAssignments.maxBundleIDLength + 1)

        let name = AppAssignments.clampedName("Spo\u{0007}tify"
            + String(repeating: "y", count: 400))
        XCTAssertFalse(name.contains("\u{0007}"))
        XCTAssertLessThanOrEqual(name.count, AppAssignments.maxNameLength + 1)
    }

    func testAnAppWithNoNameIsCalledAfterTheTailOfItsBundleId() {
        XCTAssertEqual(AppAssignments.displayName(for: "com.spotify.client",
                                                  fallbackName: ""), "client")
        XCTAssertEqual(AppAssignments.displayName(for: "com.spotify.client",
                                                  fallbackName: "Spotify"), "Spotify")
    }

    func testADeletedPresetLeavesTheRowOnDefaultAndSaysSo() {
        let gone = UUID()
        let kept = tenBandPreset(named: "Keeper")
        let resolved = AppAssignments.resolve(
            assignments: [AppAssignment(bundleID: "com.a", presetID: gone),
                          AppAssignment(bundleID: "com.b", presetID: kept.id),
                          AppAssignment(bundleID: "com.c", presetID: nil)],
            presets: [kept])
        XCTAssertEqual(resolved.count, 3)
        XCTAssertNil(resolved[0].preset)
        XCTAssertTrue(resolved[0].missingPreset)
        XCTAssertFalse(resolved[0].wantsTap)
        XCTAssertEqual(resolved[1].preset?.id, kept.id)
        XCTAssertFalse(resolved[1].missingPreset)
        XCTAssertTrue(resolved[1].wantsTap)
        XCTAssertNil(resolved[2].preset)
        XCTAssertFalse(resolved[2].missingPreset, "Default is a choice, not a loss")
    }

    func testAPresetFromTheOtherBankResolvesLikeAnyOther() {
        let twenty = LibraryPreset(name: "Studio", group: .b20,
                                   bands: QxEqGroup.b20.defaultFreqs.map {
                                       QxEqBandValue(filter: .peak, freq: $0,
                                                     gain: 2, q: 1)
                                   }, preGain: -3)
        let resolved = AppAssignments.resolve(
            assignments: [AppAssignment(bundleID: "com.a", presetID: twenty.id)],
            presets: [twenty])
        XCTAssertEqual(resolved.first?.preset?.group, .b20)
        XCTAssertTrue(resolved.first?.wantsTap ?? false,
                      "the Mac-side chain has its own band count")
    }

    func testTheAppsOwnProcessesAreNeverOfferedARowOfTheirOwn() {
        XCTAssertTrue(AppAssignments.isHiddenFromList("com.qudelixbar.app", own: nil))
        XCTAssertTrue(AppAssignments.isHiddenFromList("me.myself", own: "me.myself"))
        XCTAssertTrue(AppAssignments.isHiddenFromList("com.apple.audio.coreaudiod",
                                                      own: nil))
        XCTAssertTrue(AppAssignments.isHiddenFromList("", own: nil))
        XCTAssertFalse(AppAssignments.isHiddenFromList("com.spotify.client", own: nil))
    }
    func testNothingAssignedPlansNoTaps() {
        XCTAssertTrue(StageEngine.tapPlan(assignments: [], runningProcesses: [],
                                          selfPID: 99).isEmpty)
        let onDefault = AppAssignments.resolve(
            assignments: [AppAssignment(bundleID: "com.a", presetID: nil)], presets: [])
        XCTAssertTrue(StageEngine.tapPlan(
            assignments: onDefault,
            runningProcesses: [RunningAudioProcess(bundleID: "com.a", pid: 7, object: 1)],
            selfPID: 99).isEmpty, "Default means leave the app in the catch-all")
    }

    func testAnAssignedAppThatIsNotRunningGetsNoTap() {
        let plan = StageEngine.tapPlan(assignments: assigned(["com.a"]),
                                       runningProcesses: [],
                                       selfPID: 99)
        XCTAssertTrue(plan.isEmpty, "a tap over no processes has nothing to capture")
    }

    func testOneAppsSeveralHelperProcessesBecomeOneTap() {
        let plan = StageEngine.tapPlan(
            assignments: assigned(["com.browser"]),
            runningProcesses: [
                RunningAudioProcess(bundleID: "com.browser", pid: 3, object: 30),
                RunningAudioProcess(bundleID: "com.browser", pid: 4, object: 10),
                RunningAudioProcess(bundleID: "com.browser", pid: 5, object: 20),
            ],
            selfPID: 99)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].objects, [10, 20, 30], "sorted, so two reads compare equal")
    }

    func testDuplicateProcessObjectsAreDeduped() {
        let plan = StageEngine.tapPlan(
            assignments: assigned(["com.a"]),
            runningProcesses: [
                RunningAudioProcess(bundleID: "com.a", pid: 3, object: 5),
                RunningAudioProcess(bundleID: "com.a", pid: 4, object: 5),
            ],
            selfPID: 99)
        XCTAssertEqual(plan.first?.objects, [5])
    }

    func testThisAppsOwnProcessesAreDroppedFromThePlan() {
        let plan = StageEngine.tapPlan(
            assignments: assigned(["com.a"]),
            runningProcesses: [
                RunningAudioProcess(bundleID: "com.a", pid: 99, object: 1),
                RunningAudioProcess(bundleID: "com.a", pid: 5, object: 2),
            ],
            selfPID: 99)
        XCTAssertEqual(plan.first?.objects, [2])
    }

    func testOverTheCapThePlanSortsByBundleIdAndThenCuts() {
        let ids = (0..<12).map { "com.app.\(String(format: "%02d", $0))" }
        let processes = ids.reversed().enumerated().map { index, id in
            RunningAudioProcess(bundleID: id, pid: pid_t(index + 1),
                                object: AudioObjectID(index + 1))
        }
        let plan = StageEngine.tapPlan(assignments: assigned(ids),
                                       runningProcesses: processes, selfPID: 99)
        XCTAssertEqual(plan.count, AppAssignments.maxAssignments)
        XCTAssertEqual(plan.map(\.bundleID), Array(ids.prefix(8)))
    }

    func testUnassignedAppsAreNeitherTappedNorExcluded() {
        let plan = StageEngine.tapPlan(
            assignments: assigned(["com.a"]),
            runningProcesses: [
                RunningAudioProcess(bundleID: "com.a", pid: 1, object: 1),
                RunningAudioProcess(bundleID: "com.other", pid: 2, object: 2),
            ],
            selfPID: 99)
        XCTAssertEqual(plan.map(\.bundleID), ["com.a"])
        XCTAssertFalse(plan.flatMap(\.objects).contains(2))
    }

    func testThePlanCarriesTheCurveTheRowNamed() {
        let preset = tenBandPreset(named: "Warm")
        let resolved = AppAssignments.resolve(
            assignments: [AppAssignment(bundleID: "com.a", presetID: preset.id)],
            presets: [preset])
        let plan = StageEngine.tapPlan(
            assignments: resolved,
            runningProcesses: [RunningAudioProcess(bundleID: "com.a", pid: 1, object: 1)],
            selfPID: 99)
        XCTAssertEqual(plan.first?.chain.bands.count, preset.bands.count)
        XCTAssertEqual(plan.first?.chain.preGain, preset.preGain)
    }
    func testPerAppEqIsAReasonToInsertEvenWithTheStageOff() {
        XCTAssertEqual(StageState.wantedMode(stageEnabled: false, perAppEQ: true,
                                             levelTracking: false,
                                             detectQuality: false), .insert)
        XCTAssertEqual(StageState.wantedMode(stageEnabled: false, perAppEQ: true,
                                             levelTracking: true,
                                             detectQuality: true), .insert,
                       "monitor mode writes nothing, so it could never be heard")
        XCTAssertEqual(StageState.wantedMode(stageEnabled: true, perAppEQ: false,
                                             levelTracking: false,
                                             detectQuality: false), .insert)
        XCTAssertEqual(StageState.wantedMode(stageEnabled: false, perAppEQ: false,
                                             levelTracking: true,
                                             detectQuality: false), .monitor)
        XCTAssertNil(StageState.wantedMode(stageEnabled: false, perAppEQ: false,
                                           levelTracking: false, detectQuality: false))
    }

    func testTheHeartbeatCountsAppsAndNeverNamesThem() {
        let line = StageState.perAppDiag(taps: 2, assigned: 3)
        XCTAssertEqual(line, "apps=2/3")
        XCTAssertEqual(StageState.perAppDiag(taps: -1, assigned: -4), "apps=0/0")
    }
    func testAssignmentsRoundTripThroughThePresetsDocument() throws {
        let preset = tenBandPreset(named: "Warm")
        let document = PresetLibraryDocument(
            headphoneName: "Alder AR-5", presets: [preset],
            appAssignments: [AppAssignment(bundleID: "com.spotify.client",
                                           displayName: "Spotify",
                                           presetID: preset.id),
                             AppAssignment(bundleID: "com.apple.Music",
                                           displayName: "Music")])
        let data = try JSONEncoder().encode(document)
        let back = try JSONDecoder().decode(PresetLibraryDocument.self, from: data)
        XCTAssertEqual(back.appAssignments.count, 2)
        XCTAssertEqual(back.appAssignments[0].presetID, preset.id)
        XCTAssertNil(back.appAssignments[1].presetID)
        XCTAssertEqual(back.presets.map(\.id), [preset.id])
    }

    func testADocumentWrittenBeforeThisFeatureStillOpens() throws {
        let json = """
        {"schemaVersion":1,"headphoneName":"HD 650","suggestedHeadphones":[],
         "presets":[]}
        """
        let back = try JSONDecoder().decode(PresetLibraryDocument.self,
                                            from: Data(json.utf8))
        XCTAssertTrue(back.appAssignments.isEmpty)
        XCTAssertEqual(back.headphoneName, "HD 650")
    }

    func testADocumentWrittenNowStillCarriesEveryOlderField() throws {
        let preset = tenBandPreset(named: "Warm")
        let data = try JSONEncoder().encode(PresetLibraryDocument(
            headphoneName: "HD 650", suggestedHeadphones: ["HD 650"],
            presets: [preset],
            appAssignments: [AppAssignment(bundleID: "com.a", presetID: preset.id)]))
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data)
                                    as? [String: Any])
        for key in ["schemaVersion", "headphoneName", "suggestedHeadphones", "presets"] {
            XCTAssertNotNil(raw[key], "an older build reads \(key)")
        }
        XCTAssertNotNil(raw["appAssignments"])
    }

    func testOneBadAssignmentRecordCostsOneRecordNotTheDocument() throws {
        let json = """
        {"schemaVersion":1,"headphoneName":"","suggestedHeadphones":[],"presets":[],
         "appAssignments":[{"bundleID":"com.good","displayName":"Good"},
                           ["not an object"],
                           {"bundleID":"com.other","displayName":"Other"}]}
        """
        let back = try JSONDecoder().decode(PresetLibraryDocument.self,
                                            from: Data(json.utf8))
        XCTAssertEqual(back.appAssignments.map(\.bundleID), ["com.good", "com.other"])
    }

    func testAHandEditedDocumentCannotAskForMoreChainsThanExist() {
        let document = PresetLibraryDocument(
            appAssignments: (0..<50).map { AppAssignment(bundleID: "com.app.\($0)") })
        let clean = PresetLibraryFile.sanitize(document)
        XCTAssertEqual(clean.appAssignments.count, AppAssignments.maxAssignments)
    }

    func testTheMasterSwitchSurvivesAStateFileRoundTripAndDefaultsOn() throws {
        var state = PersistedStageState()
        state.perAppEQ = false
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(PersistedStageState.self,
                                                from: data).perAppEQ, false)
        let olderJSON = """
        {"stageByDevice":{},"exposure":[],"levelTracking":false,"detectQuality":true}
        """
        let older = try JSONDecoder().decode(PersistedStageState.self,
                                             from: Data(olderJSON.utf8))
        XCTAssertNil(older.perAppEQ, "an older document says nothing, which reads as on")
    }
    func testWithNoAssignmentsTheRenderPathIsBitIdentical() {
        let frames = 2048
        let samples = Self.deterministicStereo(frames: frames)

        let plain = StageProcessor()
        plain.prepare(sampleRate: 48000)
        plain.applyStage(Self.fullStage())

        let touched = StageProcessor()
        touched.prepare(sampleRate: 48000)
        touched.applyStage(Self.fullStage())
        touched.applyAppChains([AppCurve(bundleID: "com.a", preGain: -6,
                                         bands: Self.bell())])
        touched.applyAppChains([])
        XCTAssertEqual(touched.assignedAppCount, 0)

        XCTAssertEqual(Self.renderBits(plain, samples: samples, frames: frames),
                       Self.renderBits(touched, samples: samples, frames: frames),
                       "an empty assignment list must take today's path verbatim")
    }

    func testEachStreamGetsItsOwnGainAndAllOfThemLandOnOneBus() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyAppChains([AppCurve(bundleID: "com.a", preGain: -6.020_6, bands: []),
                          AppCurve(bundleID: "com.b", preGain: 6.020_6, bands: [])])

        let frames = 8
        let input = Buffers([(2, frames), (2, frames), (2, frames)])
        input.fill(0, [Float](repeating: 0.1, count: frames * 2))
        input.fill(1, [Float](repeating: 0.1, count: frames * 2))
        input.fill(2, [Float](repeating: 0.05, count: frames * 2))
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)

        for value in output.samples(0, count: frames * 2) {
            XCTAssertEqual(value, 0.05 + 0.2 + 0.05, accuracy: 1e-5)
        }
    }

    func testAnAssignedStreamIsFilteredWhileTheCatchAllPassesThroughRaw() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        let bands = Self.bell()
        p.applyAppChains([AppCurve(bundleID: "com.a", preGain: 0, bands: bands)])

        let frames = 64
        let impulse = Self.impulse(frames: frames)
        let input = Buffers([(2, frames), (2, frames)])
        input.fill(0, impulse)
        input.fill(1, [Float](repeating: 0.25, count: frames * 2))
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)

        let expected = Self.expectedChain(bands: bands, preGainDb: 0,
                                          input: impulse, frames: frames)
        let rendered = output.samples(0, count: frames * 2)
        for i in 0..<(frames * 2) {
            XCTAssertEqual(rendered[i], expected[i] + 0.25, accuracy: 1e-5,
                           "sample \(i)")
        }
        XCTAssertNotEqual(rendered[0], impulse[0] + 0.25,
                          "the assigned stream went through its own chain")
    }

    func testTheStreamsAreTakenFromTheEndSoADeviceInputNeverBecomesAChain() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyAppChains([AppCurve(bundleID: "com.a", preGain: 0, bands: [])])

        let frames = 8
        let input = Buffers([(1, frames), (2, frames), (2, frames)])
        input.fill(0, [Float](repeating: 9, count: frames))
        input.fill(1, [Float](repeating: 0.2, count: frames * 2))
        input.fill(2, [Float](repeating: 0.05, count: frames * 2))
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)

        for value in output.samples(0, count: frames * 2) {
            XCTAssertEqual(value, 0.25, accuracy: 1e-6)
        }
    }

    func testAMalformedBufferHoldsItsPositionSoChainsStayWithTheirStreams() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyAppChains([AppCurve(bundleID: "com.a", preGain: -6.020_6, bands: []),
                          AppCurve(bundleID: "com.b", preGain: 6.020_6, bands: [])])

        let frames = 8
        let input = Buffers([(2, frames), (2, frames), (2, frames)])
        input.fill(0, [Float](repeating: 0.1, count: frames * 2))
        input.fill(1, [Float](repeating: 0.1, count: frames * 2))
        input.fill(2, [Float](repeating: 0.05, count: frames * 2))
        input.blank(1)
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)

        for value in output.samples(0, count: frames * 2) {
            XCTAssertEqual(value, 0.05 + 0.05, accuracy: 1e-6,
                           "stream 0 kept chain 0 and the catch-all stayed last")
        }
    }

    func testTheBlockLengthComesFromTheOutputNotFromAStreamsClaim() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyAppChains([AppCurve(bundleID: "com.a", preGain: 0, bands: [])])

        let input = Buffers([(2, 64), (2, 64)])
        input.fill(0, [Float](repeating: 0.1, count: 128))
        input.fill(1, [Float](repeating: 0.1, count: 128))
        let output = Buffers([(2, 8)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)

        XCTAssertEqual(p.renderDiagnostics().channels, 2)
        for value in output.samples(0, count: 16) {
            XCTAssertEqual(value, 0.2, accuracy: 1e-6)
        }
    }

    func testTheBypassEdgeWipesEveryStreamsFilterMemory() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        let bands = [QxEqBandValue(filter: .peak, freq: 120, gain: 12, q: 8)]
        p.applyAppChains([AppCurve(bundleID: "com.a", preGain: 0, bands: bands)])

        let frames = 128
        let loud = Buffers([(2, frames), (2, frames)])
        loud.fill(0, (0..<(frames * 2)).map { _ in Float(0.8) })
        loud.fill(1, [Float](repeating: 0, count: frames * 2))
        let out1 = Buffers([(2, frames)])
        p.render(input: loud.constPointer, output: out1.list.unsafeMutablePointer)
        XCTAssertGreaterThan(out1.samples(0, count: frames * 2).map(abs).max() ?? 0, 0.1)

        let single = Buffers([(2, frames)])
        single.fill(0, [Float](repeating: 0, count: frames * 2))
        let out2 = Buffers([(2, frames)])
        p.render(input: single.constPointer, output: out2.list.unsafeMutablePointer)

        let quiet = Buffers([(2, frames), (2, frames)])
        quiet.fill(0, [Float](repeating: 0, count: frames * 2))
        quiet.fill(1, [Float](repeating: 0, count: frames * 2))
        let out3 = Buffers([(2, frames)])
        p.render(input: quiet.constPointer, output: out3.list.unsafeMutablePointer)

        XCTAssertEqual(out3.samples(0, count: frames * 2).map(abs).max() ?? 1, 0,
                       "re-engaging must not replay the tail frozen in the chain")
    }

    func testANonFiniteAssignedStreamNeverPoisonsTheBusOrTheNextBlock() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyAppChains([AppCurve(bundleID: "com.a", preGain: 0, bands: Self.bell())])

        let frames = 32
        let bad = Buffers([(2, frames), (2, frames)])
        bad.fill(0, (0..<(frames * 2)).map { $0 % 3 == 0 ? Float.nan : Float(3e38) })
        bad.fill(1, [Float](repeating: 0.1, count: frames * 2))
        let out1 = Buffers([(2, frames)])
        p.render(input: bad.constPointer, output: out1.list.unsafeMutablePointer)
        XCTAssertTrue(out1.samples(0, count: frames * 2).allSatisfy(\.isFinite))

        let good = Buffers([(2, frames), (2, frames)])
        good.fill(0, (0..<(frames * 2)).map { Float(sin(Double($0) * 0.2)) * 0.3 })
        good.fill(1, [Float](repeating: 0, count: frames * 2))
        let out2 = Buffers([(2, frames)])
        p.render(input: good.constPointer, output: out2.list.unsafeMutablePointer)
        let recovered = out2.samples(0, count: frames * 2)
        XCTAssertTrue(recovered.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(recovered.map(abs).max() ?? 0, 0.01,
                             "the chain healed rather than staying dead")
    }

    func testMonitorModeStillWritesNothingEvenWithChainsPublished() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.setMonitorOnly(true)
        p.applyAppChains([AppCurve(bundleID: "com.a", preGain: 0, bands: Self.bell())])

        let frames = 32
        let input = Buffers([(2, frames), (2, frames)])
        let samples = Self.deterministicStereo(frames: frames)
        input.fill(0, samples)
        input.fill(1, samples)
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)

        XCTAssertTrue(output.samples(0, count: frames * 2).allSatisfy { $0 == 0 })
        XCTAssertEqual(input.samples(0, count: frames * 2).map(\.bitPattern),
                       samples.map(\.bitPattern))
    }

    func testTheChainIsCappedAtTheSectionsTheTableHolds() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        let many = (0..<64).map {
            QxEqBandValue(filter: .peak, freq: 60 + $0 * 100, gain: 1, q: 1)
        }
        p.applyAppChains([AppCurve(bundleID: "com.a", preGain: 0, bands: many)])
        let frames = 16
        let input = Buffers([(2, frames), (2, frames)])
        input.fill(0, [Float](repeating: 0.1, count: frames * 2))
        input.fill(1, [Float](repeating: 0, count: frames * 2))
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        XCTAssertTrue(output.samples(0, count: frames * 2).allSatisfy(\.isFinite))
    }

    func testMoreCurvesThanChainsAreRefusedRatherThanTruncatedOnTheRenderThread() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.applyAppChains((0..<40).map {
            AppCurve(bundleID: "com.app.\($0)", preGain: 0, bands: [])
        })
        XCTAssertEqual(p.assignedAppCount, StageProcessor.maxAssignedApps)
    }
    func testTheThisAppRowNamesPerAppEqEvenWithTheStageOff() {
        var inputs = SignalPath.Inputs(engineMode: .insert, perAppCount: 2)
        inputs.stage.enabled = false
        let row = SignalPath.rows(inputs).first { $0.id == "app" }
        XCTAssertEqual(row?.state, "per-app EQ (2 apps)")
        XCTAssertEqual(row?.indicator, .altering)
    }

    func testTheThisAppRowNamesPerAppEqBesideTheStage() {
        var stage = StageSettings()
        stage.enabled = true
        stage.width = 150
        let row = SignalPath.rows(SignalPath.Inputs(engineMode: .insert, stage: stage,
                                                    perAppCount: 1))
            .first { $0.id == "app" }
        XCTAssertTrue(row?.state.hasPrefix("Soundstage inserted") ?? false)
        XCTAssertTrue(row?.state.contains("per-app EQ (1 app)") ?? false)
    }

    func testWithNoAssignedAppsTheRowSaysNothingAboutThem() {
        var stage = StageSettings()
        stage.enabled = true
        let row = SignalPath.rows(SignalPath.Inputs(engineMode: .insert, stage: stage))
            .first { $0.id == "app" }
        XCTAssertFalse(row?.state.contains("per-app") ?? true)
    }
    @MainActor
    func testThePresetsPaneStillFitsWithTheAppsSectionOpenAndPopulated() {
        let controller = QudelixController()
        controller.connection = .connected(name: "Qudelix-5K USB DAC")
        controller.compatibility = .ok
        controller.presetNames = [0: "Harman", 2: "Alder AR-5"]

        let ten = QxEqGroup.user.defaultFreqs.map {
            QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1)
        }
        let presets = (0..<4).map {
            LibraryPreset(name: "Preset \($0)", group: .user, bands: ten, preGain: -3)
        }
        let library = PresetLibrary()
        library.previewSet(presets: presets, headphoneName: "Alder AR-5")

        let apps = AppAssignments()
        apps.libraryPresets = { presets }
        apps.previewSet(
            assignments: (0..<AppAssignments.maxAssignments).map {
                AppAssignment(bundleID: "com.app.\($0)", displayName: "App \($0)",
                              presetID: presets[$0 % presets.count].id)
            },
            enabled: true,
            running: (0..<8).map {
                RunningAudioProcess(bundleID: "com.running.\($0)", pid: pid_t(10 + $0),
                                    object: AudioObjectID(10 + $0), playing: true)
            })
        apps.previewExpanded = true

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apps-pane-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let studio = AIPresetStudio(
            research: AIResearchStore(directory: directory),
            defaults: UserDefaults(suiteName: "qudelixbar.tests.apps") ?? .standard)

        let root = PresetsView()
            .environmentObject(controller)
            .environmentObject(StageState())
            .environmentObject(ProfileRules())
            .environmentObject(library)
            .environmentObject(apps)
            .environmentObject(studio)
            .environmentObject(HeadphoneSuggestions(library: library))
            .environmentObject(ABTuner())
            .environmentObject(ToneTester())
            .environmentObject(BlindTuner())
            .frame(width: 372)

        let host = NSHostingView(rootView: AnyView(root))
        host.layoutSubtreeIfNeeded()
        let wanted = host.fittingSize.height
        print(String(format: "presets (apps open): content %.1f pt vs %.0f pt pane — %@",
                     wanted, PopoverView.contentHeight,
                     wanted <= PopoverView.contentHeight ? "fits" : "OVERFLOWS"))
        XCTAssertLessThanOrEqual(
            wanted, PopoverView.contentHeight,
            "the Presets pane overflows with the Apps section open: \(wanted) pt")
    }

    @MainActor
    func testTheRowListShowsAssignedAppsFirstThenWhateverIsPlaying() {
        let preset = tenBandPreset(named: "Warm")
        let apps = AppAssignments()
        apps.libraryPresets = { [preset] }
        apps.previewSet(
            assignments: [AppAssignment(bundleID: "com.assigned", displayName: "Assigned",
                                        presetID: preset.id)],
            enabled: true,
            running: [
                RunningAudioProcess(bundleID: "com.assigned", pid: 1, object: 1,
                                    playing: true),
                RunningAudioProcess(bundleID: "com.qudelixbar.app", pid: 2, object: 2),
                RunningAudioProcess(bundleID: "com.zed.player", pid: 3, object: 3),
            ])
        let rows = apps.rows()
        XCTAssertEqual(rows.map(\.bundleID), ["com.assigned", "com.zed.player"])
        XCTAssertTrue(rows[0].assigned)
        XCTAssertTrue(rows[0].playing)
        XCTAssertEqual(rows[0].preset?.id, preset.id)
        XCTAssertFalse(rows[1].assigned)
    }

    @MainActor
    func testTheMasterSwitchOffMeansNoAppWantsATap() {
        let preset = tenBandPreset(named: "Warm")
        let apps = AppAssignments()
        apps.libraryPresets = { [preset] }
        apps.previewSet(assignments: [AppAssignment(bundleID: "com.a",
                                                    presetID: preset.id)],
                        enabled: false)
        XCTAssertEqual(apps.activeCount, 0)
        apps.setEnabled(true)
        XCTAssertEqual(apps.activeCount, 1)
    }

    @MainActor
    func testAnAppCanOnlyBeAssignedUntilTheChainsRunOut() {
        let preset = tenBandPreset(named: "Warm")
        let apps = AppAssignments()
        apps.libraryPresets = { [preset] }
        apps.previewSet(assignments: [], enabled: true)
        for i in 0..<(AppAssignments.maxAssignments + 4) {
            apps.assign(preset.id, to: "com.app.\(i)", named: "App \(i)")
        }
        XCTAssertEqual(apps.assignments.count, AppAssignments.maxAssignments)
        XCTAssertTrue(apps.isFull)

        apps.forget("com.app.0")
        XCTAssertEqual(apps.assignments.count, AppAssignments.maxAssignments - 1)
        apps.assign(nil, to: "com.never.seen", named: "Nobody")
        XCTAssertEqual(apps.assignments.count, AppAssignments.maxAssignments - 1,
                       "Default is the absence of an assignment, not one of them")
    }

    @MainActor
    func testAPresetLeavingTheLibraryKeepsTheRowAndStopsItsTap() {
        let preset = tenBandPreset(named: "Warm")
        var live = [preset]
        let apps = AppAssignments()
        apps.libraryPresets = { live }
        apps.previewSet(assignments: [AppAssignment(bundleID: "com.a",
                                                    presetID: preset.id)],
                        enabled: true)
        XCTAssertEqual(apps.activeCount, 1)

        live = []
        XCTAssertTrue(apps.resolved.first?.missingPreset ?? false)
        XCTAssertEqual(apps.activeCount, 0, "a row on Default gets no tap")
        XCTAssertEqual(apps.assignments.first?.presetID, preset.id,
                       "the id survives, so re-importing the preset restores the row")

        live = [preset]
        XCTAssertFalse(apps.resolved.first?.missingPreset ?? true)
        XCTAssertEqual(apps.activeCount, 1)
    }
    private func assigned(_ ids: [String]) -> [ResolvedAssignment] {
        let presets = ids.map { tenBandPreset(named: "For " + $0) }
        return AppAssignments.resolve(
            assignments: zip(ids, presets).map {
                AppAssignment(bundleID: $0, presetID: $1.id)
            },
            presets: presets)
    }

    private func tenBandPreset(named name: String) -> LibraryPreset {
        LibraryPreset(name: name, group: .user,
                      bands: QxEqGroup.user.defaultFreqs.map {
                          QxEqBandValue(filter: .peak, freq: $0, gain: 1.5, q: 1)
                      },
                      preGain: -4)
    }

    private static func bell() -> [QxEqBandValue] {
        [QxEqBandValue(filter: .peak, freq: 200, gain: 6, q: 1.2),
         QxEqBandValue(filter: .highShelf, freq: 6000, gain: -4, q: 0.7)]
    }

    private static func impulse(frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2)
        out[0] = 1
        out[1] = 0.5
        return out
    }

    private static func expectedChain(bands: [QxEqBandValue], preGainDb: Double,
                                      input: [Float], frames: Int) -> [Float] {
        let sections = bands.compactMap {
            StageProcessor.appSection($0, sampleRate: 48000)
        }
        let gain = pow(10, preGainDb / 20)
        var z = [Double](repeating: 0, count: sections.count * 4)
        var out = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            var l = Double(input[f * 2]) * gain
            var r = Double(input[f * 2 + 1]) * gain
            for (s, c) in sections.enumerated() {
                let base = s * 4
                let yl = c.b0 * l + z[base]
                z[base] = c.b1 * l - c.a1 * yl + z[base + 1]
                z[base + 1] = c.b2 * l - c.a2 * yl
                l = yl
                let yr = c.b0 * r + z[base + 2]
                z[base + 2] = c.b1 * r - c.a1 * yr + z[base + 3]
                z[base + 3] = c.b2 * r - c.a2 * yr
                r = yr
            }
            out[f * 2] = Float(l)
            out[f * 2 + 1] = Float(r)
        }
        return out
    }

    private static func fullStage() -> StageSettings {
        var s = StageSettings()
        s.enabled = true
        s.width = 160
        s.crossfeed = 0.5
        s.dialogue = 3
        s.room = 0.6
        s.distance = 0.4
        s.span = 0.6
        s.center = -1
        s.size = 0.5
        s.night = 0.4
        return s
    }

    private static func renderBits(_ p: StageProcessor, samples: [Float],
                                   frames: Int) -> [UInt32] {
        let input = Buffers([(2, frames)])
        input.fill(0, samples)
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
        return output.samples(0, count: frames * 2).map(\.bitPattern)
    }

    private static func deterministicStereo(frames: Int) -> [Float] {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: state)) / Float(Int64.max) * 0.15
            let tone = Float(sin(Double(i) * 0.031)) * 0.35
            out[i * 2] = tone + noise
            out[i * 2 + 1] = tone * 0.8 - noise
        }
        return out
    }

    private final class Buffers {
        let list: UnsafeMutableAudioBufferListPointer
        private var blocks: [UnsafeMutablePointer<Float>] = []

        init(_ shapes: [(channels: Int, frames: Int)]) {
            list = AudioBufferList.allocate(maximumBuffers: shapes.count)
            for (i, shape) in shapes.enumerated() {
                let count = shape.channels * shape.frames
                let block = UnsafeMutablePointer<Float>.allocate(capacity: count)
                block.initialize(repeating: 0, count: count)
                blocks.append(block)
                list[i] = AudioBuffer(
                    mNumberChannels: UInt32(shape.channels),
                    mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(block))
            }
        }

        deinit {
            for block in blocks { block.deallocate() }
            free(list.unsafeMutablePointer)
        }

        var constPointer: UnsafePointer<AudioBufferList> {
            UnsafePointer(list.unsafeMutablePointer)
        }

        func fill(_ buffer: Int, _ samples: [Float]) {
            for (i, v) in samples.enumerated() { blocks[buffer][i] = v }
        }

        func blank(_ buffer: Int) {
            list[buffer].mNumberChannels = 0
        }

        func samples(_ buffer: Int, count: Int) -> [Float] {
            Array(UnsafeBufferPointer(start: blocks[buffer], count: count))
        }
    }
}
