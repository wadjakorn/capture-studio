import SwiftUI
import AppKit

/// Best-effort teardown on quit: stop warmed sessions and drop an unfinalized
/// (armed-but-not-recording) bundle so we don't leave orphan empty bundles.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { RecordingSession.shared?.tearDownForQuit() }
    }
}

@main
struct CaptureStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
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
