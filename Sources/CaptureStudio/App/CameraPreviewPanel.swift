import AppKit
import AVFoundation

/// Floating live camera-preview window shown while recording. A local camera
/// renders from the recorder's own `AVCaptureSession` via a parallel
/// `AVCaptureVideoPreviewLayer` (no extra device open); a remote source hands
/// over an `AVSampleBufferDisplayLayer` it feeds itself. The whole app is
/// excluded from the screen capture, so this panel never appears in screen.mp4.
///
/// Draggable + resizable, non-activating (never steals focus from the recorded
/// app), floats over fullscreen. A mirror toggle flips only the preview — the
/// recorded camera.mp4 is always unmirrored.
@MainActor
final class CameraPreviewPanel: NSObject {
    private static let mirrorDefaultsKey = "previewMirrored"

    private let panel: CameraPanel
    /// The hosted preview sublayer: an `AVCaptureVideoPreviewLayer` for
    /// `.captureSession` (mirrored via its connection), or, for `.displayLayer`,
    /// a container around the source's layer (the source owns the inner layer's
    /// transform — rotation; the mirror toggle transforms only the container).
    private let previewLayer: CALayer
    private var mirrored: Bool

    /// Where the panel opens. `.corner` is the overlay-camera preview (bottom
    /// right); `.bottomCenterLarge` is the camera-main preview — larger, centered,
    /// and stacked above the `PreviewHUD` so the two never overlap.
    enum Placement {
        case corner
        case bottomCenterLarge
    }

    /// `onCancel` fires on ESC while the preview is the key window, so cancelling
    /// works even when the user last clicked (focused) the camera preview.
    init(surface: PreviewSurface, onDisplay displayID: CGDirectDisplayID?,
         placement: Placement = .corner,
         onCancel: @escaping () -> Void = {}) {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        } ?? NSScreen.main ?? NSScreen.screens.first!

        let size: NSSize
        let origin: NSPoint
        switch placement {
        case .corner:
            size = NSSize(width: 320, height: 240)
            let margin: CGFloat = 24
            origin = NSPoint(
                x: screen.frame.maxX - size.width - margin,
                y: screen.frame.minY + margin
            )
        case .bottomCenterLarge:
            size = NSSize(width: 640, height: 480)
            // `PreviewHUD` sits 130 pt above the screen bottom; clear its
            // height (~56 pt) plus a gap so the panel stacks above it.
            let hudTop: CGFloat = 130 + 56
            let gap: CGFloat = 24
            origin = NSPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.minY + hudTop + gap
            )
        }
        panel = CameraPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.onCancel = onCancel
        switch surface {
        case .captureSession(let session):
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspect
            previewLayer = layer
        case .displayLayer(let layer):
            layer.videoGravity = .resizeAspect
            previewLayer = RotatedPreviewContainerLayer(inner: layer)
        }
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
        if let captureLayer = previewLayer as? AVCaptureVideoPreviewLayer {
            guard let connection = captureLayer.connection,
                  connection.isVideoMirroringSupported else { return }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        } else {
            // Display layer: flip just the container (never the source's inner
            // layer, whose transform carries the rotation) — the mirror button is
            // a sibling subview, so it stays unmirrored.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.transform = mirrored ? CATransform3DMakeScale(-1, 1, 1)
                                              : CATransform3DIdentity
            CATransaction.commit()
        }
    }

    private static var mirrorIcon: NSImage {
        NSImage(systemSymbolName: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                accessibilityDescription: "Mirror")
            ?? NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Mirror")
            ?? NSImage()
    }
}

/// Non-activating preview panel that routes ESC to a cancel callback, so the
/// preview can be dismissed while it (rather than the tray popover) is focused.
private final class CameraPanel: NSPanel {
    var onCancel: () -> Void = {}
    override func cancelOperation(_ sender: Any?) { onCancel() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel() } else { super.keyDown(with: event) }
    }
}

/// Hosts a source-fed preview layer whose transform (rotation only) the source
/// sets; mirroring is the panel toggle on this container. For a 90/270 rotation the inner layer gets swapped
/// bounds (height × width) centered in the container, so the rotated frame fits
/// instead of being clipped. Relayout follows the inner layer's transform (KVO).
private final class RotatedPreviewContainerLayer: CALayer {
    private let inner: CALayer
    private var transformObservation: NSKeyValueObservation?

    init(inner: CALayer) {
        self.inner = inner
        super.init()
        addSublayer(inner)
        // The source sets the transform on the main thread.
        transformObservation = inner.observe(\.transform) { [weak self] _, _ in
            self?.setNeedsLayout()
        }
    }

    /// Core Animation's presentation-layer copy.
    override init(layer: Any) {
        inner = (layer as? RotatedPreviewContainerLayer)?.inner ?? CALayer()
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSublayers() {
        super.layoutSublayers()
        let t = inner.transform
        // A 90/270 rotation swaps the axes.
        let swapsAxes = abs(t.m12) > abs(t.m11)
        let size = swapsAxes ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Not `frame`: undefined under a non-identity transform.
        inner.bounds = CGRect(origin: .zero, size: size)
        inner.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
}

/// Hosts the preview sublayer, keeping it sized to the view's bounds.
private final class PreviewLayerHostView: NSView {
    private let previewLayer: CALayer

    init(previewLayer: CALayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        // Not `frame`: it is undefined under a non-identity transform (a
        // mirrored display layer). bounds + centered position is equivalent
        // for an identity transform (default 0.5 anchor).
        previewLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}
