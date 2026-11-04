import Foundation

/// Wire format shared with the Android companion. All integers big-endian.
enum PhoneMessageType: UInt8 {
    case hello = 1, auth, authOK, authFail, pairCommit, pairNonce, pairReveal, pairOK, pairDenied,
         clockPing, clockPong, start, videoConfig, videoFrame, audioConfig, audioFrame, keyframeReq, stop, error
}

struct PhoneMessage: Equatable {
    var type: PhoneMessageType
    var payload: Data
}

enum PhoneFramingError: Error, Equatable {
    case unknownType(UInt8)
    case oversize(UInt32)
}

enum PhoneFraming {
    static let maxPayload = 8 * 1024 * 1024
    private static let headerSize = 5

    /// `type: u8`, `length: u32 BE`, payload.
    static func encode(_ m: PhoneMessage) -> Data {
        var d = Data(capacity: headerSize + m.payload.count)
        d.append(m.type.rawValue)
        d.append(contentsOf: be(UInt32(m.payload.count)))
        d.append(m.payload)
        return d
    }

    /// Drains complete messages from `buffer`, leaving a partial tail. Throws on unknown type / oversize.
    static func decode(_ buffer: inout Data) throws -> [PhoneMessage] {
        let bytes = [UInt8](buffer)
        var messages: [PhoneMessage] = []
        var pos = 0
        while bytes.count - pos >= headerSize {
            guard let type = PhoneMessageType(rawValue: bytes[pos]) else {
                throw PhoneFramingError.unknownType(bytes[pos])
            }
            let length = readUInt(bytes, pos + 1, 4, as: UInt32.self)
            guard Int(length) <= maxPayload else { throw PhoneFramingError.oversize(length) }
            let end = pos + headerSize + Int(length)
            guard end <= bytes.count else { break }
            messages.append(PhoneMessage(type: type, payload: Data(bytes[(pos + headerSize)..<end])))
            pos = end
        }
        buffer = Data(bytes[pos...])
        return messages
    }
}

/// `u8 count`, then count x (`u16 len`, NAL bytes with header byte, no start code).
struct VideoConfigPayload: Equatable {
    var parameterSets: [Data]

    init(parameterSets: [Data]) { self.parameterSets = parameterSets }

    init?(_ data: Data) {
        let b = [UInt8](data)
        guard let count = b.first else { return nil }
        var pos = 1
        var sets: [Data] = []
        for _ in 0..<Int(count) {
            guard b.count - pos >= 2 else { return nil }
            let len = Int(readUInt(b, pos, 2, as: UInt16.self))
            pos += 2
            guard b.count - pos >= len else { return nil }
            sets.append(Data(b[pos..<(pos + len)]))
            pos += len
        }
        parameterSets = sets
    }

    var encoded: Data {
        var d = Data([UInt8(parameterSets.count)])
        for s in parameterSets {
            d.append(contentsOf: be(UInt16(s.count)))
            d.append(s)
        }
        return d
    }
}

/// `u64 ptsNs`, `u8 flags` (bit0 keyframe, bit1 mirrored), `u16 rotationDeg`, then AVCC NAL units verbatim.
struct VideoFramePayload: Equatable {
    var ptsNs: UInt64
    var keyframe: Bool
    var mirrored: Bool
    var rotationDeg: UInt16
    var nalus: Data

    init(ptsNs: UInt64, keyframe: Bool, mirrored: Bool, rotationDeg: UInt16, nalus: Data) {
        self.ptsNs = ptsNs
        self.keyframe = keyframe
        self.mirrored = mirrored
        self.rotationDeg = rotationDeg
        self.nalus = nalus
    }

    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 11 else { return nil }
        ptsNs = readUInt(b, 0, 8, as: UInt64.self)
        keyframe = b[8] & 0x01 != 0
        mirrored = b[8] & 0x02 != 0
        rotationDeg = readUInt(b, 9, 2, as: UInt16.self)
        nalus = Data(b[11...])
    }

    var encoded: Data {
        var d = Data(be(ptsNs))
        d.append((keyframe ? 0x01 : 0) | (mirrored ? 0x02 : 0))
        d.append(contentsOf: be(rotationDeg))
        d.append(nalus)
        return d
    }
}

/// `u64 ptsNs`, then the AAC access unit.
struct AudioFramePayload: Equatable {
    var ptsNs: UInt64
    var accessUnit: Data

    init(ptsNs: UInt64, accessUnit: Data) {
        self.ptsNs = ptsNs
        self.accessUnit = accessUnit
    }

    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 8 else { return nil }
        ptsNs = readUInt(b, 0, 8, as: UInt64.self)
        accessUnit = Data(b[8...])
    }

    var encoded: Data { Data(be(ptsNs)) + accessUnit }
}

/// `u64 macSendHostNs, u64 phoneRecvNs, u64 phoneSendNs` (24 bytes).
struct ClockPongPayload: Equatable {
    var macSendHostNs: UInt64
    var phoneRecvNs: UInt64
    var phoneSendNs: UInt64

    init(macSendHostNs: UInt64, phoneRecvNs: UInt64, phoneSendNs: UInt64) {
        self.macSendHostNs = macSendHostNs
        self.phoneRecvNs = phoneRecvNs
        self.phoneSendNs = phoneSendNs
    }

    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count == 24 else { return nil }
        macSendHostNs = readUInt(b, 0, 8, as: UInt64.self)
        phoneRecvNs = readUInt(b, 8, 8, as: UInt64.self)
        phoneSendNs = readUInt(b, 16, 8, as: UInt64.self)
    }

    var encoded: Data { Data(be(macSendHostNs) + be(phoneRecvNs) + be(phoneSendNs)) }
}

struct StartConfig: Codable, Equatable {
    var video: Bool
    var audio: Bool
    var facing: String
    var width: Int
    var height: Int
    var fps: Int
    var bitrate: Int
}

struct HelloPayload: Codable, Equatable {
    var pv: Int
    var deviceName: String
    var model: String
    var caps: [String]
}

struct ErrorPayload: Codable, Equatable {
    var code: String
    var message: String
}

// MARK: - Big-endian helpers

private func be<T: FixedWidthInteger>(_ v: T) -> [UInt8] {
    (0..<MemoryLayout<T>.size).reversed().map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) }
}

private func readUInt<T: FixedWidthInteger & UnsignedInteger>(_ b: [UInt8], _ at: Int, _ n: Int, as: T.Type) -> T {
    b[at..<(at + n)].reduce(T(0)) { ($0 << 8) | T($1) }
}
