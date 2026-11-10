import Foundation

extension StageImpulseInfo {
    init(fileName: String, displayName: String, seconds: Double, channels: Int, sourceRate: Double) {
        self.fileName = fileName
        self.displayName = displayName
        self.seconds = seconds
        self.channels = channels
        self.sourceRate = sourceRate
    }
}

package enum DemoStageScenario: String, CaseIterable {
    case on
    case off
    case failure
}

package enum DemoLevelScenario: String, CaseIterable {
    case live
    case lossy
    case idle
    case empty
}

@MainActor
package enum DemoAudioData {
    package static func stage(_ scenario: DemoStageScenario) -> StageModelState {
        var state = StageModelState()
        state.outputKey = DemoAudioBackend.fiveK.name
        state.outputDescription = DemoAudioBackend.fiveK.description
        switch scenario {
        case .off:
            state.settings = StageSettings(enabled: false, width: 115, crossfeed: 0.35, dialogue: 0, room: 0)
        case .on:
            var settings = StageSettings.music
            settings.dialogue = 1.5
            settings.room = 0.25
            settings.crossLowTrim = 0.6
            settings.balanceDb = -0.4
            settings.limiter = true
            settings.loudness = true
            settings.loudnessStrength = 0.8
            settings.bassGuard = true
            settings.bassGuardStrength = 0.7
            settings.impulseFile = "demo-room.wav"
            settings.impulseMix = 0.4
            state.settings = settings
            state.running = true
            state.mode = .insert
            state.routed = true
            state.runningRate = 48000
            state.status = "Stage active \u{2192} \(DemoAudioBackend.fiveK.description) @ 48 kHz"
            state.sourceCorrelation = 0.62
            state.limiterGainReductionDb = 1.4
            state.loudnessShelfDb = 3.2
            state.bassGuardBoostDb = 6.5
            state.bassGuardCeilingDb = 4.5
            state.bassGuardGainReductionDb = 1.1
            state.impulse = StageImpulseInfo(fileName: "demo-room.wav", displayName: "Small studio room",
                                             seconds: 0.62, channels: 2, sourceRate: 48000)
            state.impulseState = .ready(partitions: 4, taps: 29760, hop: 1024, rate: 48000)
        case .failure:
            state.settings = .music
            let message = "The audio server didn\u{2019}t switch the default output to Stage in time."
            state.failure = StageFailure(message: message, summary: "the default output didn\u{2019}t switch")
            state.status = message
        }
        return state
    }

    package static func level(_ scenario: DemoLevelScenario, now: Date = Date()) -> LevelModelState {
        var state = LevelModelState()
        state.earCalibrationDb = EarLevel.defaultCalibrationDb
        switch scenario {
        case .empty:
            state.levelTracking = false
        case .idle:
            state.levelTracking = true
            state.exposureDays = history(now: now, includeToday: false)
        case .live, .lossy:
            state.levelTracking = true
            state.currentLevelDb = -21
            state.earLevel = .estimated(78)
            state.earLevelAverageDb = 77
            state.earAnchor = .qudelix(-18)
            state.earCalibrationDb = EarLevel.defaultCalibrationDb + 3
            state.balance = BalanceFeatures(bassDb: 1.2, tiltDbPerOctave: -0.4, presenceDb: 0.6)
            state.exposureDays = history(now: now, includeToday: true)
            if scenario == .live {
                state.quality = StreamQuality(.losslessLike(cutoffKHz: 21.9))
                state.autoRate = true
                state.autoSetRate = 44100
            } else {
                state.quality = StreamQuality(.lossy(cutoffKHz: 16.0))
                state.autoRate = false
            }
        }
        return state
    }

    package static func runningStage(for level: DemoLevelScenario) -> StageModelState {
        var state = DemoAudioData.stage(.off)
        switch level {
        case .live, .lossy:
            state.running = true
            state.mode = .monitor
            state.routed = true
            state.runningRate = 48000
            state.status = "Metering \u{2192} \(DemoAudioBackend.fiveK.description) @ 48 kHz"
        case .idle, .empty:
            break
        }
        return state
    }

    private static func history(now: Date, includeToday: Bool) -> [DayExposure] {
        let seconds: [(Double, Double, Double)] = [
            (8400, 600, -26), (14100, 4300, -22), (5200, 0, -27), (19800, 5400, -21),
            (11200, 1200, -24), (9300, 300, -25)
        ]
        var days: [DayExposure] = []
        for (offset, entry) in seconds.enumerated() {
            let date = now.addingTimeInterval(-Double(seconds.count - offset) * 86_400)
            days.append(DayExposure(day: LevelModel.dayKey(date), audibleSeconds: entry.0, loudSeconds: entry.1,
                                    energySum: entry.0 * pow(10, entry.2 / 10)))
        }
        if includeToday {
            days.append(DayExposure(day: LevelModel.dayKey(now), audibleSeconds: 5_460, loudSeconds: 420,
                                    energySum: 5_460 * pow(10, -23.0 / 10)))
        }
        return days
    }
}

package enum DemoTuneScenario: String, CaseIterable {
    case compareIdle = "compare-idle"
    case compareRunning = "compare-running"
    case compareFinished = "compare-finished"
    case shapeIdle = "shape-idle"
    case shapeRunning = "shape-running"
    case shapeFinished = "shape-finished"
    case tonesIdle = "tones-idle"
    case tonesRunning = "tones-running"
    case tonesFinished = "tones-finished"
    case tonesUnreliable = "tones-unreliable"
    case blindIdle = "blind-idle"
    case blindRunning = "blind-running"
    case blindFinished = "blind-finished"
    case trimIdle = "trim-idle"
    case trimRunning = "trim-running"
    case trimFinished = "trim-finished"
    case tonesBlocked = "tones-blocked"
    case compareBlocked = "compare-blocked"
    case interrupted
    case toneInterrupted = "tone-interrupted"

    package var method: TuneMethod {
        switch self {
        case .compareIdle, .compareRunning, .compareFinished, .compareBlocked, .interrupted: return .compare
        case .shapeIdle, .shapeRunning, .shapeFinished: return .shape
        case .tonesIdle, .tonesRunning, .tonesFinished, .tonesUnreliable, .tonesBlocked, .toneInterrupted:
            return .tones
        case .blindIdle, .blindRunning, .blindFinished: return .check
        case .trimIdle, .trimRunning, .trimFinished: return .trim
        }
    }
}

