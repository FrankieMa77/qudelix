import SwiftUI

/// Live output level and listening history, measured on the Mac.
struct LevelView: View {
    @EnvironmentObject var stageState: StageState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Nothing on this pane works without the engine, and the engine
            // starts on its own for quality detection — so its refusal is
            // reported here once, at the top, whatever asked it to run.
            // Silent when nothing is wrong: `engineFailure` is nil unless a
            // start was attempted and failed.
            if let failure = stageState.engineFailure {
                Text(verbatim: failure.message)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Toggle(isOn: Binding(
                    get: { stageState.levelTracking },
                    set: { stageState.setLevelTracking($0) })) {
                    Text("Track listening levels")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Spacer()
            }

            // The switch says what it does and does what it says: it is the
            // only thing that writes to the history. It used to be forced on
            // (and greyed out) while Soundstage ran, on the grounds that the
            // meter rides that engine anyway — but the meter is not the
            // history, and nobody who turns on Soundstage has thereby asked
            // for a record of their listening.
            if !stageState.levelTracking {
                Text("Nothing is recorded while this is off. Tracking reads "
                     + "the Mac's output level only — it never touches the "
                     + "audio path.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if stageState.stage.enabled {
                Text("Metering rides the Soundstage engine while it runs.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            meter

            stageMetersRow

            earLevelSection

            Divider()

            qualitySection

            Divider()

            // The inspector used to sit below a week of history, which on a
            // real install put it past the fold of a scrolling pane — the
            // same "nobody can find it" mistake this app has already made
            // twice. It moves up here, right after the two things people
            // actually open this pane for, so reaching it never depends on
            // how much history has piled up below.
            SignalPathView()

            Divider()

            exposureSection
        }
    }

    @ViewBuilder
    private var stageMetersRow: some View {
        let inserted = stageState.stage.enabled && stageState.engine.isRunning
            && stageState.engine.mode == .insert
        let guarding = stageState.stage.bassGuardValue && !stageState.bassGuardInert
        if inserted, stageState.stage.limiterValue || stageState.stage.loudnessValue
            || guarding {
            HStack(spacing: 10) {
                if stageState.stage.limiterValue {
                    HStack(spacing: 6) {
                        Text("True-peak limiter")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(limiterText)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(stageState.limiterGainReductionDb > 0.1
                                             ? AnyShapeStyle(.orange)
                                             : AnyShapeStyle(.tertiary))
                    }
                    .help("How far the limiter is pulling the Soundstage's "
                          + "output down this second to hold −1 dBTP.")
                }
                if stageState.stage.loudnessValue {
                    HStack(spacing: 6) {
                        Text("Loudness")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(loudnessText)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(stageState.loudnessShelfDb > 0.05
                                             ? AnyShapeStyle(.secondary)
                                             : AnyShapeStyle(.tertiary))
                    }
                    .help("How much bass the compensation is adding this "
                          + "second, from the estimate below. Treble rides "
                          + "along at a third of it.")
                }
                if guarding {
                    HStack(spacing: 6) {
                        Text("Bass guard")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(bassGuardText)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(stageState.bassGuardGainReductionDb > 0.1
                                             ? AnyShapeStyle(.orange)
                                             : AnyShapeStyle(.tertiary))
                        Text(String(format: "of %.1f dB boost",
                                    stageState.bassGuardBoostDb))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .help("How much of the bass the 5K is about to add this "
                          + "app is holding back right now, so the loudest "
                          + "passages don't reach the driver with the whole "
                          + "boost on them.")
                }
                Spacer()
            }
        }
    }

    private var bassGuardText: String {
        let gr = stageState.bassGuardGainReductionDb
        return gr > 0.1 ? String(format: "\u{2212}%.1f dB", gr) : "idle"
    }

    private var loudnessText: String {
        let db = stageState.loudnessShelfDb
        return db > 0.05 ? String(format: "+%.1f dB bass", db) : "flat"
    }

    private var limiterText: String {
        let db = stageState.limiterGainReductionDb
        return db > 0.1 ? String(format: "−%.1f dB", db) : "idle"
    }

    private var earLevelSection: some View {
        let uid = stageState.outputUID
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Estimated level at ear")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(earLevelText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(earDisclaimer)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("Reads loud or quiet? Nudge it")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Stepper(value: Binding(
                    get: { stageState.earCalibrationDb },
                    set: { stageState.setEarCalibration($0, editedFor: uid) }),
                        in: EarLevel.calibrationRange, step: 1) {
                    Text(String(format: "%+.0f dB",
                                stageState.earCalibrationDb - EarLevel.defaultCalibrationDb))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .controlSize(.mini)
                .fixedSize()
                .accessibilityLabel("Ear level calibration")
                .help("Shifts the estimate for headphones that play louder or "
                      + "quieter than the typical sensitivity it assumes. "
                      + "Kept per output device.")
                if stageState.earCalibrationDb != EarLevel.defaultCalibrationDb {
                    Button("Reset") {
                        stageState.setEarCalibration(EarLevel.defaultCalibrationDb,
                                                     editedFor: uid)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                    .help("Back to the typical-headphone assumption for this output.")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var earLevelText: String {
        guard stageState.engine.isRunning else { return "—" }
        switch stageState.earLevel {
        case .unavailable: return "—"
        case .tooQuiet: return "too quiet to estimate"
        case .estimated(let db): return String(format: "~%.0f dB (estimate)", db)
        }
    }

    private var earDisclaimer: String {
        let tap = " — taken before the loudness shelf."
        switch stageState.earAnchor {
        case .qudelix:
            return "An estimate, not a measurement: the 5K's volume setting "
                + "and a typical headphone's sensitivity, not this pair" + tap
        case .system:
            return "An estimate, not a measurement: your Mac's volume for "
                + "this output and a typical headphone's sensitivity, not "
                + "this pair" + tap
        case nil:
            return "An estimate, not a measurement. It needs a volume reading "
                + "to anchor it, and this output offers none this app can read."
        }
    }

    // MARK: - Listening history

    /// Today's totals plus the trailing week, in that priority order: today
    /// is the number someone glances at daily, the week behind it is context
    /// they reach for occasionally. It collapses by default — the row list
    /// below it is the one thing in this pane that grows without bound, and
    /// its label says exactly what's folded away rather than leaving a bare
    /// chevron to guess at.
    private var exposureSection: some View {
        let today = stageState.exposureDays.first { $0.day == StageState.dayKey() }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Listening history")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                // Recorded listening is personal, so getting rid of it is one
                // click and doesn't require switching anything off first.
                if !stageState.exposureDays.isEmpty {
                    Button("Delete") { stageState.clearExposureHistory() }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                        .help("Deletes every day recorded so far, from disk too.")
                }
            }

            if !stageState.levelTracking {
                // Whatever is shown below was recorded while tracking was on;
                // saying so is what keeps this section from reading as a live
                // total under a switch that is off.
                Text(stageState.exposureDays.isEmpty
                     ? "Nothing recorded."
                     : "Paused — nothing new is being added.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let today, today.audibleSeconds > 0 { todayView(today) }
            } else if let today, today.audibleSeconds > 0 {
                todayView(today)
            } else {
                Text("Nothing listened to today yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // Filter by key, don't dropLast: when nothing played today the
            // last entry IS a previous day and must not be swallowed.
            let todayKey = StageState.dayKey()
            let history = Array(stageState.exposureDays.filter { $0.day != todayKey }
                .suffix(7)).reversed()
            if !history.isEmpty {
                DisclosureGroup {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(history), id: \.day) { day in
                                historyRow(day)
                                    .frame(height: Self.historyRowHeight)
                            }
                        }
                    }
                    .frame(height: CGFloat(min(history.count, 4))
                        * (Self.historyRowHeight + 4) - 4)
                    .padding(.top, 4)
                } label: {
                    Text("Previous \(history.count) day\(history.count == 1 ? "" : "s")")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }

            Text("Recorded as digital signal level (dBFS), not as sound "
                 + "pressure — the estimate above is the closest this app "
                 + "gets to that.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Stream quality

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: Binding(
                    get: { stageState.detectQuality },
                    set: { stageState.setDetectQuality($0) })) {
                    Text("Detect stream quality")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Spacer()
                if stageState.detectQuality {
                    Text(verbatim: verdictText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(verdictColor)
                }
            }
            .help("Measures the audio itself: lossy codecs cut the high "
                  + "frequencies at telltale points, lossless extends to the "
                  + "edge. Works with any player — it doesn't ask, it listens. "
                  + "Evidence, not proof: a lossless file made from a lossy "
                  + "source keeps the cutoff, and quiet material can't be "
                  + "judged.")

            if stageState.detectQuality {
                Toggle(isOn: Binding(
                    get: { stageState.autoRate },
                    set: { stageState.setAutoRate($0) })) {
                    Text("Auto-match USB rate")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Lossless detected → 44.1 kHz (the bit-perfect path). "
                      + "Lossy → back to the rate you last picked yourself. "
                      + "Content proven beyond the 44.1 family → 96 kHz. "
                      + "Switches only after the verdict holds for 10 seconds, "
                      + "and never while Soundstage is on (it resamples anyway).")
            }
        }
    }

    private var verdictText: String {
        guard stageState.engine.isRunning else {
            // "engine off" next to a switch reading on is true but useless.
            // The reason itself is at the top of the pane; this only has to
            // say which of the two situations it is.
            return stageState.engineFailure == nil ? "engine off" : "engine didn't start"
        }
        switch stageState.qualityVerdict {
        case nil: return "listening…"
        case .tooQuiet: return "too quiet to judge"
        case .noTreble: return "no treble to judge"
        case .lossy(let khz):
            return String(format: "lossy (cuts at %.1f kHz)", khz)
        case .lossyHigh(let khz):
            return String(format: "lossy, high bitrate (%.1f kHz)", khz)
        case .losslessLike(let khz):
            return String(format: "consistent with lossless (%.1f kHz)", khz)
        case .hiRes(let khz):
            return String(format: "hi-res content (%.1f kHz)", khz)
        case .natural(let khz):
            return String(format: "rolls off naturally (%.1f kHz) — can't judge", khz)
        }
    }

    private var verdictColor: AnyShapeStyle {
        switch stageState.qualityVerdict {
        case .losslessLike, .hiRes: return AnyShapeStyle(.green)
        case .lossy: return AnyShapeStyle(.orange)
        case .lossyHigh: return AnyShapeStyle(.yellow)
        default: return AnyShapeStyle(.secondary)
        }
    }

    // MARK: - Live meter

    private var meter: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Output level")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(levelText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.6))
                    if let db = stageState.currentLevelDb {
                        Capsule()
                            .fill(LinearGradient(
                                colors: [.green, .green, .yellow, .orange, .red],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(3, fraction(db) * geo.size.width))
                            .animation(.linear(duration: 0.5), value: db)
                    }
                    // The "loud" threshold, so the colour has a meaning.
                    Rectangle().fill(.tertiary)
                        .frame(width: 1)
                        .offset(x: fraction(StageState.loudThresholdDb) * geo.size.width)
                }
            }
            .frame(height: 8)
        }
    }

    private var levelText: String {
        guard stageState.engine.isRunning else { return "off" }
        guard let db = stageState.currentLevelDb else { return "silent" }
        return String(format: "%.0f dBFS", db)
    }

    private func fraction(_ db: Double) -> CGFloat {
        CGFloat(min(max((db + 60) / 60, 0), 1))
    }

    // MARK: - History

    private func todayView(_ day: DayExposure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Today")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            HStack(spacing: 14) {
                stat("Listened", Self.duration(day.audibleSeconds))
                stat("Loud", Self.duration(day.loudSeconds),
                     highlight: day.loudSeconds > 3600)
                // energySum can be zero with audible seconds on a crafted
                // file; log10(0) renders "-Inf dBFS".
                stat("Average", day.energySum > 0
                     ? String(format: "%.0f dBFS",
                              10 * log10(day.energySum / max(day.audibleSeconds, 1)))
                     : "—")
            }
        }
    }

