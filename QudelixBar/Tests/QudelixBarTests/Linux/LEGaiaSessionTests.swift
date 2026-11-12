#if os(Linux)
import XCTest
@testable import QudelixBar

final class LEGaiaSessionTests: XCTestCase {
    private let service = LEAtt.uuidBytes(GaiaFraming.serviceUUID)
    private let command = LEAtt.uuidBytes(GaiaFraming.commandUUID)
    private let response = LEAtt.uuidBytes(GaiaFraming.responseUUID)
    private let data = LEAtt.uuidBytes("00001103-d102-11e1-9b23-00025b00a5a5")

    private struct Rig {
        var session = LEGaiaSession()
        var now: TimeInterval = 100
        var sent: [[UInt8]] = []
        var events: [LEGaiaOutput] = []

        mutating func absorb(_ outputs: [LEGaiaOutput]) {
            for output in outputs {
                if case .send(let pdu) = output { sent.append(pdu) } else { events.append(output) }
            }
        }

        mutating func up() { absorb(session.linkUp(now: now)) }
        mutating func feed(_ pdu: [UInt8]) { absorb(session.receive(pdu, now: now)) }
        mutating func tick(after seconds: TimeInterval) {
            now += seconds
            absorb(session.tick(now: now))
        }
        mutating func send(_ frame: [UInt8]) { absorb(session.send(frame, now: now)) }

        var last: [UInt8]? { sent.last }
    }

    private func le16(_ value: UInt16) -> [UInt8] { LEAtt.le16(value) }

    private func groupResponse(_ entries: [(UInt16, UInt16, [UInt8])]) -> [UInt8] {
        let length = 4 + entries[0].2.count
        return [0x11, UInt8(length)] + entries.flatMap { le16($0.0) + le16($0.1) + $0.2 }
    }

    private func typeResponse(_ entries: [(decl: UInt16, props: UInt8, value: UInt16, uuid: [UInt8])]) -> [UInt8] {
        let length = 5 + entries[0].uuid.count
        return [0x09, UInt8(length)]
            + entries.flatMap { le16($0.decl) + [$0.props] + le16($0.value) + $0.uuid }
    }

    private func errorPDU(_ opcode: UInt8, handle: UInt16 = 0, code: UInt8 = 0x0A) -> [UInt8] {
        [0x01, opcode] + le16(handle) + [code]
    }

    private func discover(_ rig: inout Rig, peerMTU: UInt16 = 64) {
        rig.up()
        rig.feed([0x03] + le16(peerMTU))
        rig.feed(groupResponse([(0x0001, 0x0006, [0x01, 0x18])]))
        rig.feed(groupResponse([(0x0007, 0x000b, [0x00, 0x18])]))
        rig.feed(groupResponse([(0x000c, 0xFFFF, service)]))
        rig.feed(typeResponse([(0x000d, 0x08, 0x000e, command)]))
        rig.feed(typeResponse([(0x000f, 0x12, 0x0010, response)]))
        rig.feed(typeResponse([(0x0012, 0x16, 0x0013, data)]))
        rig.feed([0x05, 0x01] + le16(0x0011) + [0x02, 0x29])
        rig.feed([0x13])
    }

