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

    /// Closes the window as if the user clicked its close button, so the
    /// willClose cleanup (Dock presence, capture registration) runs.
    static func close() {
        controller?.window?.performClose(nil)
    }

    /// "Open Recorder": close the Dashboard, then open the menu-bar popup on
    /// the next main-queue turn. If the status button can't be located the
    /// Dashboard stays open and the user is told where the recorder lives —
    /// closing first would leave nothing on screen. Ordering dependency:
    /// `performClose` fires willClose synchronously → our observer enqueues a main-actor Task that
    /// releases DockPresence (possibly flipping to `.accessory`) → this
    /// main-async block clicks the status item. Both hops ride the main queue
    /// in enqueue order, so the click lands after the policy flip. Whether the
    /// click must wait for `.accessory` at all is pending Mac spike S0.3.
    static func openRecorder() {
        guard TrayPopupOpener.canOpen() else {
            showRecorderHint()
            return
        }
        close()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { _ = TrayPopupOpener.open() }
        }
    }

    private static func showRecorderHint() {
        let alert = NSAlert()
        alert.messageText = "Click the Capture Studio icon in the menu bar to open the recorder."
        alert.addButton(withTitle: "OK")
        if let window = controller?.window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
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

        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            if let token { NotificationCenter.default.removeObserver(token) }
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
