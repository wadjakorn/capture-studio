import AppKit
import AVFoundation

/// Floating live camera-preview window shown while recording. Renders the
/// camera feed from the recorder's own `AVCaptureSession` via a parallel
/// `AVCaptureVideoPreviewLayer` (no extra device open). The whole app is
/// excluded from the screen capture, so this panel never appears in screen.mp4.
///
/// Draggable + resizable, non-activating (never steals focus from the recorded
/// app), floats over fullscreen. A mirror toggle flips only the preview — the
/// recorded camera.mp4 is always unmirrored.
@MainActor
final class CameraPreviewPanel: NSObject {
    private static let mirrorDefaultsKey = "previewMirrored"

    private let panel: NSPanel
    private let previewLayer: AVCaptureVideoPreviewLayer
    private var mirrored: Bool

    init(session: AVCaptureSession, onDisplay displayID: CGDirectDisplayID?) {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        } ?? NSScreen.main ?? NSScreen.screens.first!

        let size = NSSize(width: 320, height: 240)
        let margin: CGFloat = 24
        let origin = NSPoint(
            x: screen.frame.maxX - size.width - margin,
            y: screen.frame.minY + margin
        )
        panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
        mirrored = UserDefaults.standard.bool(forKey: Self.mirrorDefaultsKey)

        super.init()

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .black
        panel.hasShadow = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let host = PreviewLayerHostView(previewLayer: previewLayer)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        let button = NSButton(
            image: Self.mirrorIcon, target: self, action: #selector(toggleMirror)
        )
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        button.layer?.cornerRadius = 6
        button.frame = NSRect(x: size.width - 36, y: size.height - 36, width: 28, height: 28)
        button.autoresizingMask = [.minXMargin, .minYMargin]
        button.toolTip = "Mirror preview (does not affect the recording)"
        host.addSubview(button)

        applyMirror()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }

    @objc private func toggleMirror() {
        mirrored.toggle()
        UserDefaults.standard.set(mirrored, forKey: Self.mirrorDefaultsKey)
        applyMirror()
    }

    private func applyMirror() {
        guard let connection = previewLayer.connection,
              connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }

    private static var mirrorIcon: NSImage {
        NSImage(systemSymbolName: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                accessibilityDescription: "Mirror")
            ?? NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Mirror")
            ?? NSImage()
    }
}

/// Hosts an `AVCaptureVideoPreviewLayer`, keeping it sized to the view's bounds.
private final class PreviewLayerHostView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}