    private func stat(_ label: String, _ value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(highlight ? .orange : .primary)
        }
    }

    private static let historyRowHeight: CGFloat = 13

    private func historyRow(_ day: DayExposure) -> some View {
        let maxSeconds = max(stageState.exposureDays.map(\.audibleSeconds).max() ?? 1, 1)
        return HStack(spacing: 8) {
            Text(shortDate(day.day))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.5))
                    Capsule().fill(Color.accentColor.opacity(0.55))
                        .frame(width: max(2, geo.size.width
                            * CGFloat(min(day.audibleSeconds / maxSeconds, 1))))
                    // The loud share, in place, so heavy days stand out.
                    Capsule().fill(Color.orange.opacity(0.8))
                        .frame(width: max(day.loudSeconds > 0 ? 2 : 0, geo.size.width
                            * CGFloat(min(day.loudSeconds / maxSeconds, 1))))
                }
            }
            .frame(height: 6)
            Text(Self.duration(day.audibleSeconds))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func shortDate(_ key: String) -> String {
        // "2026-08-06" → "Aug 6"
        let parts = key.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m) else { return key }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[m - 1]) \(d)"
    }

    static func duration(_ seconds: Double) -> String {
        // Int(Double) traps beyond Int64 range; data comes off a
        // user-writable file, so it doesn't get to crash the pane.
        let s = seconds.isFinite ? Int(min(max(seconds, 0), 999_999_999)) : 0
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }
}