    func testFullBringUpFollowsTheMeasuredGattLayout() {
        var rig = Rig()
        rig.up()
        XCTAssertEqual(rig.sent, [[0x02, 0xF7, 0x00]])
        rig.feed([0x03, 0x40, 0x00])
        XCTAssertEqual(rig.last, [0x10, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28])
        rig.feed(groupResponse([(0x0001, 0x0006, [0x01, 0x18])]))
        XCTAssertEqual(rig.last, [0x10, 0x07, 0x00, 0xFF, 0xFF, 0x00, 0x28])
        rig.feed(groupResponse([(0x0007, 0x000b, [0x00, 0x18])]))
        XCTAssertEqual(rig.last, [0x10, 0x0C, 0x00, 0xFF, 0xFF, 0x00, 0x28])
        rig.feed(groupResponse([(0x000c, 0xFFFF, service)]))
        XCTAssertEqual(rig.last, [0x08, 0x0C, 0x00, 0xFF, 0xFF, 0x03, 0x28])
        rig.feed(typeResponse([(0x000d, 0x08, 0x000e, command)]))
        XCTAssertEqual(rig.last, [0x08, 0x0E, 0x00, 0xFF, 0xFF, 0x03, 0x28])
        rig.feed(typeResponse([(0x000f, 0x12, 0x0010, response)]))
        XCTAssertEqual(rig.last, [0x08, 0x10, 0x00, 0xFF, 0xFF, 0x03, 0x28])
        rig.feed(typeResponse([(0x0012, 0x16, 0x0013, data)]))
        XCTAssertEqual(rig.last, [0x04, 0x11, 0x00, 0x11, 0x00])
        XCTAssertEqual(rig.session.commandHandle, 0x000e)
        XCTAssertEqual(rig.session.responseHandle, 0x0010)
        rig.feed([0x05, 0x01, 0x11, 0x00, 0x02, 0x29])
        XCTAssertEqual(rig.last, [0x12, 0x11, 0x00, 0x01, 0x00])
        XCTAssertTrue(rig.events.isEmpty)
        rig.feed([0x13])
        XCTAssertEqual(rig.events, [.ready(writeBudget: 61)])
        XCTAssertTrue(rig.session.isReady)
    }

    func testTwoCharacteristicsInOneResponseFinishDiscoveryEarly() {
        var rig = Rig()
        rig.up()
        rig.feed([0x03, 0x40, 0x00])
        rig.feed(groupResponse([(0x000c, 0xFFFF, service)]))
        rig.feed(typeResponse([(0x000d, 0x08, 0x000e, command), (0x000f, 0x12, 0x0010, response),
                               (0x0012, 0x16, 0x0013, data)]))
        XCTAssertEqual(rig.last, [0x04, 0x11, 0x00, 0x11, 0x00])
    }

    func testTheEndOfTheCharacteristicListUsesTheServiceEndForTheDescriptorRange() {
        var rig = Rig()
        rig.up()
        rig.feed([0x03, 0x40, 0x00])
        rig.feed(groupResponse([(0x000c, 0x0013, service)]))
        rig.feed(typeResponse([(0x000d, 0x08, 0x000e, command)]))
        rig.feed(typeResponse([(0x000f, 0x12, 0x0010, response)]))
        XCTAssertEqual(rig.last, [0x08, 0x10, 0x00, 0x13, 0x00, 0x03, 0x28])
        rig.feed(errorPDU(0x08, handle: 0x0010))
        XCTAssertEqual(rig.last, [0x04, 0x11, 0x00, 0x13, 0x00])
    }

    func testAnErrorEndsTheCharacteristicSearchAndKeepsWhatWasFound() {
        var rig = Rig()
        rig.up()
        rig.feed([0x03, 0x40, 0x00])
        rig.feed(groupResponse([(0x000c, 0xFFFF, service)]))
        rig.feed(typeResponse([(0x000d, 0x08, 0x000e, command)]))
        rig.feed(typeResponse([(0x000f, 0x12, 0x0010, response)]))
        rig.feed(errorPDU(0x08, handle: 0x0010))
        XCTAssertEqual(rig.last, [0x04, 0x11, 0x00, 0xFF, 0xFF])
        rig.feed([0x05, 0x01, 0x11, 0x00, 0x02, 0x29])
        XCTAssertEqual(rig.last, [0x12, 0x11, 0x00, 0x01, 0x00])
    }

    func testAMissingConfigurationDescriptorFallsBackToTheHandleAfterTheValue() {
        var rig = Rig()
        rig.up()
        rig.feed([0x03, 0x40, 0x00])
        rig.feed(groupResponse([(0x000c, 0xFFFF, service)]))
        rig.feed(typeResponse([(0x000d, 0x08, 0x000e, command), (0x000f, 0x12, 0x0010, response),
                               (0x0012, 0x16, 0x0013, data)]))
        rig.feed(errorPDU(0x04, handle: 0x0011))
        XCTAssertEqual(rig.last, [0x12, 0x11, 0x00, 0x01, 0x00])
    }

