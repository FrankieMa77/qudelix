import AVFoundation
import CoreAudio
import XCTest
@testable import QudelixBar

final class ConvolverStateTests: XCTestCase {

    func testAUnitImpulseGivesTheSignalBackUnchanged() throws {
        let state = try ConvolverState(impulse: Self.response([1]),
                                       sampleRate: 48000, blockFrames: 128)
        XCTAssertEqual(state.hop, 128)
        XCTAssertEqual(state.partitions, 1)

        let source = Self.signal(512)
        var left = source, right = source
        Self.run(state, &left, &right, wet: 1, block: 128)
        for i in 0..<source.count {
            XCTAssertEqual(left[i], source[i], accuracy: 1e-5, "sample \(i)")
            XCTAssertEqual(right[i], source[i], accuracy: 1e-5, "sample \(i)")
        }
    }

    func testAnImpulseOneSampleInDelaysBySpecificallyOneSample() throws {
        let state = try ConvolverState(impulse: Self.response([0, 1]),
                                       sampleRate: 48000, blockFrames: 128)
        let source = Self.signal(512)
        var left = source, right = source
        Self.run(state, &left, &right, wet: 1, block: 128)

        XCTAssertEqual(left[0], 0, accuracy: 1e-5)
        for i in 1..<source.count {
            XCTAssertEqual(left[i], source[i - 1], accuracy: 1e-5, "sample \(i)")
        }
    }

    func testATwoPartitionResponseMatchesDirectConvolution() throws {
        var taps = [Float](repeating: 0, count: 100)
        var seed: UInt64 = 99
        for i in taps.indices {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            taps[i] = Float(Int64(bitPattern: seed)) / Float(Int64.max)
                * Float(exp(-Double(i) / 25))
        }
        let state = try ConvolverState(impulse: Self.response(taps),
                                       sampleRate: 48000, blockFrames: 64)
        XCTAssertEqual(state.hop, 64)
        XCTAssertEqual(state.partitions, 2)

        let source = Self.signal(1024)
        var left = source, right = source
        Self.run(state, &left, &right, wet: 1, block: 64)
        let expected = Self.convolve(source, taps)
        for i in 0..<source.count {
            XCTAssertEqual(left[i], expected[i], accuracy: 1e-4, "sample \(i)")
        }
    }

    func testAStereoResponseAppliesOneSidePerChannel() throws {
        let impulse = ImpulseResponse(fileName: "pair-00000000.wav",
                                      displayName: "pair", hash: "0",
                                      sourceRate: 48000, sourceChannels: 2,
                                      channels: [[1], [0, 0, 1]])
        let state = try ConvolverState(impulse: impulse, sampleRate: 48000,
                                       blockFrames: 128)
        XCTAssertTrue(state.stereo)
        let source = Self.signal(256)
        var left = source, right = source
        Self.run(state, &left, &right, wet: 1, block: 128)

        XCTAssertEqual(left[10], source[10], accuracy: 1e-5)
        XCTAssertEqual(right[10], source[8], accuracy: 1e-5)
    }

    func testAMixOfZeroLeavesTheDrySignalExactlyWhereItWas() throws {
        let state = try ConvolverState(impulse: Self.response([0, 0, 0.5]),
                                       sampleRate: 48000, blockFrames: 128)
        let source = Self.signal(256)
        var left = source, right = source
        Self.run(state, &left, &right, wet: 0, block: 128)
        XCTAssertEqual(left.map(\.bitPattern), source.map(\.bitPattern))
        XCTAssertEqual(right.map(\.bitPattern), source.map(\.bitPattern))
    }

