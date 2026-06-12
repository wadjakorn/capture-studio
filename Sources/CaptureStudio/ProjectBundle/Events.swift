import Foundation

/// One line of events.jsonl. `t` is seconds relative to the screen track's
/// sessionStartHostTime. Optional fields are omitted from JSON when nil.
struct EventLine: Codable, Equatable {
    enum Kind: String, Codable {
        case pos      // 60Hz cursor position sample
        case down, up // mouse button
        case scroll
        case key
    }

    var t: Double
    var e: Kind
    /// Global screen points, top-left origin (CG coordinates) — matches
    /// DisplayInfo.originX/Y so Studio can map into video pixels.
    var x: Double?
    var y: Double?
    var btn: String?
    var dx: Double?
    var dy: Double?
    var keyCode: Int?
    var mods: [String]?
    var cursor: String?
}

enum EventsCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encodeLines(_ events: [EventLine]) throws -> Data {
        var data = Data()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0A) // \n
        }
        return data
    }

    static func decodeLines(_ data: Data) throws -> [EventLine] {
        data.split(separator: 0x0A)
            .compactMap { try? decoder.decode(EventLine.self, from: $0) }
    }
}
