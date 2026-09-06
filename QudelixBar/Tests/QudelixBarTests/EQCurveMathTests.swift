import XCTest
import CoreGraphics
@testable import QudelixBar

final class EQCurveMathTests: XCTestCase {

    private func referenceBandGainDb(_ band: QxEqBandValue, at freq: Double) -> Double {
        let f0 = max(1, min(Double(band.freq), EQCurve.sampleRate / 2 - 1))
        let q = max(0.05, band.q)
        let gain = band.gain
        let a = pow(10, gain / 40)
        let w0 = 2 * .pi * f0 / EQCurve.sampleRate
        let cosW0 = cos(w0), sinW0 = sin(w0)
        let alpha = sinW0 / (2 * q)

        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0

        switch band.filter {
        case .peak:
            b0 = 1 + alpha * a;  b1 = -2 * cosW0;  b2 = 1 - alpha * a
            a0 = 1 + alpha / a;  a1 = -2 * cosW0;  a2 = 1 - alpha / a
        case .lowShelf:
            let sq = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) - (a - 1) * cosW0 + sq)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosW0)
            b2 = a * ((a + 1) - (a - 1) * cosW0 - sq)
            a0 = (a + 1) + (a - 1) * cosW0 + sq
            a1 = -2 * ((a - 1) + (a + 1) * cosW0)
            a2 = (a + 1) + (a - 1) * cosW0 - sq
        case .highShelf:
            let sq = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) + (a - 1) * cosW0 + sq)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosW0)
            b2 = a * ((a + 1) + (a - 1) * cosW0 - sq)
            a0 = (a + 1) - (a - 1) * cosW0 + sq
            a1 = 2 * ((a - 1) - (a + 1) * cosW0)
            a2 = (a + 1) - (a - 1) * cosW0 - sq
        case .lpf:
            b0 = (1 - cosW0) / 2;  b1 = 1 - cosW0;  b2 = (1 - cosW0) / 2
            a0 = 1 + alpha;        a1 = -2 * cosW0; a2 = 1 - alpha
        case .hpf:
            b0 = (1 + cosW0) / 2;  b1 = -(1 + cosW0); b2 = (1 + cosW0) / 2
            a0 = 1 + alpha;        a1 = -2 * cosW0;   a2 = 1 - alpha
        case .bypass:
            return 0
        }

        let w = 2 * .pi * freq / EQCurve.sampleRate
        let cosW = cos(w), sinW = sin(w)
        let cos2W = cos(2 * w), sin2W = sin(2 * w)

        let numRe = b0 + b1 * cosW + b2 * cos2W
        let numIm = -(b1 * sinW + b2 * sin2W)
        let denRe = a0 + a1 * cosW + a2 * cos2W
        let denIm = -(a1 * sinW + a2 * sin2W)

        let num = sqrt(numRe * numRe + numIm * numIm)
        let den = sqrt(denRe * denRe + denIm * denIm)
        guard den > 1e-12, num > 1e-12 else { return 0 }
        let db = 20 * log10(num / den)
        return db.isFinite ? db : 0
    }

    private func referenceResponse(_ bands: [QxEqBandValue], preGain: Double,
                                   at freqs: [Double]) -> [Double] {
        freqs.map { f in
            var db = preGain
            for band in bands where band.filter != .bypass {
                db += referenceBandGainDb(band, at: f)
            }
            return db
        }
    }

    private let denseGrid = EQCurve.logSweep(count: 2000, from: 5, to: 23000)

    private let everyFilter: [QxFilter] = [.peak, .lowShelf, .highShelf, .lpf, .hpf, .bypass]

    private func worstGap(_ bands: [QxEqBandValue], preGain: Double,
                          at freqs: [Double]) -> (gap: Double, freq: Double) {
        let got = EQCurve.response(bands: bands, preGain: preGain, at: freqs)
        let want = referenceResponse(bands, preGain: preGain, at: freqs)
        guard got.count == want.count else { return (.infinity, 0) }
        var worst = 0.0
        var where_ = 0.0
        for i in got.indices {
            let gap = abs(got[i] - want[i])
            if gap > worst { worst = gap; where_ = freqs[i] }
        }
        return (worst, where_)
    }

    func testEveryFilterTypeMatchesThePerPointFormulaExactly() {
        for filter in everyFilter {
            for freq in [20, 60, 105, 1000, 4700, 10000, 19000] {
                for gain in [-12.0, -6.3, 0, 3.7, 12.0] {
                    for q in [0.1, 0.7, 1.0, 3.5, 10.0] {
                        let band = QxEqBandValue(filter: filter, freq: freq,
                                                 gain: gain, q: q)
                        let (gap, at) = worstGap([band], preGain: 0, at: denseGrid)
                        XCTAssertLessThan(gap, 1e-9,
                                          "\(filter) \(freq) Hz \(gain) dB Q \(q) at \(at) Hz")
                    }
                }
            }
        }
    }

    func testAFullCurveOfMixedFiltersMatchesThePerPointFormula() {
        let curve: [QxEqBandValue] = [
            QxEqBandValue(filter: .lowShelf, freq: 105, gain: 6.4, q: 0.7),
            QxEqBandValue(filter: .peak, freq: 118, gain: -3.1, q: 0.5),
            QxEqBandValue(filter: .bypass, freq: 400, gain: 9.0, q: 2.0),
            QxEqBandValue(filter: .peak, freq: 1200, gain: 2.2, q: 4.0),
            QxEqBandValue(filter: .hpf, freq: 32, gain: 0, q: 0.71),
            QxEqBandValue(filter: .lpf, freq: 18000, gain: 0, q: 0.71),
            QxEqBandValue(filter: .highShelf, freq: 10000, gain: -4.8, q: 0.7),
            QxEqBandValue(filter: .peak, freq: 8800, gain: 5.1, q: 1.42),
        ]
        XCTAssertLessThan(worstGap(curve, preGain: 0, at: denseGrid).gap, 1e-9)
        XCTAssertLessThan(worstGap(curve, preGain: -6.1, at: denseGrid).gap, 1e-9)
    }

    func testAllBypassedIsThePreGainAtEveryPoint() {
        let bands = QxEq.defaultFreqs.map {
            QxEqBandValue(filter: .bypass, freq: $0, gain: 9, q: 1)
        }
        XCTAssertLessThan(worstGap(bands, preGain: -3, at: denseGrid).gap, 1e-9)
        XCTAssertEqual(EQCurve.response(bands: bands, preGain: -3, at: []).count, 0)
        XCTAssertEqual(EQCurve.response(bands: [], preGain: 1.5, count: 4), [1.5, 1.5, 1.5, 1.5])
    }

    func testTheDrawnSweepMatchesThePerPointFormulaAtBothBandCounts() {
        for count in [10, 20] {
            let bands = (0..<count).map { i in
                QxEqBandValue(filter: .peak,
                              freq: Int(EQCurve.frequency(atFraction: Double(i) / Double(count))),
                              gain: Double(i % 5) - 2, q: 0.5 + Double(i) / 10)
            }
            let drawn = EQCurve.logSweep(count: 220)
            XCTAssertEqual(EQCurve.response(bands: bands, preGain: -2).count, 220)
            XCTAssertLessThan(worstGap(bands, preGain: -2, at: drawn).gap, 1e-9,
                              "\(count) bands")
        }
    }

    private func threeBands() -> [QxEqBandValue] {
        [100, 1000, 10000].map { QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1) }
    }

    func testTheSamePointerPositionAlwaysResolvesToTheSameBand() {
        let size = CGSize(width: 400, height: 104)
        let bands = threeBands()
        for x in stride(from: 0.0, through: 400.0, by: 7) {
            let point = CGPoint(x: x, y: size.height / 2)
            let first = EQCurveView.nearestBand(to: point, in: bands, size: size, range: 9)
            let again = EQCurveView.nearestBand(to: point, in: bands, size: size, range: 9)
            XCTAssertEqual(first, again, "resolving twice at x=\(x) disagreed")
        }
    }

    func testATraversalChangesTheHighlightOnlyAtTheMarkers() {
        let size = CGSize(width: 400, height: 104)
        let bands = threeBands()
        let reports = 220
        var hovering: Int?
        var changes = 0
        var everHit = false
        for step in 0..<reports {
            let x = CGFloat(step) / CGFloat(reports - 1) * size.width
            let resolved = EQCurveView.nearestBand(to: CGPoint(x: x, y: size.height / 2),
                                                   in: bands, size: size, range: 9)
            if resolved != nil { everHit = true }
            if resolved != hovering {
                hovering = resolved
                changes += 1
            }
        }
        XCTAssertTrue(everHit, "the traversal must pass over the markers")
        XCTAssertGreaterThan(changes, 0)
        XCTAssertLessThanOrEqual(changes, 6,
                                 "\(reports) pointer reports must not be \(reports) redraws")
    }

    func testBypassedBandsAreNeverHovered() {
        let size = CGSize(width: 400, height: 104)
        var bands = threeBands()
        bands[1].filter = .bypass
        let onTheBypassedOne = CGPoint(
            x: CGFloat(EQCurve.fraction(of: 1000)) * size.width, y: size.height / 2)
        XCTAssertNil(EQCurveView.nearestBand(to: onTheBypassedOne, in: bands,
                                             size: size, range: 9))
    }
}
