import Testing
@testable import CaptureStudio

@Suite struct PostRecordingActionTests {
    @Test func opensStudioWhenPreferenceOn() {
        #expect(PostRecordingAction.decide(openStudioAfterRecording: true, studioWindowVisible: false) == .openStudio)
    }

    @Test func onWithVisibleStudioOpensBehind() {
        #expect(PostRecordingAction.decide(openStudioAfterRecording: true, studioWindowVisible: true) == .openStudioBehind)
    }

    @Test func showsToastWhenPreferenceOff() {
        #expect(PostRecordingAction.decide(openStudioAfterRecording: false, studioWindowVisible: false) == .showSavedToast)
    }

    @Test func offAlwaysToasts() {
        #expect(PostRecordingAction.decide(openStudioAfterRecording: false, studioWindowVisible: true) == .showSavedToast)
    }
}
