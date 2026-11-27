import Testing
@testable import CaptureStudio

private func all(_ s: PermissionStatus) -> (PermissionKind) -> PermissionStatus { { _ in s } }
private func only(_ k: PermissionKind, _ s: PermissionStatus) -> (PermissionKind) -> PermissionStatus {
    { $0 == k ? s : .granted }
}
private typealias P = PermissionPreflight

@Test func allGrantedHasNoIssues() {
    #expect(P.issues(main: .display(1), cameraID: "cam", micID: "mic", status: all(.granted)).isEmpty)
}
@Test func displayWithoutScreenBlocks() {
    #expect(P.issues(main: .display(1), cameraID: nil, micID: nil, status: only(.screenRecording, .denied))
            == [PermissionIssue(kind: .screenRecording, blocking: true, message: P.screenOff)])
}
@Test func screenNotDeterminedAlsoBlocks() {
    #expect(P.issues(main: .display(1), cameraID: nil, micID: nil, status: only(.screenRecording, .notDetermined))
            .first?.blocking == true)
}
@Test func cameraMainNeedsNoScreen() {
    #expect(P.issues(main: .camera(uniqueID: "cam"), cameraID: nil, micID: nil,
                     status: only(.screenRecording, .denied)).isEmpty)
}
@Test func deniedMainCameraBlocks() {
    #expect(P.issues(main: .camera(uniqueID: "cam"), cameraID: nil, micID: nil, status: only(.camera, .denied))
            == [PermissionIssue(kind: .camera, blocking: true, message: P.cameraMainOff)])
}
@Test func deniedOverlayCameraWarns() {
    #expect(P.issues(main: .display(1), cameraID: "cam", micID: nil, status: only(.camera, .denied))
            == [PermissionIssue(kind: .camera, blocking: false, message: P.cameraOverlayOff)])
}
@Test func undeterminedCameraIsNotAnIssue() {
    #expect(P.issues(main: .display(1), cameraID: "cam", micID: nil, status: only(.camera, .notDetermined)).isEmpty)
}
@Test func deniedMicWarns() {
    #expect(P.issues(main: .display(1), cameraID: nil, micID: "mic", status: only(.microphone, .denied))
            == [PermissionIssue(kind: .microphone, blocking: false, message: P.micOff)])
}
@Test func phoneMicIgnoresMacMicPermission() {
    #expect(P.issues(main: .display(1), cameraID: nil, micID: "phone-mic:A", status: only(.microphone, .denied)).isEmpty)
}
@Test func phoneMainWithoutLocalNetworkBlocks() {
    #expect(P.issues(main: .camera(uniqueID: "phone:A"), cameraID: nil, micID: nil, status: only(.localNetwork, .denied))
            == [PermissionIssue(kind: .localNetwork, blocking: true, message: P.phoneMainOff)])
}
@Test func phoneOverlayWithoutLocalNetworkWarnsOnce() {
    #expect(P.issues(main: .display(1), cameraID: "phone:A", micID: "phone-mic:A", status: only(.localNetwork, .denied))
            == [PermissionIssue(kind: .localNetwork, blocking: false, message: P.phoneOptionalOff)])
}
@Test func unknownLocalNetworkIsNotAnIssue() {
    #expect(P.issues(main: .camera(uniqueID: "phone:A"), cameraID: nil, micID: nil, status: only(.localNetwork, .unknown)).isEmpty)
}
@Test func blockingIssuesComeFirst() {
    let status: (PermissionKind) -> PermissionStatus = { $0 == .localNetwork ? .granted : .denied }
    let issues = P.issues(main: .display(1), cameraID: "cam", micID: "mic", status: status)
    #expect(issues.map(\.kind) == [.screenRecording, .camera, .microphone])
    #expect(issues.map(\.blocking) == [true, false, false])
}
@Test func messageMapsBackToKind() {
    #expect(P.kind(forMessage: P.micOff) == .microphone)
    #expect(P.kind(forMessage: P.phoneMainOff) == .localNetwork)
    #expect(P.kind(forMessage: "Phone disconnected.") == nil)
}
