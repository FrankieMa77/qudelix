import XCTest
@testable import QudelixBar

@MainActor
final class TuneModelTests: XCTestCase {
    private func makeTune(_ rig: AutoRig) -> TuneModel {
        TuneModel(app: rig.app, routing: rig.stageRig?.routing, backend: rig.stageRig?.backend,
                  stage: rig.stageRig?.model, automation: rig.automation)
    }

    private func answerAll(_ tune: TuneModel, _ method: TuneMethod) {
        var guardCount = 0
        while guardCount < 200 {
            let phase: TunePhase
            switch method {
            case .compare: phase = tune.state.compare.phase
            case .shape: phase = tune.state.shape.phase
            case .check: phase = tune.state.check.phase
            case .trim: phase = tune.state.trim.phase
            case .tones: phase = tune.state.tones.phase
            }
            guard phase == .running else { return }
            tune.choose(preferA: guardCount % 2 == 0)
            guardCount += 1
        }
    }

    private func restored(_ rig: AutoRig) -> Bool {
        AutoRig.matches(rig.device.bands, rig.base)
            && abs(rig.device.preGain - -3) < 0.06
    }

    func testCompareWritesDuringTheSessionAndCancelRestoresTheBase() async throws {
        let rig = try await AutoRig()
        let tune = makeTune(rig)
        tune.start(.compare, seed: 7)
        await rig.settle()
        XCTAssertEqual(tune.state.active, .compare)
        XCTAssertTrue(tune.state.sessionActive)
        XCTAssertFalse(rig.app.eq.state.canEdit)
        XCTAssertEqual(rig.app.eq.state.readOnlyReason, EqEditorModel.sessionRefusal)
        tune.toggleSide()
        await rig.settle()
        XCTAssertFalse(restored(rig))
        tune.cancel()
        await rig.settle()
        XCTAssertTrue(restored(rig))
        XCTAssertFalse(tune.state.sessionActive)
        XCTAssertNil(tune.state.active)
        XCTAssertTrue(rig.app.eq.state.canEdit)
        XCTAssertFalse(rig.device.link.sentCommands.contains(.saveAll))
        await rig.close()
    }

    func testCompareRunsToAResultAndKeepWritesAndSaves() async throws {
        let rig = try await AutoRig()
        let tune = makeTune(rig)
        tune.start(.compare, seed: 11)
        answerAll(tune, .compare)
        await rig.settle()
        XCTAssertEqual(tune.state.compare.phase, .finished)
        XCTAssertEqual(tune.state.compare.resultBands.count, 10)
        XCTAssertTrue(tune.state.sessionActive)
        XCTAssertTrue(tune.keep())
        await rig.settle()
        XCTAssertEqual(tune.state.compare.phase, .idle)
        XCTAssertFalse(tune.state.sessionActive)
        XCTAssertTrue(rig.app.hasPendingSave)
        rig.clock.advance(5.1)
        await rig.until("saveAll") { rig.device.link.sentCommands.contains(.saveAll) }
        await rig.close()
    }

    func testDiscardingAFinishedCompareRestoresTheBase() async throws {
        let rig = try await AutoRig()
        let tune = makeTune(rig)
        tune.start(.compare, seed: 3)
        answerAll(tune, .compare)
        await rig.settle()
        XCTAssertEqual(tune.state.compare.phase, .finished)
        tune.discard()
        await rig.settle()
        XCTAssertTrue(restored(rig))
        XCTAssertNil(tune.state.active)
        XCTAssertFalse(rig.app.hasPendingSave)
        await rig.close()
    }

    func testTheFlashSaveStaysParkedWhileASessionRuns() async throws {
        let rig = try await AutoRig()
        let tune = makeTune(rig)
        tune.start(.compare, seed: 5)
        rig.app.armSave()
        rig.clock.advance(30)
        await rig.settle()
        XCTAssertFalse(rig.device.link.sentCommands.contains(.saveAll))
        tune.cancel()
        await rig.settle()
        rig.clock.advance(5.1)
        await rig.until("saveAll") { rig.device.link.sentCommands.contains(.saveAll) }
        await rig.close()
    }