    func testABlockLargerThanTheOneItWasBuiltForIsRefusedRatherThanRead() throws {
        let state = try ConvolverState(impulse: Self.response([1]),
                                       sampleRate: 48000, blockFrames: 128)
        XCTAssertTrue(state.accepts(frames: 128))
        XCTAssertFalse(state.accepts(frames: 256))
        XCTAssertFalse(state.accepts(frames: 100))
        XCTAssertFalse(state.accepts(frames: 0))

        var left = Self.signal(256), right = Self.signal(256)
        let before = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                state.render(left: l.baseAddress!, right: r.baseAddress!,
                             frames: 256, wet: 1)
            }
        }
        XCTAssertEqual(left.map(\.bitPattern), before.map(\.bitPattern))
    }

    func testABlockSizeThatCannotBePartitionedIsRefusedOutright() {
        XCTAssertEqual(ImpulseLimits.hop(forBlock: 512), 512)
        XCTAssertEqual(ImpulseLimits.hop(forBlock: 480), 32)
        XCTAssertEqual(ImpulseLimits.hop(forBlock: 4096), 2048)
        XCTAssertEqual(ImpulseLimits.hop(forBlock: 16), 0)
        XCTAssertEqual(ImpulseLimits.hop(forBlock: 100), 0)

        XCTAssertThrowsError(try ConvolverState(impulse: Self.response([1]),
                                                sampleRate: 48000,
                                                blockFrames: 100))
    }

    func testAResponseBeyondTheArithmeticBudgetIsRefusedWithAReason() {
        let budget = ImpulseLimits.maxPartitions(sampleRate: 48000)
        XCTAssertGreaterThan(budget, 100)
        let taps = [Float](repeating: 0.001, count: (budget + 2) * 32)
        do {
            _ = try ConvolverState(impulse: Self.response(taps),
                                   sampleRate: 48000, blockFrames: 480)
            XCTFail("a response past the budget should be refused")
        } catch let error as ImpulseError {
            XCTAssertTrue(error.message.contains("partitions"), error.message)
            XCTAssertTrue(error.message.contains("\(budget)"), error.message)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testAResponseLongerThanTheCeilingIsCutRatherThanRefused() throws {
        let taps = [Float](repeating: 0.0001, count: 48000 * 3)
        let state = try ConvolverState(impulse: Self.response(taps),
                                       sampleRate: 48000, blockFrames: 512)
        XCTAssertEqual(state.taps, Int(48000 * ImpulseLimits.maxSeconds))
    }

    func testResamplingLandsOnTheRightLengthAndKeepsTheEnergy() {
        let source = Self.signal(2048)
        let up = Resampler.convert(source, from: 48000, to: 96000)
        XCTAssertEqual(up.count, 4096)
        let down = Resampler.convert(source, from: 48000, to: 24000)
        XCTAssertEqual(down.count, 1024)
        XCTAssertTrue(up.allSatisfy(\.isFinite))
        XCTAssertTrue(down.allSatisfy(\.isFinite))

        let dc = [Float](repeating: 0.5, count: 1024)
        let resampled = Resampler.convert(dc, from: 44100, to: 48000)
        for v in resampled[200..<800] {
            XCTAssertEqual(v, 0.5, accuracy: 0.01)
        }
    }

    func testANonFiniteSampleNeverLeavesTheConvolver() throws {
        let state = try ConvolverState(impulse: Self.response([1, 0.5]),
                                       sampleRate: 48000, blockFrames: 128)
        var left = Self.signal(256), right = Self.signal(256)
        left[7] = .nan
        right[9] = .infinity
        Self.run(state, &left, &right, wet: 1, block: 128)
        XCTAssertTrue(left.allSatisfy(\.isFinite))
        XCTAssertTrue(right.allSatisfy(\.isFinite))
    }


    static func response(_ taps: [Float], rate: Double = 48000) -> ImpulseResponse {
        ImpulseResponse(fileName: "test-00000000.wav", displayName: "test",
                        hash: "0", sourceRate: rate, sourceChannels: 1,
                        channels: [taps])
    }

    static func signal(_ count: Int) -> [Float] {
        var seed: UInt64 = 0x1234_5678_9abc_def0
        return (0..<count).map { i in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: seed)) / Float(Int64.max) * 0.1
            return Float(sin(Double(i) * 0.07)) * 0.4 + noise
        }
    }

    static func run(_ state: ConvolverState, _ left: inout [Float],
                    _ right: inout [Float], wet: Float, block: Int) {
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var base = 0
                while base + block <= l.count {
                    state.render(left: l.baseAddress! + base,
                                 right: r.baseAddress! + base,
                                 frames: block, wet: wet)
                    base += block
                }
            }
        }
    }

    static func convolve(_ x: [Float], _ h: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        for n in 0..<x.count {
            var acc = 0.0
            for k in 0..<min(h.count, n + 1) {
                acc += Double(h[k]) * Double(x[n - k])
            }
            out[n] = Float(acc)
        }
        return out
    }
}

