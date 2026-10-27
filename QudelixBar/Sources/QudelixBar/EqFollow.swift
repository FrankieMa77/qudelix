import Foundation

enum EQFit {
    static let anchorWeight = 0.2
    static let damping = 0.3
    static let stepDb = 1.0
    static let probeDb = 0.1
    static let shrinks = 4
    static let lowHz = 40.0
    static let fullWeightHz = 100.0
    static let lowWeight = 0.5.squareRoot()
    static let highHz = 16000.0
    static let settleDb = 0.005
    static let gainLimitDb = 12.0

    static func response(bands: [QxEqBandValue], preGain: Double = 0, count: Int = 180) -> [Double] {
        EQCurve.response(bands: bands, preGain: preGain, count: count)
    }

    static func response(bands: [QxEqBandValue], preGain: Double = 0, count: Int,
                         from minHz: Double, to maxHz: Double) -> [Double] {
        EQCurve.response(bands: bands, preGain: preGain,
                         at: EQCurve.logSweep(count: count, from: minHz, to: maxHz))
    }

    static func maxDeviation(bands: [QxEqBandValue], from reference: [QxEqBandValue],
                             offsetDb: Double = 0) -> Double {
        let ours = response(bands: bands, count: 120, from: 100, to: 10000)
        let theirs = response(bands: reference, count: 120, from: 100, to: 10000)
        return zip(ours, theirs).map { abs($0 - ($1 + offsetDb)) }.max() ?? 0
    }

    static func matched(bands: [QxEqBandValue], toReference reference: [QxEqBandValue],
                        anchors: [QxEqBandValue]? = nil, offsetDb: Double = 0,
                        iterations: Int = 24, movable ids: Set<Int>? = nil) -> [QxEqBandValue] {
        let movable = bands.indices.filter {
            bands[$0].filter != .bypass && bands[$0].filter.hasGain
                && (ids?.contains($0) ?? true)
        }
        guard !movable.isEmpty, iterations > 0 else { return bands }
        var freqs = (0..<180).map { EQCurve.frequency(atFraction: Double($0) / 179) }
            .filter { $0 >= lowHz && $0 <= highHz }
        let gridCount = freqs.count
        freqs += movable.map { min(max(Double(bands[$0].freq), EQCurve.minFreq), EQCurve.maxFreq) }
        let weight = freqs.indices.map { k in
            k < gridCount && freqs[k] < fullWeightHz ? lowWeight : 1.0
        }
        let phases = freqs.map { EQCurve.Phase(radians: 2 * .pi * $0 / EQCurve.sampleRate) }
        let sections = reference.compactMap(EQCurve.BandFilter.init(band:))
        let target = phases.map { phase in
            sections.reduce(offsetDb) { $0 + $1.gainDb(at: phase) }
        }
        let anchorBands = anchors ?? reference
        let anchor = movable.map { i -> Double in
            let band = bands[i]
            func same(_ other: QxEqBandValue) -> Bool {
                other.filter == band.filter && other.freq == band.freq && other.q == band.q
            }
            if anchorBands.indices.contains(i), same(anchorBands[i]) { return anchorBands[i].gain }
            return anchorBands.first(where: same)?.gain ?? 0
        }
        let count = movable.count
        var result = bands
        var contribution = bands.map { fitCurve($0, at: phases) }
        var gains = movable.map { bands[$0].gain }

        func fitCost(_ contribution: [[Double]], _ gains: [Double]) -> Double {
            var cost = 0.0
            for k in freqs.indices {
                var sum = 0.0
                for curve in contribution { sum += curve[k] }
                let miss = weight[k] * (target[k] - sum)
                cost += miss * miss
            }
            for m in 0..<count {
                let off = gains[m] - anchor[m]
                cost += anchorWeight * off * off
            }
            return cost
        }

        var current = fitCost(contribution, gains)
        for _ in 0..<iterations {
            var residual = target
            for curve in contribution { for k in freqs.indices { residual[k] -= curve[k] } }
            for k in freqs.indices { residual[k] *= weight[k] }
            var jacobian = [[Double]]()
            jacobian.reserveCapacity(count)
            for (m, i) in movable.enumerated() {
                var probe = result[i]
                let h = gains[m] + probeDb > gainLimitDb ? -probeDb : probeDb
                probe.gain = gains[m] + h
                let curve = fitCurve(probe, at: phases)
                jacobian.append(freqs.indices.map { weight[$0] * (curve[$0] - contribution[i][$0]) / h })
            }
            var normal = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
            var rhs = [Double](repeating: 0, count: count)
            for a in 0..<count {
                for b in a..<count {
                    var dot = 0.0
                    for k in freqs.indices { dot += jacobian[a][k] * jacobian[b][k] }
                    normal[a][b] = dot
                    normal[b][a] = dot
                }
                normal[a][a] += anchorWeight + damping
                var pull = 0.0
                for k in freqs.indices { pull += jacobian[a][k] * residual[k] }
                rhs[a] = pull - anchorWeight * (gains[a] - anchor[a])
            }
            guard var delta = solvePositiveDefinite(normal, rhs) else { break }
            let largest = delta.reduce(0) { max($0, abs($1)) }
            if largest > stepDb { delta = delta.map { $0 * stepDb / largest } }
            var scale = 1.0
            var moved: Double?
            for _ in 0...shrinks {
                var trialGains = gains
                var trialContribution = contribution
                var trialBands = result
                for (m, i) in movable.enumerated() {
                    trialGains[m] = min(max(gains[m] + scale * delta[m], -gainLimitDb), gainLimitDb)
                    guard trialGains[m] != gains[m] else { continue }
                    trialBands[i].gain = trialGains[m]
                    trialContribution[i] = fitCurve(trialBands[i], at: phases)
                }
                let trial = fitCost(trialContribution, trialGains)
                if trial < current {
                    moved = zip(trialGains, gains).reduce(0) { max($0, abs($1.0 - $1.1)) }
                    result = trialBands
                    contribution = trialContribution
                    gains = trialGains
                    current = trial
                    break
                }
                scale *= 0.5
            }
            guard let step = moved, step >= settleDb else { break }
        }
        return result
    }

