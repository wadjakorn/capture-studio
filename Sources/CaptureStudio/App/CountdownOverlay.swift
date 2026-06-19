import AppKit

/// Borderless 3-2-1 countdown panel centered on the recording display.
/// Click-through, screen-saver level, never steals focus.
@MainActor
enum CountdownOverlay {
    /// `region` (display-local points, top-left origin) centers the overlay on
    /// the captured area; nil centers it on the whole display.
    static func run(seconds: Int, displayID: CGDirectDisplayID?,
                    region: CGRect? = nil) async {
        guard seconds > 0 else { return }
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        } ?? NSScreen.main
        guard let screen else { return }

        let size: CGFloat = 200
        // Region is top-left points within the display; NSScreen.frame is
        // bottom-left global → flip Y for the region center.
        let centerX = region.map { screen.frame.minX + $0.midX } ?? screen.frame.midX
        let centerY = region.map { screen.frame.maxY - $0.midY } ?? screen.frame.midY
        let rect = NSRect(
            x: centerX - size / 2,
            y: centerY - size / 2,
            width: size, height: size
        )
        let panel = NSPanel(contentRect: rect,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Recording runs with another app frontmost (area mode reactivates the
        // prior app), so the panel must stay visible while CaptureStudio is
        // inactive — same opt-out the region-outline / dim overlays use.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        container.layer?.cornerRadius = size / 2

        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 110, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (size - 130) / 2, width: size, height: 130)
        container.addSubview(label)
        panel.contentView = container
        panel.orderFrontRegardless()

        for n in stride(from: seconds, through: 1, by: -1) {
            label.stringValue = "\(n)"
            try? await Task.sleep(for: .seconds(1))
        }
        panel.orderOut(nil)
    }
}
