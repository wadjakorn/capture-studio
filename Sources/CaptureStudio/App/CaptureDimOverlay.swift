import AppKit

/// Semi-transparent scrim shown while a recording is armed/previewing, dimming
/// everything that WON'T be captured so the target is obvious at a glance:
/// - full-display capture (nil region): every OTHER display is dimmed; the
///   captured display stays clear.
/// - area capture: the captured display is dimmed except the region rectangle;
///   other displays are dimmed in full.
///
/// One borderless, click-through, app-owned panel per dimmed screen → excluded
/// from screen.mp4 (the whole app is excluded), like CameraPreviewPanel and the
/// region outline. Always torn down before the countdown, so it never shows
/// during the 3-2-1 or the recording itself.
///
/// Sits just below `.floating`, keeping the camera preview (`.floating`) and the
/// region outline (`.screenSaver`) visible on top while still covering the
/// recorded app windows beneath.
@MainActor
final class CaptureDimOverlay {
    private var panels: [NSPanel] = []

    /// `region` is display-local **top-left** points within `displayID` for area
    /// capture, or nil for full-display capture of `displayID`.
    init(region: CGRect?, capturedDisplay displayID: CGDirectDisplayID?) {
        let level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)

        for screen in NSScreen.screens {
            let screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber)?.uint32Value
            let isCaptured = screenNumber == displayID

            // Clear hole over the captured rect, in this screen's local
            // (bottom-left) coordinates.
            var hole: NSRect?
            if isCaptured {
                guard let region else { continue }  // full display → leave clear
                hole = NSRect(
                    x: region.minX,
                    y: screen.frame.height - region.maxY,  // top-left → bottom-left
                    width: region.width,
                    height: region.height
                )
            }

            let panel = NSPanel(contentRect: screen.frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = level
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.contentView = ScrimView(
                frame: NSRect(origin: .zero, size: screen.frame.size), hole: hole
            )
            panels.append(panel)
        }
    }

    func show() {
        panels.forEach { $0.orderFrontRegardless() }
    }

    func close() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}

/// Fills its bounds with translucent black, then punches the captured rect back
/// to fully transparent so the target shows through undimmed.
private final class ScrimView: NSView {
    private let hole: NSRect?

    init(frame: NSRect, hole: NSRect?) {
        self.hole = hole
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()

        guard let hole, let ctx = NSGraphicsContext.current else { return }
        let previous = ctx.compositingOperation
        ctx.compositingOperation = .clear
        hole.fill()
        ctx.compositingOperation = previous
    }
}
