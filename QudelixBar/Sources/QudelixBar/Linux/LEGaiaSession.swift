#if os(Linux)
import Foundation

enum LEGaiaOutput: Equatable {
    case send([UInt8])
    case ready(writeBudget: Int)
    case packet([UInt8])
    case writeRejected(code: UInt8)
    case failed(String)
}

enum LEAtt {
    static let errorResponse: UInt8 = 0x01
    static let mtuRequest: UInt8 = 0x02
    static let mtuResponse: UInt8 = 0x03
    static let findInformationRequest: UInt8 = 0x04
    static let findInformationResponse: UInt8 = 0x05
    static let findByTypeValueRequest: UInt8 = 0x06
    static let readByTypeRequest: UInt8 = 0x08
    static let readByTypeResponse: UInt8 = 0x09
    static let readRequest: UInt8 = 0x0A
    static let readBlobRequest: UInt8 = 0x0C
    static let readMultipleRequest: UInt8 = 0x0E
    static let readByGroupTypeRequest: UInt8 = 0x10
    static let readByGroupTypeResponse: UInt8 = 0x11
    static let writeRequest: UInt8 = 0x12
    static let writeResponse: UInt8 = 0x13
    static let prepareWriteRequest: UInt8 = 0x16
    static let executeWriteRequest: UInt8 = 0x18
    static let notification: UInt8 = 0x1B
    static let indication: UInt8 = 0x1D
    static let confirmation: UInt8 = 0x1E
    static let readMultipleVariableRequest: UInt8 = 0x20
    static let writeCommand: UInt8 = 0x52
    static let signedWriteCommand: UInt8 = 0xD2

    static let errorRequestNotSupported: UInt8 = 0x06
    static let errorAttributeNotFound: UInt8 = 0x0A

    static let primaryService: UInt16 = 0x2800
    static let characteristicDeclaration: UInt16 = 0x2803
    static let clientConfiguration: UInt16 = 0x2902

