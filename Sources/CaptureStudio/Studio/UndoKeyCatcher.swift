import SwiftUI
import AppKit

/// Invisible key layer that routes ⌘Z / ⇧⌘Z to the Studio edit history.
///
/// A local `.keyDown` monitor scoped to this view's window (no bounds check —
/// the shortcut applies anywhere in the editor). Events pass through untouched
/// while exporting, while a text field / text view is first responder (the
/// caption editor's own undo must win), and for every other key.
struct UndoKeyCatcher: NSViewRepresentable {
    /// Plain reference (not observed): the view never re-renders on model
    /// changes, so `updateNSView` isn't re-run on every playback tick.
    let model: StudioModel

    func makeNSView(context: Context) -> UndoKeyCatcherView {
        let view = UndoKeyCatcherView()
        view.model = model
        return view
    }

    func updateNSView(_ view: UndoKeyCatcherView, context: Context) {
        view.model = model
    }
}

final class UndoKeyCatcherView: NSView {
    weak var model: StudioModel?
    private var monitor: Any?

    /// The Z key's virtual key code (layout-position based, shift-independent).
    private static let zKeyCode: UInt16 = 6

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { removeMonitor() } else { installMonitor() }
    }

    deinit { removeMonitor() }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }

    /// Returns nil to consume an event we handled, else the event to pass on.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let model, let window, event.window == window else { return event }
        guard !model.isExporting else { return event }
        // Text editing (caption field, any NSTextView/field editor) keeps its own undo.
        guard !(window.firstResponder is NSText) else { return event }
        guard event.keyCode == Self.zKeyCode else { return event }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == [.command] {
            model.undo()
            return nil
        }
        if mods == [.command, .shift] {
            model.redo()
            return nil
        }
        return event
    }
}
