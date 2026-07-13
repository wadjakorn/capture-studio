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
    /// Fit/letterbox placement of the whole source in canvas px (top-left), at
    /// the current zoom/pan, for the "9:16 with template" aspect. nil = cover /
    /// crop placement (`screenCrop`). When set, `screenCrop` is nil.
    var screenFit: CGRect?
    /// Background fill behind the fitted video (only meaningful when `screenFit`
    /// is set / bars exist). `.image` uses `OverlayPayload.backgroundImage`.
    var background: CanvasBackground = .black
    /// Blur radius in canvas pixels for `background == .blur`.
    var backgroundBlurRadius: CGFloat = 0

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
    /// Corner radius / border width as fractions (0–1) of half-min-side / PiP
    /// width. Resolved to pixels against the current PiP size, so they stay
    /// correct when a breakpoint animates the camera scale.
    var cornerRadiusFrac: CGFloat = 0
    var borderWidthFrac: CGFloat = 0
    var borderColor: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    var shadow: Bool = false
    /// Shadow intensity 0–1 (scales blur/offset/opacity together).
    var shadowRadius: CGFloat = 0.5
    /// When set, the camera PiP rect + opacity are evaluated per frame from
    /// breakpoints instead of the static `pip`. nil = static placement.
    var cameraTimeline: CameraTimelineSpec?
    /// When set, the frame layout (main / camera arrangement) is evaluated per
    /// frame from the layout blocks. nil = the legacy main+float composition.
    var layoutTimeline: LayoutTimelineSpec?

    /// On-screen text/caption blocks (rendered topmost). nil / empty = none.
    var textTimeline: TextTimelineSpec?
    /// A text block being edited or dragged live on the canvas, suppressed in
    /// the composited preview so the moving SwiftUI overlay isn't doubled by a
    /// stale baked copy. nil = render all active.
    var suppressedTextBlockID: UUID?
    /// Shape overlays (rectangle / ellipse / blur), rendered below subtitles and
    /// text but above the screen / camera / cursor so a blur censors those.
    /// nil / empty = none.
    var shapeTimeline: ShapeTimelineSpec?
    /// A shape block being dragged / resized live on the canvas, suppressed in
    /// the composited preview so the moving SwiftUI overlay isn't doubled by a
    /// stale baked copy. nil = render all active.
    var suppressedShapeBlockID: UUID?
    /// Subtitle cues (rendered below text blocks). nil / empty = none.
    var subtitles: SubtitleTimelineSpec?

    /// Framing window in canvas pixels (top-left). When set, the main-video
    /// group (screen + click rings + cursor) is masked to this rect and the
    /// background fill shows outside it; camera / subtitles / text are never
    /// clipped. nil = no framing.
    var screenFrame: CGRect?

    // Cursor / click overlays (composited from events.jsonl).
    var showCursor: Bool = false
    var clickFeedback: Bool = false
    /// Source pixels per screen point (sourceSize.width / display.pointWidth);
    /// used with the screen crop scale to size the cursor glyph in canvas px.
    var sourcePerPoint: CGFloat = 1
}

/// Per-frame camera animation: the transition blocks plus the home placement
/// they ease from.
struct CameraTimelineSpec {
    var blocks: [CameraBlock]
    var home: CameraSample
}

/// Per-frame frame-layout selection: the layout blocks plus the home layout that
/// applies when there are no blocks. Uncovered gaps (blocks present but none
/// covering the frame) render blank (black).
struct LayoutTimelineSpec {
    var blocks: [LayoutBlock]
    var home: CameraLayout
}

/// The on-screen text/caption blocks for a composition. Array order is the
/// z-order (later draws on top); the compositor renders all blocks active at the
/// frame time.
struct TextTimelineSpec {
    var blocks: [TextBlock]
}

/// The on-screen shape overlays for a composition. Array order is the z-order
/// (later draws on top); the compositor renders all blocks active at the frame
/// time, below subtitles / text.
struct ShapeTimelineSpec {
    var blocks: [ShapeBlock]
}

/// The subtitle cues + shared style for a composition. Cues are read-only; the
/// compositor renders all cues active at the frame time, beneath the text blocks
/// (so manual annotations sit on top).
struct SubtitleTimelineSpec {
    var style: SubtitleStyle
    var cues: [SubtitleCue]
}

/// Frame-shape mask, optional border ring, and drop shadow for a camera PiP —
/// all in PiP-local pixel space at a specific size. Rebuilt when the PiP size
/// changes (the timeline path can animate the camera scale frame to frame).
struct CameraDecorations {
    let mask: CIImage?
    let border: CIImage?
    let shadow: CIImage?

