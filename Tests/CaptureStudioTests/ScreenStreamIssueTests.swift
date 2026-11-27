import Testing
import Foundation
import ScreenCaptureKit
@testable import CaptureStudio

private func sc(_ code: SCStreamError.Code) -> NSError {
    NSError(domain: SCStreamErrorDomain, code: code.rawValue)
}

@Test func userStopIsNormalStop() {
    #expect(ScreenStreamIssue.classify(sc(.userStopped), screenAccessGranted: true) == .userStopped)
    #expect(ScreenStreamIssue.classify(sc(.userStopped), screenAccessGranted: false) == .userStopped)
}
@Test func revokedGrantWinsOverCode() {
    #expect(ScreenStreamIssue.classify(sc(.noDisplayList), screenAccessGranted: false) == .permissionRevoked)
    #expect(ScreenStreamIssue.classify(NSError(domain: "x", code: 1), screenAccessGranted: false) == .permissionRevoked)
}
@Test func declinedIsPermission() {
    let issue = ScreenStreamIssue.classify(sc(.userDeclined), screenAccessGranted: true)
    #expect(issue == .permissionRevoked)
    #expect(issue.permission == .screenRecording)
}
@Test func displayGone() {
    #expect(ScreenStreamIssue.classify(sc(.noDisplayList), screenAccessGranted: true) == .displayLost)
    #expect(ScreenStreamIssue.classify(sc(.noCaptureSource), screenAccessGranted: true) == .displayLost)
}
@Test func systemStop() {
    #expect(ScreenStreamIssue.classify(sc(.systemStoppedStream), screenAccessGranted: true) == .systemStopped)
}
@Test func unknownErrorKeepsDescription() {
    let e = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
    let issue = ScreenStreamIssue.classify(e, screenAccessGranted: true)
    #expect(issue == .other("boom"))
    #expect(issue.savedMessage == "Recording saved, but capture stopped early: boom")
    #expect(issue.permission == nil)
}
@Test func savedMessages() {
    #expect(ScreenStreamIssue.permissionRevoked.savedMessage
            == "Screen Recording access was turned off. The recording was saved up to that point.")
    #expect(ScreenStreamIssue.displayLost.savedMessage
            == "The display was disconnected. The recording was saved up to that point.")
}
