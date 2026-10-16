import SwiftUI
import AppKit

/// Best-effort teardown on quit: stop warmed sessions and drop an unfinalized
/// (armed-but-not-recording) bundle so we don't leave orphan empty bundles.
///
/// Launch routing: a plain launch opens the Dashboard; a document launch opens
/// only Studio; a login-item launch stays menu-bar-only.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the launch has been routed (document opened, untitled-file
    /// path taken, or fallback fired) so the Dashboard never shows twice.
    private var didRouteLaunch = false
    private var isLoginItemLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Registers the global hotkey handler once. The @StateObject session is
        // created before this fires, so RecordingSession.shared is set.
        HotkeyManager.install()

        if Self.currentEventIsLoginItemLaunch() { isLoginItemLaunch = true }
        // Fallback for when AppKit never asks about an untitled file (unverified
        // for an LSUIElement, non-document app). Document opens and the
        // untitled-file callbacks normally arrive before didFinishLaunching;
        // one main-queue hop gives any stragglers a chance to route first.
        // Mac spike S0.4 must confirm which path actually fires at launch.
        DispatchQueue.main.async { [self] in
            guard !didRouteLaunch else { return }
            didRouteLaunch = true
            guard LaunchRouting.shouldShowDashboardAtLaunch(isLoginItem: isLoginItemLaunch) else { return }
            Log.app.info("Launch routing: fallback → Dashboard")
            MainActor.assumeIsolated { DashboardLauncher.show() }
        }
    }

    /// Primary launch path (pending S0.4): AppKit asks this only when the app
    /// was opened without documents.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if Self.currentEventIsLoginItemLaunch() { isLoginItemLaunch = true }
        // AppKit has made its launch decision either way; don't let the
        // fallback second-guess it (e.g. show the Dashboard for a login item).
        let wasRouted = didRouteLaunch
        didRouteLaunch = true
        guard !wasRouted else { return false }
        return LaunchRouting.shouldShowDashboardAtLaunch(isLoginItem: isLoginItemLaunch)
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        didRouteLaunch = true
        Log.app.info("Launch routing: untitled file → Dashboard")
        MainActor.assumeIsolated { DashboardLauncher.show() }
        return true
    }

    /// Dock click. Acts on our own window bookkeeping, then always returns
    /// false: returning true would let AppKit run the untitled-file path and
    /// stack a Dashboard on top of a Studio window we just restored.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            let action = ReopenAction.decide(
                hasVisibleAppWindow: StudioLauncher.hasVisibleStudioWindow || DashboardLauncher.isVisible,
                hasMiniaturizedStudio: StudioLauncher.hasMiniaturizedStudioWindow)
            Log.app.info("Reopen: \(String(describing: action), privacy: .public)")
            switch action {
            case .none: break
            case .restoreStudio: StudioLauncher.restoreMostRecentMiniaturized()
            case .showDashboard: DashboardLauncher.show()
            }
        }
        return false
    }

    /// Login-item launches carry `keyAELaunchedAsLogInItem` in the open-app
    /// Apple event's property data.
    private static func currentEventIsLoginItemLaunch() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
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
        // A document launch shows Studio only — no Dashboard on top.
        didRouteLaunch = true
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
