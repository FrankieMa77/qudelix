import Foundation

package struct LevelMeterRow: Equatable {
    package var label: String
    package var value: String
    package var note: String
    package var lit: Bool
    package var caution: Bool
    package var help: String
}

package struct LevelTodayReading: Equatable {
    package var listened: String
    package var loud: String
    package var average: String
    package var loudHighlight: Bool
}

package struct LevelHistoryRow: Equatable {
    package var day: String
    package var date: String
    package var duration: String
    package var loudDuration: String
    package var audibleFraction: Double
    package var loudFraction: Double
}

package enum LevelVerdictTone: Equatable {
    case neutral
    case good
    case caution
}

@MainActor
package enum LevelPresentation {
    package static let historyDeleteTitle = "Delete all listening history?"
    package static let historyDeleteMessage = "Every recorded day is removed from this computer, and it can\u{2019}t be brought back."
    package static let historyFootnote = "Recorded as digital signal level (dBFS), not as sound pressure. The estimate above "
        + "is the closest this app gets to that."
    package static let qualityHelp = "Measures the audio itself: lossy codecs cut the high frequencies at telltale points, "
        + "lossless extends to the edge. Works with any player: it doesn\u{2019}t ask, it listens. Evidence, not proof: "
        + "a lossless file made from a lossy source keeps the cutoff, and quiet material can\u{2019}t be judged."
    package static let balanceHelp = "Long-term tonal balance of what\u{2019}s playing, relative to pink noise (equal energy "
        + "per octave), averaged over about 30 s. Auto-trim steers toward your usual balance, learned over about 30 "
        + "minutes of listening."
    package static let autoMatchHelp = "Lossless detected: 44.1 kHz (the bit-perfect path). Lossy: back to the rate the "
        + "graph had before. Content proven beyond the 44.1 family: 96 kHz. Switches only after the verdict holds for "
        + "10 seconds, and never while Stage is on."
    package static let calibrationHelp = "Shifts the estimate for headphones that play louder or quieter than the typical "
        + "sensitivity it assumes. Kept per output device."
    package static let loudMarkerDb = StagePolicy.loudThresholdDb
    package static let meterFloorDb = -60.0
    package static let unavailableEarLevel = "\u{2014}"

    package static var autoMatchExplanation: String { LevelModel.autoRateExplanation }

    package static func trackingNote(stage: StageModelState, level: LevelModelState) -> String? {
        if !level.levelTracking {
            return "Nothing is recorded while this is off. Tracking reads the output level only: it never touches "
                + "the audio path."
        }
        if stage.settings.enabled, stage.mode == .insert {
            return "Metering rides the Stage while it runs."
        }
        return nil
    }

    package static func failureNotice(_ stage: StageModelState) -> String? {
        stage.failure?.message
    }

    package static func notices(stage: StageModelState, level: LevelModelState) -> [StageNotice] {
        var shown: [StageNotice] = []
        if let notice = stage.settingsNotice { shown.append(StageNotice(text: notice, caution: true)) }
        if let failure = failureNotice(stage) { shown.append(StageNotice(text: failure, caution: true)) }
        if let notice = stage.audioNotice { shown.append(StageNotice(text: notice, caution: true)) }
        if let rate = level.foreignForceRate {
            shown.append(StageNotice(text: LevelModel.foreignRateNotice(rate), caution: false))
        }
        return shown
    }

    package static func outputLevelText(stage: StageModelState, level: LevelModelState) -> String {
        guard stage.running else { return "off" }
        guard let db = level.currentLevelDb else { return "silent" }
        return String(format: "%.0f dBFS", db)
    }

    package static func meterFraction(_ db: Double) -> Double {
        min(max((db - meterFloorDb) / -meterFloorDb, 0), 1)
    }

    package static func meterFraction(stage: StageModelState, level: LevelModelState) -> Double? {
        guard stage.running, let db = level.currentLevelDb else { return nil }
        return meterFraction(db)
    }

    package static func limiterText(_ stage: StageModelState) -> String {
        let db = stage.limiterGainReductionDb
        return db > 0.1 ? String(format: "\u{2212}%.1f dB", db) : "idle"
    }

    package static func bassGuardReading(reduction: Double, boost: Double) -> String {
        let ceiling = String(format: "%.1f dB", boost)
        return reduction > 0.1 ? String(format: "\u{2212}%.1f of ", reduction) + ceiling : "idle of " + ceiling
    }

    package static func meterRows(stage: StageModelState) -> [LevelMeterRow] {
        let settings = stage.settings
        guard settings.enabled, stage.running, stage.mode == .insert else { return [] }
        let guarding = settings.bassGuardValue && !stage.bassGuardInert
        var rows: [LevelMeterRow] = []
        if settings.limiterValue {
            rows.append(LevelMeterRow(label: "True-peak limiter", value: limiterText(stage),
                                      note: "holding \u{2212}1 dBTP",
                                      lit: stage.limiterGainReductionDb > 0.1, caution: true,
                                      help: "How far the limiter is pulling the Stage\u{2019}s output down this second to hold \u{2212}1 dBTP."))
        }
        if settings.loudnessValue {
            rows.append(LevelMeterRow(label: "Loudness", value: StagePresentation.loudnessAmount(stage),
                                      note: "treble at a third", lit: stage.loudnessShelfDb > 0.05, caution: false,
                                      help: "How much bass the compensation is adding this second, from the estimate below. Treble rides along at a third of it."))
        }
        if guarding {
            rows.append(LevelMeterRow(label: "Bass guard",
                                      value: bassGuardReading(reduction: stage.bassGuardGainReductionDb,
                                                              boost: stage.bassGuardBoostDb),
                                      note: "before the 5K\u{2019}s boost", lit: stage.bassGuardGainReductionDb > 0.1,
                                      caution: true,
                                      help: "How much of the bass the 5K is about to add this app is holding back right now, so the loudest passages don\u{2019}t reach the driver with the whole boost on them."))
        }
        return rows
    }

    package static func earLevelText(stage: StageModelState, level: LevelModelState) -> String {
        guard stage.running else { return unavailableEarLevel }
        switch level.earLevel {
        case .unavailable: return unavailableEarLevel
        case .tooQuiet: return "too quiet to estimate"
        case .estimated(let db): return String(format: "~%.0f dB (estimate)", db)
        }
    }

    package static func earDisclaimer(_ level: LevelModelState) -> String {
        let tap = ", taken before the loudness shelf."
        switch level.earAnchor {
        case .qudelix?:
            return "An estimate, not a measurement: the 5K\u{2019}s volume setting and a typical headphone\u{2019}s sensitivity, not this pair" + tap
        case .system?:
            return "An estimate, not a measurement: this output\u{2019}s volume and a typical headphone\u{2019}s sensitivity, not this pair" + tap
        case nil:
            return "An estimate, not a measurement. It needs a volume reading to anchor it, and this output offers none this app can read."
        }
    }

    package static func calibrationOffsetText(_ level: LevelModelState) -> String {
        DisplayFormat.decibels(level.earCalibrationDb - EarLevel.defaultCalibrationDb, decimals: 0)
    }

    package static func calibrationIsDefault(_ level: LevelModelState) -> Bool {
        level.earCalibrationDb == EarLevel.defaultCalibrationDb
    }

    package static func calibrationTitle(_ stage: StageModelState) -> String {
        guard let name = stage.outputDescription else { return "Ear level calibration" }
        return "Ear level calibration for " + name
    }

    package static func verdictText(stage: StageModelState, level: LevelModelState) -> String {
        guard stage.running else { return stage.failure == nil ? "metering off" : "metering didn\u{2019}t start" }
        guard let quality = level.quality else { return "listening\u{2026}" }
        let khz = quality.cutoffKHz ?? 0
        switch quality.kind {
        case .tooQuiet: return "too quiet to judge"
        case .noTreble: return "no treble to judge"
        case .lossy: return String(format: "lossy (cuts at %.1f kHz)", khz)
        case .lossyHigh: return String(format: "lossy, high bitrate (%.1f kHz)", khz)
        case .losslessLike: return String(format: "consistent with lossless (%.1f kHz)", khz)
        case .hiRes: return String(format: "hi-res content (%.1f kHz)", khz)
        case .natural: return String(format: "rolls off naturally (%.1f kHz), can\u{2019}t judge", khz)
        }
    }

    package static func verdictTone(stage: StageModelState, level: LevelModelState) -> LevelVerdictTone {
        guard stage.running, let quality = level.quality else { return .neutral }
        switch quality.kind {
        case .losslessLike, .hiRes: return .good
        case .lossy, .lossyHigh: return .caution
        default: return .neutral
        }
    }

    package static func showsBalance(stage: StageModelState, level: LevelModelState) -> Bool {
        level.detectQuality && stage.running
    }

    package static func balanceText(_ level: LevelModelState) -> String {
        AutomationReadout.balanceText(level.balance)
    }

    package static func autoMatchStatus(_ level: LevelModelState) -> String? {
        guard level.qualityMasterOn, let rate = level.autoSetRate else { return nil }
        return String(format: "The audio graph is currently set to %g kHz by Auto-match.", rate / 1000)
    }

    package static func today(_ level: LevelModelState, now: Date) -> DayExposure? {
        let key = LevelModel.dayKey(now)
        return level.exposureDays.first { $0.day == key }
    }

    package static func todayReading(_ day: DayExposure) -> LevelTodayReading {
        LevelTodayReading(listened: duration(day.audibleSeconds), loud: duration(day.loudSeconds),
                          average: day.energySum > 0
                              ? String(format: "%.0f dBFS", 10 * log10(day.energySum / max(day.audibleSeconds, 1)))
                              : "\u{2014}",
                          loudHighlight: day.loudSeconds > 3600)
    }

    package static func historyHeadline(level: LevelModelState, now: Date) -> String {
        let today = today(level, now: now)
        if !level.levelTracking {
            return level.exposureDays.isEmpty ? "Nothing recorded." : "Paused: nothing new is being added."
        }
        if let today, today.audibleSeconds > 0 { return "Today" }
        return "Nothing listened to today yet."
    }

    package static func previousDays(level: LevelModelState, now: Date) -> [LevelHistoryRow] {
        let key = LevelModel.dayKey(now)
        let longest = max(level.exposureDays.map(\.audibleSeconds).max() ?? 1, 1)
        return level.exposureDays.filter { $0.day != key }.suffix(7).reversed().map { day in
            LevelHistoryRow(day: day.day, date: shortDate(day.day), duration: duration(day.audibleSeconds),
                            loudDuration: duration(day.loudSeconds),
                            audibleFraction: min(day.audibleSeconds / longest, 1),
                            loudFraction: min(day.loudSeconds / longest, 1))
        }
    }

    package static func previousTitle(_ count: Int) -> String {
        "Previous \(count) day\(count == 1 ? "" : "s")"
    }

    package static func shortDate(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]), (1...12).contains(m) else { return key }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[m - 1]) \(d)"
    }

    package static func duration(_ seconds: Double) -> String {
        let s = seconds.isFinite ? Int(min(max(seconds, 0), 999_999_999)) : 0
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }
}