final class ImpulseLibraryTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("impulse-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testAWavFileInstallsAndComesBackWithItsShape() throws {
        let source = scratch.appendingPathComponent("Room Sweep.wav")
        try writeWav(source, samples: taps(2048))

        let response = try IRLibrary.install(source: source, into: scratch)
        XCTAssertEqual(response.sourceChannels, 1)
        XCTAssertEqual(response.sourceRate, 48000)
        XCTAssertEqual(response.sourceFrames, 2048)
        XCTAssertTrue(response.fileName.hasPrefix("Room_Sweep-"))
        XCTAssertTrue(response.fileName.hasSuffix(".wav"))
        XCTAssertEqual(response.displayName, "Room_Sweep")

        var st = stat()
        let stored = IRLibrary.storedURL(response.fileName, in: scratch)
        XCTAssertEqual(lstat(stored.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)

        let again = try IRLibrary.load(name: response.fileName, from: scratch)
        XCTAssertEqual(again.sourceFrames, 2048)
    }

    func testASymlinkIsNeverOpenedAsAnImpulseResponse() throws {
        let real = scratch.appendingPathComponent("real.wav")
        try writeWav(real, samples: taps(512))
        let link = scratch.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertThrowsError(try IRLibrary.install(source: link, into: scratch)) {
            XCTAssertTrue(($0 as? ImpulseError)?.message.contains("link") ?? false,
                          "\($0)")
        }
    }

    func testAFifoIsRefusedInsteadOfBlockingForever() throws {
        let fifo = scratch.appendingPathComponent("pipe.wav")
        let made = fifo.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return mkfifo(path, 0o600)
        }
        XCTAssertEqual(made, 0, "could not create the FIFO this test is about")

        let returned = expectation(description: "install returned")
        var refused = false
        let dir = scratch!
        DispatchQueue.global().async {
            refused = (try? IRLibrary.install(source: fifo, into: dir)) == nil
            returned.fulfill()
        }
        wait(for: [returned], timeout: 3)
        XCTAssertTrue(refused)
    }

    func testAFileBiggerThanTheCapIsRefusedBeforeItIsRead() throws {
        let big = scratch.appendingPathComponent("huge.wav")
        let fd = big.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        }
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, off_t(ImpulseLimits.maxFileBytes + 1)), 0)
        close(fd)

        XCTAssertThrowsError(try IRLibrary.install(source: big, into: scratch)) {
            XCTAssertTrue(($0 as? ImpulseError)?.message.contains("64 MB") ?? false,
                          "\($0)")
        }
    }

    func testAThreeSecondRecordingIsNotAnImpulseResponse() throws {
        let long = scratch.appendingPathComponent("hall.wav")
        try writeWav(long, samples: taps(48000 * 3))

        XCTAssertThrowsError(try IRLibrary.install(source: long, into: scratch)) {
            XCTAssertTrue(($0 as? ImpulseError)?.message.contains("3.0") ?? false,
                          "\($0)")
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        XCTAssertEqual(left, ["hall.wav"], "the refused copy was left behind")
    }

    func testAFileWithNoAudioInItIsRefused() throws {
        let silent = scratch.appendingPathComponent("silent.wav")
        try writeWav(silent, samples: [Float](repeating: 0, count: 1024))

        XCTAssertThrowsError(try IRLibrary.install(source: silent, into: scratch)) {
            XCTAssertTrue(($0 as? ImpulseError)?.message.contains("silent") ?? false,
                          "\($0)")
        }
    }

    func testAnUnreadableExtensionIsRefusedByName() throws {
        let text = scratch.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)

        XCTAssertThrowsError(try IRLibrary.install(source: text, into: scratch)) {
            XCTAssertTrue(($0 as? ImpulseError)?.message.contains(".txt") ?? false,
                          "\($0)")
        }
    }

    func testTheSweepRemovesEveryCopyNoProfileStillNames() throws {
        let keep = scratch.appendingPathComponent("keep.wav")
        let drop = scratch.appendingPathComponent("drop.wav")
        try writeWav(keep, samples: taps(512))
        try writeWav(drop, samples: taps(512))
        let kept = try IRLibrary.install(source: keep, into: scratch)
        let dropped = try IRLibrary.install(source: drop, into: scratch)

        let swept = IRLibrary.sweep(keeping: [kept.fileName, "keep.wav", "drop.wav"],
                                    in: scratch)
        XCTAssertEqual(swept, [dropped.fileName])
        let left = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        XCTAssertTrue(left.contains(kept.fileName))
        XCTAssertFalse(left.contains(dropped.fileName))
    }

    func testAStoredNameThatTriesToLeaveTheFolderIsNotAName() {
        XCTAssertNil(IRLibrary.safeName("../../etc/passwd.wav"))
        XCTAssertNil(IRLibrary.safeName("sub/room.wav"))
        XCTAssertNil(IRLibrary.safeName("room.exe"))
        XCTAssertNil(IRLibrary.safeName(""))
        XCTAssertNil(IRLibrary.safeName(nil))
        XCTAssertNil(IRLibrary.safeName(String(repeating: "a", count: 200) + ".wav"))
        XCTAssertEqual(IRLibrary.safeName("room-1a2b3c4d.wav"), "room-1a2b3c4d.wav")
    }


    private func taps(_ count: Int) -> [Float] {
        var seed: UInt64 = 7
        return (0..<count).map { i in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed)) / Float(Int64.max)
                * Float(exp(-Double(i) / 500))
        }
    }

    private func writeWav(_ url: URL, samples: [Float], rate: Double = 48000,
                          channels: AVAudioChannelCount = 1) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate,
                                   channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            for c in 0..<Int(channels) {
                buffer.floatChannelData![c].update(from: src.baseAddress!,
                                                   count: samples.count)
            }
        }
        try file.write(from: buffer)
    }
}

