import AVFoundation
import CoreImage
import CoreGraphics
import Metal

/// Geometry + styling for one composed frame. All rects are in top-left
/// pixel coordinates (matching the rest of the model); the compositor flips
/// to Core Image's bottom-left space when building transforms.
struct CompositorLayout {
    var canvas: CGSize
    var sourceSize: CGSize
    /// Screen crop in source pixels; nil = use the whole source.
    var screenCrop: CGRect?

    var screenTrackID: CMPersistentTrackID
    var cameraTrackID: CMPersistentTrackID?

    // Camera (present only when a styled camera is shown).
    var feedSize: CGSize = .zero
    /// Visible camera-feed crop in feed pixels.
    var feedCrop: CGRect = .zero
    /// Camera PiP rect in canvas pixels (top-left).
    var pip: CGRect = .zero
    var shape: CameraShape = .rectangle
    /// Camera orientation in clockwise quarter turns (0–3); feed rotated before
    /// crop/scale so `feedSize`/`feedCrop` are already in oriented space.
    var cameraQuarterTurns: Int = 0
    var cornerRadiusPx: CGFloat = 0
    var borderWidthPx: CGFloat = 0
    var borderColor: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    var shadow: Bool = false
    /// Shadow intensity 0–1 (scales blur/offset/opacity together).
    var shadowRadius: CGFloat = 0.5

    // Cursor / click overlays (composited from events.jsonl).
    var showCursor: Bool = false
    var clickFeedback: Bool = false
    /// Source pixels per screen point (sourceSize.width / display.pointWidth);
    /// used with the screen crop scale to size the cursor glyph in canvas px.
    var sourcePerPoint: CGFloat = 1
}

/// A prerendered cursor glyph plus the metadata needed to place/size it.
struct CursorGlyph {
    /// Glyph image, origin (0,0), `pixelSize` extent.
    let image: CIImage
    /// On-screen size of the cursor in points (target size = pointSize × scale).
    let pointSize: CGSize
    /// Rendered pixel size of `image`.
    let pixelSize: CGSize
    /// Hotspot in points, top-left origin within the glyph.
    let hotspot: CGPoint
}

/// Immutable per-timeline overlay payload shared across every composed frame.
struct OverlayPayload {
    var cursorSamples: [CursorSample] = []
    var clickSamples: [ClickSample] = []
    /// Cursor name → glyph; falls back to "arrow".
    var glyphs: [String: CursorGlyph] = [:]
    /// Click ring image (square, centered circle stroke), origin (0,0).
    var ring: CIImage?
    var ringPixelSize: CGSize = .zero
}