    func testSlotActionsAndImportsAreRefusedDuringASession() async throws {
        let rig = try await AutoRig()
        let tune = makeTune(rig)
        tune.start(.compare, seed: 9)
        await rig.settle()
        rig.device.link.clearSends()
        rig.app.presets.save(slot: 2)
        rig.app.presets.load(slot: 1)
        rig.app.eq.setEnabled(false)
        await rig.settle()
        XCTAssertFalse(rig.device.link.sentCommands.contains(.saveEqPreset))
        XCTAssertFalse(rig.device.link.sentCommands.contains(.loadEqPreset))
        XCTAssertFalse(rig.device.link.sentCommands.contains(.setEqEnable))
        let refused = rig.app.eq.apply(ParametricEQFile())
        XCTAssertFalse(refused.accepted)
        XCTAssertEqual(refused.summary, EqEditorModel.sessionRefusal)
        tune.cancel()
        await rig.close()
    }

    func testShapeRunsAndCancelRestores() async throws {
        let rig = try await AutoRig()
        let tune = makeTune(rig)
        tune.start(.shape, seed: 2)
        await rig.settle()
        XCTAssertEqual(tune.state.active, .shape)
        XCTAssertEqual(tune.state.shape.phase, .running)
        tune.choose(preferA: true)
        tune.toggleSide()
        await rig.settle()
        tune.cancel()
        await rig.settle()
        XCTAssertTrue(restored(rig))
        XCTAssertNil(tune.state.active)
        await rig.close()
    }

    func testShapeFinishesAndDiscardRestoresTheBase() async throws {
        let rig = try await AutoRig()
        let tune = makeTune(rig)
        tune.start(.shape, seed: 4)
        for _ in 0..<80 where tune.state.shape.phase == .running {
            tune.choose(preferA: true)
        }
        await rig.settle()
        XCTAssertEqual(tune.state.shape.phase, .finished)
        tune.discard()
        await rig.settle()
        XCTAssertTrue(restored(rig))
        await rig.close()
    }

    func testTheBlindCheckRunsFiveTrialsAndRestores() async throws {
        let rig = try await AutoRig(bands: EqTestSupport.shaped(), preGain: -3)
        let tune = makeTune(rig)
        tune.start(.check, seed: 6)
        await rig.settle()
        XCTAssertEqual(tune.state.active, .check)
        XCTAssertEqual(tune.state.check.trialsTotal, BlindTuner.bypassTrials)
        answerAll(tune, .check)
        await rig.settle()
        XCTAssertEqual(tune.state.check.phase, .finished)
        XCTAssertEqual(tune.state.check.preferredEQ + tune.state.check.preferredFlat
                        + tune.state.check.noPreference, BlindTuner.bypassTrials)
        tune.discard()
        await rig.settle()
        XCTAssertEqual(rig.device.bands, EqTestSupport.shaped())
        XCTAssertNil(tune.state.active)
        await rig.close()
    }

    func testTheTrimCheckNeedsAutoTrimAndAnAudibleTrim() async throws {
        let rig = try await AutoRig(bands: EqTestSupport.shaped(), preGain: -3)
        let tune = makeTune(rig)
        XCTAssertEqual(tune.blocker(for: .trim), BlindTuner.Blocker.trimOff.message)
        tune.start(.trim)
        XCTAssertNil(tune.state.active)
        rig.automation.engine.previewSet(autoTrimOn: true, trim: .zero)
        XCTAssertEqual(tune.blocker(for: .trim), BlindTuner.Blocker.trimInaudible.message)
        rig.automation.engine.previewSet(autoTrimOn: true,
                                         trim: TrimGains(bassDb: 2, tiltDbPerOctave: 0.5,
                                                         presenceDb: 1, airDb: 0))
        XCTAssertNil(tune.blocker(for: .trim))
        tune.start(.trim, seed: 8)
        await rig.settle()
        XCTAssertEqual(tune.state.active, .trim)
        XCTAssertEqual(tune.state.trim.phase, .running)
        answerAll(tune, .trim)
        await rig.settle()
        XCTAssertEqual(tune.state.trim.phase, .finished)
        XCTAssertFalse(tune.state.sessionActive)
        XCTAssertEqual(rig.device.bands, EqTestSupport.shaped())
        tune.discard()
        XCTAssertNil(tune.state.active)
        await rig.close()
    }

