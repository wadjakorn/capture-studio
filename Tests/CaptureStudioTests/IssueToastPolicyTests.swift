import Testing
import Foundation
@testable import CaptureStudio

@Test func appendedWarningsAreNew() {
    #expect(IssueToastPolicy.newWarnings(previous: ["a"], current: ["a", "b"]) == ["b"])
}
@Test func resetWarningsAreAllNew() {
    #expect(IssueToastPolicy.newWarnings(previous: ["a", "b"], current: ["c"]) == ["c"])
}
@Test func clearedOrUnchangedWarningsAreNotNew() {
    #expect(IssueToastPolicy.newWarnings(previous: ["a"], current: []).isEmpty)
    #expect(IssueToastPolicy.newWarnings(previous: ["a"], current: ["a"]).isEmpty)
}
@Test func failureTitles() {
    #expect(IssueToastPolicy.failureTitle(previous: .recording(startedAt: .distantPast)) == "Recording stopped early")
    #expect(IssueToastPolicy.failureTitle(previous: .finishing) == "Recording stopped early")
    #expect(IssueToastPolicy.failureTitle(previous: .idle) == "Can't start recording")
    #expect(IssueToastPolicy.failureTitle(previous: .arming) == "Can't start recording")
    #expect(IssueToastPolicy.failureTitle(previous: .preparing) == "Can't start recording")
    #expect(IssueToastPolicy.failureTitle(previous: .failed("x")) == "Can't start recording")
}
@Test func overflowCollapses() {
    #expect(IssueToastPolicy.visibleLines(["1", "2", "3"]) == ["1", "2", "3"])
    #expect(IssueToastPolicy.visibleLines(["1", "2", "3", "4", "5"]) == ["1", "2", "and 3 more"])
}
