import Accelerate
import AVFoundation
import Foundation

struct ImpulseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ImpulseLimits {
    static let maxSeconds: Double = 2
    static let maxFileBytes = 64 << 20
    static let minHop = 32
    static let maxHop = 2048
    static let maxBlockFrames = 8192
    static let macsPerSecond: Double = 600_000_000

    static func maxPartitions(sampleRate: Double) -> Int {
        let rate = max(sampleRate, 8000)
        return max(1, min(8192, Int(macsPerSecond / (8 * rate))))
    }

    static func hop(forBlock frames: Int) -> Int {
        guard frames >= minHop, frames <= maxBlockFrames else { return 0 }
        var h = 1
        while h < maxHop, frames % (h * 2) == 0 { h *= 2 }
        return h >= minHop ? h : 0
    }

    static func log2Length(_ n: Int) -> vDSP_Length {
        vDSP_Length(log2(Double(n)).rounded())
    }
}

final class ImpulseResponse: @unchecked Sendable {
    let fileName: String
    let displayName: String
    let hash: String
    let sourceRate: Double
    let sourceChannels: Int
    let sourceFrames: Int
    let channels: [[Float]]

    private var cachedRate: Double = 0
    private var cachedChannels: [[Float]] = []

    var seconds: Double { Double(sourceFrames) / sourceRate }
    var isStereo: Bool { channels.count == 2 }

    init(fileName: String, displayName: String, hash: String,
         sourceRate: Double, sourceChannels: Int, channels: [[Float]]) {
        self.fileName = fileName
        self.displayName = displayName
        self.hash = hash
        self.sourceRate = sourceRate
        self.sourceChannels = sourceChannels
        self.channels = channels
        self.sourceFrames = channels.first?.count ?? 0
    }

    func samples(at rate: Double) -> [[Float]] {
        if rate == sourceRate { return channels }
        if cachedRate == rate, !cachedChannels.isEmpty { return cachedChannels }
        let resampled = channels.map {
            Resampler.convert($0, from: sourceRate, to: rate)
        }
        cachedRate = rate
        cachedChannels = resampled
        return resampled
    }

    func prime(at rate: Double) {
        _ = samples(at: rate)
    }
}

enum Resampler {
    static let halfWidth = 32

    static func convert(_ input: [Float], from source: Double,
                        to target: Double) -> [Float] {
        guard source > 0, target > 0, source != target, !input.isEmpty else {
            return input
        }
        let ratio = target / source
        let count = max(1, Int((Double(input.count) * ratio).rounded()))
        guard count <= 1 << 24 else { return input }
        let cutoff = min(1.0, ratio)
        let width = Double(halfWidth) / cutoff
        var out = [Float](repeating: 0, count: count)
        let last = input.count - 1
        for n in 0..<count {
            let center = Double(n) / ratio
            let lo = max(0, Int((center - width).rounded(.up)))
            let hi = min(last, Int((center + width).rounded(.down)))
            guard lo <= hi else { continue }
            var acc = 0.0
            for k in lo...hi {
                let t = center - Double(k)
                acc += Double(input[k]) * kernel(t, width: width, cutoff: cutoff)
            }
            out[n] = acc.isFinite ? Float(acc) : 0
        }
        return out
    }

    private static func kernel(_ t: Double, width: Double, cutoff: Double) -> Double {
        guard abs(t) <= width else { return 0 }
        let phase = (t + width) / (2 * width)
        let window = 0.42 - 0.5 * cos(2 * .pi * phase) + 0.08 * cos(4 * .pi * phase)
        let x = cutoff * t
        let sinc = abs(x) < 1e-9 ? 1 : sin(.pi * x) / (.pi * x)
        return cutoff * sinc * window
    }
}

final class ConvolverState {
    let name: String
    let sampleRate: Double
    let blockFrames: Int
    let hop: Int
    let fftSize: Int
    let partitions: Int
    let taps: Int
    let stereo: Bool

    private let setup: FFTSetup
    private let log2n: vDSP_Length
    private let hL, hR: UnsafeMutablePointer<Float>
    private let fdlL, fdlR: UnsafeMutablePointer<Float>
    private let curL, curR, prevL, prevR: UnsafeMutablePointer<Float>
    private let outL, outR: UnsafeMutablePointer<Float>
    private let timeBuf: UnsafeMutablePointer<Float>
    private let accLre, accLim, accRre, accRim: UnsafeMutablePointer<Float>
    private var fdlWrite = 0

