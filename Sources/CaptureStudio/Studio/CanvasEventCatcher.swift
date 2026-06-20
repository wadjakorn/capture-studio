import SwiftUI
import AppKit

/// Transparent input layer over the preview canvas that turns trackpad / mouse
/// navigation into pan + zoom of the inspection view, WITHOUT stealing clicks
/// from the editing overlays below it.
///
/// `hitTest` returns nil, so left/right clicks (block selection, PiP / text
/// drags, empty-canvas deselect) pass straight through. Scroll, pinch-magnify,
/// and middle-mouse drags are caught by a local event monitor scoped to this
/// view's bounds — events outside the canvas (e.g. over the timeline lanes or
/// the style popover) are left untouched so their own scroll views keep working.
struct CanvasEventCatcher: NSViewRepresentable {
    @ObservedObject var model: StudioModel

    func makeNSView(context: Context) -> CanvasInputView {
        let view = CanvasInputView()
        view.model = model
        return view
    }

    func updateNSView(_ view: CanvasInputView, context: Context) {
        view.model = model
    }
}

final class CanvasInputView: NSView {
    weak var model: StudioModel?
    private var monitor: Any?

    // Pass every direct click through to the SwiftUI overlays underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { removeMonitor() } else { installMonitor() }
    }

    deinit { removeMonitor() }

    private func installMonitor() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.scrollWheel, .magnify, .otherMouseDragged]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }

    /// Returns nil to consume an event we handled, else the event to pass on.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let model, let window, event.window == window else { return event }
        // Only act when the cursor is over the canvas region; anything else
        // (timeline scroll, control bar) stays with its own responders.
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else { return event }

        switch event.type {
        case .magnify:
            model.zoomCanvas(by: 1 + event.magnification)
            return nil

        case .scrollWheel:
            if event.modifierFlags.contains(.command) {
                // ⌘-scroll zooms — mouse-wheel users have no pinch gesture.
                let line = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY
                                                           : event.scrollingDeltaY * 3
                model.zoomCanvas(by: 1 + line * 0.005)
                return nil
            }
            guard model.canvasZoomed else { return event }
            // Document-scroll feel: content follows the scroll delta.
            model.panCanvas(by: CGSize(width: event.scrollingDeltaX,
                                       height: event.scrollingDeltaY))
            return nil

        case .otherMouseDragged where event.buttonNumber == 2:
            // Middle-mouse grab-pan: content follows the cursor.
            model.panCanvas(by: CGSize(width: event.deltaX, height: -event.deltaY))
            return nil

        default:
            return event
        }
    }
}