    func testStartingASessionSuspendsFollowingAndFinishingResumesIt() async throws {
        let rig = try await AutoRig()
        await rig.engage()
        XCTAssertTrue(rig.gainsMoved())
        let tune = makeTune(rig)
        tune.start(.compare, seed: 1)
        await rig.settle()
        XCTAssertTrue(rig.automation.state.suspended)
        XCTAssertFalse(rig.automation.state.following)
        tune.cancel()
        await rig.settle()
        XCTAssertTrue(restored(rig))
        await rig.tick(2)
        XCTAssertTrue(rig.automation.state.following)
        XCTAssertTrue(rig.gainsMoved())
        await rig.close()
    }

    func testADisconnectEndsARunningSessionWithANote() async throws {
        let rig = try await AutoRig()
        let tune = makeTune(rig)
        tune.start(.compare, seed: 12)
        await rig.settle()
        rig.device.link.drop()
        await rig.until("session ended") { tune.state.active == nil && !tune.state.sessionActive }
        XCTAssertEqual(tune.state.compare.phase, .idle)
        XCTAssertTrue(tune.state.compare.note?.contains("disconnected") ?? false)
        await rig.close()
    }

    func testAVoiceCallStopsARunningSessionAndRestoresTheBase() async throws {
        let rig = try await AutoRig()
        let tune = makeTune(rig)
        tune.start(.shape, seed: 13)
        await rig.settle()
        tune.toggleSide()
        await rig.settle()
        rig.device.activeCall = true
        try await rig.app.session?.refreshStatus()
        await rig.app.refreshStatus()
        await rig.settle()
        XCTAssertNil(tune.state.active)
        XCTAssertFalse(tune.state.sessionActive)
        XCTAssertTrue(tune.state.shape.note?.contains("hands-free") ?? false)
        XCTAssertTrue(restored(rig))
        await rig.close()
    }

    func testBlockersExplainWhySomethingCannotStart() async throws {
        let rig = try await AutoRig(connect: false)
        let tune = makeTune(rig)
        XCTAssertEqual(tune.blocker(for: .compare), "Connect the 5K first.")
        XCTAssertEqual(tune.blocker(for: .shape), "Connect the 5K first.")
        XCTAssertEqual(tune.blocker(for: .check), "Connect the 5K first.")
        XCTAssertEqual(tune.blocker(for: .tones), "Connect the 5K first.")
        tune.start(.compare)
        XCTAssertNil(tune.state.active)
        await rig.close()
    }

    func testASessionCannotStartWhileTheDeviceIsBusyOrAnotherSessionRuns() async throws {
        let rig = try await AutoRig()
        let tune = makeTune(rig)
        rig.app.eq.enqueueOperation { try? await Task.sleep(nanoseconds: 200_000_000) }
        XCTAssertEqual(tune.blocker(for: .compare), TuneModel.busyText)
        tune.start(.compare)
        XCTAssertNil(tune.state.active)
        await rig.settle()
        tune.start(.compare, seed: 1)
        XCTAssertEqual(tune.state.active, .compare)
        tune.start(.shape, seed: 1)
        XCTAssertEqual(tune.state.active, .compare)
        tune.cancel()
        await rig.close()
    }

    func testTheQuitCancelsARunningSessionAndRestoresTheBase() async throws {
        let rig = try await AutoRig()
        let tune = makeTune(rig)
        tune.start(.compare, seed: 21)
        await rig.settle()
        tune.toggleSide()
        await rig.settle()
        XCTAssertFalse(restored(rig))
        await rig.app.shutdown()
        XCTAssertTrue(restored(rig))
        XCTAssertFalse(rig.device.link.sentCommands.contains(.saveAll))
        await rig.close()
    }

    func testTonesAreBlockedUnlessTheRealOutputIsTheFiveK() async throws {
        let rig = try await AutoRig(withStage: true, stageDefault: "alsa_speakers")
        let tune = makeTune(rig)
        XCTAssertEqual(tune.blocker(for: .tones),
                       "Sound is going to Speakers. Choose the Qudelix as the output device.")
        tune.start(.tones)
        XCTAssertNil(tune.state.active)
        XCTAssertTrue(rig.stageRig?.backend.tones.isEmpty ?? false)
        await rig.close()
    }