    init(impulse: ImpulseResponse, sampleRate: Double, blockFrames: Int) throws {
        let rate = AudioOutputs.plausibleRate(sampleRate)
        let step = ImpulseLimits.hop(forBlock: blockFrames)
        guard step > 0 else {
            throw ImpulseError(message: "This output hands the app "
                + "\(blockFrames) samples at a time, which the convolver "
                + "can't partition. Change the output device's buffer size "
                + "in Audio MIDI Setup and it will run.")
        }
        var sources = impulse.samples(at: rate)
        guard !sources.isEmpty, let first = sources.first, !first.isEmpty else {
            throw ImpulseError(message: "That impulse response has no samples "
                + "left at \(Self.rateLabel(rate)).")
        }
        let ceiling = max(1, Int(rate * ImpulseLimits.maxSeconds))
        for i in sources.indices where sources[i].count > ceiling {
            sources[i] = Array(sources[i].prefix(ceiling))
        }
        let length = sources.map(\.count).max() ?? 0
        let count = (length + step - 1) / step
        let budget = ImpulseLimits.maxPartitions(sampleRate: rate)
        guard count <= budget else {
            throw ImpulseError(message: String(format: "That response needs "
                + "%d partitions of %d samples at %@, and the render budget "
                + "allows %d. A shorter response, or a larger buffer size for "
                + "this output, will fit.",
                count, step, Self.rateLabel(rate), budget))
        }

        name = impulse.displayName
        self.sampleRate = rate
        self.blockFrames = blockFrames
        hop = step
        fftSize = 2 * step
        partitions = count
        taps = length
        stereo = sources.count >= 2

        guard let created = vDSP_create_fftsetup(ImpulseLimits.log2Length(fftSize),
                                                 FFTRadix(kFFTRadix2)) else {
            throw ImpulseError(message: "The system refused to build the "
                + "transform this response needs.")
        }
        setup = created
        log2n = ImpulseLimits.log2Length(fftSize)

        func alloc(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        let spectrum = partitions * fftSize
        hL = alloc(spectrum); hR = alloc(spectrum)
        fdlL = alloc(spectrum); fdlR = alloc(spectrum)
        curL = alloc(step); curR = alloc(step)
        prevL = alloc(step); prevR = alloc(step)
        outL = alloc(step); outR = alloc(step)
        timeBuf = alloc(fftSize)
        accLre = alloc(step); accLim = alloc(step)
        accRre = alloc(step); accRim = alloc(step)

        let left = sources[0]
        let right = sources.count >= 2 ? sources[1] : sources[0]
        transformFilter(left, into: hL)
        transformFilter(right, into: hR)
    }

    deinit {
        for p in [hL, hR, fdlL, fdlR, curL, curR, prevL, prevR,
                  outL, outR, timeBuf, accLre, accLim, accRre, accRim] {
            p.deallocate()
        }
        vDSP_destroy_fftsetup(setup)
    }

    private static func rateLabel(_ rate: Double) -> String {
        String(format: "%g kHz", rate / 1000)
    }

    func accepts(frames: Int) -> Bool {
        frames > 0 && frames <= blockFrames && frames % hop == 0
    }

    func reset() {
        let spectrum = partitions * fftSize
        fdlL.update(repeating: 0, count: spectrum)
        fdlR.update(repeating: 0, count: spectrum)
        curL.update(repeating: 0, count: hop)
        curR.update(repeating: 0, count: hop)
        prevL.update(repeating: 0, count: hop)
        prevR.update(repeating: 0, count: hop)
        outL.update(repeating: 0, count: hop)
        outR.update(repeating: 0, count: hop)
        fdlWrite = 0
    }

    func render(left: UnsafeMutablePointer<Float>,
                right: UnsafeMutablePointer<Float>,
                frames: Int, wet: Float) {
        guard accepts(frames: frames) else { return }
        let mix = min(max(wet.isFinite ? wet : 0, 0), 1)
        let dry = 1 - mix
        var base = 0
        while base < frames {
            for i in 0..<hop {
                var a = left[base + i], b = right[base + i]
                if !a.isFinite { a = 0 }
                if !b.isFinite { b = 0 }
                curL[i] = a
                curR[i] = b
            }
            forward(current: curL, previous: prevL, into: fdlL)
            forward(current: curR, previous: prevR, into: fdlR)
            prevL.update(from: curL, count: hop)
            prevR.update(from: curR, count: hop)
            accumulate()
            for i in 0..<hop {
                var a = curL[i] * dry + outL[i] * mix
                var b = curR[i] * dry + outR[i] * mix
                if !a.isFinite { a = 0 }
                if !b.isFinite { b = 0 }
                left[base + i] = a
                right[base + i] = b
            }
            fdlWrite += 1
            if fdlWrite >= partitions { fdlWrite = 0 }
            base += hop
        }
    }

    private func transformFilter(_ samples: [Float],
                                 into destination: UnsafeMutablePointer<Float>) {
        let scale = Float(1) / Float(4 * fftSize)
        for p in 0..<partitions {
            timeBuf.update(repeating: 0, count: fftSize)
            let start = p * hop
            if start < samples.count {
                let n = min(hop, samples.count - start)
                samples.withUnsafeBufferPointer { src in
                    timeBuf.update(from: src.baseAddress! + start, count: n)
                }
            }
            let slot = destination + p * fftSize
            var split = DSPSplitComplex(realp: slot, imagp: slot + hop)
            timeBuf.withMemoryRebound(to: DSPComplex.self, capacity: hop) { c in
                vDSP_ctoz(c, 2, &split, 1, vDSP_Length(hop))
            }
            vDSP_fft_zrip(setup, &split, 1, log2n,
                          FFTDirection(kFFTDirection_Forward))
            for k in 0..<(2 * hop) { slot[k] *= scale }
        }
    }

    private func forward(current: UnsafeMutablePointer<Float>,
                         previous: UnsafeMutablePointer<Float>,
                         into fdl: UnsafeMutablePointer<Float>) {
        timeBuf.update(from: previous, count: hop)
        (timeBuf + hop).update(from: current, count: hop)
        let slot = fdl + fdlWrite * fftSize
        var split = DSPSplitComplex(realp: slot, imagp: slot + hop)
        timeBuf.withMemoryRebound(to: DSPComplex.self, capacity: hop) { c in
            vDSP_ctoz(c, 2, &split, 1, vDSP_Length(hop))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
    }

    private func accumulate() {
        accLre.update(repeating: 0, count: hop)
        accLim.update(repeating: 0, count: hop)
        accRre.update(repeating: 0, count: hop)
        accRim.update(repeating: 0, count: hop)
        for p in 0..<partitions {
            var idx = fdlWrite - p
            if idx < 0 { idx += partitions }
            let offset = p * fftSize
            multiplyAccumulate(fdlL + idx * fftSize, hL + offset, accLre, accLim)
            multiplyAccumulate(fdlR + idx * fftSize, hR + offset, accRre, accRim)
        }
        inverse(accLre, accLim, into: outL)
        inverse(accRre, accRim, into: outR)
    }

    @inline(__always)
    private func multiplyAccumulate(_ x: UnsafeMutablePointer<Float>,
                                    _ h: UnsafeMutablePointer<Float>,
                                    _ accRe: UnsafeMutablePointer<Float>,
                                    _ accIm: UnsafeMutablePointer<Float>) {
        let xr = x, xi = x + hop
        let hr = h, hi = h + hop
        accRe[0] += xr[0] * hr[0]
        accIm[0] += xi[0] * hi[0]
        for k in 1..<hop {
            let a = xr[k], b = xi[k], c = hr[k], d = hi[k]
            accRe[k] += a * c - b * d
            accIm[k] += a * d + b * c
        }
    }

    private func inverse(_ re: UnsafeMutablePointer<Float>,
                         _ im: UnsafeMutablePointer<Float>,
                         into destination: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: re, imagp: im)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        timeBuf.withMemoryRebound(to: DSPComplex.self, capacity: hop) { c in
            vDSP_ztoc(&split, 1, c, 2, vDSP_Length(hop))
        }
        destination.update(from: timeBuf + hop, count: hop)
    }
}

struct ImpulseInfo: Equatable {
    var fileName: String
    var displayName: String
    var seconds: Double
    var channels: Int
    var sourceRate: Double

