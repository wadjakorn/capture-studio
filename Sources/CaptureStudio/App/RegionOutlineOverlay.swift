import AppKit

/// Thin, non-interactive outline drawn around the captured region while a
/// recording is armed/previewing and throughout the recording itself, so the
/// user can see exactly which rectangle is being captured.
///
/// Click-through (`ignoresMouseEvents = true`) and owned by the app, so — like
/// `CameraPreviewPanel` — it is excluded from the screen capture and never
/// appears in screen.mp4.
@MainActor
final class RegionOutlineOverlay {
    private let panel: NSPanel

    /// `region` is display-local **top-left** points within `displayID`. nil
    /// init if the target screen can't be resolved.
    init?(region: CGRect, onDisplay displayID: CGDirectDisplayID?) {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        } ?? NSScreen.main
        guard let screen else { return nil }

        // Display-local top-left → global bottom-left (inverse of AreaSelector).
        let frame = NSRect(
            x: screen.frame.minX + region.minX,
            y: screen.frame.maxY - region.maxY,
            width: region.width,
            height: region.height
        )

        panel = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = BorderView(frame: NSRect(origin: .zero, size: frame.size))
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }
}

/// Draws a 2pt accent border, inset so the full stroke stays inside the panel
/// (and thus on the very edge of the captured region). Transparent fill.
private final class BorderView: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth: CGFloat = 2
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = lineWidth
        path.stroke()
    }
}
