import Foundation

enum StageMode: Equatable {
    case insert, monitor
}

struct AutoRateDevice: Equatable {
    var uid: String
    var isBluetooth: Bool
    var rate: Double
}

enum StagePolicy {
    static let silenceFloorDb: Double = -55
    static let loudThresholdDb: Double = -12

    static func wantedMode(stageEnabled: Bool, perAppEQ: Bool,
                           levelTracking: Bool,
                           detectQuality: Bool) -> StageMode? {
        if stageEnabled { return .insert }
        if perAppEQ { return .insert }
        if levelTracking || detectQuality { return .monitor }
        return nil
    }

    static func callIsActive(outputOnCall: Bool,
                             deviceActiveCall: Bool?,
                             deviceInputSource: String?) -> Bool {
        if outputOnCall { return true }
        if deviceActiveCall == true { return true }
        return deviceInputSource?.hasPrefix("HFP") ?? false
    }

    static func callVerdict(_ witnesses: CallWitnesses,
                            releasedByHand: Bool) -> (active: Bool, stillReleased: Bool) {
        let stillReleased = releasedByHand && witnesses.deviceSaysCall
        let active = witnesses.outputOnCall || (witnesses.deviceSaysCall && !stillReleased)
        return (active, stillReleased)
    }

    static func rateAfterCall(manual: Double?, available: [Double]) -> Double? {
        let candidates = available.filter { $0 > AudioOutputs.callModeCeilingHz }
        if let manual, candidates.contains(manual) { return manual }
        return candidates.filter { $0 <= 48000 }.max() ?? candidates.min()
    }

    static func callBadgeHelp(_ witnesses: CallWitnesses) -> String {
        if witnesses.headsetMicRunning {
            return "An app is using the headset's microphone, so Bluetooth has "
                + "dropped to call mode (HFP) at voice quality. The muffled sound "
                + "is the codec, not the EQ. If the call is over, click to move "
                + "the microphone to this Mac and end call mode."
        }
        if witnesses.outputAtCallRate {
            return "The headset is still running at the call sample rate. If the "
                + "call is over, click to restore the playback rate."
        }
        return "The 5K reports that it is on a call. If the call is over, click "
            + "to clear this — it comes back when a new call starts."
    }

    static let bassGuardScanLowHz: Double = 20
    static let bassGuardScanHighHz: Double = 200
    static let bassGuardScanPoints = 201
    static let bassGuardInertDb: Double = 0.5

    static func bassGuardBoostDb(bands: [QxEqBandValue],
                                 loudnessShelfDb: Double) -> Double {
        let freqs = EQCurve.logSweep(count: bassGuardScanPoints,
                                     from: bassGuardScanLowHz,
                                     to: bassGuardScanHighHz)
        let curve = EQCurve.response(bands: bands, preGain: 0, at: freqs)
        let shelfDb = loudnessShelfDb.isFinite
            ? min(max(loudnessShelfDb, 0), EarLevel.maxShelfDb) : 0
        let shelf = shelfDb > 0.05
            ? BiquadSection.lowShelf(freq: StageProcessor.loudnessLowHz,
                                     gainDb: shelfDb,
                                     q: StageProcessor.loudnessShelfQ,
                                     sampleRate: EQCurve.sampleRate)
            : nil
        var worst = 0.0
        for (i, f) in freqs.enumerated() {
            var db = curve[i]
            if let shelf {
                db += shelf.magnitudeDb(at: f, sampleRate: EQCurve.sampleRate)
            }
            if db.isFinite, db > worst { worst = db }
        }
        return worst
    }

    static func bassGuardCeilingDb(worstBoostDb: Double,
                                   strength: Double) -> Double {
        guard worstBoostDb.isFinite, worstBoostDb > bassGuardInertDb else { return 0 }
        let scale = strength.isFinite ? min(max(strength, 0), 1) : 0
        return min(worstBoostDb, StageProcessor.bassGuardMaxCeilingDb) * scale
    }

    static func volumeAnchor(playingToQudelix: Bool, qudelixVolumeDb: Double?,
                             systemVolumeDb: @autoclosure () -> Double?
                             ) -> EarVolumeAnchor? {
        if playingToQudelix, let db = qudelixVolumeDb,
           EarLevel.plausibleVolumeDb.contains(db) {
            return .qudelix(db)
        }
        guard let db = systemVolumeDb(), EarLevel.plausibleVolumeDb.contains(db) else {
            return nil
        }
        return .system(db)
    }

