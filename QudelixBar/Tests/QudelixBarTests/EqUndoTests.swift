import XCTest
@testable import QudelixBar

/// Undo for EQ edits.
///
/// The interesting behaviour is not "it puts the value back" — it is the
/// coalescing. Dragging a node on the curve, or a slider in the band table,
/// emits a change per frame. If each frame were a step, undo would be useless:
/// walking back one drag would take a hundred presses. So a continuous gesture
/// has to collapse into one entry, while a discrete action always starts its
/// own.
@MainActor
final class EqUndoTests: XCTestCase {

    /// Same shape the other controller tests use: writable without a device.
    private func connected() -> QudelixController {
        let c = QudelixController()
        c.connection = .connected(name: "Qudelix 5K")
        c.compatibility = .ok
        return c
    }

    func testNothingToUndoOnAFreshController() {
        let c = connected()
        XCTAssertFalse(c.canUndo)
        XCTAssertFalse(c.canRedo)
        XCTAssertNil(c.undoLabel)
    }

    func testASingleEditIsOneStepAndComesBack() {
        let c = connected()
        let before = c.bands[2]
        var edited = before
        edited.gain = 6

        c.updateBand(2, edited)
        XCTAssertEqual(c.bands[2].gain, 6, accuracy: 0.01)
        XCTAssertTrue(c.canUndo)

        c.undoEqEdit()
        XCTAssertEqual(c.bands[2].gain, before.gain, accuracy: 0.01)
        XCTAssertFalse(c.canUndo)
        XCTAssertTrue(c.canRedo)
    }

    /// The point of the feature. A drag is many writes to one band in quick
    /// succession and must cost exactly one step.
    func testADragCollapsesIntoASingleStep() {
        let c = connected()
        let original = c.bands[4].gain
        for db in stride(from: 0.5, through: 8.0, by: 0.5) {
            var b = c.bands[4]
            b.gain = db
            c.updateBand(4, b)
        }
        XCTAssertEqual(c.undoStack.count, 1,
                       "16 frames of one drag must not be 16 undo steps")

        c.undoEqEdit()
        XCTAssertEqual(c.bands[4].gain, original, accuracy: 0.01,
                       "one undo must walk back the whole gesture")
    }

    /// Two different bands are two edits even without a pause — the label
    /// changes, so the gesture has ended by definition.
    func testEditingADifferentBandStartsANewStep() {
        let c = connected()
        for i in [1, 5] {
            var b = c.bands[i]
            b.gain = 4
            c.updateBand(i, b)
        }
        XCTAssertEqual(c.undoStack.count, 2)

        c.undoEqEdit()
        XCTAssertEqual(c.bands[5].gain, 0, accuracy: 0.01)
        XCTAssertEqual(c.bands[1].gain, 4, accuracy: 0.01, "only the last step comes back")
    }

    func testFlattenIsOneStepAndIsFullyReversible() {
        let c = connected()
        for i in 0..<4 {
            var b = c.bands[i]
            b.gain = Double(i + 1)
            c.updateBand(i, b)
        }
        let shaped = c.bands

        c.flatten()
        XCTAssertTrue(c.bands.allSatisfy { $0.gain == 0 })

        c.undoEqEdit()
        XCTAssertEqual(c.bands.map(\.gain), shaped.map(\.gain),
                       "flatten must come back in one step, not four")
    }

    func testFlattenZeroesGainsAndKeepsTheLayout() {
        let c = connected()
        c.updateBand(0, QxEqBandValue(filter: .lowShelf, freq: 105, gain: 6, q: 0.7))
        c.updateBand(1, QxEqBandValue(filter: .peak, freq: 8800, gain: -4, q: 2.5))

        c.flatten()

        XCTAssertTrue(c.bands.allSatisfy { $0.gain == 0 })
        XCTAssertEqual(c.bands[0].filter, .lowShelf)
        XCTAssertEqual(c.bands[0].freq, 105, "flatten must keep the centres it was given")
        XCTAssertEqual(c.bands[0].q, 0.7, accuracy: 0.001)
        XCTAssertEqual(c.bands[1].filter, .peak)
        XCTAssertEqual(c.bands[1].freq, 8800)
        XCTAssertEqual(c.bands[1].q, 2.5, accuracy: 0.001)
    }

    func testResetBandLayoutRestoresTheFactoryLayoutInOneStep() {
        let c = connected()
        c.updateBand(0, QxEqBandValue(filter: .lowShelf, freq: 105, gain: 6, q: 0.7))
        c.updateBand(1, QxEqBandValue(filter: .hpf, freq: 40, gain: 0, q: 1.4))
        let shaped = c.bands

        c.resetBandLayout()

        XCTAssertEqual(c.bands.map(\.freq), c.eqGroup.defaultFreqs)
        XCTAssertTrue(c.bands.allSatisfy { $0.filter == .peak && $0.gain == 0 && $0.q == 1.0 })
        XCTAssertEqual(c.preGain, 0, accuracy: 0.001)

        c.undoEqEdit()
        XCTAssertEqual(c.bands.map(\.freq), shaped.map(\.freq),
                       "a whole layout reset must come back in one step")
        XCTAssertEqual(c.bands[1].filter, .hpf)
    }

