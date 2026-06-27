import SwiftUI
import AppKit

/// Best-effort teardown on quit: stop warmed sessions and drop an unfinalized
/// (armed-but-not-recording) bundle so we don't leave orphan empty bundles.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Registers the global hotkey handler once. The @StateObject session is
        // created before this fires, so RecordingSession.shared is set.
        HotkeyManager.install()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { RecordingSession.shared?.tearDownForQuit() }
    }

    /// Finder double-click (and `open file.capturestudio`) routes the document
    /// here. Info.plist declares the `.capturestudio` doc type so AppKit
    /// dispatches the URL; without this handler it would be silently dropped —
    /// the app would launch but no Studio window appears. Fires for both cold
    /// launch (around didFinishLaunching) and while already running.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls where url.pathExtension.lowercased() == ProjectBundle.pathExtension {
                StudioLauncher.open(bundleURL: url)
            }
        }
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