    static func exposureAfterTick(_ days: [DayExposure], db: Double, power: Double,
                                  tracking: Bool, today key: String) -> [DayExposure] {
        guard tracking, db > silenceFloorDb else { return days }
        var days = days
        var idx = days.firstIndex { $0.day == key }
        if idx == nil {
            days.append(DayExposure(day: key, audibleSeconds: 0,
                                    loudSeconds: 0, energySum: 0))
            if days.count > 14 {
                days.removeFirst(days.count - 14)
            }
            idx = days.count - 1
        }
        guard let i = idx else { return days }
        days[i].audibleSeconds += 1
        days[i].energySum += power
        if db > loudThresholdDb { days[i].loudSeconds += 1 }
        return days
    }

    static func playbackRates(_ rates: [Double]) -> [Double] {
        rates.filter { $0 > AudioOutputs.callModeCeilingHz }
    }

    static func acceptableManualRate(_ rate: Double?) -> Double? {
        guard let rate, AudioOutputs.isPlausibleRate(rate),
              rate > AudioOutputs.callModeCeilingHz else { return nil }
        return rate
    }

    static func rateForVerdict(_ verdict: QualityAnalyzer.Verdict,
                               availableRates: [Double],
                               manualRateHz: Double?,
                               deviceRate: Double) -> Double? {
        guard let lossless = verdict.isLosslessClass else { return nil }
        if case .hiRes = verdict {
            return availableRates.filter { $0 >= 88200 }.max()
        }
        if lossless { return 44100 }
        return manualRateHz ?? deviceRate
    }

    static func autoRateTarget(verdict: QualityAnalyzer.Verdict?,
                               measuredOn verdictDeviceUID: String?,
                               device: AutoRateDevice?,
                               availableRates: [Double],
                               manualRateHz: Double?,
                               autoRate: Bool,
                               stageEnabled: Bool,
                               callActive: Bool,
                               secondsStable: Double?,
                               secondsSinceLastSwitch: Double) -> Double? {
        guard autoRate, !stageEnabled, !callActive,
              let device, !device.isBluetooth,
              let verdictDeviceUID, device.uid == verdictDeviceUID,
              let verdict,
              let stable = secondsStable, stable >= 10,
              secondsSinceLastSwitch >= 45
        else { return nil }
        let rates = playbackRates(availableRates)
        guard let target = rateForVerdict(verdict, availableRates: rates,
                                          manualRateHz: acceptableManualRate(manualRateHz),
                                          deviceRate: device.rate),
              rates.contains(target), device.rate != target
        else { return nil }
        return target
    }
}

struct ImpulsePrimeGate: Equatable {
    enum Verdict: Equatable {
        case proceed
        case wait
        case prime(rate: Double)
    }

    private(set) var generation = 0
    private(set) var cachedRate: Double?
    private(set) var inFlightGeneration: Int?

    mutating func verdict(sourceRate: Double?, targetRate: Double) -> Verdict {
        guard let sourceRate else { return .proceed }
        if inFlightGeneration != nil { return .wait }
        if targetRate == sourceRate || targetRate == cachedRate { return .proceed }
        inFlightGeneration = generation
        return .prime(rate: targetRate)
    }

    mutating func finished(generation finished: Int, rate: Double) {
        if inFlightGeneration == finished { inFlightGeneration = nil }
        if finished == generation { cachedRate = rate }
    }

    mutating func adopted() {
        generation += 1
        cachedRate = nil
    }

    mutating func engineStarted(at rate: Double) {
        cachedRate = rate
    }
}

struct CallWitnesses: Equatable {
    var outputAtCallRate = false
    var headsetMicRunning = false
    var deviceActiveCall: Bool?
    var deviceInputSource: String?

    var outputOnCall: Bool { outputAtCallRate || headsetMicRunning }

    var deviceSaysCall: Bool {
        StagePolicy.callIsActive(outputOnCall: false, deviceActiveCall: deviceActiveCall,
                                deviceInputSource: deviceInputSource)
    }

    var summary: String {
        var parts: [String] = []
        if outputAtCallRate { parts.append("rate16k") }
        if headsetMicRunning { parts.append("mic") }
        if deviceActiveCall == true { parts.append("devcall") }
        if let source = deviceInputSource, source.hasPrefix("HFP") {
            parts.append("src=" + source.replacingOccurrences(of: " ", with: ""))
        }
        return parts.isEmpty ? "none" : parts.joined(separator: "+")
    }
}