    func testTonesRefuseAnOverAmplifiedOutput() async throws {
        let rig = try await AutoRig(withStage: true)
        let tune = makeTune(rig)
        rig.stageRig?.backend.volumes["qx_5k"] = AudioSinkVolume(volume: 1, channelVolume: 1.0, muted: false)
        XCTAssertNil(tune.blocker(for: .tones))
        rig.stageRig?.backend.volumes["qx_5k"] = AudioSinkVolume(volume: 1, channelVolume: 1.2, muted: false)
        XCTAssertEqual(tune.blocker(for: .tones), ToneTestModel.Blocker.overAmplified.message)
        XCTAssertTrue(tune.state.blockers[.tones] == nil)
        tune.start(.tones)
        XCTAssertNil(tune.state.active)
        XCTAssertTrue(rig.stageRig?.backend.tones.isEmpty ?? false)
        rig.stageRig?.backend.volumes["qx_5k"] = AudioSinkVolume(volume: 1, channelVolume: 1.0, muted: false)
        XCTAssertNil(tune.blocker(for: .tones))
        await rig.close()
    }

    func testTheToneScreenCautionsAboutTheLevelBeforeStarting() async throws {
        let rig = try await AutoRig(withStage: true)
        let tune = makeTune(rig)
        let screen = TunePresentation.screen(.tones, tune.state)
        XCTAssertEqual(screen.cautions, ["Set your usual listening volume first; the loudest tone is \u{2212}12 dBFS."])
        XCTAssertEqual(ToneTestMath.maxLevelDBFS, -12)
        await rig.close()
    }

    func testTonesAreBlockedOnACall() async throws {
        let rig = try await AutoRig(withStage: true)
        let tune = makeTune(rig)
        XCTAssertNil(tune.blocker(for: .tones))
        rig.device.activeCall = true
        try await rig.app.session?.refreshStatus()
        await rig.app.refreshStatus()
        await rig.settle()
        XCTAssertEqual(tune.blocker(for: .tones), ToneTestModel.Blocker.voiceCall.message)
        tune.start(.tones)
        XCTAssertNil(tune.state.active)
        await rig.close()
    }

    func testTonesNeedAnAudioBackend() async throws {
        let rig = try await AutoRig()
        let tune = makeTune(rig)
        XCTAssertEqual(tune.blocker(for: .tones), ToneTestModel.Blocker.noOutput.message)
        await rig.close()
    }

    private func target(_ hz: Int) -> Double {
        let raw = (ToneTestMath.reference[hz] ?? 0) - 80
        let stepped = (raw / 5).rounded() * 5
        return stepped + (hz == 250 ? 10 : 0)
    }

    private func autoRespond(_ tune: TuneModel, _ rig: AutoRig, peaks: PeakLog) {
        tune.tones.randomPause = { 0 }
        var catches = 0
        tune.tones.randomCatch = {
            catches += 1
            return catches % 5 == 0
        }
        tune.tones.sleepMs = { [weak tune] ms in
            await Task.yield()
            guard ms == 1250, let tune, let presented = tune.tones.lastPresented else { return }
            guard let level = presented.level else { return }
            if let tone = rig.stageRig?.backend.tones.last {
                var out = [Float](repeating: 9, count: 4800 * 2)
                out.withUnsafeMutableBufferPointer {
                    tone.render($0.baseAddress!, 4800, 2, 48000)
                }
                let peak = out.map { abs($0) }.max() ?? 0
                peaks.values.append((presented.hz, level, Double(peak)))
            }
            if level >= self.target(presented.hz) { tune.reportHeard() }
        }
    }

    final class PeakLog {
        var values: [(hz: Int, level: Double, peak: Double)] = []
    }

