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

// MARK: - merge (one toast slot, nothing silently lost)

private func toast(_ title: String, _ lines: [String], error: Bool,
                   fix: PermissionKind? = nil) -> IssueToastContent {
    IssueToastContent(title: title, lines: lines, isError: error, fix: fix)
}

@Test func mergeWithNothingVisibleShowsIncoming() {
    let warning = toast("Recording issue", ["w"], error: false, fix: .microphone)
    let error = toast("Can't start recording", ["e"], error: true, fix: .screenRecording)
    #expect(IssueToastPolicy.merge(visible: nil, incoming: warning) == warning)
    #expect(IssueToastPolicy.merge(visible: nil, incoming: error) == error)
}
@Test func mergeErrorAlwaysReplaces() {
    let error = toast("Recording stopped early", ["e2"], error: true)
    let overWarning = IssueToastPolicy.merge(
        visible: toast("Recording issue", ["w"], error: false, fix: .microphone),
        incoming: error)
    #expect(overWarning == error)
    let overError = IssueToastPolicy.merge(
        visible: toast("Can't start recording", ["e1"], error: true, fix: .screenRecording),
        incoming: error)
    #expect(overError == error)
}
@Test func mergeWarningAppendsToVisibleErrorKeepingItsTitleAndFix() {
    let merged = IssueToastPolicy.merge(
        visible: toast("Can't start recording", ["e"], error: true, fix: .screenRecording),
        incoming: toast("Recording issue", ["w"], error: false, fix: .microphone))
    #expect(merged == toast("Can't start recording", ["e", "w"], error: true, fix: .screenRecording))
}
@Test func mergeWarningBorrowsFixOnlyWhenVisibleHasNone() {
    let merged = IssueToastPolicy.merge(
        visible: toast("Recording stopped early", ["e"], error: true),
        incoming: toast("Recording issue", ["w"], error: false, fix: .microphone))
    #expect(merged == toast("Recording stopped early", ["e", "w"], error: true, fix: .microphone))
}
@Test func mergeWarningAppendsToVisibleWarningWithoutRepeats() {
    let merged = IssueToastPolicy.merge(
        visible: toast("Recording issue", ["a", "b"], error: false),
        incoming: toast("Recording issue", ["b", "c", "c"], error: false, fix: .camera))
    #expect(merged == toast("Recording issue", ["a", "b", "c"], error: false, fix: .camera))
}