    func testAnAdjacentDeclarationMeansNoDescriptorSearchAtAll() {
        var rig = Rig()
        rig.up()
        rig.feed([0x03, 0x40, 0x00])
        rig.feed(groupResponse([(0x000c, 0xFFFF, service)]))
        rig.feed(typeResponse([(0x000d, 0x08, 0x000e, command), (0x000f, 0x12, 0x0010, response),
                               (0x0011, 0x16, 0x0012, data)]))
        XCTAssertEqual(rig.last, [0x12, 0x11, 0x00, 0x01, 0x00])
    }

    func testTheDescriptorSearchContinuesPastOtherDescriptors() {
        var rig = Rig()
        rig.up()
        rig.feed([0x03, 0x40, 0x00])
        rig.feed(groupResponse([(0x000c, 0xFFFF, service)]))
        rig.feed(typeResponse([(0x000d, 0x08, 0x000e, command), (0x000f, 0x12, 0x0010, response),
                               (0x0014, 0x16, 0x0015, data)]))
        XCTAssertEqual(rig.last, [0x04, 0x11, 0x00, 0x13, 0x00])
        rig.feed([0x05, 0x01, 0x11, 0x00, 0x01, 0x29, 0x12, 0x00, 0x03, 0x29])
        XCTAssertEqual(rig.last, [0x04, 0x13, 0x00, 0x13, 0x00])
        rig.feed([0x05, 0x01, 0x13, 0x00, 0x02, 0x29])
        XCTAssertEqual(rig.last, [0x12, 0x13, 0x00, 0x01, 0x00])
    }

    func testTheFiveKsMTURequestBeforeOursIsAnsweredAnswersAreIndependent() {
        var rig = Rig()
        rig.up()
        rig.feed([0x02, 0x40, 0x00])
        XCTAssertEqual(rig.last, [0x03, 0xF7, 0x00])
        XCTAssertEqual(rig.session.mtu, 64)
        XCTAssertEqual(rig.sent.count, 2)
        rig.feed([0x03, 0x40, 0x00])
        XCTAssertEqual(rig.last, [0x10, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28])
    }

    func testTheFiveKsMTURequestAfterOursIsAnsweredAndDiscoveryContinues() {
        var rig = Rig()
        rig.up()
        rig.feed([0x03, 0x40, 0x00])
        rig.feed(groupResponse([(0x0001, 0x0006, [0x01, 0x18])]))
        rig.feed([0x02, 0x40, 0x00])
        XCTAssertEqual(rig.last, [0x03, 0xF7, 0x00])
        rig.feed(groupResponse([(0x0007, 0x000b, [0x00, 0x18])]))
        XCTAssertEqual(rig.last, [0x10, 0x0C, 0x00, 0xFF, 0xFF, 0x00, 0x28])
    }

    func testTheNegotiatedMTUIsTheSmallerAndSetsTheWriteBudget() {
        var small = Rig()
        discover(&small, peerMTU: 23)
        XCTAssertEqual(small.events, [.ready(writeBudget: 20)])
        var mid = Rig()
        discover(&mid, peerMTU: 64)
        XCTAssertEqual(mid.events, [.ready(writeBudget: 61)])
        var large = Rig()
        discover(&large, peerMTU: 517)
        XCTAssertEqual(large.events, [.ready(writeBudget: 244)])
        XCTAssertEqual(LEGaiaSession().mtu, 23)
        XCTAssertEqual(LEGaiaSession().writeBudget, 20)
    }

    func testAnUnansweredMTURequestDoesNotStallDiscovery() {
        var rig = Rig()
        rig.up()
        rig.tick(after: 0.5)
        XCTAssertEqual(rig.sent.count, 1)
        rig.tick(after: 0.6)
        XCTAssertEqual(rig.last, [0x10, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28])
        rig.feed([0x03, 0x40, 0x00])
        XCTAssertEqual(rig.sent.count, 2)
        XCTAssertEqual(rig.session.mtu, 64)
    }

    func testAnMTUErrorAlsoMovesOn() {
        var rig = Rig()
        rig.up()
        rig.feed(errorPDU(0x02, code: 0x06))
        XCTAssertEqual(rig.last, [0x10, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28])
    }

