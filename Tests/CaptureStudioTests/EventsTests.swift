import Testing
import Foundation
@testable import CaptureStudio

@Suite struct EventsTests {
    @Test func roundTrip() throws {
        let events: [EventLine] = [
            EventLine(t: 0.016, e: .pos, x: 812.5, y: 340.2, cursor: "arrow"),
            EventLine(t: 1.25, e: .down, x: 100, y: 200, btn: "left"),
            EventLine(t: 1.31, e: .up, x: 100, y: 200, btn: "left"),
            EventLine(t: 2.0, e: .scroll, x: 50, y: 60, dx: 0, dy: -12),
            EventLine(t: 3.1, e: .key, keyCode: 36, mods: ["cmd"]),
        ]
        let data = try EventsCodec.encodeLines(events)
        let decoded = try EventsCodec.decodeLines(data)
        #expect(decoded == events)
    }

    @Test func nilFieldsOmittedFromJSON() throws {
        let data = try EventsCodec.encodeLines([EventLine(t: 1.0, e: .pos, x: 1, y: 2)])
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("btn"))
        #expect(!json.contains("keyCode"))
        #expect(json.hasSuffix("\n"))
    }

    @Test func oneEventPerLine() throws {
        let events = (0..<10).map { EventLine(t: Double($0), e: .pos, x: 0, y: 0) }
        let data = try EventsCodec.encodeLines(events)
        let lines = String(data: data, encoding: .utf8)!
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 10)
    }
}