    func testTheToneTestRunsOnTheFiveKHoldsStageOffAndRestoresTheEq() async throws {
        let rig = try await AutoRig(withStage: true)
        let tune = makeTune(rig)
        let log = PeakLog()
        autoRespond(tune, rig, peaks: log)
        let stage = try XCTUnwrap(rig.stageRig).model
        tune.start(.tones)
        XCTAssertEqual(tune.state.active, .tones)
        XCTAssertTrue(stage.toneHold)
        XCTAssertTrue(stage.processor.isMutedNow)
        XCTAssertEqual(rig.stageRig?.backend.tones.last?.sink, "qx_5k")
        await rig.settle()
        XCTAssertFalse(rig.app.eq.liveEnabled)
        XCTAssertTrue(tune.state.sessionActive)
        await rig.until("tone test finished", timeout: 20) { tune.state.tones.phase == .finished }
        await rig.settle()
        XCTAssertFalse(stage.toneHold)
        XCTAssertFalse(stage.processor.isMutedNow)
        XCTAssertTrue(rig.app.eq.liveEnabled)
        XCTAssertTrue(rig.device.enabled)
        XCTAssertFalse(tune.state.sessionActive)
        XCTAssertEqual(tune.state.tones.readingCount, 10)
        XCTAssertEqual(tune.state.tones.bandsDone, 10)
        XCTAssertTrue(rig.stageRig?.backend.tones.last?.stream.stopped ?? false)
        let first = try XCTUnwrap(log.values.first)
        XCTAssertEqual(first.peak, pow(10, first.level / 20), accuracy: pow(10, first.level / 20) * 0.05)
        await rig.close()
    }

    func testApplyingTheToneSuggestionGoesThroughTheNormalWritePath() async throws {
        let rig = try await AutoRig(withStage: true)
        let tune = makeTune(rig)
        autoRespond(tune, rig, peaks: PeakLog())
        tune.start(.tones)
        await rig.until("tone test finished", timeout: 20) { tune.state.tones.phase == .finished }
        await rig.settle()
        XCTAssertEqual(tune.state.tones.verdict, .usable)
        rig.device.link.clearSends()
        XCTAssertTrue(tune.keep())
        await rig.settle()
        XCTAssertNil(tune.state.active)
        XCTAssertTrue(rig.device.bands.contains { $0.gain != 0 })
        XCTAssertTrue(rig.app.hasPendingSave)
        XCTAssertEqual(rig.app.eq.state.undoLabel, "hearing correction")
        rig.clock.advance(5.1)
        await rig.until("saveAll") { rig.device.link.sentCommands.contains(.saveAll) }
        await rig.close()
    }

    func testTheToneTestStopsWhenTheOutputMovesAndRestoresTheEq() async throws {
        let rig = try await AutoRig(withStage: true)
        let tune = makeTune(rig)
        let stageRig = try XCTUnwrap(rig.stageRig)
        autoRespond(tune, rig, peaks: PeakLog())
        var calls = 0
        let inner = tune.tones.sleepMs
        tune.tones.sleepMs = { ms in
            await inner(ms)
            calls += 1
            if calls == 6 { stageRig.changeDefault(to: "alsa_speakers") }
        }
        tune.start(.tones)
        await rig.until("tone test stopped", timeout: 20) { tune.state.tones.phase == .idle }
        await rig.settle()
        XCTAssertTrue(tune.state.tones.note?.contains("another output device") ?? false)
        XCTAssertTrue(rig.app.eq.liveEnabled)
        XCTAssertFalse(stageRig.model.toneHold)
        XCTAssertFalse(tune.state.sessionActive)
        XCTAssertTrue(stageRig.backend.tones.last?.stream.stopped ?? false)
        await rig.close()
    }

    func testTheToneTestStopsOnADisconnect() async throws {
        let rig = try await AutoRig(withStage: true)
        let tune = makeTune(rig)
        autoRespond(tune, rig, peaks: PeakLog())
        var calls = 0
        let inner = tune.tones.sleepMs
        tune.tones.sleepMs = { [weak rig] ms in
            await inner(ms)
            calls += 1
            if calls == 4 { rig?.device.link.drop() }
        }
        tune.start(.tones)
        await rig.until("tone test stopped", timeout: 20) { tune.state.tones.phase == .idle }
        XCTAssertTrue(tune.state.tones.note?.contains("disconnected") ?? false)
        XCTAssertFalse(try XCTUnwrap(rig.stageRig).model.toneHold)
        XCTAssertFalse(tune.state.sessionActive)
        await rig.close()
    }

    func testStoppingTheToneTestRestoresEverything() async throws {
        let rig = try await AutoRig(withStage: true)
        let tune = makeTune(rig)
        autoRespond(tune, rig, peaks: PeakLog())
        tune.tones.sleepMs = { _ in try? await Task.sleep(nanoseconds: 20_000_000) }
        tune.start(.tones)
        await rig.settle()
        XCTAssertFalse(rig.app.eq.liveEnabled)
        tune.cancel()
        await rig.settle()
        XCTAssertTrue(rig.app.eq.liveEnabled)
        XCTAssertFalse(try XCTUnwrap(rig.stageRig).model.toneHold)
        XCTAssertNil(tune.state.active)
        await rig.close()
    }

