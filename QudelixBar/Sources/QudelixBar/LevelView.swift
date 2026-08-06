import SwiftUI

/// Live output level and listening history, measured on the Mac.
///
/// Everything here is digital signal level (dBFS), not sound pressure — the
/// app cannot know the headphone's sensitivity or the analog volume. Trends
/// and durations are honest; absolute loudness claims would not be, so the
/// pane never makes any.
struct LevelView: View {
    @EnvironmentObject var stageState: StageState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle(isOn: Binding(
                    get: { stageState.levelTracking || stageState.stage.enabled },
                    set: { stageState.setLevelTracking($0) })) {
                    Text("Track listening levels")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                // While the Stage runs, the meter rides its engine for free
                // and there is nothing to switch off here.
                .disabled(stageState.stage.enabled)
                Spacer()
            }

            if stageState.stage.enabled {
                Text("Metering rides the Soundstage engine while it runs.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            } else if stageState.levelTracking, !stageState.engine.isRunning {
                Text(verbatim: stageState.engine.status)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !stageState.levelTracking {
                Text("Listens to the Mac's output level only — nothing is "
                     + "recorded and the audio path is untouched.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            meter

            Divider()

            qualitySection

            Divider()

            if let today = stageState.exposureDays.first(where: { $0.day == StageState.dayKey() }),
               today.audibleSeconds > 0 {
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("Previous days")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    ForEach(Array(history), id: \.day) { day in
                        historyRow(day)
                    }
                }
            }

            Text("Levels are the digital signal (dBFS). How loud that is in "
                 + "your ears depends on the 5K's volume and your headphones.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            SignalPathView()
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
        guard stageState.engine.isRunning else { return "engine off" }
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
