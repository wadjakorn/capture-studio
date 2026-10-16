import Foundation

/// What to do once a recording has been saved. A single decision point (rather
/// than an inline `if` in `stop()`) so it stays testable and later features can
/// add cases without touching the recorder.
enum PostRecordingAction: Equatable {
    case openStudio
    /// Open the new project behind the Studio window the user is editing,
    /// instead of stealing focus from it.
    case openStudioBehind
    case showSavedToast

    static func decide(openStudioAfterRecording: Bool, studioWindowVisible: Bool) -> PostRecordingAction {
        guard openStudioAfterRecording else { return .showSavedToast }
        return studioWindowVisible ? .openStudioBehind : .openStudio
    }
}
