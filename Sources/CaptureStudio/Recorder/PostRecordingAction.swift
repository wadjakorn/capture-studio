import Foundation

/// What to do once a recording has been saved. A single decision point (rather
/// than an inline `if` in `stop()`) so it stays testable and later features can
/// add cases without touching the recorder.
enum PostRecordingAction: Equatable {
    case openStudio
    case showSavedToast

    static func decide(openStudioAfterRecording: Bool) -> PostRecordingAction {
        openStudioAfterRecording ? .openStudio : .showSavedToast
    }
}