    static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    static func uuidBytes(_ text: String) -> [UInt8] {
        let digits = text.replacingOccurrences(of: "-", with: "")
        var bytes: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2, limitedBy: digits.endIndex) ?? digits.endIndex
            bytes.append(UInt8(digits[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes.reversed()
    }
}

struct LEGaiaSession {
    static let ourMTU = 247
    static let defaultMTU = 23
    static let discoverySeconds: TimeInterval = 4
    static let requestSeconds: TimeInterval = 5
    static let mtuGraceSeconds: TimeInterval = 1
    static let serviceBytes = LEAtt.uuidBytes(GaiaFraming.serviceUUID)
    static let commandBytes = LEAtt.uuidBytes(GaiaFraming.commandUUID)
    static let responseBytes = LEAtt.uuidBytes(GaiaFraming.responseUUID)

    enum Phase: Equatable {
        case idle
        case exchangingMTU
        case findingService
        case findingCharacteristics
        case findingDescriptor
        case enablingNotifications
        case ready
        case failed
    }

    private enum Pending: Equatable {
        case none
        case mtu
        case service
        case characteristics
        case descriptor
        case enable
        case write
    }

    private(set) var phase = Phase.idle
    private(set) var ignoredPDUs = 0
    private(set) var commandHandle: UInt16?
    private(set) var responseHandle: UInt16?
    private(set) var notificationConfigHandle: UInt16?

    private var pending = Pending.none
    private var sentAt: TimeInterval = 0
    private var linkUpAt: TimeInterval = 0
    private var peerMTU: Int?
    private var serviceEnd: UInt16 = 0xFFFF
    private var serviceStart: UInt16 = 0x0001
    private var declarations: [UInt16] = []
    private var descriptorEnd: UInt16 = 0xFFFF
    private var writeQueue: [[UInt8]] = []

    var mtu: Int {
        min(Self.ourMTU, max(peerMTU ?? Self.defaultMTU, Self.defaultMTU))
    }

    var writeBudget: Int { mtu - 3 }
    var isReady: Bool { phase == .ready }

    mutating func linkUp(now: TimeInterval) -> [LEGaiaOutput] {
        guard phase == .idle else { return [] }
        var out: [LEGaiaOutput] = []
        linkUpAt = now
        phase = .exchangingMTU
        issue(LEAtt.mtuRequest, LEAtt.le16(UInt16(Self.ourMTU)), .mtu, now, &out)
        return out
    }

    mutating func send(_ frame: [UInt8], now: TimeInterval) -> [LEGaiaOutput] {
        guard phase == .ready, !frame.isEmpty, frame.count <= writeBudget else { return [] }
        writeQueue.append(frame)
        var out: [LEGaiaOutput] = []
        sendNext(now, &out)
        return out
    }

    mutating func tick(now: TimeInterval) -> [LEGaiaOutput] {
        guard phase != .idle, phase != .failed else { return [] }
        var out: [LEGaiaOutput] = []
        if phase != .ready, now - linkUpAt > Self.discoverySeconds {
            fail("the 5K did not answer GATT discovery", &out)
            return out
        }
        if pending == .mtu, now - sentAt > Self.mtuGraceSeconds {
            pending = .none
            beginService(now, &out)
            return out
        }
        if pending != .none, now - sentAt > Self.requestSeconds {
            fail(pending == .write ? "the 5K did not answer a command in time"
                                   : "the 5K did not answer an ATT request in time", &out)
        }
        return out
    }

    mutating func receive(_ pdu: [UInt8], now: TimeInterval) -> [LEGaiaOutput] {
        guard phase != .failed, let opcode = pdu.first else { return [] }
        if phase == .idle {
            guard opcode == LEAtt.mtuRequest, pdu.count >= 3 else { return [] }
            peerMTU = Int(LEAtt.u16(pdu, 1))
            return [.send([LEAtt.mtuResponse] + LEAtt.le16(UInt16(Self.ourMTU)))]
        }
        var out: [LEGaiaOutput] = []
        switch opcode {
        case LEAtt.mtuRequest:
            guard pdu.count >= 3 else { return reject(pdu, &out) }
            peerMTU = Int(LEAtt.u16(pdu, 1))
            out.append(.send([LEAtt.mtuResponse] + LEAtt.le16(UInt16(Self.ourMTU))))
        case LEAtt.mtuResponse:
            guard pdu.count >= 3 else { return reject(pdu, &out) }
            peerMTU = Int(LEAtt.u16(pdu, 1))
            if pending == .mtu {
                pending = .none
                beginService(now, &out)
            }
        case LEAtt.errorResponse:
            guard pdu.count >= 5 else { return reject(pdu, &out) }
            handleError(request: pdu[1], code: pdu[4], now, &out)
        case LEAtt.readByGroupTypeResponse:
            guard pending == .service else { return reject(pdu, &out) }
            handleServices(pdu, now, &out)
        case LEAtt.readByTypeResponse:
            guard pending == .characteristics else { return reject(pdu, &out) }
            handleCharacteristics(pdu, now, &out)
        case LEAtt.findInformationResponse:
            guard pending == .descriptor else { return reject(pdu, &out) }
            handleDescriptors(pdu, now, &out)
        case LEAtt.writeResponse:
            handleWriteResponse(now, &out)
        case LEAtt.notification:
            handleValue(pdu, confirm: false, &out)
        case LEAtt.indication:
            handleValue(pdu, confirm: true, &out)
        case LEAtt.confirmation, LEAtt.writeCommand, LEAtt.signedWriteCommand:
            break
        case LEAtt.findInformationRequest, LEAtt.findByTypeValueRequest, LEAtt.readByTypeRequest,
             LEAtt.readByGroupTypeRequest:
            out.append(.send(Self.error(opcode, handle: pdu.count >= 3 ? LEAtt.u16(pdu, 1) : 0,
                                        code: LEAtt.errorAttributeNotFound)))
        case LEAtt.readRequest, LEAtt.readBlobRequest, LEAtt.writeRequest, LEAtt.prepareWriteRequest:
            out.append(.send(Self.error(opcode, handle: pdu.count >= 3 ? LEAtt.u16(pdu, 1) : 0,
                                        code: LEAtt.errorRequestNotSupported)))
        case LEAtt.readMultipleRequest, LEAtt.executeWriteRequest, LEAtt.readMultipleVariableRequest:
            out.append(.send(Self.error(opcode, handle: 0, code: LEAtt.errorRequestNotSupported)))
        default:
            ignoredPDUs += 1
        }
        return out
    }

    private static func error(_ opcode: UInt8, handle: UInt16, code: UInt8) -> [UInt8] {
        [LEAtt.errorResponse, opcode] + LEAtt.le16(handle) + [code]
    }

    private mutating func reject(_ pdu: [UInt8], _ out: inout [LEGaiaOutput]) -> [LEGaiaOutput] {
        ignoredPDUs += 1
        return out
    }

    private mutating func issue(_ opcode: UInt8, _ body: [UInt8], _ kind: Pending,
                                _ now: TimeInterval, _ out: inout [LEGaiaOutput]) {
        pending = kind
        sentAt = now
        out.append(.send([opcode] + body))
    }

    private mutating func fail(_ reason: String, _ out: inout [LEGaiaOutput]) {
        phase = .failed
        pending = .none
        writeQueue.removeAll()
        out.append(.failed(reason))
    }

    private mutating func beginService(_ now: TimeInterval, _ out: inout [LEGaiaOutput]) {
        phase = .findingService
        requestService(from: 0x0001, now, &out)
    }

    private mutating func requestService(from start: UInt16, _ now: TimeInterval,
                                         _ out: inout [LEGaiaOutput]) {
        issue(LEAtt.readByGroupTypeRequest,
              LEAtt.le16(start) + LEAtt.le16(0xFFFF) + LEAtt.le16(LEAtt.primaryService),
              .service, now, &out)
    }

    private mutating func requestCharacteristics(from start: UInt16, _ now: TimeInterval,
                                                 _ out: inout [LEGaiaOutput]) {
        issue(LEAtt.readByTypeRequest,
              LEAtt.le16(start) + LEAtt.le16(serviceEnd) + LEAtt.le16(LEAtt.characteristicDeclaration),
              .characteristics, now, &out)
    }

    private mutating func handleError(request: UInt8, code: UInt8, _ now: TimeInterval,
                                      _ out: inout [LEGaiaOutput]) {
        let notFound = code == LEAtt.errorAttributeNotFound
        switch (pending, request) {
        case (.mtu, LEAtt.mtuRequest):
            pending = .none
            beginService(now, &out)
        case (.service, LEAtt.readByGroupTypeRequest):
            fail(notFound ? "the 5K does not offer its control service"
                          : "the 5K refused GATT discovery (ATT error \(Self.hex(code)))", &out)
        case (.characteristics, LEAtt.readByTypeRequest):
            if notFound {
                finishCharacteristics(now, &out)
            } else {
                fail("the 5K refused GATT discovery (ATT error \(Self.hex(code)))", &out)
            }
        case (.descriptor, LEAtt.findInformationRequest):
            enable(configHandle: (responseHandle ?? 0) &+ 1, now, &out)
        case (.enable, LEAtt.writeRequest):
            fail("the 5K refused to switch on its notifications (ATT error \(Self.hex(code)))", &out)
        case (.write, LEAtt.writeRequest):
            pending = .none
            out.append(.writeRejected(code: code))
            sendNext(now, &out)
        default:
            ignoredPDUs += 1
        }
    }

    private static func hex(_ value: UInt8) -> String { String(format: "0x%02X", value) }

    private mutating func handleServices(_ pdu: [UInt8], _ now: TimeInterval,
                                         _ out: inout [LEGaiaOutput]) {
        guard pdu.count >= 2 else { return fail("the 5K sent a malformed service list", &out) }
        let length = Int(pdu[1])
        guard length >= 6, (pdu.count - 2) % length == 0, pdu.count > 2 else {
            return fail("the 5K sent a malformed service list", &out)
        }
        var lastEnd: UInt16 = 0
        var offset = 2
        while offset + length <= pdu.count {
            let start = LEAtt.u16(pdu, offset)
            let end = LEAtt.u16(pdu, offset + 2)
            let uuid = Array(pdu[(offset + 4)..<(offset + length)])
            if uuid == Self.serviceBytes {
                serviceStart = start
                serviceEnd = end
                declarations = []
                phase = .findingCharacteristics
                requestCharacteristics(from: start, now, &out)
                return
            }
            lastEnd = end
            offset += length
        }
        guard lastEnd < 0xFFFF, lastEnd >= 1 else {
            return fail("the 5K does not offer its control service", &out)
        }
        requestService(from: lastEnd + 1, now, &out)
    }

    private mutating func handleCharacteristics(_ pdu: [UInt8], _ now: TimeInterval,
                                                _ out: inout [LEGaiaOutput]) {
        guard pdu.count > 2 else { return fail("the 5K sent a malformed characteristic list", &out) }
        let length = Int(pdu[1])
        guard length >= 7, (pdu.count - 2) % length == 0 else {
            return fail("the 5K sent a malformed characteristic list", &out)
        }
        var lastHandle: UInt16 = 0
        var offset = 2
        while offset + length <= pdu.count {
            let declaration = LEAtt.u16(pdu, offset)
            let value = LEAtt.u16(pdu, offset + 3)
            let uuid = Array(pdu[(offset + 5)..<(offset + length)])
            declarations.append(declaration)
            if uuid == Self.commandBytes { commandHandle = value }
            if uuid == Self.responseBytes { responseHandle = value }
            lastHandle = declaration
            offset += length
        }
        let nextStart = lastHandle &+ 1
        let responseKnownWithNext = responseHandle.map { response in
            declarations.contains { $0 > response }
        } ?? false
        if (commandHandle != nil && responseKnownWithNext) || lastHandle >= serviceEnd
            || lastHandle < serviceStart || nextStart == 0 {
            finishCharacteristics(now, &out)
        } else {
            requestCharacteristics(from: nextStart, now, &out)
        }
    }

    private mutating func finishCharacteristics(_ now: TimeInterval, _ out: inout [LEGaiaOutput]) {
        guard commandHandle != nil, let response = responseHandle else {
            return fail("the 5K's control service has no command and response characteristics", &out)
        }
        let next = declarations.filter { $0 > response }.min()
        descriptorEnd = next.map { $0 - 1 } ?? serviceEnd
        let start = response &+ 1
        if response == 0xFFFF || start > descriptorEnd {
            enable(configHandle: start, now, &out)
            return
        }
        phase = .findingDescriptor
        issue(LEAtt.findInformationRequest, LEAtt.le16(start) + LEAtt.le16(descriptorEnd),
              .descriptor, now, &out)
    }

    private mutating func handleDescriptors(_ pdu: [UInt8], _ now: TimeInterval,
                                            _ out: inout [LEGaiaOutput]) {
        let fallback = (responseHandle ?? 0) &+ 1
        guard pdu.count > 2, pdu[1] == 1 || pdu[1] == 2 else {
            return enable(configHandle: fallback, now, &out)
        }
        let uuidLength = pdu[1] == 1 ? 2 : 16
        let size = 2 + uuidLength
        var lastHandle: UInt16 = 0
        var offset = 2
        while offset + size <= pdu.count {
            let handle = LEAtt.u16(pdu, offset)
            if uuidLength == 2, LEAtt.u16(pdu, offset + 2) == LEAtt.clientConfiguration {
                return enable(configHandle: handle, now, &out)
            }
            lastHandle = handle
            offset += size
        }
        if lastHandle != 0, lastHandle < descriptorEnd {
            issue(LEAtt.findInformationRequest, LEAtt.le16(lastHandle + 1) + LEAtt.le16(descriptorEnd),
                  .descriptor, now, &out)
        } else {
            enable(configHandle: fallback, now, &out)
        }
    }

    private mutating func enable(configHandle: UInt16, _ now: TimeInterval,
                                 _ out: inout [LEGaiaOutput]) {
        notificationConfigHandle = configHandle
        phase = .enablingNotifications
        issue(LEAtt.writeRequest, LEAtt.le16(configHandle) + [0x01, 0x00], .enable, now, &out)
    }

    private mutating func handleWriteResponse(_ now: TimeInterval, _ out: inout [LEGaiaOutput]) {
        switch pending {
        case .enable:
            pending = .none
            phase = .ready
            out.append(.ready(writeBudget: writeBudget))
            sendNext(now, &out)
        case .write:
            pending = .none
            sendNext(now, &out)
        default:
            ignoredPDUs += 1
        }
    }

    private mutating func sendNext(_ now: TimeInterval, _ out: inout [LEGaiaOutput]) {
        guard phase == .ready, pending == .none, let handle = commandHandle,
              !writeQueue.isEmpty else { return }
        let frame = writeQueue.removeFirst()
        issue(LEAtt.writeRequest, LEAtt.le16(handle) + frame, .write, now, &out)
    }

    private mutating func handleValue(_ pdu: [UInt8], confirm: Bool, _ out: inout [LEGaiaOutput]) {
        if confirm { out.append(.send([LEAtt.confirmation])) }
        guard pdu.count >= 3 else {
            ignoredPDUs += 1
            return
        }
        guard let responseHandle, LEAtt.u16(pdu, 1) == responseHandle,
              phase == .enablingNotifications || phase == .ready else {
            ignoredPDUs += 1
            return
        }
        out.append(.packet(Array(pdu[3...])))
    }
}
#endif
