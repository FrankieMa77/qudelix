import XCTest
@testable import QudelixBar

final class PreGainChannelTests: XCTestCase {
    private func buffer(ch0Db: Double, ch1Db: Double, group: QxEqGroup) -> [UInt8] {
        var bits: [Int] = []
        func put(_ value: Int, _ width: Int) {
            for i in 0..<width { bits.append((value >> i) & 1) }
        }
        put(1, 1)
        put(0, 14); put(0, 11)
        put(0, 6)
        put(Int((ch0Db * QxScale.gain).rounded()) & 0xFFFF, 16)
        put(Int((ch1Db * QxScale.gain).rounded()) & 0xFFFF, 16)
        for _ in 0..<group.freqChannels {
            for f in group.defaultFreqs.prefix(group.bandCount) { put(f, 16) }
        }
        for _ in 0..<group.bandCount {
            put(Int(QxFilter.peak.rawValue), 4); put(0, 10)
            put(Int(1.0 * QxScale.q), 14); put(0, 4)
        }
        var bytes = [UInt8](repeating: 0, count: max(128, (bits.count + 7) / 8))
        for (i, b) in bits.enumerated() where b == 1 { bytes[i >> 3] |= UInt8(1 << (i & 7)) }
        return bytes
    }

    func testDecoderReadsBothChannelsRatherThanSkippingTheSecond() {
        let p = QxUserEqPreset.decode(buffer(ch0Db: -8.0, ch1Db: -3.7, group: .b20),
                                      group: .b20)
        XCTAssertEqual(p.preGain, -8.0, accuracy: 0.05)
        XCTAssertEqual(p.preGainCh1, -3.7, accuracy: 0.05,
                       "channel 1 used to be skipped, making this exact imbalance invisible")
    }

    func testMatchedChannelsDecodeEqual() {
        for db in [0.0, -3.5, -12.0, 6.0] {
            let p = QxUserEqPreset.decode(buffer(ch0Db: db, ch1Db: db, group: .user),
                                          group: .user)
            XCTAssertEqual(p.preGain, p.preGainCh1, accuracy: 0.05, "at \(db) dB")
        }
    }

    func testBothGroupsDecodeTheSecondChannel() {
        for group in [QxEqGroup.user, .b20] {
            let p = QxUserEqPreset.decode(buffer(ch0Db: -2.0, ch1Db: -9.5, group: group),
                                          group: group)
            XCTAssertEqual(p.preGainCh1, -9.5, accuracy: 0.05, "group \(group)")
            XCTAssertEqual(p.bands.count, group.bandCount)
        }
    }

    func testBandTableStillDecodesAfterTheSecondChannel() {
        let group = QxEqGroup.b20
        let p = QxUserEqPreset.decode(buffer(ch0Db: -4.0, ch1Db: -4.0, group: group),
                                      group: group)
        XCTAssertEqual(p.bands.map(\.freq), Array(group.defaultFreqs.prefix(group.bandCount)))
        XCTAssertTrue(p.bands.allSatisfy { $0.filter == .peak })
        XCTAssertTrue(p.looksPlausible)
    }

    func testNoGroupWeWriteToUsesTheBothChannelsMask() {
        XCTAssertEqual(QxEqGroup.user.writeChannelMask, 1)
        XCTAssertEqual(QxEqGroup.b20.writeChannelMask, 1)
    }
}
