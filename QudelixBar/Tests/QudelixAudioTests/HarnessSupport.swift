import Foundation
import QudelixAudio
import QudelixBar
import XCTest

enum Harness {
    static let fiveK = "qx_test_5k"
    static let other = "qx_test_other"
    static let sampleRate = 48000

    static var isActive: Bool {
        ProcessInfo.processInfo.environment["QX_PIPEWIRE_HARNESS"] == "1"
    }

    static func require() throws {
        if !isActive { throw XCTSkip("QX_PIPEWIRE_HARNESS is not set; run linux/tests/pipewire-harness.sh") }
    }
}

func waitFor(_ seconds: Double = 8, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

@discardableResult
func runTool(_ arguments: [String], timeout: Double = 30) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-1, "")
    }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func writeSineWav(frequency: Double, amplitude: Double, seconds: Double) throws -> URL {
    let rate = Harness.sampleRate
    let frames = Int(Double(rate) * seconds)
    var data = Data()
    func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let payload = frames * 4
    data.append(contentsOf: Array("RIFF".utf8))
    append32(UInt32(36 + payload))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append32(16)
    append16(1)
    append16(2)
    append32(UInt32(rate))
    append32(UInt32(rate * 4))
    append16(4)
    append16(16)
    data.append(contentsOf: Array("data".utf8))
    append32(UInt32(payload))
    for i in 0..<frames {
        let value = Int16((amplitude * 32767.0 * sin(2.0 * Double.pi * frequency * Double(i) / Double(rate))).rounded())
        append16(UInt16(bitPattern: value))
        append16(UInt16(bitPattern: value))
    }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("qx-sine-\(UUID().uuidString).wav")
    try data.write(to: url)
    return url
}

final class Recorder {
    private let lock = NSLock()
    private var left: [Float] = []
    private var right: [Float] = []
    private var rates: Set<Int> = []
    private var widths: Set<Int> = []

    init() {
        left.reserveCapacity(48000 * 12)
        right.reserveCapacity(48000 * 12)
    }

    var block: AudioCaptureBlock {
        { [self] samples, frames, channels, rate in
            lock.lock()
            rates.insert(rate)
            widths.insert(channels)
            for i in 0..<frames {
                left.append(samples[i * channels])
                right.append(samples[i * channels + (channels > 1 ? 1 : 0)])
            }
            lock.unlock()
        }
    }

    var snapshot: (left: [Float], right: [Float], rates: Set<Int>, channels: Set<Int>) {
        lock.lock()
        defer { lock.unlock() }
        return (left, right, rates, widths)
    }

    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return left.count
    }

    func reset() {
        lock.lock()
        left.removeAll(keepingCapacity: true)
        right.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

struct ToneFit {
    var amplitude: Double
    var residualRatio: Double
    var activeFrames: Int
}

func fitTone(_ samples: [Float], frequency: Double, rate: Int = Harness.sampleRate) -> ToneFit? {
    guard let first = samples.firstIndex(where: { abs($0) > 0.02 }),
          let last = samples.lastIndex(where: { abs($0) > 0.02 }),
          last - first > rate / 2 else { return nil }
    let margin = (last - first) / 5
    let start = first + margin
    let end = last - margin
    var scc = 0.0, sss = 0.0, scs = 0.0, sxc = 0.0, sxs = 0.0
    let step = 2.0 * Double.pi * frequency / Double(rate)
    for i in start..<end {
        let phase = step * Double(i)
        let c = cos(phase), s = sin(phase), x = Double(samples[i])
        scc += c * c
        sss += s * s
        scs += c * s
        sxc += x * c
        sxs += x * s
    }
    let determinant = scc * sss - scs * scs
    guard abs(determinant) > 1e-9 else { return nil }
    let a = (sxc * sss - sxs * scs) / determinant
    let b = (sxs * scc - sxc * scs) / determinant
    var residual = 0.0
    var energy = 0.0
    for i in start..<end {
        let phase = step * Double(i)
        let fitted = a * cos(phase) + b * sin(phase)
        let x = Double(samples[i])
        residual += (x - fitted) * (x - fitted)
        energy += x * x
    }
    return ToneFit(amplitude: (a * a + b * b).squareRoot(),
                   residualRatio: (residual / max(energy, 1e-12)).squareRoot(),
                   activeFrames: last - first)
}

struct SteadyTone {
    var amplitude: Double
    var residualRatio: Double
    var windows: Int
    var agreeing: Int
    var amplitudes: [Double]

    func agreeingSeconds(rate: Int = Harness.sampleRate, windowFrames: Int) -> Double {
        Double(agreeing * windowFrames) / Double(rate)
    }
}

func fitToneWindows(_ samples: [Float], frequency: Double, rate: Int = Harness.sampleRate,
                    windowFrames: Int = Harness.sampleRate / 10) -> SteadyTone? {
    guard let first = samples.firstIndex(where: { abs($0) > 0.02 }),
          let last = samples.lastIndex(where: { abs($0) > 0.02 }),
          last - first >= windowFrames * 4 else { return nil }
    let step = 2.0 * Double.pi * frequency / Double(rate)
    var amplitudes: [Double] = []
    var residuals: [Double] = []
    var start = first
    while start + windowFrames <= last {
        var scc = 0.0, sss = 0.0, scs = 0.0, sxc = 0.0, sxs = 0.0
        for i in start..<(start + windowFrames) {
            let phase = step * Double(i)
            let c = cos(phase), s = sin(phase), x = Double(samples[i])
            scc += c * c
            sss += s * s
            scs += c * s
            sxc += x * c
            sxs += x * s
        }
        let determinant = scc * sss - scs * scs
        guard abs(determinant) > 1e-9 else { return nil }
        let a = (sxc * sss - sxs * scs) / determinant
        let b = (sxs * scc - sxc * scs) / determinant
        var residual = 0.0
        var energy = 0.0
        for i in start..<(start + windowFrames) {
            let phase = step * Double(i)
            let fitted = a * cos(phase) + b * sin(phase)
            let x = Double(samples[i])
            residual += (x - fitted) * (x - fitted)
            energy += x * x
        }
        amplitudes.append((a * a + b * b).squareRoot())
        residuals.append((residual / max(energy, 1e-12)).squareRoot())
        start += windowFrames
    }
    let sounding = amplitudes.indices.filter { amplitudes[$0] > 0.02 }
    guard !sounding.isEmpty else { return nil }
    let sorted = sounding.map { amplitudes[$0] }.sorted()
    let median = sorted[sorted.count / 2]
    let medianResidual = sounding.map { residuals[$0] }.sorted()[sounding.count / 2]
    let agreeing = sounding.filter { abs(amplitudes[$0] - median) <= 0.05 * median }.count
    return SteadyTone(amplitude: median, residualRatio: medianResidual, windows: amplitudes.count,
                      agreeing: agreeing, amplitudes: amplitudes)
}

func playWav(_ url: URL, target: String) -> Bool {
    runTool(["pw-play", "--target", target, url.path]).status == 0
}
