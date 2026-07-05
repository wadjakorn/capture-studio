import SwiftUI
import AppKit

/// Vetoes closing the Studio window while an export is running — the user must
/// Stop the export first. Minimizing is unaffected, so the window (and its
/// StudioModel) survive to the Dock and restore in the same locked, in-progress
/// state. Dropped into the editor's background; it renders nothing.
struct StudioWindowCloseGuard: NSViewRepresentable {
    /// Read live so the delegate always sees the current export state.
    let isExporting: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(isExporting: isExporting) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The window isn't attached yet inside makeNSView; grab it next tick.
        DispatchQueue.main.async { [weak view] in
            context.coordinator.attach(to: view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isExporting = isExporting
        if nsView.window !== context.coordinator.window {
            context.coordinator.attach(to: nsView.window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var isExporting: () -> Bool
        weak var window: NSWindow?

        init(isExporting: @escaping () -> Bool) {
            self.isExporting = isExporting
        }

        func attach(to window: NSWindow?) {
            guard let window, window !== self.window else { return }
            self.window = window
            // Launcher tracks close via NotificationCenter, not the delegate,
            // so taking the delegate slot here doesn't disturb it.
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard isExporting() else { return true }
            let alert = NSAlert()
            alert.messageText = "Export in progress"
            alert.informativeText = "Stop the export before closing this window."
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: sender, completionHandler: nil)
            return false
        }
    }
}
