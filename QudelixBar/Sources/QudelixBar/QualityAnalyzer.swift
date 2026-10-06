import Accelerate
import Foundation

final class QualityAnalyzer {
    enum Verdict: Equatable {
        case tooQuiet
        case noTreble
        case lossy(cutoffKHz: Double)
        case lossyHigh(cutoffKHz: Double)
        case losslessLike(cutoffKHz: Double)
        case hiRes(cutoffKHz: Double)
        case natural(cutoffKHz: Double)

        var isLosslessClass: Bool? {
            switch self {
            case .lossy: return false
            case .lossyHigh(let k): return k < 19.7 ? false : nil
            case .losslessLike, .hiRes: return true
            case .tooQuiet, .noTreble, .natural: return nil
            }
        }

        var kind: Int {
            switch self {
            case .tooQuiet: return 0
            case .noTreble: return 1
            case .lossy: return 2
            case .lossyHigh: return 3
            case .losslessLike: return 4
            case .hiRes: return 5
            case .natural: return 6
            }
        }
    }

    static let fftSize = 8192
    private let log2n = vDSP_Length(13)
    private var fftSetup: FFTSetup?
    private var window = [Float](repeating: 0, count: fftSize)
    private var real = [Float](repeating: 0, count: fftSize / 2)
    private var imag = [Float](repeating: 0, count: fftSize / 2)
    private var magnitudes = [Float](repeating: 0, count: fftSize / 2)
    private var averagedDb = [Float](repeating: -160, count: fftSize / 2)
    private var windowsAveraged = 0

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    func feed(_ samples: [Float]) {
        guard samples.count >= Self.fftSize, let fftSetup else { return }

        var windowed = [Float](repeating: 0, count: Self.fftSize)
        samples.withUnsafeBufferPointer { p in
            vDSP_vmul(p.baseAddress!, 1, window, 1, &windowed, 1,
                      vDSP_Length(Self.fftSize))
        }

        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                              &split, 1, vDSP_Length(Self.fftSize / 2))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(Self.fftSize / 2))
            }
        }

        var floorVal: Float = 1e-12
        vDSP_vthr(magnitudes, 1, &floorVal, &magnitudes, 1, vDSP_Length(Self.fftSize / 2))
        var one: Float = 1
        var db = [Float](repeating: 0, count: Self.fftSize / 2)
        vDSP_vdbcon(magnitudes, 1, &one, &db, 1, vDSP_Length(Self.fftSize / 2), 0)
        if windowsAveraged == 0 {
            averagedDb = db
        } else {
            vDSP_vmax(averagedDb, 1, db, 1, &averagedDb, 1, vDSP_Length(Self.fftSize / 2))
        }
        windowsAveraged += 1
    }

    func reset() {
        windowsAveraged = 0
        for i in averagedDb.indices { averagedDb[i] = -160 }
    }

    private(set) var lastDebug = ""

    func classify(sampleRate: Double) -> Verdict? {
        defer { windowsAveraged = 0 }
        guard windowsAveraged > 0, AudioOutputs.isPlausibleRate(sampleRate) else { return nil }

        let binHz = sampleRate / Double(Self.fftSize)
        func bin(_ hz: Double) -> Int {
            min(Self.fftSize / 2 - 1, max(0, Int(hz / binHz)))
        }

        var totalPower: Double = 0
        for i in bin(300)...bin(8000) {
            totalPower += pow(10, Double(averagedDb[i]) / 10)
        }
        let bandPowerDb = 10 * log10(max(totalPower, 1e-16)) - 79
        lastDebug = String(format: "bandPower=%.1f dBFS", bandPowerDb)
        guard bandPowerDb > -55 else { return .tooQuiet }

        let refBins = Array(averagedDb[bin(1000)...bin(8000)]).sorted()
        let reference = refBins[(refBins.count * 3) / 4]

        let topHz = sampleRate / 2 - 200
        var cells: [(kHz: Double, level: Float)] = []
        var f = 9000.0
        while f + 250 <= topHz {
            var level: Float = -160
            for i in bin(f)...bin(f + 250) { level = max(level, averagedDb[i]) }
            cells.append((kHz: (f + 125) / 1000, level: level))
            f += 250
        }
        guard cells.count > 8 else { return .noTreble }

        var profile = ""
        for kHz in [10.0, 13, 16, 18, 19, 20, 21, 21.8] where kHz * 1000 < topHz {
            if let cell = cells.last(where: { $0.kHz <= kHz }) {
                profile += String(format: " %gk:%.0f", kHz, cell.level - reference)
            }
        }
        lastDebug += " ref-rel:" + profile

        let anchor = cells.prefix(8).map(\.level).max() ?? -160
        guard anchor > reference - 40 else { return .noTreble }

        var cliffKHz = 0.0
        var cliffDrop: Float = 0
        for i in 0..<(cells.count - 4) where cells[i].kHz >= 12 {
            let drop = cells[i].level - cells[i + 4].level
            if drop > cliffDrop {
                cliffDrop = drop
                cliffKHz = cells[i].kHz + 0.5
            }
        }
        if cliffDrop >= 20 {
            lastDebug += String(format: " cliff=%.1fk (%.0f dB)", cliffKHz, cliffDrop)
            switch cliffKHz {
            case ..<18.5: return .lossy(cutoffKHz: cliffKHz)
            case ..<20.25: return .lossyHigh(cutoffKHz: cliffKHz)
            case ..<22.5: return .losslessLike(cutoffKHz: cliffKHz)
            default: return .hiRes(cutoffKHz: cliffKHz)
            }
        }

        let fadeKHz = cells.last(where: { $0.level > anchor - 35 })?.kHz ?? 0
        lastDebug += String(format: " fade=%.1fk", fadeKHz)
        let topKHz = topHz / 1000
        if fadeKHz >= 22.5 { return .hiRes(cutoffKHz: fadeKHz) }
        if fadeKHz >= min(20.9, topKHz - 0.5) { return .losslessLike(cutoffKHz: fadeKHz) }
        if fadeKHz < 14.5 { return .noTreble }
        return .natural(cutoffKHz: fadeKHz)
    }
}
