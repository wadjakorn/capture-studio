import AppKit
import SwiftUI

/// Opens Studio windows imperatively. A SwiftUI WindowGroup + openWindow
/// can't be triggered from the menubar popup reliably — the popup's view
/// is torn down when it closes, so onChange never fires.
@MainActor
enum StudioLauncher {
    private static var controllers: [NSWindowController] = []

    static func open(bundleURL: URL) {
        Log.studio.info("StudioLauncher.open: \(bundleURL.lastPathComponent, privacy: .public)")
        // Re-focus an already-open window for the same bundle.
        if let existing = controllers.first(where: { $0.window?.identifier?.rawValue == bundleURL.path }) {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: StudioView(bundleURL: bundleURL))
        let window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier(bundleURL.path)
        window.title = bundleURL.deletingPathExtension().lastPathComponent
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1000, height: 680))
        window.center()
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        // First Studio window: become a regular Dock app so the window gets a
        // Dock tile and can be minimized/restored. Cold launch stays dockless
        // (LSUIElement); this only flips while >=1 editor window is open.
        if controllers.isEmpty {
            NSApp.setActivationPolicy(.regular)
        }
        controllers.append(controller)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            Task { @MainActor in
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
}