    private static func fitCurve(_ band: QxEqBandValue, at phases: [EQCurve.Phase]) -> [Double] {
        guard let section = EQCurve.BandFilter(band: band) else {
            return [Double](repeating: 0, count: phases.count)
        }
        return phases.map { section.gainDb(at: $0) }
    }

    static func solvePositiveDefinite(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var l = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0...i {
                var sum = a[i][j]
                for k in 0..<j { sum -= l[i][k] * l[j][k] }
                if i == j {
                    guard sum > 0 else { return nil }
                    l[i][i] = sum.squareRoot()
                } else {
                    l[i][j] = sum / l[j][j]
                }
            }
        }
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sum = b[i]
            for k in 0..<i { sum -= l[i][k] * y[k] }
            y[i] = sum / l[i][i]
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var sum = y[i]
            for k in (i + 1)..<n { sum -= l[k][i] * x[k] }
            x[i] = sum / l[i][i]
        }
        return x
    }
}

enum ReferenceFollower {
    struct Target: Equatable {
        var bands: [QxEqBandValue]
        var anchors: [QxEqBandValue]
        var offsetDb: Double
    }

    struct Result: Equatable {
        var bands: [QxEqBandValue]
        var preGain: Double
        var deviationDb: Double

        var gains: [Double] { bands.map(\.gain) }
    }

    struct FollowHealth: Equatable {
        static let risingLimit = 5
        static let stuckLimit = 5
        static let riseDb = 0.05
        static let riseFloorDb = 1.5
        static let stuckDb = 6.0
        static let clampDb = 11.95
        static let tameReferenceDb = 6.0

