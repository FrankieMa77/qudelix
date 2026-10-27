import Foundation

struct EQLine: Equatable {
    var bands: [QxEqBandValue]
    var offsetDb: Double

    func response() -> [Double] {
        EQCurve.response(bands: bands, preGain: 0).map { $0 + offsetDb }
    }
}

enum AutomationReadout {
    struct Lines: Equatable {
        var reference: EQLine?
        var trim: EQLine?
    }

    struct Inputs: Equatable {
        var showReference = true
        var source: ReferenceSource = .listening
        var reference: ReferenceCurve?
        var userBands: [QxEqBandValue] = []
        var trim: TrimGains = .zero
        var autoTrimOn = false
        var following = false
    }

    static func lines(_ input: Inputs) -> Lines {
        let trimActive = input.autoTrimOn && !input.trim.isZero
        let trim: TrimGains? = trimActive ? input.trim : nil
        var reference: EQLine?
        if input.showReference {
            switch input.source {
            case .auto, .catalog:
                if let curve = input.reference {
                    reference = line(reference: curve.bands, trim: trim)
                }
            case .listening:
                if trimActive, !input.userBands.isEmpty {
                    reference = line(reference: input.userBands, trim: trim)
                }
            }
        }
        var trimLine: EQLine?
        if trimActive, reference == nil, !input.following, !input.userBands.isEmpty {
            trimLine = line(reference: input.userBands, trim: trim)
        }
        return Lines(reference: reference, trim: trimLine)
    }

    private static func line(reference: [QxEqBandValue], trim: TrimGains?) -> EQLine {
        let target = ReferenceFollower.target(reference: reference, trim: trim)
        return EQLine(bands: target.bands, offsetDb: target.offsetDb)
    }

    static func signed(_ value: Double) -> String {
        String(format: "%+.1f", value).replacingOccurrences(of: "-", with: "\u{2212}")
    }

    static func trimValues(_ g: TrimGains) -> String {
        "bass \(signed(g.bassDb)) \u{00B7} tilt \(signed(g.tiltDbPerOctave)) dB/oct \u{00B7} "
            + "presence \(signed(g.presenceDb)) \u{00B7} air \(signed(g.airDb))"
    }

    static func trimValuesShort(_ g: TrimGains) -> String {
        "b \(signed(g.bassDb)) \u{00B7} t \(signed(g.tiltDbPerOctave)) \u{00B7} "
            + "p \(signed(g.presenceDb)) \u{00B7} a \(signed(g.airDb))"
    }

    static func learningMinutes(_ baseline: BalanceBaseline) -> Int? {
        baseline.isLearned ? nil : baseline.readings * 3 / 60
    }

    static func referenceTexts(source: ReferenceSource, reference: ReferenceCurve?,
                               trim: TrimGains, autoTrimOn: Bool,
                               mode: TrimMode) -> [String] {
        switch source {
        case .auto, .catalog:
            guard let r = reference else {
                return ["catalog \u{2014} none fitted for this headphone yet",
                        "catalog \u{2014} none yet"]
            }
            let name = r.headphone.isEmpty ? "fitted correction" : r.headphone
            let by = r.measuredBy.isEmpty ? "" : " \u{00B7} " + r.measuredBy
            return [name + by, name]
        case .listening:
            guard autoTrimOn else {
                return ["listening \u{2014} Auto-trim is off, nothing to follow",
                        "listening \u{2014} Auto-trim is off"]
            }
            if trim.isZero, mode == .audiophile {
                return ["listening \u{2014} audiophile: nothing to follow",
                        "listening \u{2014} audiophile"]
            }
            if trim.isZero { return ["listening\u{2026}"] }
            return ["listening \u{2014} " + trimValues(trim),
                    "listening \u{2014} " + trimValuesShort(trim)]
        }
    }

    static func followNote(following: Bool, paused: Bool, waitingReason: String?,
                           deviationDb: Double?, referenceActive: Bool) -> String? {
        if paused {
            return "Paused \u{2014} this band layout can't follow the line. Resume to try again."
        }
        if let waitingReason { return waitingReason }
        guard following else { return nil }
        let what = referenceActive ? "Auto-fit is following the line" : "Auto-trim is moving the gains"
        guard let deviationDb else { return what }
        return what + String(format: " \u{2014} %.1f dB off", deviationDb)
    }

    static let readOnlyHelp = "The 5K's gains are moving on their own \u{2014} Keep them, "
        + "or turn Auto-fit and Auto-trim off, to edit."

    static func advisoryValues(_ g: TrimGains) -> String {
        "would trim bass \(signed(g.bassDb)) \u{00B7} tilt \(signed(g.tiltDbPerOctave)) \u{00B7} "
            + "presence \(signed(g.presenceDb))"
    }

    static func trimLines(on: Bool, detecting: Bool, mode: TrimMode, trim: TrimGains,
                          baseline: BalanceBaseline, advisory: TrimGains = .zero) -> [String] {
        guard on else {
            return ["moves the 5K's gains a little at a time toward your usual balance"]
        }
        guard detecting else { return ["needs Detect stream quality (Level pane)"] }
        if mode == .audiophile {
            let rounded = advisory.rounded()
            if rounded.bassDb != 0 || rounded.tiltDbPerOctave != 0 || rounded.presenceDb != 0 {
                return ["audiophile \u{2014} " + advisoryValues(rounded) + ", nothing moves",
                        advisoryValues(rounded)]
            }
            return ["audiophile \u{2014} measures only, nothing moves"]
        }
        let values = trimValues(trim)
        if let minutes = learningMinutes(baseline) {
            return [values + " \u{2014} baseline learning (\(minutes) min)", values]
        }
        return [values + " \u{2014} toward your usual balance", values,
                trimValuesShort(trim)]
    }

    static func balanceText(_ b: BalanceFeatures?) -> String {
        guard let b else { return "listening\u{2026}" }
        return "bass \(signed(b.bassDb)) \u{00B7} tilt \(signed(b.tiltDbPerOctave)) dB/oct"
            + " \u{00B7} presence \(signed(b.presenceDb))"
    }

    static func baselineText(_ baseline: BalanceBaseline) -> String {
        if let minutes = learningMinutes(baseline) {
            return "learning your usual balance (\(minutes) of \(BalanceBaseline.learnedAfter * 3 / 60) min)"
        }
        return "your usual balance is learned"
    }
}

extension AutomationReadout {
    @MainActor
    static func inputs(_ automation: EqAutomation, _ controller: QudelixController) -> Inputs {
        Inputs(showReference: automation.showReference,
               source: automation.effectiveSource,
               reference: automation.currentReference,
               userBands: controller.userBands,
               trim: automation.trim,
               autoTrimOn: automation.autoTrimOn,
               following: automation.following)
    }
}
