import Foundation

/// One line of windows.jsonl: from `t` on, this is the window under the
/// pointer. `t` is seconds relative to the screen track's sessionStartHostTime;
/// the frame is in global screen points, top-left origin — the same space as
/// events.jsonl, so `DisplayInfo` maps it into video pixels. `id == 0` with a
/// zero size means "no window".
///
/// Deliberately nothing else: no title, no owning app.
struct WindowLine: Codable, Equatable {
    var t: Double
    var id: Int
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    static func none(t: Double) -> WindowLine {
        WindowLine(t: t, id: 0, x: 0, y: 0, w: 0, h: 0)
    }

    var isNone: Bool { id == 0 || w <= 0 || h <= 0 }
}

enum WindowsCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encodeLines(_ lines: [WindowLine]) throws -> Data {
        var data = Data()
        for line in lines {
            data.append(try encoder.encode(line))
            data.append(0x0A) // \n
        }
        return data
    }

    /// Malformed lines are skipped: the file is optional, best-effort data.
    static func decodeLines(_ data: Data) -> [WindowLine] {
        data.split(separator: 0x0A)
            .compactMap { try? decoder.decode(WindowLine.self, from: $0) }
    }
}
