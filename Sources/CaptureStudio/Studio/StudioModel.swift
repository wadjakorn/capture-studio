import Foundation
import AVFoundation
import AppKit
import CoreImage

/// Loads a bundle, builds the preview composition (screen video + mic audio,
/// offset-aligned on the shared host-clock anchors), and owns trim/export state.
@MainActor
final class StudioModel: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum ExportState: Equatable {
        case idle
        case exporting(Double) // progress 0...1
        case done(URL)
        case failed(String)
    }

    let bundle: ProjectBundle

    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var meta: ProjectMeta?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var duration: Double = 0
    @Published var currentTime: Double = 0
    @Published private(set) var trimIn: Double = 0
    @Published private(set) var trimOut: Double = 0
    @Published private(set) var exportState: ExportState = .idle

    // Camera PiP — center normalized 0–1 in render space, scale = width
    // fraction of screen width. Persisted to edit.json.
    @Published var cameraVisible = true
    @Published var cameraCenterX = 0.85
    @Published var cameraCenterY = 0.82
    @Published var cameraScale = 0.24
    // Camera feed reframe — zoom 1…4 (1 = whole feed), feed center normalized
    // 0–1 in the camera's own space. Persisted to edit.json.
    @Published var cameraZoom = 1.0
    @Published var cameraFeedX = 0.5
    @Published var cameraFeedY = 0.5
    // Camera PiP frame styling. Corner radius / border width are fractions
    // (0–1 of half-min-side / pip width). Persisted to edit.json.
    @Published private(set) var cameraShape: CameraShape = .rectangle
    @Published var cameraCornerRadius = 0.0
    @Published var cameraBorderWidth = 0.0
    @Published var cameraBorderHex = "#FFFFFF"
    @Published var cameraShadow = false
    @Published var cameraShadowRadius = 0.5
    // Camera feed crop aspect — `original` keeps native aspect.
    @Published private(set) var cameraAspect: CameraAspect = .original
    // Camera orientation, degrees clockwise: 0/90/180/270. 90/270 swap w/h.
    @Published private(set) var cameraRotation = 0

    var cameraShown: Bool { cameraVisible && cameraTrackID != nil }
    /// Camera feed size after the 90° orientation step — width/height swapped
    /// at 90/270 so PiP aspect and feed crop track the rotated content.
    var cameraOrientedSize: CGSize? {
        guard let s = cameraNaturalSize else { return nil }
        return (cameraRotation == 90 || cameraRotation == 270)
            ? CGSize(width: s.height, height: s.width) : s
    }
    /// The styled-camera pipeline (custom Core Image compositor) is needed
    /// only when the camera frame is non-rectangular, rounded, bordered, or
    /// shadowed; otherwise the cheap layer-instruction path is used.
    var cameraNeedsCompositor: Bool {
        cameraShown && (cameraShape != .rectangle || cameraCornerRadius > 0
                        || cameraBorderWidth > 0 || cameraShadow
                        || cameraRotation != 0)
    }
    /// Camera feed crop aspect — circle forces 1:1, then an explicit preset,
    /// else the native feed aspect.
    private var cameraFeedAspect: CGFloat {
        if cameraShape == .circle { return 1 }
        if let r = cameraAspect.ratio { return CGFloat(r) }
        guard let s = cameraOrientedSize, s.height > 0 else { return 1 }
        return s.width / s.height
    }

    // Reframe crop — center normalized 0–1 in screen-source space, zoom =
    // fraction of the max-fit crop (1.0 = widest). Persisted to edit.json.
    @Published private(set) var cropAspect: CropAspect = .original
    @Published var cropCenterX = 0.5
    @Published var cropCenterY = 0.5
    @Published var cropZoom = 1.0
    var cropActive: Bool { cropAspect != .original }

    /// Screen master natural size (source space for the crop).
    private(set) var sourceSize: CGSize = .zero
    /// Output canvas: crop output size when reframing, else the source size.
    /// When the custom compositor runs without a crop, the preview canvas is
    /// capped to a 1080-class short side so CI compositing stays smooth;
    /// export still rebuilds at full resolution.
    var renderSize: CGSize {
        if cropActive { return previewCanvasSize }
        if needsCompositor { return Self.cappedPreviewSize(sourceSize) }
        return sourceSize
    }

    /// Scales `size` down so its shorter side is ≤ 1080 (even pixels); leaves
    /// smaller sizes untouched.
    private static func cappedPreviewSize(_ size: CGSize) -> CGSize {
        let shortSide = min(size.width, size.height)
        guard shortSide > 1080 else { return size }
        let scale = 1080 / shortSide
        return CGSize(width: (size.width * scale / 2).rounded() * 2,
                      height: (size.height * scale / 2).rounded() * 2)
    }
    private(set) var cameraNaturalSize: CGSize?
    var hasCameraTrack: Bool { cameraTrackID != nil }
    var hasMicTrack: Bool { micTrackID != nil }
    var hasSystemAudioTrack: Bool { systemTrackID != nil }

    // Per-source volumes. Applied live via AVAudioMix; persisted to edit.json.
    // System is 0–1 (attenuation only). Mic is 0–3: values >1 boost gain for
    // quiet voice (~+9.5 dB at 3.0; may clip loud peaks).
    @Published var micVolume = 1.0
    @Published var systemVolume = 1.0

    // Cursor + click overlays composited from events.jsonl (screen.mp4 has no
    // baked cursor). Cursor defaults on; click feedback off. Persisted to edit.json.
    @Published var showCursor = true
    @Published var clickFeedback = false
    /// Cursor positions / clicks in screen-source pixels (crop-independent).
    private var cursorSamples: [CursorSample] = []
    private var clickSamples: [ClickSample] = []
    /// Cached, canvas-independent overlay glyphs (rendered once at load).
    private var overlayGlyphs: [String: CursorGlyph] = [:]
    private var ringImage: CIImage?
    private var ringPixelSize: CGSize = .zero
    var hasCursorData: Bool { !cursorSamples.isEmpty }
    var hasClickData: Bool { !clickSamples.isEmpty }
    /// The Core Image compositor is needed for a styled camera OR for any active
    /// cursor/click overlay (layer instructions can't draw per-frame motion).
    var needsCompositor: Bool {
        cameraNeedsCompositor
            || (showCursor && hasCursorData)
            || (clickFeedback && hasClickData)
    }

    private var screenTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    private var cameraTrackID: CMPersistentTrackID?
    private var micTrackID: CMPersistentTrackID?
    private var systemTrackID: CMPersistentTrackID?
    private var playerItem: AVPlayerItem?

    private var composition: AVMutableComposition?
    /// Removes the periodic time observer; nonisolated so deinit can call it.
    nonisolated(unsafe) private var observerCleanup: (() -> Void)?

    init(bundleURL: URL) {
        self.bundle = ProjectBundle(url: bundleURL)
    }

    deinit {
        observerCleanup?()
    }

    func load() async {
        guard loadState == .loading else { return }
        Log.studio.info("StudioModel.load: \(self.bundle.url.lastPathComponent, privacy: .public)")
        do {
            guard bundle.isFinalized else {
                Log.studio.error("StudioModel.load failed: bundle not finalized")
                loadState = .failed("Recording is incomplete (no meta.json).")
                return
            }
            let meta = try bundle.loadMeta()
            let built = try await Self.makeComposition(bundle: bundle, meta: meta)
            let item = AVPlayerItem(asset: built.composition)
            let player = AVPlayer(playerItem: item)

            self.meta = meta
            self.composition = built.composition
            self.sourceSize = built.renderSize
            self.screenTrackID = built.screenTrackID
            self.cameraTrackID = built.cameraTrackID
            self.micTrackID = built.micTrackID
            self.systemTrackID = built.systemTrackID
            self.cameraNaturalSize = built.cameraSize
            self.playerItem = item
            self.player = player
            self.duration = built.composition.duration.seconds

            let edit = bundle.loadEdit()
            trimIn = min(max(0, edit.trimIn), duration)
            trimOut = min(edit.trimOut ?? duration, duration)
            if trimOut <= trimIn { trimIn = 0; trimOut = duration }
            cameraVisible = edit.cameraVisible
            cameraCenterX = edit.cameraCenterX
            cameraCenterY = edit.cameraCenterY
            cameraScale = edit.cameraScale
            cameraZoom = min(max(1, edit.cameraZoom), 4)
            cameraFeedX = min(max(0, edit.cameraFeedX), 1)
            cameraFeedY = min(max(0, edit.cameraFeedY), 1)
            cameraShape = edit.cameraShape
            cameraCornerRadius = min(max(0, edit.cameraCornerRadius), 1)
            cameraBorderWidth = min(max(0, edit.cameraBorderWidth), 0.1)
            cameraBorderHex = edit.cameraBorderHex
            cameraShadow = edit.cameraShadow
            cameraShadowRadius = min(max(0, edit.cameraShadowRadius), 1)
            cameraAspect = edit.cameraAspect
            cameraRotation = ((edit.cameraRotation / 90 % 4) + 4) % 4 * 90
            micVolume = min(max(0, edit.micVolume), 3)
            systemVolume = min(max(0, edit.systemVolume), 1)
            showCursor = edit.showCursor
            clickFeedback = edit.clickFeedback
            loadOverlayData(display: meta.display)
            cropAspect = edit.cropAspect
            cropCenterX = min(max(0, edit.cropCenterX), 1)
            cropCenterY = min(max(0, edit.cropCenterY), 1)
            cropZoom = min(max(0.2, edit.cropZoom), 1)
            applyVideoComposition()
            applyAudioMix()

            let token = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 30),
                queue: .main
            ) { [weak self] time in
                Task { @MainActor in self?.currentTime = time.seconds }
            }
            observerCleanup = { player.removeTimeObserver(token) }
            loadState = .ready
            Log.studio.info("StudioModel.load OK: duration=\(self.duration, format: .fixed(precision: 2))s tracks=\(meta.tracks.count)")
        } catch {
            Log.studio.error("StudioModel.load failed: \(error.localizedDescription, privacy: .public)")
            loadState = .failed(error.localizedDescription)
        }
    }

    private struct BuiltComposition {
        let composition: AVMutableComposition
        let renderSize: CGSize
        let screenTrackID: CMPersistentTrackID
        let cameraTrackID: CMPersistentTrackID?
        let micTrackID: CMPersistentTrackID?
        let systemTrackID: CMPersistentTrackID?
        let cameraSize: CGSize?
    }

    /// screen video at t=0; camera video, mic and system audio inserted at
    /// their host-clock offsets. Camera renders as PiP via the video composition.
    private static func makeComposition(bundle: ProjectBundle,
                                        meta: ProjectMeta) async throws -> BuiltComposition {
        guard let screenInfo = meta.tracks.first(where: { $0.type == .screen }) else {
            throw NSError(domain: "CaptureStudio", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Bundle has no screen track."
            ])
        }
        let composition = AVMutableComposition()
        var renderSize = CGSize(width: 1920, height: 1080)
        var screenTrackID = kCMPersistentTrackID_Invalid
        var cameraTrackID: CMPersistentTrackID?
        var micTrackID: CMPersistentTrackID?
        var systemTrackID: CMPersistentTrackID?
        var cameraSize: CGSize?

        let screenAsset = AVURLAsset(url: bundle.screenURL)
        let screenDuration = try await screenAsset.load(.duration)
        if let videoTrack = try await screenAsset.loadTracks(withMediaType: .video).first,
           let compTrack = composition.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: screenDuration),
                of: videoTrack, at: .zero
            )
            renderSize = try await videoTrack.load(.naturalSize)
            screenTrackID = compTrack.trackID
        }

        if let cameraInfo = meta.tracks.first(where: { $0.type == .camera }),
           FileManager.default.fileExists(atPath: bundle.cameraURL.path) {
            let offset = cameraInfo.sessionStartHostTime - screenInfo.sessionStartHostTime
            let cameraAsset = AVURLAsset(url: bundle.cameraURL)
            let cameraDuration = try await cameraAsset.load(.duration)
            if let videoTrack = try await cameraAsset.loadTracks(withMediaType: .video).first,
               let compTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: cameraDuration),
                    of: videoTrack,
                    at: CMTime(seconds: max(0, offset), preferredTimescale: 600)
                )
                cameraTrackID = compTrack.trackID
                cameraSize = try await videoTrack.load(.naturalSize)
            }
        }

        if let micInfo = meta.tracks.first(where: { $0.type == .mic }),
           FileManager.default.fileExists(atPath: bundle.micURL.path) {
            let offset = micInfo.sessionStartHostTime - screenInfo.sessionStartHostTime
            let micAsset = AVURLAsset(url: bundle.micURL)
            let micDuration = try await micAsset.load(.duration)
            if let audioTrack = try await micAsset.loadTracks(withMediaType: .audio).first,
               let compTrack = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: micDuration),
                    of: audioTrack,
                    at: CMTime(seconds: max(0, offset), preferredTimescale: 600)
                )
                micTrackID = compTrack.trackID
            }
        }

        if let systemInfo = meta.tracks.first(where: { $0.type == .systemAudio }),
           FileManager.default.fileExists(atPath: bundle.systemAudioURL.path) {
            let offset = systemInfo.sessionStartHostTime - screenInfo.sessionStartHostTime
            let systemAsset = AVURLAsset(url: bundle.systemAudioURL)
            let systemDuration = try await systemAsset.load(.duration)
            if let audioTrack = try await systemAsset.loadTracks(withMediaType: .audio).first,
               let compTrack = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: systemDuration),
                    of: audioTrack,
                    at: CMTime(seconds: max(0, offset), preferredTimescale: 600)
                )
                systemTrackID = compTrack.trackID
            }
        }
        return BuiltComposition(
            composition: composition,
            renderSize: renderSize,
            screenTrackID: screenTrackID,
            cameraTrackID: cameraTrackID,
            micTrackID: micTrackID,
            systemTrackID: systemTrackID,
            cameraSize: cameraSize
        )
    }

    // MARK: - Cursor / click overlays

    /// Reads events.jsonl, maps cursor/click events to source pixels, and
    /// prerenders the cursor glyphs + click ring. No-op if no events file.
    private func loadOverlayData(display: DisplayInfo) {
        guard let data = try? Data(contentsOf: bundle.eventsURL),
              let events = try? EventsCodec.decodeLines(data), !events.isEmpty else {
            cursorSamples = []; clickSamples = []
            return
        }
        let s = CursorOverlay.samples(from: events, display: display, sourceSize: sourceSize)
        cursorSamples = s.cursor
        clickSamples = s.clicks

        var glyphs: [String: CursorGlyph] = [:]
        for name in Set(cursorSamples.map(\.cursor)) {
            if let g = Self.makeGlyph(named: name) { glyphs[name] = g }
        }
        if glyphs["arrow"] == nil, let g = Self.makeGlyph(named: "arrow") {
            glyphs["arrow"] = g
        }
        overlayGlyphs = glyphs
        if !clickSamples.isEmpty {
            let r = Self.makeRingImage(side: 128)
            ringImage = r?.image
            ringPixelSize = r?.size ?? .zero
        }
    }

    private static func nsCursor(named name: String) -> NSCursor {
        switch name {
        case "ibeam": return .iBeam
        case "pointingHand": return .pointingHand
        case "crosshair": return .crosshair
        case "closedHand": return .closedHand
        case "openHand": return .openHand
        case "resizeLeftRight": return .resizeLeftRight
        case "resizeUpDown": return .resizeUpDown
        default: return .arrow
        }
    }

    private static func makeGlyph(named name: String) -> CursorGlyph? {
        let cursor = nsCursor(named: name)
        let image = cursor.image
        let pointSize = image.size
        guard pointSize.width > 0,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return CursorGlyph(
            image: CIImage(cgImage: cg),
            pointSize: pointSize,
            pixelSize: CGSize(width: cg.width, height: cg.height),
            hotspot: cursor.hotSpot
        )
    }

    /// White ring (stroked circle) on a clear square, for click feedback.
    private static func makeRingImage(side: CGFloat) -> (image: CIImage, size: CGSize)? {
        let px = Int(side)
        guard let ctx = CGContext(data: nil, width: px, height: px,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let lw = side * 0.09
        let rect = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: lw, dy: lw)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        ctx.setLineWidth(lw)
        ctx.addEllipse(in: rect)
        ctx.strokePath()
        return ctx.makeImage().map { (CIImage(cgImage: $0), CGSize(width: side, height: side)) }
    }

    // MARK: - Camera PiP

    /// PiP rect in render-space pixels for the current camera settings.
    var cameraPipRect: CGRect? {
        guard let cameraOrientedSize, renderSize.width > 0 else { return nil }
        return pipRect(in: renderSize, cameraSize: cameraOrientedSize)
    }

    /// PiP rect for an arbitrary canvas — settings are normalized, so the
    /// same values place the camera in both preview and export canvases.
    /// PiP height keys off the visible feed crop's aspect so the camera fills
    /// the frame without distortion when zoomed/panned.
    private func pipRect(in canvas: CGSize, cameraSize: CGSize) -> CGRect {
        let width = canvas.width * cameraScale
        let cropSize = cameraCropRectInFeed?.size ?? cameraSize
        let aspect = cropSize.height > 0 ? cropSize.width / cropSize.height : 1
        let height = aspect > 0 ? width / aspect : width
        return CGRect(
            x: cameraCenterX * canvas.width - width / 2,
            y: cameraCenterY * canvas.height - height / 2,
            width: width, height: height
        )
    }

    /// Visible crop of the camera feed in feed pixels; nil when unavailable.
    /// Reuses CropMath at the feed's native aspect — zoom 1 = whole feed,
    /// zoom 4 = quarter. Center clamped so the crop stays inside the feed.
    var cameraCropRectInFeed: CGRect? {
        guard let cameraOrientedSize, cameraOrientedSize.width > 0,
              cameraOrientedSize.height > 0 else { return nil }
        return CropMath.cropRect(source: cameraOrientedSize, ratio: cameraFeedAspect,
                                 zoom: 1.0 / cameraZoom,
                                 centerX: cameraFeedX, centerY: cameraFeedY)
    }

    /// Rebuilds the video composition (crop + PiP transforms) and applies it
    /// to the player item. Cheap — instructions only, no re-encode.
    func applyVideoComposition() {
        playerItem?.videoComposition = buildVideoComposition()
    }

    /// Persist camera PiP settings; call at gesture end, not per drag tick.
    func commitCameraEdit() {
        saveEdit()
    }

    func toggleCamera() {
        cameraVisible.toggle()
        applyVideoComposition()
        saveEdit()
    }

    /// Live camera feed zoom during slider drag; re-clamps the feed center.
    func setCameraZoom(_ value: Double) {
        cameraZoom = min(max(1, value), 4)
        setCameraFeedCenter(x: cameraFeedX, y: cameraFeedY)
    }

    /// Live camera feed pan during drag; clamps so the crop stays inside feed.
    func setCameraFeedCenter(x: Double, y: Double) {
        guard let cameraOrientedSize, cameraOrientedSize.width > 0,
              cameraOrientedSize.height > 0 else { return }
        let maxFit = CropMath.maxFitSize(source: cameraOrientedSize, ratio: cameraFeedAspect)
        let z = 1.0 / cameraZoom
        let size = CGSize(width: maxFit.width * z, height: maxFit.height * z)
        let c = CropMath.clampedCenter(source: cameraOrientedSize, cropSize: size,
                                       centerX: x, centerY: y)
        cameraFeedX = c.x
        cameraFeedY = c.y
        applyVideoComposition()
    }

    func setCameraShape(_ shape: CameraShape) {
        applyCameraStyle { cameraShape = shape }
        // Aspect changed → re-clamp the feed center for the new crop.
        setCameraFeedCenter(x: cameraFeedX, y: cameraFeedY)
        saveEdit()
    }

    /// Cycle camera orientation +90° clockwise (0→90→180→270→0).
    func rotateCamera() {
        setCameraRotation((cameraRotation + 90) % 360)
    }

    /// Set camera orientation to a 90° step (degrees normalized to 0/90/180/270).
    func setCameraRotation(_ degrees: Int) {
        let normalized = ((degrees / 90 % 4) + 4) % 4 * 90
        applyCameraStyle { cameraRotation = normalized }
        // Aspect swapped → re-clamp the feed center for the rotated crop.
        setCameraFeedCenter(x: cameraFeedX, y: cameraFeedY)
        saveEdit()
    }

    func setCameraAspect(_ aspect: CameraAspect) {
        cameraAspect = aspect
        // Crop aspect changed → re-clamp the feed center (also re-renders).
        setCameraFeedCenter(x: cameraFeedX, y: cameraFeedY)
        saveEdit()
    }

    func setCameraShadowRadius(_ value: Double) {
        applyCameraStyle { cameraShadowRadius = min(max(0, value), 1) }
    }

    func setCameraCornerRadius(_ value: Double) {
        applyCameraStyle { cameraCornerRadius = min(max(0, value), 1) }
    }

    func setCameraBorderWidth(_ value: Double) {
        applyCameraStyle { cameraBorderWidth = min(max(0, value), 0.1) }
    }

    func setCameraBorderHex(_ hex: String) {
        applyCameraStyle { cameraBorderHex = hex }
        saveEdit()
    }

    func setCameraShadow(_ on: Bool) {
        applyCameraStyle { cameraShadow = on }
        saveEdit()
    }

    func setShowCursor(_ on: Bool) {
        applyOverlayChange { showCursor = on }
        saveEdit()
    }

    func setClickFeedback(_ on: Bool) {
        applyOverlayChange { clickFeedback = on }
        saveEdit()
    }

    /// Like `applyCameraStyle`, but watches `needsCompositor` (cursor/click
    /// overlays toggle the compositor and the preview canvas cap).
    private func applyOverlayChange(_ mutate: () -> Void) {
        let was = needsCompositor
        mutate()
        if needsCompositor != was {
            refreshPlayerItemForCanvasChange()
        }
        applyVideoComposition()
    }

    /// Applies a camera-style mutation; if it engages/disengages the custom
    /// compositor, swap the player item so AVPlayer re-evaluates the
    /// compositor class, then reapply the composition.
    private func applyCameraStyle(_ mutate: () -> Void) {
        let was = cameraNeedsCompositor
        mutate()
        if cameraNeedsCompositor != was {
            refreshPlayerItemForCanvasChange()
        }
        applyVideoComposition()
    }

    // MARK: - Reframe crop

    /// Current crop rect in screen-source pixels; nil when not reframing.
    var cropRectInSource: CGRect? {
        guard let ratio = cropAspect.ratio, sourceSize.width > 0 else { return nil }
        return CropMath.cropRect(source: sourceSize, ratio: ratio, zoom: cropZoom,
                                 centerX: cropCenterX, centerY: cropCenterY)
    }

    func setCropAspect(_ aspect: CropAspect) {
        cropAspect = aspect
        cropCenterX = 0.5
        cropCenterY = 0.5
        cropZoom = 1.0
        refreshPlayerItemForCanvasChange()
        applyVideoComposition()
        saveEdit()
    }

    /// Live crop pan during drag; clamps so the crop stays inside the source.
    func setCropCenter(x: Double, y: Double) {
        guard let ratio = cropAspect.ratio, sourceSize.width > 0 else { return }
        let maxFit = CropMath.maxFitSize(source: sourceSize, ratio: ratio)
        let size = CGSize(width: maxFit.width * cropZoom, height: maxFit.height * cropZoom)
        let c = CropMath.clampedCenter(source: sourceSize, cropSize: size,
                                       centerX: x, centerY: y)
        cropCenterX = c.x
        cropCenterY = c.y
        applyVideoComposition()
    }

    /// Live crop zoom during slider drag; re-clamps the center for the new size.
    func setCropZoom(_ value: Double) {
        cropZoom = min(max(0.2, value), 1.0)
        setCropCenter(x: cropCenterX, y: cropCenterY)
    }

    /// Persist crop settings; call at gesture end, not per drag tick.
    func commitCropEdit() {
        saveEdit()
    }

    /// Preview output canvas when reframing (1080-class; export may rebuild
    /// at a higher resolution).
    private var previewCanvasSize: CGSize {
        canvasSize(shortSide: 1080) ?? sourceSize
    }

    /// Output canvas for the active aspect: the short side is fixed
    /// (1080-class / 2160-class), the long side derived (even-pixel).
    /// Landscape 16:9 at 1080 → 1920×1080; portrait 9:16 → 1080×1920.
    private func canvasSize(shortSide: CGFloat) -> CGSize? {
        guard let ratio = cropAspect.ratio else { return nil }
        if ratio >= 1 {
            let width = (shortSide * ratio / 2).rounded() * 2
            return CGSize(width: width, height: shortSide)
        }
        let height = (shortSide / ratio / 2).rounded() * 2
        return CGSize(width: shortSide, height: height)
    }

    /// AVPlayer caches the item's presentation size; replacing the video
    /// composition alone keeps the old letterbox when renderSize changes
    /// shape, so swap in a fresh player item at the same position.
    private func refreshPlayerItemForCanvasChange() {
        guard let composition, let player else { return }
        let wasPlaying = isPlaying
        let position = player.currentTime()
        let item = AVPlayerItem(asset: composition)
        playerItem = item
        player.replaceCurrentItem(with: item)
        applyAudioMix()
        player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.play() }
    }

    private func buildVideoComposition(canvasOverride: CGSize? = nil) -> AVMutableVideoComposition? {
        guard let composition,
              let screenTrack = composition.track(withTrackID: screenTrackID) else {
            return nil
        }
        let cameraShown = cameraVisible && cameraTrackID != nil
        guard cameraShown || cropActive || needsCompositor else { return nil }
        let canvas = canvasOverride ?? renderSize
        guard canvas.width > 0 else { return nil }

        // The custom Core Image compositor handles a styled camera and/or the
        // cursor + click overlays; everything else uses cheap layer instructions.
        if needsCompositor {
            return buildCompositorComposition(canvas: canvas, screenTrack: screenTrack,
                                              cameraTrackID: cameraShown ? cameraTrackID : nil,
                                              composition: composition)
        }

        var layers: [AVMutableVideoCompositionLayerInstruction] = []

        // Camera PiP — first layer instruction renders topmost.
        if cameraShown, let cameraTrackID, let cameraNaturalSize,
           cameraNaturalSize.width > 0,
           let cameraTrack = composition.track(withTrackID: cameraTrackID) {
            let pip = pipRect(in: canvas, cameraSize: cameraNaturalSize)
            let feedCrop = cameraCropRectInFeed ?? CGRect(origin: .zero, size: cameraNaturalSize)
            // Scale the cropped feed to fill the PiP, then shift so the crop's
            // origin lands at the PiP origin. cropRectangle is applied first.
            let scale = pip.width / feedCrop.width
            let cameraLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: cameraTrack)
            cameraLayer.setCropRectangle(feedCrop, at: .zero)
            cameraLayer.setTransform(
                CGAffineTransform(scaleX: scale, y: scale)
                    .concatenating(CGAffineTransform(translationX: pip.minX - feedCrop.minX * scale,
                                                     y: pip.minY - feedCrop.minY * scale)),
                at: .zero
            )
            layers.append(cameraLayer)
        }

        let screenLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: screenTrack)
        if let crop = cropRectInSource, crop.width > 0 {
            // Scale so the crop fills the canvas, then shift its origin to 0.
            let s = canvas.width / crop.width
            screenLayer.setTransform(
                CGAffineTransform(scaleX: s, y: s)
                    .concatenating(CGAffineTransform(translationX: -crop.minX * s,
                                                     y: -crop.minY * s)),
                at: .zero
            )
        }
        layers.append(screenLayer)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        instruction.layerInstructions = layers

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = canvas
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)
        videoComposition.instructions = [instruction]
        return videoComposition
    }

    /// Builds a composition that routes through `StudioCompositor` for the
    /// styled camera. Screen crop + camera feed crop + PiP placement are all
    /// passed as a `CompositorLayout` (top-left pixel coords).
    private func buildCompositorComposition(canvas: CGSize,
                                            screenTrack: AVMutableCompositionTrack,
                                            cameraTrackID: CMPersistentTrackID?,
                                            composition: AVMutableComposition) -> AVMutableVideoComposition? {
        var layout = CompositorLayout(
            canvas: canvas,
            sourceSize: sourceSize,
            screenCrop: cropRectInSource,
            screenTrackID: screenTrackID,
            cameraTrackID: cameraTrackID
        )
        // Camera styling only when a (styled) camera is actually shown.
        if cameraTrackID != nil, let oriented = cameraOrientedSize {
            let pip = pipRect(in: canvas, cameraSize: oriented)
            let feedCrop = cameraCropRectInFeed ?? CGRect(origin: .zero, size: oriented)
            let minSide = min(pip.width, pip.height)
            layout.feedSize = oriented
            layout.feedCrop = feedCrop
            layout.pip = pip
            layout.shape = cameraShape
            layout.cornerRadiusPx = cameraCornerRadius * minSide / 2
            layout.borderWidthPx = cameraBorderWidth * pip.width
            layout.borderColor = Self.cgColor(hex: cameraBorderHex)
            layout.shadow = cameraShadow
            layout.shadowRadius = CGFloat(cameraShadowRadius)
            layout.cameraQuarterTurns = cameraRotation / 90
        } else {
            layout.cameraTrackID = nil
        }

        // Cursor / click overlay payload.
        let pointWidth = meta?.display.pointWidth ?? 0
        layout.sourcePerPoint = pointWidth > 0 ? sourceSize.width / pointWidth : 1
        layout.showCursor = showCursor && hasCursorData
        layout.clickFeedback = clickFeedback && hasClickData
        var overlay = OverlayPayload()
        if layout.showCursor {
            overlay.cursorSamples = cursorSamples
            overlay.glyphs = overlayGlyphs
        }
        if layout.clickFeedback {
            overlay.clickSamples = clickSamples
            overlay.ring = ringImage
            overlay.ringPixelSize = ringPixelSize
        }

        let instruction = StudioCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: composition.duration),
            layout: layout,
            overlay: overlay
        )
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = StudioCompositor.self
        videoComposition.renderSize = canvas
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)
        videoComposition.instructions = [instruction]
        return videoComposition
    }

    /// Parses "#RRGGBB" (or "RRGGBB"); falls back to white.
    private static func cgColor(hex: String) -> CGColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        }
        return CGColor(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }

    // MARK: - Audio mix (per-source volume)

    /// Live volume change during slider drag; persist via commitVolumeEdit().
    func setMicVolume(_ value: Double) {
        micVolume = min(max(0, value), 3)
        applyAudioMix()
    }

    func setSystemVolume(_ value: Double) {
        systemVolume = min(max(0, value), 1)
        applyAudioMix()
    }

    /// Persist volumes; call at slider gesture end, not per tick.
    func commitVolumeEdit() {
        saveEdit()
    }

    /// Reapplies per-source volumes to the player item. Cheap — mix
    /// parameters only, no re-encode.
    private func applyAudioMix() {
        playerItem?.audioMix = buildAudioMix()
    }

    private func buildAudioMix() -> AVAudioMix? {
        guard let composition else { return nil }
        var parameters: [AVMutableAudioMixInputParameters] = []
        if let micTrackID, let track = composition.track(withTrackID: micTrackID) {
            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolume(Float(micVolume), at: .zero)
            parameters.append(params)
        }
        if let systemTrackID, let track = composition.track(withTrackID: systemTrackID) {
            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolume(Float(systemVolume), at: .zero)
            parameters.append(params)
        }
        guard !parameters.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    // MARK: - Playback

    func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            if currentTime >= duration - 0.05 { seek(to: trimIn) }
            player.play()
        }
    }

    var isPlaying: Bool { player?.timeControlStatus == .playing }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), duration)
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }

    // MARK: - Trim (persisted to edit.json; masters untouched)

    func setTrimIn(_ value: Double) {
        trimIn = min(max(0, value), trimOut - 0.1)
        saveEdit()
    }

    func setTrimOut(_ value: Double) {
        trimOut = max(min(duration, value), trimIn + 0.1)
        saveEdit()
    }

    func resetTrim() {
        trimIn = 0
        trimOut = duration
        saveEdit()
    }

    private func saveEdit() {
        let edit = EditState(
            trimIn: trimIn,
            trimOut: trimOut >= duration - 0.001 ? nil : trimOut,
            cameraVisible: cameraVisible,
            cameraCenterX: cameraCenterX,
            cameraCenterY: cameraCenterY,
            cameraScale: cameraScale,
            cameraZoom: cameraZoom,
            cameraFeedX: cameraFeedX,
            cameraFeedY: cameraFeedY,
            cameraShape: cameraShape,
            cameraCornerRadius: cameraCornerRadius,
            cameraBorderWidth: cameraBorderWidth,
            cameraBorderHex: cameraBorderHex,
            cameraShadow: cameraShadow,
            cameraShadowRadius: cameraShadowRadius,
            cameraAspect: cameraAspect,
            cameraRotation: cameraRotation,
            micVolume: micVolume,
            systemVolume: systemVolume,
            showCursor: showCursor,
            clickFeedback: clickFeedback,
            cropAspect: cropAspect,
            cropCenterX: cropCenterX,
            cropCenterY: cropCenterY,
            cropZoom: cropZoom
        )
        try? bundle.writeEdit(edit)
    }

    // MARK: - Export

    func export(preset: ExportPreset, to destination: URL) {
        guard let composition else { return }
        if case .exporting = exportState { return }
        exportState = .exporting(0)
        let range = CMTimeRange(
            start: CMTime(seconds: trimIn, preferredTimescale: 600),
            end: CMTime(seconds: trimOut, preferredTimescale: 600)
        )
        // Fixed-size session presets letterbox a portrait renderSize, so when
        // reframing the output pixels come from the video composition's
        // canvas and the session preset is quality-only.
        let videoComposition: AVMutableVideoComposition?
        let avPresetOverride: String?
        if cropActive {
            videoComposition = buildVideoComposition(canvasOverride: exportCanvasSize(for: preset))
            avPresetOverride = AVAssetExportPresetHighestQuality
        } else {
            // Camera-only (plain or styled): export at full source resolution
            // (renderSize may be capped for smooth preview), preset scales.
            videoComposition = buildVideoComposition(canvasOverride: sourceSize)
            avPresetOverride = nil
        }
        Task {
            do {
                let url = try await Exporter.export(
                    composition: composition,
                    videoComposition: videoComposition,
                    audioMix: buildAudioMix(),
                    timeRange: range,
                    preset: preset,
                    avPresetOverride: avPresetOverride,
                    to: destination
                ) { [weak self] progress in
                    Task { @MainActor in
                        if case .exporting = self?.exportState {
                            self?.exportState = .exporting(progress)
                        }
                    }
                }
                exportState = .done(url)
            } catch {
                exportState = .failed(error.localizedDescription)
            }
        }
    }

    /// Export canvas when reframing: 1080/2160-wide for the quality presets,
    /// crop-rect pixel size (even-aligned, no upscale) for Source.
    private func exportCanvasSize(for preset: ExportPreset) -> CGSize {
        switch preset {
        case .hd1080:
            return canvasSize(shortSide: 1080) ?? sourceSize
        case .uhd4K:
            return canvasSize(shortSide: 2160) ?? sourceSize
        case .source:
            guard let crop = cropRectInSource else { return sourceSize }
            return CGSize(width: (crop.width / 2).rounded(.down) * 2,
                          height: (crop.height / 2).rounded(.down) * 2)
        }
    }

    func dismissExportResult() {
        exportState = .idle
    }

    func revealMastersInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([bundle.screenURL])
    }
}