@MainActor
package enum DemoTuneData {
    private static let shapeValues: [String: Double] = ["bass": 2.5, "presence": -1, "tilt": 0.5]

    package static func state(_ scenario: DemoTuneScenario) -> TuneState {
        var state = TuneState()
        state.trimNow = "bass +0.5 \u{00B7} tilt +0.3 dB/oct \u{00B7} presence +0.8 \u{00B7} air +0.0"
        switch scenario {
        case .compareIdle:
            break
        case .compareRunning:
            state.active = .compare
            state.sessionActive = true
            state.compare = running(title: "Bass", detail: "31\u{2013}250 Hz", done: 6, total: 20, showingA: false)
        case .compareFinished:
            state.active = .compare
            state.sessionActive = true
            state.compare = TuneSideState()
            state.compare.phase = .finished
            state.compare.sameTrials = 4
            state.compare.sameGuesses = 1
            state.compare.maxMovement = 3.1
            state.compare.values = ["Bass": 3.0, "Warmth": -1.5, "Presence": 0, "Treble": 2.0]
            state.compare.inaudible = ["Presence"]
        case .shapeIdle:
            break
        case .shapeRunning:
            state.active = .shape
            state.sessionActive = true
            state.shape = running(title: "Presence", detail: "2.8 kHz", done: 4, total: 12, showingA: true)
        case .shapeFinished:
            state.active = .shape
            state.sessionActive = true
            state.shape.phase = .finished
            state.shape.sameTrials = 3
            state.shape.sameGuesses = 0
            state.shape.skippedTrials = 1
            state.shape.values = shapeValues
            state.shape.summary = "bass +2.5 dB \u{00B7} presence \u{2212}1 dB \u{00B7} tilt +0.5 dB/oct"
            state.shape.verdict = .usable
        case .tonesIdle:
            break
        case .tonesRunning:
            state.active = .tones
            state.sessionActive = true
            state.tones.phase = .running
            state.tones.currentHz = 2000
            state.tones.bandsDone = 1
            state.tones.listening = true
        case .tonesFinished:
            state.active = .tones
            state.sessionActive = true
            state.tones.phase = .finished
            state.tones.verdict = .usable
            state.tones.readingCount = 9
            state.tones.catchPlayed = 3
            state.tones.catchFalsePositives = 0
            state.tones.suggestion = tonePoints()
        case .tonesUnreliable:
            state.active = .tones
            state.sessionActive = true
            state.tones.phase = .finished
            state.tones.verdict = .unreliable
            state.tones.readingCount = 8
            state.tones.catchPlayed = 4
            state.tones.catchFalsePositives = 3
            state.tones.suggestion = tonePoints()
        case .blindIdle:
            break
        case .blindRunning:
            state.active = .check
            state.sessionActive = true
            state.check = running(title: "Your EQ or flat", detail: "blind", done: 2, total: 5, showingA: true)
        case .blindFinished:
            state.active = .check
            state.sessionActive = true
            state.check.phase = .finished
            state.check.preferredEQ = 4
            state.check.preferredFlat = 1
            state.check.noPreference = 0
            state.check.outcome = .preferredEQ(4)
        case .trimIdle:
            break
        case .trimRunning:
            state.active = .trim
            state.sessionActive = true
            state.trim = running(title: "Trim or your EQ", detail: "blind", done: 3, total: 5, showingA: false)
        case .trimFinished:
            state.active = .trim
            state.sessionActive = true
            state.trim.phase = .finished
            state.trim.preferredEQ = 1
            state.trim.preferredFlat = 3
            state.trim.noPreference = 1
            state.trim.outcome = .preferredFlat(3)
        case .tonesBlocked:
            state.blockers[.tones] = ToneTestModel.Blocker.wrongOutput("Built-in Audio Analog Stereo").message
        case .compareBlocked:
            for method in TuneMethod.allCases where method != .tones {
                state.blockers[method] = ABTuner.Blocker.eqOff.message
            }
        case .interrupted:
            state.compare.note = "Comparison stopped \u{2014} the 5K disconnected."
            state.note = state.compare.note
        case .toneInterrupted:
            state.tones.note = "Tone test stopped \u{2014} the 5K disconnected."
            state.note = state.tones.note
        }
        return state
    }

    private static func running(title: String, detail: String, done: Int, total: Int, showingA: Bool) -> TuneSideState {
        var side = TuneSideState()
        side.phase = .running
        side.title = title
        side.detail = detail
        side.trialsDone = done
        side.trialsTotal = total
        side.showingA = showingA
        return side
    }

    private static func tonePoints() -> [TonePoint] {
        let readings: [(Int, Double, Double, Bool)] = [
            (31, 0, 0, false), (63, 6, -4, true), (125, 2, -2, true), (250, 1, -1, true), (500, 0, 0, true),
            (1000, 0, 0, true), (2000, -1, 1, true), (4000, -2, 2, true), (8000, -4, 4, true), (16000, -3, 3, true)
        ]
        return readings.map { TonePoint(hz: $0.0, gain: $0.2, deviation: $0.1, measured: $0.3) }
    }
}