final class StageImpulseRenderTests: XCTestCase {

    func testNoImpulseRendersExactlyWhatItAlwaysDid() {
        let plain = render(impulse: nil, settings: Self.stage())
        var withFile = Self.stage()
        withFile.impulseFile = nil
        let loaded = render(impulse: ConvolverStateTests.response([0, 0, 1]),
                            settings: withFile)
        XCTAssertEqual(loaded.map(\.bitPattern), plain.map(\.bitPattern))
    }

    func testAMixOfZeroIsTheSameSamplesAsNoResponseAtAll() {
        let plain = render(impulse: nil, settings: Self.stage())
        var mixed = Self.stage()
        mixed.impulseFile = "test-00000000.wav"
        mixed.impulseMix = 0
        let convolved = render(impulse: ConvolverStateTests.response([0, 0, 1]),
                               settings: mixed)
        XCTAssertEqual(convolved.map(\.bitPattern), plain.map(\.bitPattern))
    }

    func testAUnitResponseAtFullMixLeavesTheStageWhereItWas() {
        let plain = render(impulse: nil, settings: Self.stage())
        var wet = Self.stage()
        wet.impulseFile = "test-00000000.wav"
        let convolved = render(impulse: ConvolverStateTests.response([1]),
                               settings: wet)
        for i in 0..<plain.count {
            XCTAssertEqual(convolved[i], plain[i], accuracy: 2e-5, "sample \(i)")
        }
    }

    func testAResponseActuallyChangesTheOutput() {
        let plain = render(impulse: nil, settings: Self.stage())
        var wet = Self.stage()
        wet.impulseFile = "test-00000000.wav"
        let convolved = render(impulse: ConvolverStateTests.response([0, 0, 0, 1]),
                               settings: wet)
        let difference = zip(plain, convolved).map { abs($0 - $1) }.max() ?? 0
        XCTAssertGreaterThan(difference, 0.01)
        XCTAssertTrue(convolved.allSatisfy(\.isFinite))
    }

    func testABlockTheSetWasNotBuiltForPassesStraightThrough() {
        let plain = render(impulse: nil, settings: Self.stage(), frames: 500)
        var wet = Self.stage()
        wet.impulseFile = "test-00000000.wav"
        let convolved = render(impulse: ConvolverStateTests.response([0, 0, 0, 1]),
                               settings: wet, frames: 500)
        XCTAssertEqual(convolved.map(\.bitPattern), plain.map(\.bitPattern))
    }

