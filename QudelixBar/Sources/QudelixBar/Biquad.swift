import Foundation

/// Normalised biquad coefficients (a0 divided out), designed in double
/// precision — 32-bit state audibly quantizes on low-frequency sections.
struct BiquadSection {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    static let passthrough = BiquadSection(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// Peaking filter with a matched (impulse-invariant) design — Vicanek,
    /// "Matched Second Order Digital Filters" (2016), §3.2 + §4.4. Unlike the
    /// bilinear transform it doesn't cramp the bandwidth toward Nyquist, so a
    /// treble bell at 44.1 kHz is still the curve it claims to be.
    static func peak(freq: Double, gainDb: Double, q: Double,
                     sampleRate: Double) -> BiquadSection {
        let f0 = max(10, min(freq, sampleRate / 2 - 1))
        let Q = max(0.05, q)
        let G = pow(10, gainDb / 20)
        let w0 = 2 * Double.pi * f0 / sampleRate
        // Pole damping from the prototype's denominator (eq. 42):
        // s·ω0/(√G·Q) ⇒ q = 1/(2·Q·√G). The √G is load-bearing — dropping it
        // fits boosts by luck and audibly mis-shapes cuts.
        let qp = 1 / (2 * Q * sqrt(G))

        // Poles by impulse invariance (eq. 12).
        let expqw = exp(-qp * w0)
        let a1: Double
        if qp <= 1 {
            a1 = -2 * expqw * cos(sqrt(1 - qp * qp) * w0)
        } else {
            a1 = -2 * expqw * cosh(sqrt(qp * qp - 1) * w0)
        }
        let a2 = exp(-2 * qp * w0)

        // Helper quantities at w0 (eqs. 26–27).
        let sinHalf = sin(w0 / 2)
        let phi1 = sinHalf * sinHalf
        let phi0 = 1 - phi1
        let phi2 = 4 * phi0 * phi1
        let A0 = (1 + a1 + a2) * (1 + a1 + a2)
        let A1 = (1 - a1 + a2) * (1 - a1 + a2)
        let A2 = -4 * a2

        // Peaking numerator: unity at DC, |H| = G and extremum at w0
        // (eqs. 43–45).
        let G2 = G * G
        let B0 = A0
        let R1 = (A0 * phi0 + A1 * phi1 + A2 * phi2) * G2
        let R2 = (-A0 + A1 + 4 * (phi0 - phi1) * A2) * G2
        let B2 = (R1 - R2 * phi1 - B0) / (4 * phi1 * phi1)
        let B1 = R2 + B0 + 4 * (phi1 - phi0) * B2

        // Minimum-phase recovery (eqs. 28–29). B1 can dip epsilon-negative
        // through cancellation; clamp before the root.
        let sqB0 = 1 + a1 + a2
        let sqB1 = sqrt(max(0, B1))
        let W = 0.5 * (sqB0 + sqB1)
        let b0 = 0.5 * (W + sqrt(max(0, W * W + B2)))
        let b1 = 0.5 * (sqB0 - sqB1)
        let b2 = -B2 / (4 * b0)
        return BiquadSection(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2)
    }

    /// RBJ cookbook high shelf.
    static func highShelf(freq: Double, gainDb: Double, q: Double,
                          sampleRate: Double) -> BiquadSection {
        let f0 = max(10, min(freq, sampleRate / 2 - 1))
        let Q = max(0.05, q)
        let a = pow(10, gainDb / 40)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cosW0 = cos(w0), sinW0 = sin(w0)
        let alpha = sinW0 / (2 * Q)
        let sq = 2 * sqrt(a) * alpha
        let b0 = a * ((a + 1) + (a - 1) * cosW0 + sq)
        let b1 = -2 * a * ((a - 1) + (a + 1) * cosW0)
        let b2 = a * ((a + 1) + (a - 1) * cosW0 - sq)
        let a0 = (a + 1) - (a - 1) * cosW0 + sq
        let a1 = 2 * ((a - 1) - (a + 1) * cosW0)
        let a2 = (a + 1) - (a - 1) * cosW0 - sq
        return BiquadSection(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0,
                             a1: a1 / a0, a2: a2 / a0)
    }

    static func lowShelf(freq: Double, gainDb: Double, q: Double,
                         sampleRate: Double) -> BiquadSection {
        let f0 = max(10, min(freq, sampleRate / 2 - 1))
        let Q = max(0.05, q)
        let a = pow(10, gainDb / 40)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cosW0 = cos(w0), sinW0 = sin(w0)
        let alpha = sinW0 / (2 * Q)
        let sq = 2 * sqrt(a) * alpha
        let b0 = a * ((a + 1) - (a - 1) * cosW0 + sq)
        let b1 = 2 * a * ((a - 1) - (a + 1) * cosW0)
        let b2 = a * ((a + 1) - (a - 1) * cosW0 - sq)
        let a0 = (a + 1) + (a - 1) * cosW0 + sq
        let a1 = -2 * ((a - 1) + (a + 1) * cosW0)
        let a2 = (a + 1) + (a - 1) * cosW0 - sq
        return BiquadSection(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0,
                             a1: a1 / a0, a2: a2 / a0)
    }

    static func lowPass(freq: Double, q: Double,
                        sampleRate: Double) -> BiquadSection {
        let (cosW0, alpha) = passShape(freq: freq, q: q, sampleRate: sampleRate)
        let b0 = (1 - cosW0) / 2, b1 = 1 - cosW0, b2 = (1 - cosW0) / 2
        let a0 = 1 + alpha, a1 = -2 * cosW0, a2 = 1 - alpha
        return BiquadSection(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0,
                             a1: a1 / a0, a2: a2 / a0)
    }

    static func highPass(freq: Double, q: Double,
                         sampleRate: Double) -> BiquadSection {
        let (cosW0, alpha) = passShape(freq: freq, q: q, sampleRate: sampleRate)
        let b0 = (1 + cosW0) / 2, b1 = -(1 + cosW0), b2 = (1 + cosW0) / 2
        let a0 = 1 + alpha, a1 = -2 * cosW0, a2 = 1 - alpha
        return BiquadSection(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0,
                             a1: a1 / a0, a2: a2 / a0)
    }

    func magnitudeDb(at hz: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * hz / sampleRate
        let cos1 = cos(w), cos2 = cos(2 * w)
        let sin1 = sin(w), sin2 = sin(2 * w)
        let numRe = b0 + b1 * cos1 + b2 * cos2
        let numIm = -(b1 * sin1 + b2 * sin2)
        let denRe = 1 + a1 * cos1 + a2 * cos2
        let denIm = -(a1 * sin1 + a2 * sin2)
        let den = denRe * denRe + denIm * denIm
        guard den > 0 else { return 0 }
        let power = (numRe * numRe + numIm * numIm) / den
        return power > 0 ? 10 * log10(power) : -200
    }

    private static func passShape(freq: Double, q: Double,
                                  sampleRate: Double) -> (cosW0: Double, alpha: Double) {
        let f0 = max(10, min(freq, sampleRate / 2 - 1))
        let Q = max(0.05, q)
        let w0 = 2 * Double.pi * f0 / sampleRate
        return (cos(w0), sin(w0) / (2 * Q))
    }
}
