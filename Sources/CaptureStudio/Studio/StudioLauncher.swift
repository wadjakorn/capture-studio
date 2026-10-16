import AppKit
import SwiftUI

/// Whether a bundle may be opened in Studio. Plain (non-actor) type so the
/// rule is unit-testable without the launcher's AppKit glue.
enum StudioOpenEligibility: Equatable {
    case ok
    /// The session is still writing this bundle (arming through finishing).
    case recordingInProgress
    /// No meta.json — an aborted or crashed recording that can never load.
    case notFinalized

    /// Active-recording is checked first: a bundle mid-recording also lacks
    /// meta.json, and "in progress" is the more accurate answer. Paths are
    /// compared standardized so a trailing slash or `..` can't slip past.
    static func evaluate(url: URL, activeRecording: URL?) -> StudioOpenEligibility {
        if let activeRecording,
           activeRecording.standardizedFileURL.path == url.standardizedFileURL.path {
            return .recordingInProgress
        }
        if !ProjectBundle(url: url).isFinalized { return .notFinalized }
        return .ok
    }
}

/// Opens Studio windows imperatively. A SwiftUI WindowGroup + openWindow
/// can't be triggered from the menubar popup reliably — the popup's view
/// is torn down when it closes, so onChange never fires.
@MainActor
enum StudioLauncher {
    private static var controllers: [NSWindowController] = []

    static func open(bundleURL: URL) {
        Log.studio.info("StudioLauncher.open: \(bundleURL.lastPathComponent, privacy: .public)")
        // Every entry point (Open…, Finder/Dock, Recent, toast, auto-open) funnels
        // through here, so this one check covers them all. Runs before re-focus
        // and before noteOpened: a refused open must not become a recent entry.
        let eligibility = StudioOpenEligibility.evaluate(
            url: bundleURL, activeRecording: RecordingSession.shared?.activeBundleURL)
        guard eligibility == .ok else {
            Log.studio.info("StudioLauncher.open refused: \(String(describing: eligibility), privacy: .public)")
            showRefusal(eligibility)
            return
        }
        // Window identity = standardized path, so lookups can't be fooled by
        // trailing slashes or `..` segments.
        let windowID = bundleURL.standardizedFileURL.path
        // Re-focus an already-open window for the same bundle.
        if let existing = controllers.first(where: { $0.window?.identifier?.rawValue == windowID }) {
            RecentProjectsStore.shared.noteOpened(bundleURL)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: StudioView(bundleURL: bundleURL))
        let window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier(windowID)
        window.title = bundleURL.deletingPathExtension().lastPathComponent
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1000, height: 680))
        window.center()
        window.isReleasedWhenClosed = false

        RecentProjectsStore.shared.noteOpened(bundleURL)

        let controller = NSWindowController(window: window)
        // First Studio window: become a regular Dock app so the window gets a
        // Dock tile and can be minimized/restored. Cold launch stays dockless
        // (LSUIElement); this only flips while >=1 editor window is open.
        if controllers.isEmpty {
            NSApp.setActivationPolicy(.regular)
        }
        controllers.append(controller)
        // Studio is content: let it into the recording (everything else the
        // app shows stays excluded).
        CaptureContentWindows.shared.register(window)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            Task { @MainActor in
                CaptureContentWindows.shared.unregister(window)
                controllers.removeAll { $0.window === window }
                // Last Studio window closed: revert to menu-bar-only.
                if controllers.isEmpty {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.studio.info("StudioLauncher: window shown, visible=\(window.isVisible)")
    }

    /// Explains a refused open. The app may be accessory-only with no windows,
    /// so activate first or the alert lands behind the frontmost app.
    private static func showRefusal(_ eligibility: StudioOpenEligibility) {
        let alert = NSAlert()
        switch eligibility {
        case .recordingInProgress: alert.messageText = "This recording is still in progress."
        case .notFinalized: alert.messageText = "This recording is incomplete and can't be opened."
        case .ok: return
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