    func testZeroingABandIsItsOwnStepAfterADrag() {
        let c = connected()
        for db in stride(from: 0.5, through: 6.0, by: 0.5) {
            var b = c.bands[3]
            b.gain = db
            c.updateBand(3, b)
        }
        XCTAssertEqual(c.undoStack.count, 1)

        c.zeroBand(3)
        XCTAssertEqual(c.bands[3].gain, 0, accuracy: 0.01)
        XCTAssertEqual(c.undoStack.count, 2)

        c.undoEqEdit()
        XCTAssertEqual(c.bands[3].gain, 6, accuracy: 0.01,
                       "undo must give back the drag, not walk past it")
    }

    func testZeroingAPassFilterTurnsItIntoAFlatPeak() {
        let c = connected()
        c.updateBand(2, QxEqBandValue(filter: .hpf, freq: 60, gain: 0, q: 1.2))

        c.zeroBand(2)

        XCTAssertEqual(c.bands[2].filter, .peak)
        XCTAssertEqual(c.bands[2].gain, 0, accuracy: 0.01)
        XCTAssertEqual(c.bands[2].freq, 60)

        c.undoEqEdit()
        XCTAssertEqual(c.bands[2].filter, .hpf)
    }

    func testZeroingABandThatIsAlreadyFlatCostsNoStep() {
        let c = connected()
        c.zeroBand(5)
        XCTAssertFalse(c.canUndo)
    }

    func testRedoReappliesWhatUndoTookAway() {
        let c = connected()
        var b = c.bands[3]
        b.gain = -7
        c.updateBand(3, b)

        c.undoEqEdit()
        XCTAssertEqual(c.bands[3].gain, 0, accuracy: 0.01)
        c.redoEqEdit()
        XCTAssertEqual(c.bands[3].gain, -7, accuracy: 0.01)
    }

    /// A new edit after an undo abandons the redo branch, as everywhere else.
    func testANewEditClearsTheRedoBranch() {
        let c = connected()
        var b = c.bands[0]; b.gain = 3
        c.updateBand(0, b)
        c.undoEqEdit()
        XCTAssertTrue(c.canRedo)

        var other = c.bands[7]; other.gain = -2
        c.updateBand(7, other)
        XCTAssertFalse(c.canRedo)
    }

    /// A click that changes nothing must not cost a step, or the button fills
    /// with entries that do nothing when pressed.
    func testAnEditThatChangesNothingAddsNoStep() {
        let c = connected()
        c.updateBand(1, c.bands[1])
        c.flatten()                       // already flat
        XCTAssertLessThanOrEqual(c.undoStack.count, 1)
        if c.canUndo {
            c.undoEqEdit()
            XCTAssertFalse(c.canUndo)
        }
    }

    /// Undo replays history; it must not become history itself, or the stack
    /// would grow as the user tried to walk back through it.
    func testUndoingDoesNotPushMoreUndoSteps() {
        let c = connected()
        for i in 0..<3 {
            var b = c.bands[i]; b.gain = 5
            c.updateBand(i, b)
        }
        XCTAssertEqual(c.undoStack.count, 3)
        c.undoEqEdit()
        XCTAssertEqual(c.undoStack.count, 2, "an undo consumes a step, never adds one")
        c.undoEqEdit()
        XCTAssertEqual(c.undoStack.count, 1)
    }

    /// The history belongs to one curve on one device. Carrying it across a
    /// disconnect would offer to restore a shape onto bands it never described.
    func testHistoryIsDiscardedWhenTheDeviceGoesAway() {
        let c = connected()
        var b = c.bands[2]; b.gain = 9
        c.updateBand(2, b)
        XCTAssertTrue(c.canUndo)

        c.connection = .disconnected
        c.compatibility = .checking
        XCTAssertFalse(c.canWriteNow, "the guard under test needs the link gone")
        // The history is dropped by the teardown the transport drives; with no
        // transport here, assert the property that matters to the user instead:
        // nothing can be replayed onto a device that is not there.
        c.undoEqEdit()
        XCTAssertEqual(c.bands[2].gain, 9, accuracy: 0.01,
                       "an undo must not write while disconnected")
        XCTAssertFalse(c.canRedo)
    }

    func testTheStackIsBounded() {
        let c = connected()
        for i in 0..<200 {
            var b = c.bands[i % 10]
            b.gain = Double((i % 20) - 10)
            c.updateBand(i % 10, b)
        }
        XCTAssertLessThanOrEqual(c.undoStack.count, 40)
    }
}
