import XCTest
@testable import QudelixBar

final class StageProcessorRawRenderTests: XCTestCase {
    private func ready() -> StageProcessor {
        let p = StageProcessor()
        p.prepare(sampleRate: 48000)
        return p
    }

    private func feed(_ p: StageProcessor, frames: Int) {
        let input = RawStageBuffers([(2, frames)])
        input.fill(0, (0..<(frames * 2)).map { Float(sin(Double($0) * 0.02)) * 0.3 })
        let output = RawStageBuffers([(2, frames)])
        p.render(input: input.list, output: output.list)
    }

    func testTheTapsBufferIsTakenFromTheEndOfTheInputList() {
        let p = ready()
        let input = RawStageBuffers([(1, 8), (2, 8)])
        input.fill(0, [Float](repeating: 1, count: 8))
        input.fill(1, (0..<16).map { Float($0) / 100 })
        let output = RawStageBuffers([(2, 8)])
        p.render(input: input.list, output: output.list)
        XCTAssertEqual(output.samples(0, count: 16), (0..<16).map { Float($0) / 100 })
        XCTAssertEqual(p.renderDiagnostics().channels, 2)
    }

    func testAMonoInputFansOutToEveryOutputChannel() {
        let p = ready()
        let input = RawStageBuffers([(1, 4)])
        input.fill(0, [0.1, 0.2, 0.3, 0.4])
        let output = RawStageBuffers([(2, 4)])
        p.render(input: input.list, output: output.list)
        XCTAssertEqual(output.samples(0, count: 8), [0.1, 0.1, 0.2, 0.2, 0.3, 0.3, 0.4, 0.4])
    }

    func testAStereoInputMixesDownToAMonoOutput() {
        let p = ready()
        let input = RawStageBuffers([(2, 4)])
        input.fill(0, [0.2, 0.4, 0.2, 0.4, 0.2, 0.4, 0.2, 0.4])
        let output = RawStageBuffers([(1, 4)])
        p.render(input: input.list, output: output.list)
        XCTAssertEqual(output.samples(0, count: 4), [0.3, 0.3, 0.3, 0.3])
    }

    func testTheOutputIsSilencedBeforeAnythingIsWritten() {
        let p = ready()
        let input = RawStageBuffers([(2, 4)])
        let output = RawStageBuffers([(2, 4)])
        output.fill(0, [Float](repeating: 9, count: 8))
        p.setMuted(true)
        p.render(input: input.list, output: output.list)
        XCTAssertEqual(output.samples(0, count: 8), [Float](repeating: 0, count: 8))
    }

    func testMonitorOnlyLeavesTheOutputSilentButStillMeters() {
        let p = ready()
        p.setMonitorOnly(true)
        let input = RawStageBuffers([(2, 256)])
        input.fill(0, [Float](repeating: 0.5, count: 512))
        let output = RawStageBuffers([(2, 256)])
        output.fill(0, [Float](repeating: 9, count: 512))
        p.render(input: input.list, output: output.list)
        XCTAssertEqual(output.samples(0, count: 512), [Float](repeating: 0, count: 512))
        let meter = p.drainMeter()
        XCTAssertEqual(meter.frames, 256)
        XCTAssertEqual(meter.sumSquares, 256 * 0.25, accuracy: 1e-6)
    }

    func testTheSpectrumRingIsFedFromTheTap() {
        let p = ready()
        let n = QualityAnalyzer.fftSize
        let tap = (0..<n).map { Float(sin(Double($0) * 0.01)) * 0.5 }
        let input = RawStageBuffers([(1, n), (1, n)])
        input.fill(0, [Float](repeating: 1, count: n))
        input.fill(1, tap)
        let output = RawStageBuffers([(2, n)])
        p.render(input: input.list, output: output.list)
        XCTAssertEqual(p.drainSpectrumSamples(n), tap)
        XCTAssertTrue(p.drainSpectrumSamples(n).isEmpty)
    }

    func testAnEmptyBufferListRendersNothingAndDoesNotCrash() {
        let p = ready()
        let none = RawStageBuffers([])
        let output = RawStageBuffers([(2, 4)])
        p.render(input: none.list, output: output.list)
        XCTAssertEqual(output.samples(0, count: 8), [Float](repeating: 0, count: 8))
    }

    func testTheStageRunsOnTheRawEntryPoint() {
        let p = ready()
        var settings = StageSettings()
        settings.enabled = true
        settings.crossfeed = 0.8
        p.applyStage(settings)
        let frames = 1024
        let source = (0..<(frames * 2)).map {
            Float(sin(Double($0 / 2) * 0.05) * ($0 % 2 == 0 ? 0.4 : -0.2))
        }
        let input = RawStageBuffers([(2, frames)])
        input.fill(0, source)
        let output = RawStageBuffers([(2, frames)])
        p.render(input: input.list, output: output.list)
        XCTAssertTrue(p.renderDiagnostics().stageRan)
        XCTAssertTrue(output.samples(0, count: frames * 2).allSatisfy(\.isFinite))
        XCTAssertNotEqual(output.samples(0, count: frames * 2), source)
    }

    func testRepeatedRendersStayFinite() {
        let p = ready()
        for _ in 0..<50 { feed(p, frames: 480) }
        let meter = p.drainMeter()
        XCTAssertEqual(meter.frames, 50 * 480)
        XCTAssertTrue(meter.sumSquares.isFinite)
    }

    func testTheLockSurvivesConcurrentConfigChangesAndRenders() {
        let p = ready()
        let done = expectation(description: "renders finished")
        let queue = DispatchQueue(label: "render")
        queue.async {
            for _ in 0..<200 { self.feed(p, frames: 256) }
            done.fulfill()
        }
        for i in 0..<200 { p.applyLoudness(shelfDb: Double(i % 7)) }
        wait(for: [done], timeout: 10)
    }
}
