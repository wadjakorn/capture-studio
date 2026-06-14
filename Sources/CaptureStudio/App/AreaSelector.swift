import AppKit

/// Drag-to-select overlay (macOS-screenshot style). Dims **every** screen at once
/// with a single overlay session; the user drags a rectangle on whichever screen
/// they like. The screen the drag lands on **is** the capture display — derived
/// from the drag, not chosen separately. Returns the selection in **display-local
/// points** (top-left origin within that display) together with its display id.
/// ESC or right-click cancels.
@MainActor
enum AreaSelector {
    /// Minimum drag size (points); smaller drags are treated as a cancel so a
    /// stray click never produces a 1px region.
    private static let minSize: CGFloat = 20

    /// The single in-flight session, if any. A new `selectRegion` call dismisses
    /// it first, so the dim overlay can never stack.
    private static var active: Coordinator?

    static func selectRegion() async -> (region: CGRect, displayID: CGDirectDisplayID)? {
        // Guarantee a single overlay: tear down any session still on screen.
        active?.cancel()
        active = nil

        let priorApp = NSWorkspace.shared.frontmostApplication

        return await withCheckedContinuation { continuation in
            let coordinator = Coordinator(continuation: continuation, priorApp: priorApp)
            active = coordinator
            coordinator.present(minSize: minSize)
        }
    }

    /// Owns every screen's panel + the continuation, resolving exactly once. Also
    /// installs a shared ESC monitor (only one panel can be key, so per-view key
    /// handling alone wouldn't catch ESC on the others).
    @MainActor
    private final class Coordinator {
        private var panels: [NSPanel] = []
        private var continuation: CheckedContinuation<(region: CGRect, displayID: CGDirectDisplayID)?, Never>?
        private let priorApp: NSRunningApplication?
        private var keyMonitor: Any?

        init(continuation: CheckedContinuation<(region: CGRect, displayID: CGDirectDisplayID)?, Never>,
             priorApp: NSRunningApplication?) {
            self.continuation = continuation
            self.priorApp = priorApp
        }

        func present(minSize: CGFloat) {
            for screen in NSScreen.screens {
                let panel = NSPanel(contentRect: screen.frame,
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
                panel.level = .screenSaver
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.ignoresMouseEvents = false
                panel.acceptsMouseMovedEvents = true

                let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
                view.minSize = minSize
                view.onFinish = { [weak self] selection in
                    self?.finish(selection, on: screen)
                }
                panel.contentView = view
                panel.orderFrontRegardless()
                panels.append(panel)
            }

            // ESC cancels regardless of which screen is key.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 {  // Escape
                    self?.finish(nil, on: nil)
                    return nil
                }
                return event
            }

            NSApp.activate(ignoringOtherApps: true)
            // Make the screen under the cursor key so it gets first crack at the
            // drag; any panel still receives its own mouse via acceptsFirstMouse.
            panels.first?.makeKey()
        }

        /// Resolve once: tear down all panels, restore focus, resume the result.
        private func finish(_ selection: NSRect?, on screen: NSScreen?) {
            guard continuation != nil else { return }

            let result: (region: CGRect, displayID: CGDirectDisplayID)?
            if let selection, let screen, let displayID = screen.displayID {
                // selection is view coords (bottom-left). Convert to display-local
                // top-left points.
                let region = CGRect(x: selection.minX,
                                    y: screen.frame.height - selection.maxY,
                                    width: selection.width, height: selection.height)
                result = (region, displayID)
            } else {
                result = nil
            }

            teardown()
            priorApp?.activate()
            continuation?.resume(returning: result)
            continuation = nil
            if AreaSelector.active === self { AreaSelector.active = nil }
        }

        /// Cancel from a superseding session: resume nil and clear the screen.
        func cancel() {
            finish(nil, on: nil)
        }

        private func teardown() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            for panel in panels { panel.orderOut(nil) }
            panels.removeAll()
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Tracks the drag, draws the dim backdrop + cleared selection rect + a W×H
/// readout, and reports the result exactly once.
private final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    var minSize: CGFloat = 20

    private var origin: NSPoint?
    private var current: NSRect = .zero
    private var finished = false

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        origin = convert(event.locationInWindow, from: nil)
        current = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let p = convert(event.locationInWindow, from: nil)
        current = NSRect(x: min(origin.x, p.x), y: min(origin.y, p.y),
                         width: abs(p.x - origin.x), height: abs(p.y - origin.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard current.width >= minSize, current.height >= minSize else {
            finish(nil)
            return
        }
        finish(current)
    }

    override func rightMouseDown(with event: NSEvent) { finish(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) }  // Escape
    }

    override func cancelOperation(_ sender: Any?) { finish(nil) }

    private func finish(_ rect: NSRect?) {
        guard !finished else { return }
        finished = true
        onFinish?(rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard current.width > 0, current.height > 0 else { return }

        // Punch the selection clear so the user sees what they're capturing.
        NSColor.clear.set()
        current.fill(using: .copy)

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: current)
        border.lineWidth = 1.5
        border.stroke()

        let label = "\(Int(current.width.rounded())) × \(Int(current.height.rounded()))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        let pad: CGFloat = 6
        let boxW = size.width + pad * 2
        let boxH = size.height + pad
        var boxX = current.midX - boxW / 2
        var boxY = current.minY - boxH - 6
        boxX = max(bounds.minX + 4, min(boxX, bounds.maxX - boxW - 4))
        if boxY < bounds.minY + 4 { boxY = current.maxY + 6 }
        let box = NSRect(x: boxX, y: boxY, width: boxW, height: boxH)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        label.draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad / 2), withAttributes: attrs)
    }
}