    static func build(pipSize: CGSize, shape: CameraShape,
                      cornerRadiusPx: CGFloat, borderWidthPx: CGFloat,
                      borderColor: CGColor, shadow: Bool,
                      shadowRadius: CGFloat) -> CameraDecorations {
        let radius = effectiveRadius(pipSize: pipSize, shape: shape, cornerRadiusPx: cornerRadiusPx)
        let mask = makeMask(pipSize: pipSize, radius: radius)
        let border = makeBorder(pipSize: pipSize, radius: radius,
                                widthPx: borderWidthPx, color: borderColor)
        let shadowImage = shadow ? makeShadow(pipSize: pipSize, mask: mask,
                                              intensity: shadowRadius) : nil
        return CameraDecorations(mask: mask, border: border, shadow: shadowImage)
    }

    private static func effectiveRadius(pipSize: CGSize, shape: CameraShape,
                                        cornerRadiusPx: CGFloat) -> CGFloat {
        switch shape {
        case .circle: return min(pipSize.width, pipSize.height) / 2
        case .rectangle: return cornerRadiusPx
        }
    }

    private static func makeMask(pipSize: CGSize, radius: CGFloat) -> CIImage? {
        guard pipSize.width > 1, pipSize.height > 1,
              let ctx = makeContext(size: pipSize) else { return nil }
        let rect = CGRect(origin: .zero, size: pipSize)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                           cornerHeight: radius, transform: nil))
        ctx.fillPath()
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    private static func makeBorder(pipSize: CGSize, radius: CGFloat,
                                   widthPx: CGFloat, color: CGColor) -> CIImage? {
        guard widthPx > 0.5, pipSize.width > 1, pipSize.height > 1,
              let ctx = makeContext(size: pipSize) else { return nil }
        let rect = CGRect(origin: .zero, size: pipSize).insetBy(dx: widthPx / 2, dy: widthPx / 2)
        let r = max(0, radius - widthPx / 2)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(widthPx)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.strokePath()
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    private static func makeShadow(pipSize: CGSize, mask: CIImage?,
                                   intensity: CGFloat) -> CIImage? {
        guard let mask else { return nil }
        // Scale blur / offset / opacity together by the intensity. Tuned so
        // 0.5 reads clearly and 1.0 is a strong soft drop shadow.
        let r = max(0, min(1, intensity))
        let blur = max(2, pipSize.width * (0.04 + 0.12 * r))
        let offsetY = -max(2, pipSize.height * (0.02 + 0.06 * r)) // down in CI space
        let alpha = 0.35 + 0.4 * r
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

    private static func makeContext(size: CGSize) -> CGContext? {
        CGContext(data: nil,
                  width: Int(size.width.rounded()),
                  height: Int(size.height.rounded()),
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
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
    /// Pre-built auto-zoom track (screen-source focus + magnification per time).
    /// Empty = no auto zoom/pan. Interpolated per frame; see `AutoZoomTrack`.
    var autoZoom: [ZoomKeyframe] = []
    /// Cursor name → glyph; falls back to "arrow".
    var glyphs: [String: CursorGlyph] = [:]
    /// Click ring image (square, centered circle stroke), origin (0,0).
    var ring: CIImage?
    var ringPixelSize: CGSize = .zero
    /// Uploaded canvas-background photo (origin (0,0), y-up), for
    /// `CompositorLayout.background == .image`. nil = fall back to black.
    var backgroundImage: CIImage?
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

    /// Mask / border / shadow for the static PiP size, built once. The timeline
    /// path bypasses this and builds decorations per frame (the PiP can resize).
    private(set) lazy var decorations: CameraDecorations = CameraDecorations.build(
        pipSize: layout.pip.size, shape: layout.shape,
        cornerRadiusPx: layout.cornerRadiusFrac * min(layout.pip.width, layout.pip.height) / 2,
        borderWidthPx: layout.borderWidthFrac * layout.pip.width,
        borderColor: layout.borderColor, shadow: layout.shadow,
        shadowRadius: layout.shadowRadius)

    init(timeRange: CMTimeRange, layout: CompositorLayout,
         overlay: OverlayPayload = OverlayPayload()) {
        self.timeRange = timeRange
        self.layout = layout
        self.overlay = overlay
        var ids: [NSValue] = [NSNumber(value: layout.screenTrackID)]
        if let cam = layout.cameraTrackID { ids.append(NSNumber(value: cam)) }
        self.requiredSourceTrackIDs = ids
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

    /// Last per-frame camera decorations, keyed by integer PiP size. The size
    /// is constant while a segment holds, so this hits every frame except
    /// during a scale-animating transition.
    private var cachedDecorationsSize: CGSize = .zero
    private var cachedDecorations: CameraDecorations?
    private let decorationsLock = NSLock()

    /// Rendered text images keyed by content+style+canvas (position excluded, so
    /// a moved block reuses its render). A held caption renders once.
    private var textCache: [TextCacheKey: CIImage] = [:]
    private let textCacheLock = NSLock()

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
            let now = request.compositionTime.seconds

            // Resolve auto-zoom for this frame (identity when scale == 1).
            let zoom = AutoZoomTrack.sample(at: now, track: instruction.overlay.autoZoom)
            let focusCanvas = Self.sourceToCanvas(zoom.focus, layout: layout)
            let canvasRect = CGRect(origin: .zero, size: layout.canvas)
            // The zoom recenters the focus (cursor) onto the region centre so it
            // sits in the middle of what the viewer watches — the framing window
            // (else the whole canvas). The region is the SAME in both modes; only
            // the clamp differs:
            //  - contained (default): the pan is clamped so the video always covers
            //    the region — no empty edge inside it.
            //  - overflow: the pan is unclamped — the video may pan past the region
            //    edge and the background shows INSIDE the region where it stops.
            // Either way the main video is hard-clipped to the framing window and
            // never draws outside it. The recenter is blended by `zoom.weight` so it
            // ramps with the scale.
            let region = layout.screenFrame ?? canvasRect
            let content = layout.screenFit ?? canvasRect      // where the source sits pre-zoom
            let targetCanvas = Self.recenterTarget(focus: focusCanvas, weight: zoom.weight,
                                                   scale: zoom.scale, content: content,
                                                   region: region, clamp: !zoom.overflow)
            func zoomed(_ img: CIImage) -> CIImage {
                Self.magnify(img, scale: zoom.scale, focusCanvas: focusCanvas,
                             targetCanvas: targetCanvas, canvas: layout.canvas)
            }
            // Hard-clip every main-video layer (screen, click rings, cursor) to the
            // framing window in ALL modes — the window is a fixed peephole, never
            // skipped by overflow. Background shows wherever the clipped video
            // doesn't cover (letterbox bars, or overflow gaps at the window edge).
            // nil = no framing window → no clip (only the canvas crop at the end).
            // CI bottom-left space.
            let frameCI: CGRect? = layout.screenFrame.map { Self.flip($0, in: layout.canvas.height) }
            func framed(_ img: CIImage) -> CIImage {
                guard let frameCI else { return img }
                return img.cropped(to: frameCI)
            }

            // Camera placement (position/scale) from the camera move timeline.
            let camSample: CameraSample? = layout.cameraTimeline.map {
                CameraTimeline.sample(at: now, blocks: $0.blocks, home: $0.home)
            }
            // Frame layout from the layout timeline: a covering block's layout,
            // else the home layout when there are no blocks, else a blank gap
            // (blocks exist but none covers this frame → solid black).
            let frameLayout: CameraLayout
            let blankGap: Bool
            if let spec = layout.layoutTimeline {
                if let covered = LayoutTimeline.sample(at: now, blocks: spec.blocks) {
                    frameLayout = covered; blankGap = false
                } else if spec.blocks.isEmpty {
                    frameLayout = spec.home; blankGap = false
                } else {
                    frameLayout = .mainOnly; blankGap = true
                }
            } else {
                frameLayout = .mainAndFloat; blankGap = false
            }

            // Base: solid black for a gap; the main video for layouts that include
            // it; else the background fill (camera-only layouts suppress the screen).
            var output: CIImage
            if blankGap {
                output = CIImage(color: .black)
                    .cropped(to: CGRect(origin: .zero, size: layout.canvas))
            } else if frameLayout.showsMainVideo {
                // Place the full source, apply the zoom, clip to the framing window,
                // then composite over the background. The screen carries only the
                // real source pixels (transparent elsewhere), so the background
                // shows through the letterbox bars, outside the frame, and in any
                // overflow gap the pan opens at the frame edge — all in one step.
                let screen = zoomed(screenCanvasImage(screenBuf, layout: layout))
                let bg = backgroundFill(video: CIImage(cvPixelBuffer: screenBuf),
                                        layout: layout,
                                        image: instruction.overlay.backgroundImage)
                output = framed(screen).composited(over: bg)
            } else {
                output = backgroundFill(video: CIImage(cvPixelBuffer: screenBuf),
                                        layout: layout,
                                        image: instruction.overlay.backgroundImage)
            }

            if !blankGap, frameLayout.showsCamera, let cameraID = layout.cameraTrackID,
               let cameraBuf = request.sourceFrame(byTrackID: cameraID),
               let camera = cameraImage(cameraBuf, sample: camSample, frameLayout: frameLayout,
                                        layout: layout, instruction: instruction) {
                output = camera.composited(over: output)   // camera is NOT zoomed
            }

            // Click rings + cursor belong to the screen — only when it's shown.
            if !blankGap, frameLayout.showsMainVideo {
                // Click rings sit under the cursor; both ride the screen zoom.
                if layout.clickFeedback {
                    for ring in clickRings(at: now, layout: layout, overlay: instruction.overlay) {
                        output = framed(zoomed(ring)).composited(over: output)
                    }
                }
                if layout.showCursor, let cursor = cursorImage(at: now, layout: layout,
                                                               overlay: instruction.overlay) {
                    output = framed(zoomed(cursor)).composited(over: output)
                }
            }

            // Shape overlays sit above the screen/camera/cursor (so a blur
            // censors them) but below subtitles and text. All blocks active at
            // `now`, in array (z) order, except the one being edited live.
            if let spec = layout.shapeTimeline {
                for block in ShapeTimeline.active(at: now, blocks: spec.blocks)
                where block.id != layout.suppressedShapeBlockID {
                    output = Self.applyShape(block, to: output, canvas: layout.canvas)
                }
            }

            // Subtitles sit above cursor/camera but below manual text blocks.
            if let sub = layout.subtitles {
                for cue in SubtitleTimeline.active(at: now, cues: sub.cues) {
                    let block = sub.style.asTextBlock(id: cue.id, begin: cue.begin,
                                                      end: cue.end, text: cue.text)
                    if let img = textImage(block, canvas: layout.canvas) {
                        output = img.composited(over: output)
                    }
                }
            }

            // Text/captions sit topmost. All blocks active at `now`, in array
            // (z) order, except the one being edited live on the canvas.
            if let spec = layout.textTimeline {
                for block in TextTimeline.active(at: now, blocks: spec.blocks)
                where block.id != layout.suppressedTextBlockID {
                    if let text = textImage(block, canvas: layout.canvas) {
                        output = text.composited(over: output)
                    }
                }
            }

            output = output.cropped(to: CGRect(origin: .zero, size: layout.canvas))
            Self.ciContext.render(output, to: dst, bounds: output.extent,
                                  colorSpace: colorSpace)
            request.finish(withComposedVideoFrame: dst)
        }
    }

    // MARK: - Frame building

    /// Place the source onto the canvas at the manual reframe (fit letterbox or
    /// cover crop) WITHOUT discarding the out-of-frame source. The transform only
    /// positions/scales the full source; nothing is cropped here. The caller adds
    /// the auto-zoom magnify, then clips to the framing window and composites over
    /// the background. Keeping the whole source live is what lets the zoom pan
    /// slide previously-cut source area back into the frame (defect #2) — the
    /// reframe positions the source, the zoom crops/zooms within it. Pixels the
    /// zoom leaves outside the frame are transparent, so the background shows
    /// through there.
    private func screenCanvasImage(_ buffer: CVPixelBuffer, layout: CompositorLayout) -> CIImage {
        let image = CIImage(cvPixelBuffer: buffer)
        if let place = layout.screenFit {
            // Contain (letterbox) the whole source at the fit placement.
            guard place.width > 0, layout.sourceSize.width > 0 else { return image }
            let s = place.width / layout.sourceSize.width
            let ty = layout.canvas.height - place.maxY    // top-left → CI bottom-left
            return image.transformed(by: CGAffineTransform(scaleX: s, y: s)
                .concatenating(CGAffineTransform(translationX: place.minX, y: ty)))
        }
        // Cover: scale so the reframe crop fills the canvas and shift its origin to
        // 0 — but apply the transform to the FULL source (no `.cropped(to: crop)`),
        // so the pixels outside the crop stay available for the zoom pan to reveal.
        let crop = layout.screenCrop ?? CGRect(origin: .zero, size: layout.sourceSize)
        guard crop.width > 0 else { return image }
        let cropCI = Self.flip(crop, in: layout.sourceSize.height)
        let scale = layout.canvas.width / crop.width
        let t = CGAffineTransform(translationX: -cropCI.minX, y: -cropCI.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        return image.transformed(by: t)
    }

    /// Opaque full-canvas background fill behind the fitted video (the letterbox
    /// bars): solid black, the main video blurred to cover, or the uploaded photo
    /// cover-filled. All centered and cropped to the canvas.
    private func backgroundFill(video: CIImage, layout: CompositorLayout,
                                image: CIImage?) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: layout.canvas)
        let black = CIImage(color: .black).cropped(to: canvasRect)
        switch layout.background {
        case .black:
            return black
        case .blur:
            let fill = CropMath.aspectFillRect(layout.sourceSize, in: layout.canvas)
            guard fill.width > 0, layout.sourceSize.width > 0 else { return black }
            let s = fill.width / layout.sourceSize.width
            let covered = video.transformed(by: CGAffineTransform(scaleX: s, y: s)
                .concatenating(CGAffineTransform(translationX: fill.minX, y: fill.minY)))
            return covered.clampedToExtent()
                .applyingFilter("CIGaussianBlur",
                                parameters: [kCIInputRadiusKey: layout.backgroundBlurRadius])
                .cropped(to: canvasRect)
        case .image:
            guard let image, image.extent.width > 0 else { return black }
            let fill = CropMath.aspectFillRect(image.extent.size, in: layout.canvas)
            let s = fill.width / image.extent.width
            let covered = image.transformed(by: CGAffineTransform(scaleX: s, y: s)
                .concatenating(CGAffineTransform(translationX: fill.minX - image.extent.minX * s,
                                                 y: fill.minY - image.extent.minY * s)))
            // Over black so any transparent pixels still read as a filled bg.
            return covered.cropped(to: canvasRect).composited(over: black)
        }
    }

    private func cameraImage(_ buffer: CVPixelBuffer, sample: CameraSample?,
                             frameLayout: CameraLayout = .mainAndFloat,
                             layout: CompositorLayout,
                             instruction: StudioCompositionInstruction) -> CIImage? {
        let pip: CGRect
        let decorations: CameraDecorations
        let opacity: CGFloat
        if let sample {
            opacity = CGFloat(sample.opacity)
            guard opacity > 0.001 else { return nil }
            pip = frameLayout == .cameraStatic
                ? Self.staticPip(canvas: layout.canvas, feedCrop: layout.feedCrop)
                : Self.timelinePip(canvas: layout.canvas, feedCrop: layout.feedCrop,
                                   centerX: sample.centerX, centerY: sample.centerY,
                                   scale: sample.scale)
            decorations = self.decorations(for: pip, layout: layout)
        } else {
            pip = layout.pip
            decorations = instruction.decorations
            opacity = 1
        }
        return composeCamera(buffer, layout: layout, pip: pip,
                             decorations: decorations, opacity: opacity)
    }

    /// Static-layout placement: the camera contain-fit into the canvas inset by a
    /// padding margin and centered. Small feeds are enlarged to fill the padded
    /// area (the fit starts from the available width, so any feed scales up).
    private static func staticPip(canvas: CGSize, feedCrop: CGRect) -> CGRect {
        let pad = canvas.width * 0.06
        let availW = max(0, canvas.width - 2 * pad)
        let availH = max(0, canvas.height - 2 * pad)
        let aspect = feedCrop.height > 0 ? feedCrop.width / feedCrop.height : 1
        var w = availW
        var h = aspect > 0 ? w / aspect : w
        if h > availH { h = availH; w = h * aspect }
        return CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2,
                      width: w, height: h)
    }

    private func composeCamera(_ buffer: CVPixelBuffer, layout: CompositorLayout,
                               pip: CGRect, decorations: CameraDecorations,
                               opacity: CGFloat) -> CIImage? {
        guard layout.feedCrop.width > 0, pip.width > 0,
              let mask = decorations.mask else { return nil }
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
        let sx = pip.width / layout.feedCrop.width
        let sy = pip.height / layout.feedCrop.height
        let toLocal = CGAffineTransform(translationX: -cropCI.minX, y: -cropCI.minY)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
        let local = image.cropped(to: cropCI).transformed(by: toLocal)
            .cropped(to: CGRect(origin: .zero, size: pip.size))

        // Clip the camera to the frame shape.
        var styled = local.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ]).cropped(to: CGRect(origin: .zero, size: pip.size))

        if let border = decorations.border {
            styled = border.composited(over: styled)
        }
        if let shadow = decorations.shadow {
            styled = styled.composited(over: shadow)
        }

        // Move the PiP-local group into the canvas at the PiP position.
        let pipCI = Self.flip(pip, in: layout.canvas.height)
        var positioned = styled.transformed(by: CGAffineTransform(translationX: pipCI.minX,
                                                                  y: pipCI.minY))
        // Crossfade for show/hide breakpoints: scale the whole group's alpha.
        if opacity < 0.999 {
            positioned = positioned.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
            ])
        }
        return positioned
    }

    /// PiP rect from a sampled camera state — mirrors `StudioModel.pipRect`, so
    /// preview and export place the animated camera identically.
    private static func timelinePip(canvas: CGSize, feedCrop: CGRect,
                                    centerX: Double, centerY: Double,
                                    scale: Double) -> CGRect {
        let width = canvas.width * CGFloat(scale)
        let aspect = feedCrop.height > 0 ? feedCrop.width / feedCrop.height : 1
        let height = aspect > 0 ? width / aspect : width
        return CGRect(x: CGFloat(centerX) * canvas.width - width / 2,
                      y: CGFloat(centerY) * canvas.height - height / 2,
                      width: width, height: height)
    }

    /// Decorations for a per-frame PiP size, reusing the last build when the
    /// size is unchanged (a held segment).
    private func decorations(for pip: CGRect, layout: CompositorLayout) -> CameraDecorations {
        let key = CGSize(width: pip.width.rounded(), height: pip.height.rounded())
        decorationsLock.lock()
        defer { decorationsLock.unlock() }
        if key == cachedDecorationsSize, let cached = cachedDecorations {
            return cached
        }
        let minSide = min(pip.width, pip.height)
        let built = CameraDecorations.build(
            pipSize: pip.size, shape: layout.shape,
            cornerRadiusPx: layout.cornerRadiusFrac * minSide / 2,
            borderWidthPx: layout.borderWidthFrac * pip.width,
            borderColor: layout.borderColor, shadow: layout.shadow,
            shadowRadius: layout.shadowRadius)
        cachedDecorationsSize = key
        cachedDecorations = built
        return built
    }

    // MARK: - Cursor / click overlays

    /// The uniform scale + top-left origin (canvas px) the full source maps into,
    /// for either fit (letterbox) or cover (crop) placement. Cursor/click
    /// overlays ride this so they land on the screen content, not the raw canvas.
    private static func screenPlacement(_ layout: CompositorLayout) -> (scale: CGFloat, origin: CGPoint) {
        if let place = layout.screenFit {
            let s = layout.sourceSize.width > 0 ? place.width / layout.sourceSize.width : 1
            return (s, place.origin)
        }
        let crop = layout.screenCrop ?? CGRect(origin: .zero, size: layout.sourceSize)
        let s = crop.width > 0 ? layout.canvas.width / crop.width : 1
        return (s, CGPoint(x: -crop.minX * s, y: -crop.minY * s))
    }

    /// Screen-source pixel point → canvas pixel point (top-left origin), using
    /// the same scale/offset the screen image gets.
    private static func sourceToCanvas(_ p: CGPoint, layout: CompositorLayout) -> CGPoint {
        let pl = screenPlacement(layout)
        return CGPoint(x: pl.origin.x + p.x * pl.scale, y: pl.origin.y + p.y * pl.scale)
    }

    /// Where the focus point should land on the canvas after the zoom. The focus
    /// eases toward `region`'s centre by `weight` (0 = stay on the focus, i.e. an
    /// in-place zoom; 1 = fully centred). When `clamp` is set the target is bounded
    /// so the scaled `content` rect still fully covers `region` — the video never
    /// pulls away from the region edge, so no background shows inside it. With
    /// `clamp` off the target is free, letting the video pan past the edge and
    /// reveal the background. All rects/points are canvas top-left space; pure and
    /// unit-tested (no Core Image).
    static func recenterTarget(focus: CGPoint, weight: CGFloat, scale: CGFloat,
                               content: CGRect, region: CGRect, clamp: Bool) -> CGPoint {
        let centre = CGPoint(x: region.midX, y: region.midY)
        var target = CGPoint(x: focus.x + (centre.x - focus.x) * weight,
                             y: focus.y + (centre.y - focus.y) * weight)
        guard clamp else { return target }
        // Cover constraint per axis: content.min·scale-mapped ≤ region.min and
        // content.max·scale-mapped ≥ region.max. Solving for the target gives a
        // [lower, upper] band; if the scaled content is too small to cover the
        // region the band inverts → fall back to the band midpoint, which centres
        // the content in the region (best coverage when it can't fully cover).
        // Using the midpoint rather than the region centre keeps the target
        // CONTINUOUS across the inversion boundary: as scale falls to the exact
        // covering scale, lower→upper→midpoint == the clamped band edge, so the
        // auto zoom-out eases smoothly instead of snapping when the scaled content
        // shrinks below covering the region (the "weird jump", clamp/overflow-off
        // only).
        func bound(_ t: CGFloat, _ f: CGFloat, _ cMin: CGFloat, _ cMax: CGFloat,
                   _ rMin: CGFloat, _ rMax: CGFloat) -> CGFloat {
            let lower = rMax - scale * (cMax - f)
            let upper = rMin - scale * (cMin - f)
            return lower <= upper ? min(max(t, lower), upper) : (lower + upper) / 2
        }
        target.x = bound(target.x, focus.x, content.minX, content.maxX,
                         region.minX, region.maxX)
        target.y = bound(target.y, focus.y, content.minY, content.maxY,
                         region.minY, region.maxY)
        return target
    }

    /// Magnify an already-placed canvas-space image by `scale`, mapping the
    /// `focusCanvas` point onto `targetCanvas` (both top-left origin). The result
    /// satisfies `out(p) = target + scale·(p − focus)`, so the focus lands on the
    /// target at the given zoom. Passing `target == focus` gives an in-place zoom
    /// (fixed point). Identity when `scale <= 1`. Used to apply auto-zoom to the
    /// screen + cursor + click layers (camera/text are not passed through this,
    /// so they stay fixed).
    private static func magnify(_ image: CIImage, scale: CGFloat,
                                focusCanvas: CGPoint, targetCanvas: CGPoint,
                                canvas: CGSize) -> CIImage {
        guard scale > 1.0001 else { return image }
        let fx = focusCanvas.x
        let fy = canvas.height - focusCanvas.y          // top-left → CI bottom-left
        let tx = targetCanvas.x
        let ty = canvas.height - targetCanvas.y
        let t = CGAffineTransform(translationX: -fx, y: -fy)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
        return image.transformed(by: t)
    }

    /// Canvas pixels per screen point (glyph sizing).
    private static func cursorScale(_ layout: CompositorLayout) -> CGFloat {
        screenPlacement(layout).scale * layout.sourcePerPoint
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

    // MARK: - Text / caption overlays

    /// Cache identity for a rendered text image: everything that affects the
    /// pixels (content + style + canvas), but NOT position — a moved block keeps
    /// its render. Begin/end and id are irrelevant to the pixels.
    // Internal (not private) so a unit test can assert the key distinguishes
    // every pixel-affecting field. Nested in the compositor as an impl detail.
    struct TextCacheKey: Hashable {
        let text: String
        let fontName: String
        let fontSize: Double
        let fontWeight: TextWeight
        let colorHex: String
        let alignment: TextAlignmentH
        let boxEnabled: Bool
        let boxHex: String
        let boxOpacity: Double
        let strokeWidth: Double
        let strokeHex: String
        let shadow: Bool
        // Wrapping affects the rendered pixels, so it must be part of the key —
        // omitting these returns a stale image when the wrap box is resized or
        // auto-wrap is toggled.
        let boxWidth: Double
        let autoWrap: Bool
        let canvasW: Double
        let canvasH: Double

        init(_ b: TextBlock, canvas: CGSize) {
            text = b.text; fontName = b.fontName; fontSize = b.fontSize
            fontWeight = b.fontWeight; colorHex = b.colorHex; alignment = b.alignment
            boxEnabled = b.boxEnabled; boxHex = b.boxHex; boxOpacity = b.boxOpacity
            strokeWidth = b.strokeWidth; strokeHex = b.strokeHex; shadow = b.shadow
            boxWidth = b.boxWidth; autoWrap = b.autoWrap
            canvasW = canvas.width; canvasH = canvas.height
        }
    }

    /// Rendered, positioned text image for a block, or nil if it has no visible
    /// content. The render (content/style/canvas) is cached; the position
    /// transform is applied per call.
    private func textImage(_ block: TextBlock, canvas: CGSize) -> CIImage? {
        guard !block.text.isEmpty, canvas.width > 1, canvas.height > 1 else { return nil }
        let key = TextCacheKey(block, canvas: canvas)

        let base: CIImage
        textCacheLock.lock()
        if let cached = textCache[key] {
            base = cached
            textCacheLock.unlock()
        } else {
            textCacheLock.unlock()
            guard let cg = TextImageRenderer.image(block, canvas: canvas) else { return nil }
            let rendered = CIImage(cgImage: cg)
            textCacheLock.lock()
            if textCache.count > 64 { textCache.removeAll() }   // bound memory
            textCache[key] = rendered
            base = rendered
            textCacheLock.unlock()
        }

        // Center the image at (centerX, centerY) in top-left canvas coords, then
        // map to Core Image's bottom-left space (cursor/click use the same flip).
        let w = base.extent.width, h = base.extent.height
        let topLeftX = CGFloat(block.centerX) * canvas.width - w / 2
        let topLeftY = CGFloat(block.centerY) * canvas.height - h / 2
        let tx = topLeftX
        let ty = canvas.height - topLeftY - h
        return base.transformed(by: CGAffineTransform(translationX: tx.rounded(), y: ty.rounded()))
    }

    // MARK: - Shape overlays

    /// Composite one shape block over `output`. Rectangle / ellipse draw a filled
    /// and/or stroked shape; blur replaces its rectangular region with a blurred
    /// or pixellated copy of what's underneath (censoring the screen / camera /
    /// cursor). Geometry is normalized against the canvas so preview and export
    /// match. Returns `output` unchanged if the shape is degenerate.
    private static func applyShape(_ block: ShapeBlock, to output: CIImage,
                                   canvas: CGSize) -> CIImage {
        let w = CGFloat(block.width) * canvas.width
        let h = CGFloat(block.height) * canvas.height
        guard w > 1, h > 1 else { return output }
        let topLeftX = CGFloat(block.centerX) * canvas.width - w / 2
        let topLeftY = CGFloat(block.centerY) * canvas.height - h / 2
        let rectCI = flip(CGRect(x: topLeftX, y: topLeftY, width: w, height: h),
                          in: canvas.height)

        switch block.kind {
        case .blur:
            let region = output.cropped(to: rectCI)
            guard region.extent.width > 0, region.extent.height > 0 else { return output }
            let strength = max(0, CGFloat(block.blurStrength)) * canvas.height
            let processed: CIImage
            switch block.blurStyle {
            case .gaussian:
                processed = region.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, strength)])
                    .cropped(to: rectCI)
            case .pixellate:
                processed = region.clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [
                        kCIInputScaleKey: max(2, strength),
                        kCIInputCenterKey: CIVector(x: rectCI.midX, y: rectCI.midY),
                    ])
                    .cropped(to: rectCI)
            }
            return processed.composited(over: output)
        case .rectangle, .ellipse:
            guard let img = makeShapeImage(block, sizePx: rectCI.size, canvasH: canvas.height)
            else { return output }
            return img.transformed(by: CGAffineTransform(translationX: rectCI.minX.rounded(),
                                                         y: rectCI.minY.rounded()))
                .composited(over: output)
        }
    }

    /// Rasterize a rectangle / ellipse (optional fill + optional stroke) at the
    /// origin, `sizePx` extent. `strokeWidth` / `cornerRadius` resolve to pixels
    /// against the canvas height / shape short side (matching `applyShape`).
    private static func makeShapeImage(_ block: ShapeBlock, sizePx: CGSize,
                                       canvasH: CGFloat) -> CIImage? {
        let w = sizePx.width, h = sizePx.height
        guard w > 1, h > 1, let ctx = makeShapeContext(size: sizePx) else { return nil }
        let strokeWidthPx = CGFloat(block.strokeWidth) * canvasH
        let cornerPx = min(max(0, CGFloat(block.cornerRadius)) * min(w, h), min(w, h) / 2)

        func addPath(_ rect: CGRect, radius: CGFloat) {
            if block.kind == .ellipse {
                ctx.addPath(CGPath(ellipseIn: rect, transform: nil))
            } else {
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil))
            }
        }

        let full = CGRect(x: 0, y: 0, width: w, height: h)
        let fillAlpha = CGFloat(block.fillOpacity)
        if fillAlpha > 0.001, let fill = parseHex(block.fillHex, alpha: fillAlpha) {
            ctx.setFillColor(fill)
            addPath(full, radius: cornerPx)
            ctx.fillPath()
        }
        if strokeWidthPx > 0.5, let stroke = parseHex(block.strokeHex, alpha: 1) {
            let inset = full.insetBy(dx: strokeWidthPx / 2, dy: strokeWidthPx / 2)
            let r = max(0, cornerPx - strokeWidthPx / 2)
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(strokeWidthPx)
            addPath(inset, radius: r)
            ctx.strokePath()
        }
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    private static func makeShapeContext(size: CGSize) -> CGContext? {
        CGContext(data: nil,
                  width: Int(size.width.rounded()),
                  height: Int(size.height.rounded()),
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Parse "#RRGGBB" (or "RRGGBB") into a CGColor at `alpha`; nil on malformed.
    private static func parseHex(_ hex: String, alpha: CGFloat) -> CGColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return CGColor(red: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }

    /// Top-left rect → Core Image bottom-left rect, given the container height.
    private static func flip(_ r: CGRect, in height: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    enum CompositorError: Error { case noFrame }
}
