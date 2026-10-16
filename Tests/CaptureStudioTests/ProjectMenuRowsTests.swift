import Testing
import Foundation
@testable import CaptureStudio

@Suite struct ProjectMenuRowsTests {
    private func url(_ n: String) -> URL { URL(fileURLWithPath: "/tmp/\(n).capturestudio", isDirectory: true) }

    @Test func lastIsExcludedFromRecentAndLimitIsFive() {
        let all = (1...8).map { url("p\($0)") }
        let rows = ProjectMenuRows.load(recent: all, last: all[0], isOpenable: { _ in true })
        #expect(rows.last?.title == "p1")
        #expect(rows.recent.map(\.title) == ["p2", "p3", "p4", "p5", "p6"])
    }

    @Test func unopenableEntriesAreHidden() {
        let a = url("a"), b = url("b")
        let rows = ProjectMenuRows.load(recent: [a, b], last: a, isOpenable: { $0 == b })
        #expect(rows.last == nil)
        #expect(rows.recent.map(\.title) == ["b"])
    }

    @Test func emptyWhenNothingOpenable() {
        let rows = ProjectMenuRows.load(recent: [url("a")], last: url("a"), isOpenable: { _ in false })
        #expect(rows.isEmpty)
    }

    @Test func activeRecordingIsHidden() {
        let a = url("a"), b = url("b")
        // Spelled differently (trailing slash) — compared by standardized path.
        let active = URL(fileURLWithPath: "/tmp/a.capturestudio/")
        let rows = ProjectMenuRows.load(recent: [a, b], last: a, activeRecording: active,
                                        isOpenable: { _ in true })
        #expect(rows.last == nil)
        #expect(rows.recent.map(\.title) == ["b"])
    }
}
