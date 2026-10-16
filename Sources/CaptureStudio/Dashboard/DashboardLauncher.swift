import AppKit
import SwiftUI

/// Single Dashboard window. Same imperative pattern as StudioLauncher: the
/// menubar popup's view tree is torn down on close, so SwiftUI openWindow
/// can't be driven from there.
@MainActor
enum DashboardLauncher {
    static let windowID = NSUserInterfaceItemIdentifier("CaptureStudio.Dashboard")
    private static var controller: NSWindowController?

    static var isVisible: Bool {
        guard let window = controller?.window else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    static func show() {
        if let window = controller?.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: DashboardView())
        let window = NSWindow(contentViewController: hosting)
        window.identifier = windowID
        window.title = "Capture Studio — Projects"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 600))
        window.minSize = NSSize(width: 560, height: 380)
        window.isReleasedWhenClosed = false
        // Centre first; a saved frame (if any) then overrides it.
        window.center()
        window.setFrameAutosaveName("Dashboard")

        let newController = NSWindowController(window: window)
        controller = newController
        DockPresence.shared.retain()
        // Dashboard is content, like Studio: it may appear in the recording.
        CaptureContentWindows.shared.register(window)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            Task { @MainActor in
                CaptureContentWindows.shared.unregister(window)
                if controller?.window === window { controller = nil }
                DockPresence.shared.release()
            }
        }

        newController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