    init(_ response: ImpulseResponse) {
        fileName = response.fileName
        displayName = response.displayName
        seconds = response.seconds
        channels = response.sourceChannels
        sourceRate = response.sourceRate
    }
}

enum IRLibrary {
    static var directory: URL { prepared(StageStateFile.directory) }

    private static func prepared(_ parent: URL) -> URL {
        let fm = FileManager.default
        let dir = parent.appendingPathComponent("impulses", isDirectory: true)
        var st = stat()
        let mode: mode_t? = dir.withUnsafeFileSystemRepresentation { path -> mode_t? in
            guard let path, lstat(path, &st) == 0 else { return nil }
            return st.st_mode
        }
        switch mode {
        case let m? where m & S_IFMT == S_IFDIR:
            if m & 0o777 != 0o700 {
                try? fm.setAttributes([.posixPermissions: 0o700],
                                      ofItemAtPath: dir.path)
            }
        case .some:
            let aside = parent.appendingPathComponent(
                "impulses.displaced-\(Int(Date().timeIntervalSince1970))")
            try? fm.moveItem(at: dir, to: aside)
            fallthrough
        case nil:
            try? fm.createDirectory(at: dir, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        }
        return dir
    }

    static func storedURL(_ name: String, in dir: URL = directory) -> URL {
        dir.appendingPathComponent(name)
    }

    static func displayName(for stored: String) -> String {
        let base = (stored as NSString).deletingPathExtension
        guard let dash = base.lastIndex(of: "-"),
              base.distance(from: base.index(after: dash),
                            to: base.endIndex) == 8 else {
            return SafeText.scrubbed(base, limit: ImpulseLimits.maxDisplayLength)
        }
        let head = String(base[base.startIndex..<dash])
        let name = head.isEmpty ? base : head
        return SafeText.scrubbed(name, limit: ImpulseLimits.maxDisplayLength)
    }

    static func install(source: URL, into dir: URL = directory) throws -> ImpulseResponse {
        let ext = source.pathExtension.lowercased()
        guard ImpulseLimits.allowedExtensions.contains(ext) else {
            throw ImpulseError(message: ext.isEmpty
                ? "That file has no extension. This reads WAV, AIFF and CAF "
                    + "impulse responses."
                : "This reads WAV, AIFF and CAF impulse responses, not ." + ext + ".")
        }
        var st = stat()
        let mode: mode_t? = source.withUnsafeFileSystemRepresentation { path -> mode_t? in
            guard let path, lstat(path, &st) == 0 else { return nil }
            return st.st_mode
        }
        guard let mode else {
            throw ImpulseError(message: "That file isn't there any more.")
        }
        guard mode & S_IFMT == S_IFREG else {
            throw ImpulseError(message: mode & S_IFMT == S_IFLNK
                ? "That path is a symbolic link. Pick the audio file itself."
                : "That isn't a regular file — a pipe, a folder or a device "
                    + "can't be an impulse response.")
        }
        guard st.st_size > 0 else {
            throw ImpulseError(message: "That file is empty.")
        }
        guard st.st_size <= ImpulseLimits.maxFileBytes else {
            throw ImpulseError(message: "That file is larger than 64 MB. An "
                + "impulse response is a couple of seconds of audio.")
        }
        guard let bytes = SafeFile.read(source, cap: ImpulseLimits.maxFileBytes) else {
            throw ImpulseError(message: "Couldn't read that file.")
        }
        let hash = fingerprint(bytes)
        let name = storedName(for: source, extension: ext, hash: hash)
        let destination = storedURL(name, in: dir)
        guard SafeFile.writeAtomic(bytes, to: destination) else {
            throw ImpulseError(message: "Couldn't copy that file into the app's "
                + "own folder — check the disk has room.")
        }
        do {
            return try load(name: name, from: dir)
        } catch {
            remove(name: name, from: dir)
            throw error
        }
    }

    static func load(name: String, from dir: URL = directory) throws -> ImpulseResponse {
        guard let safe = safeName(name) else {
            throw ImpulseError(message: "That impulse response's name isn't one "
                + "this app wrote.")
        }
        let url = storedURL(safe, in: dir)
        var st = stat()
        let ok = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path, lstat(path, &st) == 0 else { return false }
            return st.st_mode & S_IFMT == S_IFREG
        }
        guard ok else {
            throw ImpulseError(message: "The stored copy of that impulse "
                + "response is gone.")
        }
        guard let bytes = SafeFile.read(url, cap: ImpulseLimits.maxFileBytes) else {
            throw ImpulseError(message: "Couldn't read the stored copy of that "
                + "impulse response.")
        }
        let hash = fingerprint(bytes)

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ImpulseError(message: "macOS couldn't read that as audio. "
                + "Impulse responses are WAV, AIFF or CAF files.")
        }
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        guard channelCount == 1 || channelCount == 2 else {
            throw ImpulseError(message: "That file has \(channelCount) channels. "
                + "An impulse response has to be mono — applied to both ears — "
                + "or stereo, one response per side.")
        }
        let sourceRate = format.sampleRate
        guard AudioOutputs.isPlausibleRate(sourceRate) else {
            throw ImpulseError(message: "That file claims a sample rate no "
                + "device could play.")
        }
        let frames = file.length
        guard frames > 0 else {
            throw ImpulseError(message: "That file has no audio in it.")
        }
        let duration = Double(frames) / sourceRate
        guard duration <= ImpulseLimits.maxSeconds,
              frames <= Int64(ImpulseLimits.maxSeconds * 384_000) else {
            throw ImpulseError(message: String(format: "That file is %.1f "
                + "seconds long. An impulse response is a decay, not a "
                + "recording — the longest this reads is %.0f seconds.",
                duration, ImpulseLimits.maxSeconds))
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              (try? file.read(into: buffer)) != nil,
              buffer.frameLength > 0,
              let raw = buffer.floatChannelData else {
            throw ImpulseError(message: "macOS read that file but produced no "
                + "audio from it.")
        }
        let read = Int(buffer.frameLength)

        var bad = 0
        for c in 0..<channelCount {
            let p = raw[c]
            for i in 0..<read where !p[i].isFinite {
                p[i] = 0
                bad += 1
            }
        }
        let total = read * channelCount
        if total > 0, Double(bad) / Double(total) > 0.01 {
            throw ImpulseError(message: String(format: "%.0f%% of that file is "
                + "NaNs or infinities — it isn't usable audio.",
                Double(bad) / Double(total) * 100))
        }

        var decoded: [[Float]] = []
        for c in 0..<channelCount {
            var samples = [Float](repeating: 0, count: read)
            samples.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: raw[c], count: read)
            }
            decoded.append(samples)
        }
        var peak: Float = 0
        for channel in decoded {
            for v in channel { peak = max(peak, abs(v)) }
        }
        guard peak > 0 else {
            throw ImpulseError(message: "That impulse response is silent — "
                + "every sample in it is zero.")
        }

