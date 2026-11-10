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