/// Custom video compositor instruction carrying a `CompositorLayout` plus
/// lazily-built (and cached) shape mask / border / shadow images. One
/// instruction spans the whole timeline, so the decorations are computed once.
final class StudioCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let layout: CompositorLayout
    let overlay: OverlayPayload

    /// Camera frame shape as a white-on-clear alpha mask, in PiP-local space.
    private(set) lazy var maskImage: CIImage? = makeMask()
    /// Border ring in PiP-local space; nil when no border.
    private(set) lazy var borderImage: CIImage? = makeBorder()
    /// Drop-shadow silhouette in PiP-local space (offset/blurred); nil if off.
    private(set) lazy var shadowImage: CIImage? = makeShadow()

    init(timeRange: CMTimeRange, layout: CompositorLayout,
         overlay: OverlayPayload = OverlayPayload()) {
        self.timeRange = timeRange
        self.layout = layout
        self.overlay = overlay
        var ids: [NSValue] = [NSNumber(value: layout.screenTrackID)]
        if let cam = layout.cameraTrackID { ids.append(NSNumber(value: cam)) }
        self.requiredSourceTrackIDs = ids
    }

    private var pipSize: CGSize { layout.pip.size }

    private func cornerRadius() -> CGFloat {
        switch layout.shape {
        case .circle: return min(pipSize.width, pipSize.height) / 2
        case .rectangle: return layout.cornerRadiusPx
        }
    }

    private func makeMask() -> CIImage? {
        guard pipSize.width > 1, pipSize.height > 1 else { return nil }
        let rect = CGRect(origin: .zero, size: pipSize)
        guard let ctx = makeContext(size: pipSize) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius(),
                           cornerHeight: cornerRadius(), transform: nil))
        ctx.fillPath()
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    private func makeBorder() -> CIImage? {
        guard layout.borderWidthPx > 0.5, pipSize.width > 1, pipSize.height > 1,
              let ctx = makeContext(size: pipSize) else { return nil }
        let w = layout.borderWidthPx
        let rect = CGRect(origin: .zero, size: pipSize).insetBy(dx: w / 2, dy: w / 2)
        let r = max(0, cornerRadius() - w / 2)
        ctx.setStrokeColor(layout.borderColor)
        ctx.setLineWidth(w)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.strokePath()
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    private func makeShadow() -> CIImage? {
        guard layout.shadow, let mask = maskImage else { return nil }
        // Scale blur / offset / opacity together by the intensity. Tuned so
        // 0.5 reads clearly and 1.0 is a strong soft drop shadow.
        let r = max(0, min(1, layout.shadowRadius))
        let blur = max(2, pipSize.width * (0.04 + 0.12 * r))
        let offsetY = -max(2, pipSize.height * (0.02 + 0.06 * r)) // down in CI space
        let alpha = 0.35 + 0.4 * r
        // Tint the silhouette black, blur, then offset.
        let tint = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
        ])
        return tint
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])
            .transformed(by: CGAffineTransform(translationX: 0, y: offsetY))
    }

    private func makeContext(size: CGSize) -> CGContext? {
        CGContext(data: nil,
                  width: Int(size.width.rounded()),
                  height: Int(size.height.rounded()),
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

/// Core Image compositor: crops/scales the screen to fill the canvas, then
/// composites a shaped, optionally bordered & shadowed camera over it.
/// Works identically in AVPlayer preview and AVAssetExportSession export.
final class StudioCompositor: NSObject, AVVideoCompositing {
    private static let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext()
    }()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction
                    as? StudioCompositionInstruction,
                  let dst = request.renderContext.newPixelBuffer() else {
                request.finish(with: CompositorError.noFrame)
                return
            }
            let layout = instruction.layout

            guard let screenBuf = request.sourceFrame(byTrackID: layout.screenTrackID) else {
                request.finish(with: CompositorError.noFrame)
                return
            }
            var output = screenCanvasImage(screenBuf, layout: layout)

            if let cameraID = layout.cameraTrackID,
               let cameraBuf = request.sourceFrame(byTrackID: cameraID),
               let camera = cameraImage(cameraBuf, layout: layout, instruction: instruction) {
                output = camera.composited(over: output)
            }

            let now = request.compositionTime.seconds
            // Click rings sit under the cursor; both above screen + camera.
            if layout.clickFeedback {
                for ring in clickRings(at: now, layout: layout, overlay: instruction.overlay) {
                    output = ring.composited(over: output)
                }
            }
            if layout.showCursor, let cursor = cursorImage(at: now, layout: layout,
                                                           overlay: instruction.overlay) {
                output = cursor.composited(over: output)
            }

            output = output.cropped(to: CGRect(origin: .zero, size: layout.canvas))
            Self.ciContext.render(output, to: dst, bounds: output.extent,
                                  colorSpace: colorSpace)
            request.finish(withComposedVideoFrame: dst)
        }
    }

    // MARK: - Frame building

    private func screenCanvasImage(_ buffer: CVPixelBuffer,
                                   layout: CompositorLayout) -> CIImage {
        let image = CIImage(cvPixelBuffer: buffer)
        let crop = layout.screenCrop ?? CGRect(origin: .zero, size: layout.sourceSize)
        guard crop.width > 0 else { return image }
        let cropCI = Self.flip(crop, in: layout.sourceSize.height)
        let scale = layout.canvas.width / crop.width
        let t = CGAffineTransform(translationX: -cropCI.minX, y: -cropCI.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        return image.cropped(to: cropCI).transformed(by: t)
            .cropped(to: CGRect(origin: .zero, size: layout.canvas))
    }

    private func cameraImage(_ buffer: CVPixelBuffer, layout: CompositorLayout,
                             instruction: StudioCompositionInstruction) -> CIImage? {
        guard layout.feedCrop.width > 0, layout.pip.width > 0,
              let mask = instruction.maskImage else { return nil }
        var image = CIImage(cvPixelBuffer: buffer)
        // Orient the raw feed first (clockwise quarter turns), then re-anchor its
        // extent at the origin so all downstream crop/scale runs in oriented space.
        if layout.cameraQuarterTurns != 0 {
            let angle = -CGFloat(layout.cameraQuarterTurns) * .pi / 2
            let rotated = image.transformed(by: CGAffineTransform(rotationAngle: angle))
            image = rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.minX,
                                                              y: -rotated.extent.minY))
        }
        let cropCI = Self.flip(layout.feedCrop, in: layout.feedSize.height)
        let sx = layout.pip.width / layout.feedCrop.width
        let sy = layout.pip.height / layout.feedCrop.height
        let toLocal = CGAffineTransform(translationX: -cropCI.minX, y: -cropCI.minY)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
        let local = image.cropped(to: cropCI).transformed(by: toLocal)
            .cropped(to: CGRect(origin: .zero, size: layout.pip.size))

        // Clip the camera to the frame shape.
        var styled = local.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ]).cropped(to: CGRect(origin: .zero, size: layout.pip.size))

        if let border = instruction.borderImage {
            styled = border.composited(over: styled)
        }
        if let shadow = instruction.shadowImage {
            styled = styled.composited(over: shadow)
        }

        // Move the PiP-local group into the canvas at the PiP position.
        let pipCI = Self.flip(layout.pip, in: layout.canvas.height)
        return styled.transformed(by: CGAffineTransform(translationX: pipCI.minX,
                                                        y: pipCI.minY))
    }

    // MARK: - Cursor / click overlays

    /// Screen-source pixel point → canvas pixel point (top-left origin), using
    /// the same crop/scale the screen image gets.
    private static func sourceToCanvas(_ p: CGPoint, layout: CompositorLayout) -> CGPoint {
        let crop = layout.screenCrop ?? CGRect(origin: .zero, size: layout.sourceSize)
        guard crop.width > 0, crop.height > 0 else { return p }
        let sx = layout.canvas.width / crop.width
        let sy = layout.canvas.height / crop.height
        return CGPoint(x: (p.x - crop.minX) * sx, y: (p.y - crop.minY) * sy)
    }

    /// Canvas pixels per screen point (glyph sizing).
    private static func cursorScale(_ layout: CompositorLayout) -> CGFloat {
        let crop = layout.screenCrop ?? CGRect(origin: .zero, size: layout.sourceSize)
        guard crop.width > 0 else { return layout.sourcePerPoint }
        return (layout.canvas.width / crop.width) * layout.sourcePerPoint
    }

    private func cursorImage(at now: Double, layout: CompositorLayout,
                             overlay: OverlayPayload) -> CIImage? {
        guard let (srcP, name) = CursorOverlay.position(at: now, in: overlay.cursorSamples) else {
            return nil
        }
        guard let glyph = overlay.glyphs[name] ?? overlay.glyphs["arrow"],
              glyph.pixelSize.width > 0 else { return nil }
        let scale = Self.cursorScale(layout)
        // Glyph point-size → canvas px, applied to its rendered pixel image.
        let s = (glyph.pointSize.width * scale) / glyph.pixelSize.width
        let canvasP = Self.sourceToCanvas(srcP, layout: layout)
        // Place the hotspot (points, top-left) at canvasP (top-left).
        let topLeftX = canvasP.x - glyph.hotspot.x * scale
        let topLeftY = canvasP.y - glyph.hotspot.y * scale
        let drawnH = glyph.pixelSize.height * s
        // Top-left → CI bottom-left.
        let tx = topLeftX
        let ty = layout.canvas.height - topLeftY - drawnH
        return glyph.image
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))
    }

    /// One faded/scaled ring per click still inside its lifetime window.
    private func clickRings(at now: Double, layout: CompositorLayout,
                            overlay: OverlayPayload) -> [CIImage] {
        guard let ring = overlay.ring, overlay.ringPixelSize.width > 0 else { return [] }
        let maxRadius = layout.canvas.width * 0.035
        var out: [CIImage] = []
        for c in overlay.clickSamples {
            let dt = now - c.t
            guard dt >= 0, dt <= CursorOverlay.ringDuration else { continue }
            let p = dt / CursorOverlay.ringDuration            // 0…1
            let radius = maxRadius * (0.25 + 0.75 * p)          // expands
            let alpha = 1.0 - p                                 // fades out
            let s = (radius * 2) / overlay.ringPixelSize.width
            let faded = ring.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha)),
            ])
            let canvasP = Self.sourceToCanvas(c.p, layout: layout)
            let drawn = radius * 2
            let tx = canvasP.x - drawn / 2
            let ty = layout.canvas.height - canvasP.y - drawn / 2
            out.append(faded
                .transformed(by: CGAffineTransform(scaleX: s, y: s))
                .transformed(by: CGAffineTransform(translationX: tx, y: ty)))
        }
        return out
    }

    /// Top-left rect → Core Image bottom-left rect, given the container height.
    private static func flip(_ r: CGRect, in height: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    enum CompositorError: Error { case noFrame }
}