        return ImpulseResponse(fileName: safe, displayName: displayName(for: safe),
                               hash: hash, sourceRate: sourceRate,
                               sourceChannels: channelCount, channels: decoded)
    }

    static func remove(name: String, from dir: URL = directory) {
        guard let safe = safeName(name) else { return }
        try? FileManager.default.removeItem(at: storedURL(safe, in: dir))
    }

    @discardableResult
    static func sweep(keeping referenced: Set<String>,
                      in dir: URL = directory) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var swept: [String] = []
        for name in names.sorted() where !referenced.contains(name) {
            if name.hasPrefix(".") { continue }
            remove(name: name, from: dir)
            swept.append(name)
        }
        return swept
    }

    static func fingerprint(_ data: Data) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", h)
    }

    private static func storedName(for source: URL, extension ext: String,
                                   hash: String) -> String {
        let raw = source.deletingPathExtension().lastPathComponent
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
                          + "0123456789_-")
        var base = ""
        for ch in raw {
            if allowed.contains(ch) {
                base.append(ch)
            } else if ch == " " || ch == "." {
                base.append("_")
            }
            if base.count >= ImpulseLimits.maxDisplayLength { break }
        }
        while base.hasPrefix("_") || base.hasPrefix("-") { base.removeFirst() }
        if base.isEmpty { base = "impulse" }
        return base + "-" + String(hash.prefix(8)) + "." + ext
    }
}
