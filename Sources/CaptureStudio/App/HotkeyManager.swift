import KeyboardShortcuts

/// Wires the global hotkey to the recording session. Installed once at launch.
enum HotkeyManager {
    static func install() {
        // Carbon-backed global hotkey; fires regardless of app focus. The
        // handler hops to the main actor and routes to the shared session.
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) {
            Task { @MainActor in
                await RecordingSession.shared?.toggleFromHotkey()
            }
        }
    }
}