    func testAMissingControlServiceFails() {
        var rig = Rig()
        rig.up()
        rig.feed([0x03, 0x40, 0x00])
        rig.feed(groupResponse([(0x0001, 0x0006, [0x01, 0x18])]))
        rig.feed(errorPDU(0x10, handle: 0x0007))
        XCTAssertEqual(rig.events, [.failed("the 5K does not offer its control service")])
        let tail = rig.session.receive([0x13], now: rig.now)
        XCTAssertTrue(tail.isEmpty)
    }

    func testAServiceListThatEndsAtTheTopOfTheHandleSpaceWithoutTheServiceFails() {
        var rig = Rig()
        rig.up()
        rig.feed([0x03, 0x40, 0x00])
        rig.feed(groupResponse([(0x0001, 0xFFFF, [0x01, 0x18])]))
        XCTAssertEqual(rig.events, [.failed("the 5K does not offer its control service")])
    }

    func testAServiceWithoutBothCharacteristicsFails() {
        var rig = Rig()
        rig.up()
        rig.feed([0x03, 0x40, 0x00])
        rig.feed(groupResponse([(0x000c, 0xFFFF, service)]))
        rig.feed(typeResponse([(0x000d, 0x08, 0x000e, command)]))
        rig.feed(errorPDU(0x08, handle: 0x000e))
        XCTAssertEqual(rig.events,
                       [.failed("the 5K's control service has no command and response characteristics")])
    }

    func testRefusingTheNotificationSwitchFails() {
        var rig = Rig()
        rig.up()
        rig.feed([0x03, 0x40, 0x00])
        rig.feed(groupResponse([(0x000c, 0xFFFF, service)]))
        rig.feed(typeResponse([(0x000d, 0x08, 0x000e, command), (0x000f, 0x12, 0x0010, response),
                               (0x0012, 0x16, 0x0013, data)]))
        rig.feed([0x05, 0x01, 0x11, 0x00, 0x02, 0x29])
        rig.feed(errorPDU(0x12, handle: 0x0011, code: 0x03))
        XCTAssertEqual(rig.events,
                       [.failed("the 5K refused to switch on its notifications (ATT error 0x03)")])
    }

    func testDiscoveryThatTakesLongerThanFourSecondsFails() {
        var rig = Rig()
        rig.up()
        rig.feed([0x03, 0x40, 0x00])
        rig.tick(after: 3.9)
        XCTAssertTrue(rig.events.isEmpty)
        rig.tick(after: 0.2)
        XCTAssertEqual(rig.events, [.failed("the 5K did not answer GATT discovery")])
    }

    func testTheDiscoveryClockStopsOnceTheLinkIsReady() {
        var rig = Rig()
        discover(&rig)
        rig.tick(after: 30)
        XCTAssertEqual(rig.events, [.ready(writeBudget: 61)])
    }

    func testCommandsAreWriteRequestsOneAtATime() {
        var rig = Rig()
        discover(&rig)
        let before = rig.sent.count
        rig.send([0xF0, 0x01, 0x01, 0x00, 0x00, 0x00, 0x04])
        rig.send([0xF0, 0x01, 0x01, 0x10, 0x47])
        rig.send([0xF0, 0x01, 0x01, 0x10, 0x48])
        XCTAssertEqual(rig.sent.count, before + 1)
        XCTAssertEqual(rig.last, [0x12, 0x0E, 0x00, 0xF0, 0x01, 0x01, 0x00, 0x00, 0x00, 0x04])
        rig.feed([0x13])
        XCTAssertEqual(rig.sent.count, before + 2)
        XCTAssertEqual(rig.last, [0x12, 0x0E, 0x00, 0xF0, 0x01, 0x01, 0x10, 0x47])
        rig.feed([0x13])
        XCTAssertEqual(rig.last, [0x12, 0x0E, 0x00, 0xF0, 0x01, 0x01, 0x10, 0x48])
        rig.feed([0x13])
        XCTAssertEqual(rig.sent.count, before + 3)
    }

    func testARequestThatIsNeverAnsweredFailsAfterFiveSeconds() {
        var rig = Rig()
        discover(&rig)
        rig.send([0xF0, 0x01, 0x01, 0x10, 0x47])
        rig.tick(after: 4.9)
        XCTAssertEqual(rig.events, [.ready(writeBudget: 61)])
        rig.tick(after: 0.2)
        XCTAssertEqual(rig.events.last, .failed("the 5K did not answer a command in time"))
    }

