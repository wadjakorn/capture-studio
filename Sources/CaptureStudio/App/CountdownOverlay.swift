import AppKit

/// Borderless 3-2-1 countdown panel centered on the recording display.
/// Click-through, screen-saver level, never steals focus.
@MainActor
enum CountdownOverlay {
    static func run(seconds: Int, displayID: CGDirectDisplayID?) async {
        guard seconds > 0 else { return }
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        } ?? NSScreen.main
        guard let screen else { return }

        let size: CGFloat = 200
        let rect = NSRect(
            x: screen.frame.midX - size / 2,
            y: screen.frame.midY - size / 2,
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
