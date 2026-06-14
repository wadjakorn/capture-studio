import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global toggle for start/stop recording. No default value, so it is OFF
    /// (no Carbon hotkey registered) until the user records a combo in the popup.
    static let toggleRecording = Self("toggleRecording")
}
