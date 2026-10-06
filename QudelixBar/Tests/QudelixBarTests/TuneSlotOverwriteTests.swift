import XCTest
@testable import QudelixBar

@MainActor
final class TuneSlotOverwriteTests: XCTestCase {
    private typealias Gate = TuneView.SlotSaveGate

    private func connected() -> QudelixController {
        let c = QudelixController()
        c.connection = .connected(name: "Qudelix 5K")
        c.compatibility = .ok
        c.presetNames = [2: "Alder AR-5", 5: "Bass boost"]
        return c
    }

    func testAnEmptySlotIsWrittenWithoutAsking() {
        var gate = Gate()
        let request = gate.request(slot: 1, source: .compare, names: [2: "Alder AR-5"])
        XCTAssertEqual(request, TuneView.SlotSaveRequest(slot: 1, source: .compare))
        XCTAssertNil(gate.pending)
    }

    func testANamedSlotIsHeldBackUntilTheDialogAnswers() {
        var gate = Gate()
        let request = gate.request(slot: 2, source: .shape, names: [2: "Alder AR-5"])
        XCTAssertNil(request, "a named slot must not be written straight away")
        XCTAssertEqual(gate.pending, TuneView.SlotSaveRequest(slot: 2, source: .shape))
    }

    func testCancellingLeavesNothingToWrite() {
        var gate = Gate()
        _ = gate.request(slot: 5, source: .compare, names: [5: "Bass boost"])
        gate.clear()
        XCTAssertNil(gate.pending)
    }

    func testAFreshPickReplacesAnUnansweredOne() {
        var gate = Gate()
        _ = gate.request(slot: 2, source: .compare, names: [2: "a", 5: "b"])
        _ = gate.request(slot: 5, source: .shape, names: [2: "a", 5: "b"])
        XCTAssertEqual(gate.pending?.slot, 5)
        XCTAssertEqual(gate.pending?.source, .shape)
    }

    func testCommittingAComparisonKeepsTheResultThenWritesTheSlot() {
        let c = connected()
        let tuner = ABTuner()
        tuner.start(c)
        var steps = 0
        while tuner.phase == .running && steps < 300 {
            steps += 1
            if tuner.isConsistencyCheck { tuner.noDifference(c) } else { tuner.choose(preferA: true, c) }
        }
        XCTAssertEqual(tuner.phase, .finished)
        c.clearSendTrace()
        TuneView.commit(.init(slot: 2, source: .compare), tuner: tuner, blind: BlindTuner(), controller: c)
        XCTAssertEqual(tuner.phase, .idle, "the result is kept before it is written")
        XCTAssertTrue(c.sendTrace.contains("saveEqPreset"), "trace: \(c.sendTrace)")
    }

    func testCommittingAShapeResultKeepsItThenWritesTheSlot() {
        let c = connected()
        let blind = BlindTuner.previewShape { trial in
            trial.axis == nil ? .same : (trial.highIsA ? .preferA : .preferB)
        }
        XCTAssertEqual(blind.phase, .finished)
        c.clearSendTrace()
        TuneView.commit(.init(slot: 5, source: .shape), tuner: ABTuner(), blind: blind, controller: c)
        XCTAssertTrue(c.sendTrace.contains("saveEqPreset"), "trace: \(c.sendTrace)")
    }
}