    func testTheToneTestFailsCleanlyWhenThePlayerCannotStart() async throws {
        let rig = try await AutoRig(withStage: true)
        let tune = makeTune(rig)
        rig.stageRig?.backend.failStreams = true
        tune.start(.tones)
        await rig.settle()
        XCTAssertNil(tune.state.active)
        XCTAssertFalse(tune.state.sessionActive)
        XCTAssertTrue(rig.app.eq.liveEnabled)
        XCTAssertTrue(tune.state.tones.note?.contains("tone player") ?? false)
        await rig.close()
    }

    func testToneSourceRendersSilenceThenThePulsesAndLoops() {
        let source = ToneSource()
        var buffer = [Float](repeating: 5, count: 8)
        buffer.withUnsafeMutableBufferPointer { source.render($0.baseAddress!, frames: 4, channels: 2) }
        XCTAssertEqual(buffer, [Float](repeating: 0, count: 8))
        source.load([0.5, -0.25, 0.125])
        buffer.withUnsafeMutableBufferPointer { source.render($0.baseAddress!, frames: 4, channels: 2) }
        XCTAssertEqual(buffer, [0.5, 0.5, -0.25, -0.25, 0.125, 0.125, 0, 0])
        source.load([1])
        source.clear()
        buffer.withUnsafeMutableBufferPointer { source.render($0.baseAddress!, frames: 2, channels: 2) }
        XCTAssertEqual(Array(buffer[0..<4]), [0, 0, 0, 0])
    }

    func testReloadingASourceSwapsTheWholeBufferAndNeverKeepsAStaleTail() {
        let source = ToneSource()
        source.load([1, 2, 3, 4, 5, 6])
        var buffer = [Float](repeating: 9, count: 2)
        buffer.withUnsafeMutableBufferPointer { source.render($0.baseAddress!, frames: 2, channels: 1) }
        XCTAssertEqual(buffer, [1, 2])
        source.load([7, 8])
        var out = [Float](repeating: 9, count: 6)
        out.withUnsafeMutableBufferPointer { source.render($0.baseAddress!, frames: 6, channels: 1) }
        XCTAssertEqual(out, [7, 8, 0, 0, 0, 0])
        source.load([])
        out.withUnsafeMutableBufferPointer { source.render($0.baseAddress!, frames: 6, channels: 1) }
        XCTAssertEqual(out, [Float](repeating: 0, count: 6))
    }

    func testASourceLongerThanTheCapacityIsTruncated() {
        let source = ToneSource()
        source.load([Float](repeating: 0.5, count: ToneSource.capacity + 10))
        var out = [Float](repeating: 0, count: ToneSource.capacity + 20)
        out.withUnsafeMutableBufferPointer { source.render($0.baseAddress!, frames: ToneSource.capacity + 20, channels: 1) }
        XCTAssertEqual(out[ToneSource.capacity - 1], 0.5)
        XCTAssertEqual(out[ToneSource.capacity], 0)
    }

    func testReloadsWhileTheRenderThreadRunsNeverTearAndNeverStallIt() {
        let source = ToneSource()
        let chunk = ToneSource.capacity
        let finished = DispatchSemaphore(value: 0)
        let longest = LockedValue(0.0)
        let torn = LockedValue(false)
        let stop = LockedValue(false)
        DispatchQueue.global().async {
            var out = [Float](repeating: 0, count: 256)
            while !stop.value {
                let began = DispatchTime.now().uptimeNanoseconds
                out.withUnsafeMutableBufferPointer { source.render($0.baseAddress!, frames: 256, channels: 1) }
                let took = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
                if took > longest.value { longest.value = took }
                if Set(out).subtracting([0]).count > 1 { torn.value = true }
            }
            finished.signal()
        }
        for round in 0..<40 {
            source.load([Float](repeating: Float(round % 2 + 1), count: chunk))
        }
        stop.value = true
        finished.wait()
        XCTAssertFalse(torn.value)
        XCTAssertLessThan(longest.value, 0.25)
    }
}

private final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