        var lastDeviationDb: Double?
        var risingTicks = 0
        var stuckTicks = 0

        mutating func failing(display: [QxEqBandValue], target: Target, pinned: Set<Int>,
                              targetChanged: Bool) -> Bool {
            let dev = EQFit.maxDeviation(bands: display, from: target.bands,
                                         offsetDb: target.offsetDb)
            return failing(deviationDb: dev, display: display, target: target, pinned: pinned,
                           targetChanged: targetChanged)
        }

        mutating func failing(deviationDb dev: Double, display: [QxEqBandValue], target: Target,
                              pinned: Set<Int>, targetChanged: Bool) -> Bool {
            if !targetChanged, let last = lastDeviationDb, dev > last + Self.riseDb,
               dev > Self.riseFloorDb {
                risingTicks += 1
            } else {
                risingTicks = 0
            }
            stuckTicks = dev >= Self.stuckDb ? stuckTicks + 1 : 0
            lastDeviationDb = dev
            if risingTicks >= Self.risingLimit || stuckTicks >= Self.stuckLimit { return true }
            let pinnedAtClamp = display.indices.contains {
                pinned.contains($0) && abs(display[$0].gain) >= Self.clampDb
            }
            guard pinnedAtClamp else { return false }
            let span = EQFit.response(bands: target.bands, preGain: target.offsetDb)
                .reduce(0) { max($0, abs($1)) }
            return span <= Self.tameReferenceDb
        }
    }

    static let iterationsPerTick = 6
    static let startIterations = 24
    static let quantumDb = 0.1

    static func pinnedSet(base: [QxEqBandValue]) -> Set<Int> {
        Set(base.indices.filter { base[$0].filter != .bypass && base[$0].filter.hasGain })
    }

    static func sameLayout(_ a: [QxEqBandValue], _ b: [QxEqBandValue]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            $0.filter == $1.filter && $0.freq == $1.freq && $0.q == $1.q
        }
    }

    static func target(reference: [QxEqBandValue], trim: TrimGains?) -> Target {
        guard let trim, !trim.isZero else {
            return Target(bands: reference, anchors: reference, offsetDb: 0)
        }
        return Target(bands: reference + trim.bands, anchors: reference,
                      offsetDb: -trim.levelDb())
    }

    static func quantized(_ db: Double) -> Double {
        guard db.isFinite else { return 0 }
        return (db * 10).rounded() / 10 + 0
    }

    static func solve(base: [QxEqBandValue], basePreGain: Double,
                      reference: [QxEqBandValue], referencePreGain: Double,
                      trim: TrimGains?, iterations: Int, previousGains: [Double]? = nil,
                      capToHeadroom: Bool = true) -> Result {
        let pinned = pinnedSet(base: base)
        var start = base
        if let previousGains, previousGains.count == base.count {
            for i in pinned {
                let g = previousGains[i]
                start[i].gain = g.isFinite ? min(max(g, -EQFit.gainLimitDb), EQFit.gainLimitDb) : 0
            }
        }
        let goal = target(reference: reference, trim: trim)
        var bands = EQFit.matched(bands: start, toReference: goal.bands, anchors: goal.anchors,
                                  offsetDb: goal.offsetDb, iterations: iterations,
                                  movable: pinned)
        for i in pinned { bands[i].gain = quantized(bands[i].gain) }
        let neutral = EQHeadroom.clamp(quantized(
            referencePreGain.isFinite ? referencePreGain : basePreGain))
        let preGain = capToHeadroom
            ? min(neutral, EQHeadroom.suggestedPreGain(for: bands)
                  + max(0, basePreGain - EQHeadroom.suggestedPreGain(for: base)))
            : neutral
        let deviation = EQFit.maxDeviation(bands: bands, from: goal.bands, offsetDb: goal.offsetDb)
        return Result(bands: bands, preGain: preGain, deviationDb: deviation)
    }
}