    func testTheSetIsRebuiltForTheRateThatPrepareAnnounces() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.setImpulse(ConvolverStateTests.response([1], rate: 48000))
        guard case .ready(_, _, _, let hop, let rate) = p.impulseStatus else {
            return XCTFail("no set was built: \(p.impulseStatus)")
        }
        XCTAssertEqual(rate, 48000)
        XCTAssertEqual(hop, StageProcessor.defaultBlockFrames)

        p.prepare(sampleRate: 44100)
        guard case .ready(_, _, _, _, let after) = p.impulseStatus else {
            return XCTFail("the rate change lost the set: \(p.impulseStatus)")
        }
        XCTAssertEqual(after, 44100)
    }

    func testTheLayoutFollowsTheBlockSizeTheDeviceActuallyHandsOver() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.setImpulse(ConvolverStateTests.response([1]))
        XCTAssertEqual(p.observedBlockFrames, 0)

        feed(p, frames: 128)
        XCTAssertEqual(p.observedBlockFrames, 128)
        p.refreshImpulseLayout()
        guard case .ready(_, _, _, let hop, _) = p.impulseStatus else {
            return XCTFail("no set after the rebuild: \(p.impulseStatus)")
        }
        XCTAssertEqual(hop, 128)
    }

    func testARefusedLayoutSaysWhyRatherThanFallingSilent() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        feed(p, frames: 100)
        p.setImpulse(ConvolverStateTests.response([1]))
        guard case .refused(let message) = p.impulseStatus else {
            return XCTFail("a block of 100 has no partition: \(p.impulseStatus)")
        }
        XCTAssertTrue(message.contains("100"), message)
    }

    func testDroppingTheResponseClearsTheSet() {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        p.setImpulse(ConvolverStateTests.response([1]))
        XCTAssertNotNil(p.impulseName)
        p.setImpulse(nil)
        XCTAssertNil(p.impulseName)
        XCTAssertEqual(p.impulseStatus, .off)
    }


    private static func stage() -> StageSettings {
        var s = StageSettings()
        s.enabled = true
        s.width = 140
        s.crossfeed = 0.3
        s.dialogue = 2
        s.room = 0.3
        s.distance = 0.3
        s.span = 0.5
        s.center = 0
        s.size = 0.5
        return s
    }

    private func render(impulse: ImpulseResponse?, settings: StageSettings,
                        frames: Int = 512) -> [Float] {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        if let impulse { p.setImpulse(impulse) }
        p.applyStage(settings)

        var out: [Float] = []
        for block in 0..<4 {
            let input = Buffers([(2, frames)])
            input.fill(0, Self.stereo(frames: frames, block: block))
            let output = Buffers([(2, frames)])
            p.render(input: input.constPointer,
                     output: output.list.unsafeMutablePointer)
            out.append(contentsOf: output.samples(0, count: frames * 2))
        }
        return out
    }

    private func feed(_ p: StageProcessor, frames: Int) {
        let input = Buffers([(2, frames)])
        input.fill(0, Self.stereo(frames: frames, block: 0))
        let output = Buffers([(2, frames)])
        p.render(input: input.constPointer, output: output.list.unsafeMutablePointer)
    }

    private static func stereo(frames: Int, block: Int) -> [Float] {
        var seed = UInt64(0x2545_F491_4F6C_DD1D) &+ UInt64(block)
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: seed)) / Float(Int64.max) * 0.12
            let tone = Float(sin(Double(i + block * frames) * 0.029)) * 0.35
            out[i * 2] = tone + noise
            out[i * 2 + 1] = tone * 0.8 - noise
        }
        return out
    }

    private final class Buffers {
        let list: UnsafeMutableAudioBufferListPointer
        private var blocks: [UnsafeMutablePointer<Float>] = []

        init(_ shapes: [(channels: Int, frames: Int)]) {
            list = AudioBufferList.allocate(maximumBuffers: shapes.count)
            for (i, shape) in shapes.enumerated() {
                let count = shape.channels * shape.frames
                let block = UnsafeMutablePointer<Float>.allocate(capacity: count)
                block.initialize(repeating: 0, count: count)
                blocks.append(block)
                list[i] = AudioBuffer(
                    mNumberChannels: UInt32(shape.channels),
                    mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(block))
            }
        }

        deinit {
            for block in blocks { block.deallocate() }
            free(list.unsafeMutablePointer)
        }

        var constPointer: UnsafePointer<AudioBufferList> {
            UnsafePointer(list.unsafeMutablePointer)
        }

        func fill(_ buffer: Int, _ samples: [Float]) {
            for (i, v) in samples.enumerated() { blocks[buffer][i] = v }
        }

        func samples(_ buffer: Int, count: Int) -> [Float] {
            Array(UnsafeBufferPointer(start: blocks[buffer], count: count))
        }
    }
}

