import SwiftUI

@main
struct CaptureStudioApp: App {
    @StateObject private var session = RecordingSession()

    var body: some Scene {
        MenuBarExtra {
            RecorderMenuView()
                .environmentObject(session)
        } label: {
            // No Text(style: .timer) here — live-updating text in a
            // MenuBarExtra label re-renders the status item every frame,
            // saturating the main thread (clicks dropped, memory churn).
            // Elapsed time lives in the popup instead.
            Image(systemName: session.isRecording ? "record.circle.fill" : "record.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
