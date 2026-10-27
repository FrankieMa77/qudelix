import Foundation

struct ReferenceCurve: Codable, Equatable {
    var bands: [QxEqBandValue]
    var preGain: Double
    var source: String
    var headphone: String
    var rig: String
    var target: String
    var bassBoostDb: Double
    var tilt: Double
    var ceilingHz: Double?
    var fittedAt: Date

    static let maxTextLength = 128
    static let maxBands = 32
    static let gainRange: ClosedRange<Double> = -12...12
    static let freqRange = 20...20000
    static let qRange: ClosedRange<Double> = 0.05...100

    init(file: ParametricEQFile, source: String, headphone: String, rig: String = "",
         options: CorrectionOptions = CorrectionOptions(), fittedAt: Date = Date()) {
        bands = file.bands
        preGain = file.preamp
        self.source = source
        self.headphone = headphone
        self.rig = rig
        target = options.target ?? ""
        bassBoostDb = options.bassBoostGain
        tilt = options.tilt
        ceilingHz = options.maxCorrectionHz
        self.fittedAt = fittedAt
        self = sanitized()
    }

    private enum CodingKeys: String, CodingKey {
        case bands, preGain, source, headphone, rig, target, bassBoostDb, tilt, ceilingHz,
             fittedAt
    }

    private struct LossyBand: Decodable {
        let value: QxEqBandValue?

        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(QxEqBandValue.self)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode([LossyBand].self, forKey: .bands)
        bands = raw.compactMap(\.value)
        preGain = (try? c.decodeIfPresent(Double.self, forKey: .preGain)) ?? 0
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? ""
        headphone = (try? c.decodeIfPresent(String.self, forKey: .headphone)) ?? ""
        rig = (try? c.decodeIfPresent(String.self, forKey: .rig)) ?? ""
        target = (try? c.decodeIfPresent(String.self, forKey: .target)) ?? ""
        bassBoostDb = (try? c.decodeIfPresent(Double.self, forKey: .bassBoostDb)) ?? 0
        tilt = (try? c.decodeIfPresent(Double.self, forKey: .tilt)) ?? 0
        ceilingHz = try? c.decodeIfPresent(Double.self, forKey: .ceilingHz)
        fittedAt = (try? c.decodeIfPresent(Date.self, forKey: .fittedAt)) ?? .distantPast
        self = sanitized()
        guard bands.contains(where: { $0.filter != .bypass }) else {
            throw DecodingError.dataCorruptedError(forKey: .bands, in: c,
                                                   debugDescription: "no usable bands")
        }
    }

    struct Lossy: Decodable {
        let value: ReferenceCurve?

        init(from decoder: Decoder) throws {
            value = try? ReferenceCurve(from: decoder)
        }
    }

    func sanitized() -> ReferenceCurve {
        var r = self
        r.bands = bands.filter { $0.filter != .bypass }.prefix(Self.maxBands).map { band in
            var b = band
            b.freq = min(max(b.freq, Self.freqRange.lowerBound), Self.freqRange.upperBound)
            b.gain = b.gain.isFinite
                ? min(max(b.gain, Self.gainRange.lowerBound), Self.gainRange.upperBound) : 0
            b.q = b.q.isFinite
                ? min(max(b.q, Self.qRange.lowerBound), Self.qRange.upperBound) : 1
            return b
        }
        r.preGain = EQHeadroom.clamp(preGain)
        r.source = SafeText.scrubbed(source, limit: Self.maxTextLength)
        r.headphone = SafeText.scrubbed(headphone, limit: Self.maxTextLength)
        r.rig = SafeText.scrubbed(rig, limit: Self.maxTextLength)
        r.target = SafeText.scrubbed(target, limit: Self.maxTextLength)
        let options = CorrectionOptions(bassBoostGain: bassBoostDb, tilt: tilt,
                                        target: nil, maxCorrectionHz: ceilingHz).quantized()
        r.bassBoostDb = options.bassBoostGain
        r.tilt = options.tilt
        r.ceilingHz = options.maxCorrectionHz.map {
            min(max($0, CorrectionOptions.minCorrectionHz), DeviceEQLimits.qudelix(bandCount: 1).maxFc)
        }
        r.fittedAt = fittedAt.timeIntervalSinceReferenceDate.isFinite ? fittedAt : .distantPast
        return r
    }

    var measuredBy: String {
        let name = rig.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? source : name
    }
}
