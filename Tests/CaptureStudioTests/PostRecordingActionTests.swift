import Testing
@testable import CaptureStudio

@Suite struct PostRecordingActionTests {
    @Test func opensStudioWhenPreferenceOn() {
        #expect(PostRecordingAction.decide(openStudioAfterRecording: true) == .openStudio)
    }

    @Test func showsToastWhenPreferenceOff() {
        #expect(PostRecordingAction.decide(openStudioAfterRecording: false) == .showSavedToast)
    }
}