    func testARejectedWriteIsReportedAndTheQueueMovesOn() {
        var rig = Rig()
        discover(&rig)
        rig.send([0xF0, 0x01, 0x01, 0x10, 0x47])
        rig.send([0xF0, 0x01, 0x01, 0x10, 0x48])
        rig.feed(errorPDU(0x12, handle: 0x000e, code: 0x03))
        XCTAssertEqual(rig.events.last, .writeRejected(code: 0x03))
        XCTAssertEqual(rig.last, [0x12, 0x0E, 0x00, 0xF0, 0x01, 0x01, 0x10, 0x48])
    }

    func testFramesAreDroppedBeforeReadyAndWhenTooLarge() {
        var rig = Rig()
        rig.up()
        rig.send([0xF0, 0x01])
        XCTAssertEqual(rig.sent.count, 1)
        var ready = Rig()
        discover(&ready, peerMTU: 23)
        let before = ready.sent.count
        ready.send([UInt8](repeating: 1, count: 21))
        XCTAssertEqual(ready.sent.count, before)
        ready.send([UInt8](repeating: 1, count: 20))
        XCTAssertEqual(ready.sent.count, before + 1)
    }

    func testNotificationsOnTheResponseHandleBecomePackets() {
        var rig = Rig()
        discover(&rig)
        let payload: [UInt8] = [0xF0, 0x01, 0x81, 0x02, 0x00, 0x11, 0x22]
        rig.feed([0x1B, 0x10, 0x00] + payload)
        XCTAssertEqual(rig.events.last, .packet(payload))
        let count = rig.events.count
        rig.feed([0x1B, 0x13, 0x00, 0x01])
        rig.feed([0x1B, 0x10])
        XCTAssertEqual(rig.events.count, count)
        XCTAssertEqual(rig.session.ignoredPDUs, 2)
    }

    func testIndicationsAreConfirmedBeforeTheyBecomePackets() {
        var rig = Rig()
        discover(&rig)
        let payload: [UInt8] = [0xF0, 0x01, 0x81, 0x03, 0x00, 0x33]
        let before = rig.sent.count
        rig.feed([0x1D, 0x10, 0x00] + payload)
        XCTAssertEqual(rig.sent.count, before + 1)
        XCTAssertEqual(rig.last, [0x1E])
        XCTAssertEqual(rig.events.last, .packet(payload))
        rig.feed([0x1D, 0x13, 0x00, 0x01])
        XCTAssertEqual(rig.last, [0x1E])
        XCTAssertEqual(rig.events.last, .packet(payload))
    }

    func testAnEarlyNotificationDuringTheSwitchOnIsKept() {
        var rig = Rig()
        rig.up()
        rig.feed([0x03, 0x40, 0x00])
        rig.feed(groupResponse([(0x000c, 0xFFFF, service)]))
        rig.feed(typeResponse([(0x000d, 0x08, 0x000e, command), (0x000f, 0x12, 0x0010, response),
                               (0x0012, 0x16, 0x0013, data)]))
        rig.feed([0x05, 0x01, 0x11, 0x00, 0x02, 0x29])
        rig.feed([0x1B, 0x10, 0x00, 0xAA])
        XCTAssertEqual(rig.events, [.packet([0xAA])])
    }

    func testRequestsFromTheFiveKAreAnsweredWithTheRightError() {
        var rig = Rig()
        discover(&rig)
        let notFound: [UInt8] = [0x04, 0x06, 0x08, 0x10]
        for opcode in notFound {
            rig.feed([opcode, 0x05, 0x00, 0x09, 0x00, 0x00, 0x28])
            XCTAssertEqual(rig.last, [0x01, opcode, 0x05, 0x00, 0x0A], "opcode \(opcode)")
        }
        let notSupported: [UInt8] = [0x0A, 0x0C, 0x12, 0x16]
        for opcode in notSupported {
            rig.feed([opcode, 0x07, 0x00, 0x00])
            XCTAssertEqual(rig.last, [0x01, opcode, 0x07, 0x00, 0x06], "opcode \(opcode)")
        }
        for opcode: UInt8 in [0x0E, 0x18, 0x20] {
            rig.feed([opcode, 0x01])
            XCTAssertEqual(rig.last, [0x01, opcode, 0x00, 0x00, 0x06], "opcode \(opcode)")
        }
    }