final class StageImpulseSettingsTests: XCTestCase {

    func testAStageWithNoResponseEncodesExactlyWhatItUsedTo() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(StageSettings.movie.clamped())
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertFalse(text.contains("impulse"), text)
    }

    func testTheStoredNameAndMixSurviveARoundTrip() throws {
        var s = StageSettings.music
        s.impulseFile = "room-1a2b3c4d.wav"
        s.impulseMix = 0.4
        let data = try JSONEncoder().encode(s.clamped())
        let back = try JSONDecoder().decode(StageSettings.self, from: data)
        XCTAssertEqual(back.impulseFileValue, "room-1a2b3c4d.wav")
        XCTAssertEqual(back.impulseMixValue, 0.4)
    }

    func testAHandEditedNameIsDroppedOnTheWayToTheDsp() {
        var s = StageSettings()
        s.impulseFile = "../../../etc/passwd"
        s.impulseMix = 0.5
        let clamped = s.clamped()
        XCTAssertNil(clamped.impulseFile)
        XCTAssertNil(clamped.impulseMix)
        XCTAssertFalse(clamped.hasImpulse)
    }

    func testAMixOutsideTheRangeIsPulledBackIn() {
        var s = StageSettings()
        s.impulseFile = "room-1a2b3c4d.wav"
        s.impulseMix = 9
        XCTAssertEqual(s.clamped().impulseMixValue, 1)
        s.impulseMix = -2
        XCTAssertEqual(s.clamped().impulseMixValue, 0)
        s.impulseMix = .nan
        XCTAssertEqual(s.clamped().impulseMixValue, 1)
    }

    func testTwoStagesDifferingOnlyByTheirResponseAreNotTheSameStage() {
        var a = StageSettings.music
        var b = StageSettings.music
        XCTAssertTrue(a.audiblyEquals(b))
        a.impulseFile = "room-1a2b3c4d.wav"
        XCTAssertFalse(a.audiblyEquals(b))
        b.impulseFile = "room-1a2b3c4d.wav"
        XCTAssertTrue(a.audiblyEquals(b))
        b.impulseMix = 0.2
        XCTAssertFalse(a.audiblyEquals(b))
    }

    func testAStageCarryingAResponseIsNeverAudiblyNeutral() {
        var s = StageSettings()
        s.enabled = true
        s.width = 100
        s.crossfeed = 0
        s.dialogue = 0
        s.room = 0
        s.distance = 0
        s.center = 0
        s.night = 0
        XCTAssertTrue(s.isAudiblyNeutral)
        s.impulseFile = "room-1a2b3c4d.wav"
        XCTAssertFalse(s.isAudiblyNeutral)
        XCTAssertTrue(s.doesAnything)
    }

    func testTheSignalPathNamesTheResponseOnlyWhenASetIsBuilt() {
        var stage = StageSettings.music
        stage.enabled = true
        stage.impulseFile = "room-1a2b3c4d.wav"

        let named = SignalPath.rows(.init(engineMode: .insert, stage: stage,
                                          impulseActive: true))
            .first { $0.id == "app" }
        XCTAssertTrue(named?.state.contains("impulse response") ?? false,
                      named?.state ?? "")

        let quiet = SignalPath.rows(.init(engineMode: .insert, stage: stage,
                                          impulseActive: false))
            .first { $0.id == "app" }
        XCTAssertFalse(quiet?.state.contains("impulse response") ?? true,
                       quiet?.state ?? "")
    }
}