    func testWriteCommandsSignedWritesAndUnknownPDUsAreIgnored() {
        var rig = Rig()
        discover(&rig)
        let before = rig.sent.count
        rig.feed([0x52, 0x0E, 0x00, 0x01])
        rig.feed([0xD2, 0x0E, 0x00, 0x01])
        rig.feed([0x1E])
        XCTAssertEqual(rig.session.ignoredPDUs, 0)
        rig.feed([0x77, 0x01])
        rig.feed([0xFE])
        XCTAssertEqual(rig.session.ignoredPDUs, 2)
        XCTAssertEqual(rig.sent.count, before)
    }

    func testRequestsDuringDiscoveryAreAnsweredToo() {
        var rig = Rig()
        rig.up()
        rig.feed([0x08, 0x01, 0x00, 0xFF, 0xFF, 0x03, 0x28])
        XCTAssertEqual(rig.last, [0x01, 0x08, 0x01, 0x00, 0x0A])
    }

    func testNothingHappensBeforeTheLinkIsUpOrAfterAFailure() {
        var rig = Rig()
        rig.feed([0x1B, 0x10, 0x00, 0x01])
        rig.feed([0x10, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28])
        rig.send([1])
        rig.tick(after: 100)
        XCTAssertTrue(rig.sent.isEmpty)
        XCTAssertTrue(rig.events.isEmpty)
        XCTAssertEqual(rig.session.phase, .idle)
        rig.up()
        XCTAssertTrue(rig.session.linkUp(now: 1).isEmpty)
    }

    func testTheFiveKsMTURequestBeforeLinkUpIsAnsweredAndRemembered() {
        var rig = Rig()
        rig.feed([0x02, 0x40, 0x00])
        XCTAssertEqual(rig.sent, [[0x03, 0xF7, 0x00]])
        XCTAssertEqual(rig.session.phase, .idle)
        XCTAssertEqual(rig.session.mtu, 64)
        rig.feed([0x02])
        XCTAssertEqual(rig.sent.count, 1)
        rig.up()
        XCTAssertEqual(rig.last, [0x02, 0xF7, 0x00])
        rig.feed([0x03, 0x40, 0x00])
        XCTAssertEqual(rig.session.mtu, 64)
        XCTAssertEqual(rig.last, [0x10, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28])
    }

    func testMalformedDiscoveryAnswersFailInsteadOfLooping() {
        var rig = Rig()
        rig.up()
        rig.feed([0x03, 0x40, 0x00])
        rig.feed([0x11, 0x14, 0x01, 0x00])
        XCTAssertEqual(rig.events, [.failed("the 5K sent a malformed service list")])
    }

    func testTheSessionIsIdleOnlyWhenNoWriteIsOutstandingOrQueued() {
        var rig = Rig()
        discover(&rig)
        XCTAssertTrue(rig.session.isIdle)
        rig.send([0xF0, 0x01, 0x01, 0x10, 0x47])
        rig.send([0xF0, 0x01, 0x01, 0x10, 0x48])
        XCTAssertFalse(rig.session.isIdle)
        rig.feed([0x13])
        XCTAssertFalse(rig.session.isIdle)
        rig.feed([0x13])
        XCTAssertTrue(rig.session.isIdle)
    }

    func testAnAcceptedWriteIsReportedAndARejectedOneIsNot() {
        var rig = Rig()
        discover(&rig)
        rig.events.removeAll()
        rig.send([0xF0, 0x01, 0x01, 0x10, 0x47])
        rig.feed([0x13])
        XCTAssertEqual(rig.events, [.writeAccepted])
        rig.send([0xF0, 0x01, 0x01, 0x10, 0x48])
        rig.feed(errorPDU(0x12, handle: 0x000e, code: 0x03))
        XCTAssertEqual(rig.events, [.writeAccepted, .writeRejected(code: 0x03)])
    }
}
#endif
