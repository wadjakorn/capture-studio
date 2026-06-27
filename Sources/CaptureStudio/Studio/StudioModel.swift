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
    /// Transient: while true, dragging the preview pans the reframed video
    /// (see CropPanOverlay). Not persisted; reset when the reframe isn't pannable.
    @Published var panVideoMode = false
    @Published private(set) var trimIn: Double = 0
    @Published private(set) var trimOut: Double = 0
    @Published private(set) var exportState: ExportState = .idle

    // Camera PiP — center normalized 0–1 in render space, scale = width
    // fraction of screen width. Persisted to edit.json.
    /// The layout used before the first timeline block (and when the timeline is
    /// empty). The old binary show/hide toggle is now the `mainOnly` ↔ camera
    /// distinction within this. Persisted to edit.json.
    @Published var cameraHomeLayout: CameraLayout = .mainAndFloat
    /// Back-compat alias: the home state shows the camera unless `mainOnly`.
    /// Drives the many gates that only care whether a camera is present.
    var cameraVisible: Bool { cameraHomeLayout.showsCamera }
    @Published var cameraCenterX = 0.85
    @Published var cameraCenterY = 0.82
    @Published var cameraScale = 0.24
    // Camera timeline. Empty = static placement (the fields above act as the
    // "home" placement). Non-empty = blocks drive position/scale/visibility over
    // time, easing from home / the previous block into each block. The selected
    // block is the one the lane + PiP overlay edit. Persisted to edit.json.
    @Published private(set) var cameraBlocks: [CameraBlock] = []
    @Published var selectedBlockID: UUID?
    /// The home/static camera placement is selected for editing — drives the PiP
    /// overlay in static mode (block selection drives it in timeline mode), so
    /// the camera is deselectable like every other element. Transient: not saved.
    @Published var cameraSelected = false
    /// Default width of a newly added block (seconds).
    static let defaultBlockWidth = 0.5
    /// Default width of a newly added layout block (seconds) — wider than a
    /// camera move block so it's easy to see and grab on the lane.
    static let defaultLayoutWidth = 3.0
    // Text/caption timeline. Multiple instances, MAY overlap in time; array
    // order is the z-order (later = on top) and is never re-sorted. The selected
    // block is the one the lane + style bar + canvas overlay edit. Persisted to edit.json.
    @Published private(set) var textBlocks: [TextBlock] = []
    @Published var selectedTextBlockID: UUID?
    // Zoom/pan timeline. Blocks drive an auto-zoom track in the compositor.
    // Persisted to edit.json.
    @Published private(set) var zoomBlocks: [ZoomBlock] = []
    @Published var selectedZoomBlockID: UUID?
    // Layout timeline. Each block sets the frame layout (main / camera mix) over
    // its span; uncovered gaps render blank. Empty = the whole clip uses
    // `cameraHomeLayout`. Non-overlapping. Persisted to edit.json.
    @Published private(set) var layoutBlocks: [LayoutBlock] = []
    @Published var selectedLayoutBlockID: UUID?
    /// Set while a text block is being dragged on the canvas, so the compositor
    /// suppresses its baked copy and the smooth SwiftUI overlay drives motion
    /// (no per-tick recomposite). Cleared on drop.
    @Published private(set) var draggingTextBlockID: UUID?
    /// Default width of a newly added text block (seconds).
    static let defaultTextWidth = 3.0
    /// Subtitle states for the loader gate while importing/removing.
    enum SubtitleState: Equatable { case idle, applying, removing }
    /// Imported subtitle track (nil = none, lane hidden). Cues are read-only;
    /// `style` is the one shared, user-configured look applied to every cue.
    /// Persisted to edit.json; the `.srt` file lives in the bundle.
    @Published private(set) var subtitles: SubtitleTrack?
    /// Loader gate: import/remove run off the main actor so the UI never blocks.
    @Published private(set) var subtitleState: SubtitleState = .idle
    /// The subtitle track is selected for configuration (mutually exclusive with
    /// camera-block and text-block selection).
    @Published var subtitleSelected = false
    /// Set while dragging the subtitle position box on the canvas, so the
    /// compositor suppresses the baked subtitles and the smooth overlay drives
    /// motion. Cleared on drop.
    @Published private(set) var draggingSubtitle = false
    /// Frames-per-second of the preview/export video composition. The seek that
    /// reveals a selected caption must align to this grid (see
    /// `TextTimeline.firstVisibleTime`), so it is the single source of truth for
    /// both the composition `frameDuration` and that seek.
    static let compositionFrameRate: Double = 60
    /// New playhead time after a horizontal scroll of `dx` view points across a
    /// canvas `viewWidth` wide; a full-width scroll spans the whole `duration`.
    /// Positive `dx` (swipe right) rewinds; negative advances. Clamped to clip.
    nonisolated static func scrubbedTime(from current: Double, scrollDX dx: CGFloat,
                                         viewWidth: CGFloat, duration: Double) -> Double {
        guard viewWidth > 0, duration > 0 else { return current }
        let delta = Double(dx / viewWidth) * duration
        return min(max(0, current - delta), duration)
    }
    /// Style/position template for the next added text block — every block edit
    /// snapshots into it so a new block clones the most recent one (text aside).
    /// In-memory only: resets each launch (no cross-session memory).
    private var lastTextStyle = TextBlock(begin: 0, end: 0)
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

    /// Whether the camera is drawn at any point — the home layout or any block
    /// layout shows it. Gates passing the camera track to the compositor.
    var anyCameraVisible: Bool {
        layoutBlocks.isEmpty
            ? cameraHomeLayout.showsCamera
            : layoutBlocks.contains { $0.layout.showsCamera }
    }
    var cameraShown: Bool { anyCameraVisible && cameraTrackID != nil }
    /// The camera has a block timeline driving it (vs. a static placement).
    var cameraHasTimeline: Bool { cameraTrackID != nil && !cameraBlocks.isEmpty }
    /// The layout lane is shown whenever there are blocks to edit (the home
    /// layout is set from the toolbar, independent of the lane).
    var showsCameraTimeline: Bool { cameraHasTimeline }
    /// The zoom lane is shown only when there is at least one zoom block.
    var showsZoomTimeline: Bool { !zoomBlocks.isEmpty }

    /// Per-project defaults for new/unset blocks (global config).
    var autoZoomConfig: AutoZoomConfig {
        var c = AutoZoomConfig()
        let v = UserDefaults.standard.double(forKey: "autoZoomDefaultScale")
        if v > 1 { c.defaultScale = v }
        let s = UserDefaults.standard.double(forKey: "autoZoomDefaultSensitivity")
        if s > 0 && s <= 1 { c.defaultSensitivity = s }
        return c
    }
    var selectedBlock: CameraBlock? {
        guard let id = selectedBlockID else { return nil }
        return cameraBlocks.first { $0.id == id }
    }
    var selectedTextBlock: TextBlock? {
        guard let id = selectedTextBlockID else { return nil }
        return textBlocks.first { $0.id == id }
    }
    /// The subtitle lane shows only when a track with at least one cue exists.
    var showsSubtitleTimeline: Bool {
        guard let s = subtitles else { return false }
        return !s.cues.isEmpty
    }
    /// Cues shifted by the track offset and clamped to the clip — exactly what
    /// renders. Empty when there is no track or every cue falls outside the clip.
    var effectiveSubtitleCues: [SubtitleCue] {
        guard let s = subtitles else { return [] }
        return SubtitleTimeline.effective(s.cues, offset: s.offset, duration: duration)
    }
    /// The static "home" placement — the camera's resting state, held before the
    /// first block and used as the first block's "from".
    var cameraHome: CameraSample {
        CameraSample(centerX: cameraCenterX, centerY: cameraCenterY,
                     scale: cameraScale, opacity: cameraHomeLayout.showsCamera ? 1 : 0,
                     layout: cameraHomeLayout)
    }
    /// Placement the PiP overlay shows + edits: the selected block's target when
    /// the timeline is active, else the home placement.
    var editingCameraSample: CameraSample {
        if cameraHasTimeline, let b = selectedBlock {
            return CameraSample(centerX: b.centerX, centerY: b.centerY,
                                scale: b.scale, opacity: b.layout.showsCamera ? 1 : 0,
                                layout: b.layout)
        }
        return cameraHome
    }
    /// The layout in effect at the playhead — the selected/under-playhead block,
    /// or the home layout before the first block. Drives toolbar gating.
    var layoutAtPlayhead: CameraLayout {
        LayoutTimeline.sample(at: currentTime, blocks: layoutBlocks) ?? cameraHomeLayout
    }
    /// The layout the toolbar picker reflects + edits: the selected layout
    /// block's, else the layout at the playhead (a covering block or home).
    var editingLayout: CameraLayout {
        selectedLayoutBlock?.layout ?? layoutAtPlayhead
    }
    var selectedLayoutBlock: LayoutBlock? {
        guard let id = selectedLayoutBlockID else { return nil }
        return layoutBlocks.first { $0.id == id }
    }
    /// The layout lane shows only when there is at least one layout block.
    var showsLayoutTimeline: Bool { !layoutBlocks.isEmpty }
    /// Whether a new layout block would fit — gates the "add layout" button.
    var canAddLayoutBlock: Bool {
        LayoutTimeline.hasSpace(layoutBlocks, duration: duration)
    }
    /// Whether the camera placement can be edited at the current playhead. Only
    /// the floating layouts have a moveable PiP; static / main-only have none.
    /// Static mode is always editable; timeline mode only before the first block
    /// (where the home placement applies). Drives the select hit-target and
    /// overlay gating.
    var cameraOverlayEditableAtPlayhead: Bool {
        guard hasCameraTrack, layoutAtPlayhead.cameraFloats else { return false }
        guard cameraHasTimeline else { return true }
        if let first = cameraBlocks.first { return currentTime < first.begin }
        return true
    }
    /// Whether the interactive PiP box is shown. Timeline mode: a floating-layout
    /// block is selected (edits its target). Home/static: only while the camera
    /// is explicitly selected — so it can be deselected like every other element
    /// (Esc / empty canvas / empty timeline / inert UI).
    var showsCameraOverlay: Bool {
        if cameraHasTimeline, selectedBlock != nil { return layoutAtPlayhead.cameraFloats }
        return cameraSelected && cameraOverlayEditableAtPlayhead
    }
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
                        || cameraRotation != 0
                        || cameraHomeLayout.needsCompositor)
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

    /// A non-source output canvas is in play (any reframe — crop OR fit).
    var hasReframeCanvas: Bool { cropAspect != .original }

    /// User can pan/zoom the reframe (crop in cover aspects, fitted content in
    /// fit/template mode). True for any reframe aspect.
    var cropPannable: Bool { hasReframeCanvas }

    /// Canvas pixels per source pixel for the current preview placement — fit
    /// placement scale in template mode, crop fill scale otherwise. Drives the
    /// drag-to-pan gesture conversion.
    var screenDrawScale: CGFloat {
        guard renderSize.width > 0, sourceSize.width > 0 else { return 1 }
        if cropAspect.isFit {
            let s0 = min(renderSize.width / sourceSize.width,
                         renderSize.height / sourceSize.height)
            return s0 / min(max(CGFloat(cropZoom), 0.2), 1.0)
        }
        if let crop = cropRectInSource, crop.width > 0 { return renderSize.width / crop.width }
        return 1
    }

    /// Studio-only reels safe-area guide visibility. Ephemeral (never persisted,
    /// never exported); auto-on when the template aspect is selected.
    @Published var templateGuideVisible = false

    // Background behind the fitted video in template/fit mode (letterbox bars).
    // Persisted to edit.json. The photo file lives in the bundle; its name is
    // `canvasBackgroundImage`, loaded into `backgroundCIImage` for rendering.
    @Published private(set) var canvasBackground: CanvasBackground = .black
    @Published var canvasBackgroundBlur = 0.03
    @Published private(set) var canvasBackgroundImage: String?
    /// Loaded background photo (EXIF-oriented), cached. nil = none.
    private var backgroundCIImage: CIImage?

    // Canvas inspection view — a view-only pan/zoom of the whole preview for
    // inspecting high-res frames. NEVER persisted and never affects the
    // composited/exported output. `canvasZoom` 1 = fit; pan is a view-point
    // offset of the scaled canvas, clamped so content edges can't be dragged
    // past the container edges.
    @Published var canvasZoom: CGFloat = 1
    @Published var canvasPanX: CGFloat = 0
    @Published var canvasPanY: CGFloat = 0
    /// Live size of the preview canvas view (set by `StudioView`); used to
    /// clamp the pan offset against the fitted content size.
    private(set) var canvasViewSize: CGSize = .zero
    /// Whether the canvas is zoomed past fit (drives the reset badge + pan).
    var canvasZoomed: Bool { canvasZoom > 1.001 }

    /// Screen master natural size (source space for the crop).
    private(set) var sourceSize: CGSize = .zero
    /// Output canvas: crop output size when reframing, else the source size.
    /// When the custom compositor runs without a crop, the preview canvas is
    /// capped to a 1080-class short side so CI compositing stays smooth;
    /// export still rebuilds at full resolution.
    var renderSize: CGSize {
        if hasReframeCanvas { return previewCanvasSize }
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
            || cameraHasTimeline
            || !layoutBlocks.isEmpty
            || cameraHomeLayout.needsCompositor
            || !textBlocks.isEmpty
            || showsSubtitleTimeline
            || !zoomBlocks.isEmpty
            || (showCursor && hasCursorData)
            || (clickFeedback && hasClickData)
            || (cropAspect.isFit && canvasBackground != .black)
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
            cameraHomeLayout = edit.cameraHomeLayout
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
            canvasBackground = edit.canvasBackground
            canvasBackgroundBlur = min(max(0, edit.canvasBackgroundBlur), 0.2)
            canvasBackgroundImage = edit.canvasBackgroundImage
            loadBackgroundImage()
            cameraBlocks = edit.cameraBlocks.sorted { $0.begin < $1.begin }
            // Stored verbatim — array order is the z-order, never re-sorted.
            textBlocks = edit.textBlocks
            // Keep cues raw; the offset is applied at consumption. A track whose
            // cues all fall outside the clip (after offset) loads as no subtitles
            // (the .srt file is left in the bundle).
            if let track = edit.subtitles {
                let surviving = SubtitleTimeline.effective(track.cues, offset: track.offset,
                                                           duration: duration)
                subtitles = surviving.isEmpty ? nil
                    : SubtitleTrack(srtFilename: track.srtFilename, style: track.style,
                                    cues: track.cues, offset: track.offset)
            }
            zoomBlocks = edit.zoomBlocks.sorted { $0.begin < $1.begin }
            layoutBlocks = edit.layoutBlocks.sorted { $0.begin < $1.begin }
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

    /// PiP rect in render-space pixels for the placement the overlay edits
    /// (selected breakpoint when on the timeline, else the static placement).
    var cameraPipRect: CGRect? {
        guard let cameraOrientedSize, renderSize.width > 0 else { return nil }
        let s = editingCameraSample
        return pipRect(in: renderSize, cameraSize: cameraOrientedSize,
                       centerX: s.centerX, centerY: s.centerY, scale: s.scale)
    }

    /// PiP rect for an arbitrary canvas — settings are normalized, so the
    /// same values place the camera in both preview and export canvases.
    /// PiP height keys off the visible feed crop's aspect so the camera fills
    /// the frame without distortion when zoomed/panned.
    private func pipRect(in canvas: CGSize, cameraSize: CGSize) -> CGRect {
        pipRect(in: canvas, cameraSize: cameraSize, centerX: cameraCenterX,
                centerY: cameraCenterY, scale: cameraScale)
    }

    private func pipRect(in canvas: CGSize, cameraSize: CGSize,
                         centerX: Double, centerY: Double, scale: Double) -> CGRect {
        let width = canvas.width * scale
        let cropSize = cameraCropRectInFeed?.size ?? cameraSize
        let aspect = cropSize.height > 0 ? cropSize.width / cropSize.height : 1
        let height = aspect > 0 ? width / aspect : width
        return CGRect(
            x: centerX * canvas.width - width / 2,
            y: centerY * canvas.height - height / 2,
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

    /// Live PiP move during overlay drag → the selected block's target when on
    /// the timeline, else the home placement.
    func dragCameraCenter(x: Double, y: Double) {
        let cx = min(max(x, 0), 1)
        let cy = min(max(y, 0), 1)
        if cameraHasTimeline, let id = selectedBlockID,
           let i = cameraBlocks.firstIndex(where: { $0.id == id }) {
            cameraBlocks[i].centerX = cx
            cameraBlocks[i].centerY = cy
        } else {
            cameraCenterX = cx
            cameraCenterY = cy
        }
        applyVideoComposition()
    }

    /// Live PiP resize during overlay drag → selected block's target or home.
    func dragCameraScale(_ value: Double) {
        let s = min(max(value, 0.08), 0.8)
        if cameraHasTimeline, let id = selectedBlockID,
           let i = cameraBlocks.firstIndex(where: { $0.id == id }) {
            cameraBlocks[i].scale = s
        } else {
            cameraScale = s
        }
        applyVideoComposition()
    }

    // MARK: - Camera timeline (blocks)

    /// Camera state sampled at `t` from the current blocks + home.
    private func sampledCameraState(at t: Double) -> CameraSample {
        CameraTimeline.sample(at: t, blocks: cameraBlocks, home: cameraHome)
    }

    /// Add a camera **move** block at the playhead, seeding it with the camera's
    /// current placement so nothing jumps until the user repositions the PiP.
    /// Camera move blocks carry position/scale only — the frame layout lives on
    /// the separate layout timeline.
    func addBlock() {
        let t = min(max(currentTime, 0), duration)
        let placement = sampledCameraState(at: t)
        let added = CameraTimeline.add(cameraBlocks, atTime: t,
                                       width: Self.defaultBlockWidth,
                                       duration: duration, placement: placement,
                                       layout: .mainAndFloat)
        setBlocks(added.blocks, select: added.id)
    }

    /// The block whose span strictly contains the playhead, if any. Used to
    /// gate block insertion (no overlapping blocks).
    var blockAtPlayhead: CameraBlock? {
        cameraBlocks.first { $0.begin <= currentTime && currentTime < $0.end }
    }

    // MARK: - Layout timeline (blocks)

    /// Add a layout block at the playhead, defaulting to the layout currently in
    /// effect there (a covering block or home) so nothing jumps until edited.
    /// Snapped into the first free gap; no-op when the timeline is full.
    func addLayoutBlock(layout: CameraLayout? = nil) {
        let t = min(max(currentTime, 0), duration)
        guard let added = LayoutTimeline.add(layoutBlocks, atTime: t,
                                             width: Self.defaultLayoutWidth,
                                             duration: duration,
                                             layout: layout ?? layoutAtPlayhead)
        else { return }
        setLayoutBlocks(added.blocks, select: added.id)
    }

    /// Change a layout block's layout (the lane's per-block / toolbar picker).
    func setLayoutBlockLayout(_ id: UUID, _ layout: CameraLayout) {
        guard let i = layoutBlocks.firstIndex(where: { $0.id == id }) else { return }
        layoutBlocks[i].layout = layout
        applyVideoComposition()
        saveEdit()
    }

    func moveLayoutBlockBegin(_ id: UUID, toTime: Double) {
        layoutBlocks = LayoutTimeline.moveBegin(layoutBlocks, id: id, toTime: toTime, duration: duration)
        applyVideoComposition()
    }

    func moveLayoutBlockEnd(_ id: UUID, toTime: Double) {
        layoutBlocks = LayoutTimeline.moveEnd(layoutBlocks, id: id, toTime: toTime, duration: duration)
        applyVideoComposition()
    }

    func moveLayoutBlock(_ id: UUID, toBegin: Double) {
        layoutBlocks = LayoutTimeline.moveBlock(layoutBlocks, id: id, toBegin: toBegin, duration: duration)
        applyVideoComposition()
    }

    func commitLayoutEdit() { saveEdit() }

    func removeLayoutBlock(_ id: UUID) {
        let list = LayoutTimeline.remove(layoutBlocks, id: id)
        setLayoutBlocks(list, select: selectedLayoutBlockID == id ? nil : selectedLayoutBlockID)
    }

    /// Select a layout block (clears other selections) and park the playhead
    /// inside its span so the preview shows that layout.
    func selectLayoutBlock(_ id: UUID?) {
        selectedLayoutBlockID = id
        if id != nil {
            selectedBlockID = nil; selectedTextBlockID = nil
            selectedZoomBlockID = nil; subtitleSelected = false; cameraSelected = false
        }
        if let id, let b = layoutBlocks.first(where: { $0.id == id }) {
            seek(to: min((b.begin + b.end) / 2, duration))
        }
    }

    private func setLayoutBlocks(_ list: [LayoutBlock], select id: UUID?) {
        layoutBlocks = list.sorted { $0.begin < $1.begin }
        selectedLayoutBlockID = id
        if id != nil {
            selectedBlockID = nil; selectedTextBlockID = nil
            selectedZoomBlockID = nil; subtitleSelected = false; cameraSelected = false
        }
        applyVideoComposition()
        saveEdit()
    }

    /// Live begin-edge drag; persist with `commitBlockEdit`.
    func moveBlockBegin(_ id: UUID, toTime: Double) {
        cameraBlocks = CameraTimeline.moveBegin(cameraBlocks, id: id, toTime: toTime, duration: duration)
        applyVideoComposition()
    }

    /// Live end-edge drag; persist with `commitBlockEdit`.
    func moveBlockEnd(_ id: UUID, toTime: Double) {
        cameraBlocks = CameraTimeline.moveEnd(cameraBlocks, id: id, toTime: toTime, duration: duration)
        applyVideoComposition()
    }

    /// Live whole-block drag (keeps width); persist with `commitBlockEdit`.
    func moveBlock(_ id: UUID, toBegin: Double) {
        cameraBlocks = CameraTimeline.moveBlock(cameraBlocks, id: id, toBegin: toBegin, duration: duration)
        applyVideoComposition()
    }

    func commitBlockEdit() {
        saveEdit()
    }

    func removeBlock(_ id: UUID) {
        let list = CameraTimeline.remove(cameraBlocks, id: id)
        setBlocks(list, select: selectedBlockID == id ? nil : selectedBlockID)
    }

    // MARK: - Zoom timeline (auto zoom/pan blocks)

    /// Add a zoom block at the playhead (scale = nil → uses the global default).
    func addZoomBlock() {
        let t = min(max(currentTime, 0), duration)
        let added = ZoomTimeline.add(zoomBlocks, atTime: t,
                                     width: Self.defaultBlockWidth, duration: duration)
        setZoomBlocks(added.blocks, select: added.id)
    }

    func moveZoomBlockBegin(_ id: UUID, toTime: Double) {
        zoomBlocks = ZoomTimeline.moveBegin(zoomBlocks, id: id, toTime: toTime, duration: duration)
        applyVideoComposition()
    }

    func moveZoomBlockEnd(_ id: UUID, toTime: Double) {
        zoomBlocks = ZoomTimeline.moveEnd(zoomBlocks, id: id, toTime: toTime, duration: duration)
        applyVideoComposition()
    }

    func moveZoomBlock(_ id: UUID, toBegin: Double) {
        zoomBlocks = ZoomTimeline.moveBlock(zoomBlocks, id: id, toBegin: toBegin, duration: duration)
        applyVideoComposition()
    }

    func commitZoomEdit() { saveEdit() }

    func removeZoomBlock(_ id: UUID) {
        let list = ZoomTimeline.remove(zoomBlocks, id: id)
        setZoomBlocks(list, select: selectedZoomBlockID == id ? nil : selectedZoomBlockID)
    }

    /// Select a zoom block (clears camera/text selection) and park the playhead
    /// inside its span so the preview shows the zoom.
    func selectZoomBlock(_ id: UUID?) {
        selectedZoomBlockID = id
        if id != nil { selectedBlockID = nil; selectedTextBlockID = nil; subtitleSelected = false; cameraSelected = false }
        if let id, let b = zoomBlocks.first(where: { $0.id == id }) {
            seek(to: min((b.begin + b.end) / 2, duration))
        }
    }

    /// Effective scale of the selected block (its override, else global default).
    var selectedZoomScale: Double {
        guard let id = selectedZoomBlockID,
              let b = zoomBlocks.first(where: { $0.id == id }) else {
            return autoZoomConfig.defaultScale
        }
        return b.scale ?? autoZoomConfig.defaultScale
    }

    /// Set the selected block's scale override (live; persist via commitZoomEdit).
    func setZoomScale(_ v: Double) {
        guard let id = selectedZoomBlockID,
              let i = zoomBlocks.firstIndex(where: { $0.id == id }) else { return }
        zoomBlocks[i].scale = min(max(1, v), 6)
        applyVideoComposition()
    }

    /// Clear the override so the block follows the global default again.
    func resetZoomScale() {
        guard let id = selectedZoomBlockID,
              let i = zoomBlocks.firstIndex(where: { $0.id == id }) else { return }
        zoomBlocks[i].scale = nil
        applyVideoComposition()
        saveEdit()
    }

    /// Effective follow-sensitivity of the selected block (its override, else
    /// the global default).
    var selectedZoomSensitivity: Double {
        guard let id = selectedZoomBlockID,
              let b = zoomBlocks.first(where: { $0.id == id }) else {
            return autoZoomConfig.defaultSensitivity
        }
        return b.sensitivity ?? autoZoomConfig.defaultSensitivity
    }

    /// Set the selected block's sensitivity override (live; persist via
    /// commitZoomEdit).
    func setZoomSensitivity(_ v: Double) {
        guard let id = selectedZoomBlockID,
              let i = zoomBlocks.firstIndex(where: { $0.id == id }) else { return }
        zoomBlocks[i].sensitivity = min(max(0, v), 1)
        applyVideoComposition()
    }

    /// Clear the override so the block follows the global default again.
    func resetZoomSensitivity() {
        guard let id = selectedZoomBlockID,
              let i = zoomBlocks.firstIndex(where: { $0.id == id }) else { return }
        zoomBlocks[i].sensitivity = nil
        applyVideoComposition()
        saveEdit()
    }

    /// Replace the zoom-block list. Adding the first / removing the last flips
    /// the compositor on/off, so refresh the player item when `needsCompositor`
    /// changes, mirroring `setBlocks`.
    private func setZoomBlocks(_ list: [ZoomBlock], select id: UUID?) {
        let was = needsCompositor
        zoomBlocks = list
        selectedZoomBlockID = id
        // One selection at a time (see `setBlocks`).
        if id != nil { selectedBlockID = nil; selectedTextBlockID = nil; subtitleSelected = false; cameraSelected = false }
        if needsCompositor != was {
            refreshPlayerItemForCanvasChange()
        }
        applyVideoComposition()
        saveEdit()
    }

    // MARK: - Text timeline (captions)

    /// Replace the text-block list (preserving its array order = z-order). Adding
    /// the first / removing the last flips the compositor on/off, so refresh the
    /// player item when `needsCompositor` changes, mirroring `setBlocks`.
    private func setTextBlocks(_ list: [TextBlock], select id: UUID?) {
        let was = needsCompositor
        textBlocks = list
        selectedTextBlockID = id
        // One selection at a time (see `setBlocks`).
        if id != nil { selectedBlockID = nil; selectedZoomBlockID = nil; subtitleSelected = false; cameraSelected = false }
        if needsCompositor != was {
            refreshPlayerItemForCanvasChange()
        }
        applyVideoComposition()
        saveEdit()
    }

    /// Select a text block (clears any camera-block selection) and park the
    /// playhead inside its span so the preview shows it. Pass nil to deselect.
    func selectTextBlock(_ id: UUID?) {
        if id != selectedTextBlockID { saveEdit() }   // persist the prior block's live text
        selectedTextBlockID = id
        if id != nil { selectedBlockID = nil; subtitleSelected = false; selectedZoomBlockID = nil; cameraSelected = false }
        if let id, let b = textBlocks.first(where: { $0.id == id }),
           !(b.begin <= currentTime && currentTime < b.end) {
            // Align to the composition frame grid so the caption is visible at
            // the seeked frame (a raw begin can render one frame late). For a
            // sub-frame-length block the aligned time can reach `end`, so fall
            // back to `begin` to keep the playhead inside the span.
            let aligned = TextTimeline.firstVisibleTime(begin: b.begin,
                                                        fps: Self.compositionFrameRate)
            seek(to: min(aligned < b.end ? aligned : b.begin, duration))
        }
    }

    /// Add an empty default text block at the playhead and select it. Selecting
    /// it reveals the inline caption field in the text tool group, so the user
    /// can type immediately. The new block clones the last-edited style.
    func addTextBlock() {
        let t = min(max(currentTime, 0), duration)
        var template = lastTextStyle
        template.text = ""              // inherit style + position, never the words
        let added = TextTimeline.add(textBlocks, atTime: t, width: Self.defaultTextWidth,
                                     duration: duration, template: template)
        setTextBlocks(added.blocks, select: added.id)
    }

    func removeTextBlock(_ id: UUID) {
        let list = TextTimeline.remove(textBlocks, id: id)
        setTextBlocks(list, select: selectedTextBlockID == id ? nil : selectedTextBlockID)
    }

    /// Live begin-edge drag; persist with `commitTextEdit`.
    func moveTextBlockBegin(_ id: UUID, toTime: Double) {
        textBlocks = TextTimeline.moveBegin(textBlocks, id: id, toTime: toTime, duration: duration)
        applyVideoComposition()
    }

    /// Live end-edge drag; persist with `commitTextEdit`.
    func moveTextBlockEnd(_ id: UUID, toTime: Double) {
        textBlocks = TextTimeline.moveEnd(textBlocks, id: id, toTime: toTime, duration: duration)
        applyVideoComposition()
    }

    /// Live whole-block drag (keeps width); persist with `commitTextEdit`.
    func moveTextBlock(_ id: UUID, toBegin: Double) {
        textBlocks = TextTimeline.moveBlock(textBlocks, id: id, toBegin: toBegin, duration: duration)
        applyVideoComposition()
    }

    func commitTextEdit() {
        saveEdit()
    }

    /// Mutate one block in place (preserves array order / z-order) and refresh
    /// the preview live. Does NOT persist — call `commitTextEdit` at gesture /
    /// edit end, mirroring the camera drag/commit split.
    private func updateTextBlock(_ id: UUID, _ mutate: (inout TextBlock) -> Void) {
        guard let i = textBlocks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&textBlocks[i])
        lastTextStyle = textBlocks[i]   // template tracks the last-edited block
        applyVideoComposition()
    }

    func setText(_ text: String, for id: UUID) {
        updateTextBlock(id) { $0.text = text }
    }

    func setTextPosition(x: Double, y: Double, for id: UUID) {
        updateTextBlock(id) {
            $0.centerX = min(max(0, x), 1)
            $0.centerY = min(max(0, y), 1)
        }
    }

    /// Begin a canvas position drag: select and suppress the baked copy (one
    /// recomposite) so the smooth SwiftUI overlay drives motion.
    func beginDraggingText(_ id: UUID) {
        selectTextBlock(id)
        draggingTextBlockID = id
        applyVideoComposition()
    }

    /// Live position update during a drag — moves only the published model (the
    /// overlay follows). No recomposite, so it stays smooth.
    func dragTextPosition(x: Double, y: Double, for id: UUID) {
        guard let i = textBlocks.firstIndex(where: { $0.id == id }) else { return }
        textBlocks[i].centerX = min(max(0, x), 1)
        textBlocks[i].centerY = min(max(0, y), 1)
    }

    /// End a canvas position drag: un-suppress, recomposite once at the final
    /// position, and persist.
    func endDraggingText() {
        guard let id = draggingTextBlockID else { return }
        draggingTextBlockID = nil
        if let b = textBlocks.first(where: { $0.id == id }) { lastTextStyle = b }
        applyVideoComposition()
        saveEdit()
    }

    /// Deselect any text block (closing the inline editor / drag first).
    func deselectText() {
        if draggingTextBlockID != nil {
            endDraggingText()
        } else if selectedTextBlockID != nil {
            saveEdit()   // persist any live text edit (drag-end already saved)
        }
        selectedTextBlockID = nil
    }

    /// Clear every selection — camera block and text block — so the canvas has
    /// nothing selected. Backs the empty-canvas tap and the Esc key.
    func deselectAll() {
        deselectText()
        selectedBlockID = nil
        selectedZoomBlockID = nil
        selectedLayoutBlockID = nil
        cameraSelected = false
        if draggingSubtitle { endDraggingSubtitle() }
        subtitleSelected = false
    }

    // MARK: Canvas pan/zoom (inspection only)

    private static let maxCanvasZoom: CGFloat = 8

    /// Aspect-fit size of the render canvas inside the live view bounds.
    private func canvasFitSize() -> CGSize {
        let content = renderSize, c = canvasViewSize
        guard content.width > 0, content.height > 0, c.width > 0, c.height > 0
        else { return .zero }
        let s = min(c.width / content.width, c.height / content.height)
        return CGSize(width: content.width * s, height: content.height * s)
    }

    /// Clamp the pan offset so the zoomed content can't be dragged past the
    /// view edges (and snaps to 0 once it no longer overflows).
    private func clampCanvasPan() {
        let fit = canvasFitSize()
        let overflowX = max(0, (fit.width * canvasZoom - canvasViewSize.width) / 2)
        let overflowY = max(0, (fit.height * canvasZoom - canvasViewSize.height) / 2)
        canvasPanX = min(max(canvasPanX, -overflowX), overflowX)
        canvasPanY = min(max(canvasPanY, -overflowY), overflowY)
    }

    /// Multiply the canvas zoom (center-anchored), clamped to [1, max].
    func zoomCanvas(by factor: CGFloat) {
        guard factor.isFinite, factor > 0 else { return }
        canvasZoom = min(max(canvasZoom * factor, 1), Self.maxCanvasZoom)
        clampCanvasPan()
    }

    /// Pan the zoomed canvas by a view-point delta (no-op at fit).
    func panCanvas(by delta: CGSize) {
        guard canvasZoomed else { return }
        canvasPanX += delta.width
        canvasPanY += delta.height
        clampCanvasPan()
    }

    /// Reset the inspection view back to fit.
    func resetCanvasView() {
        canvasZoom = 1
        canvasPanX = 0
        canvasPanY = 0
    }

    /// Track the live view size (e.g. window resize) and re-clamp the pan.
    func setCanvasViewSize(_ size: CGSize) {
        canvasViewSize = size
        clampCanvasPan()
    }

    // MARK: Text z-order

    func bringTextForward(_ id: UUID) {
        setTextBlocks(TextTimeline.bringForward(textBlocks, id: id), select: selectedTextBlockID)
    }

    func sendTextBackward(_ id: UUID) {
        setTextBlocks(TextTimeline.sendBackward(textBlocks, id: id), select: selectedTextBlockID)
    }

    func moveTextToFront(_ id: UUID) {
        setTextBlocks(TextTimeline.moveToFront(textBlocks, id: id), select: selectedTextBlockID)
    }

    func moveTextToBack(_ id: UUID) {
        setTextBlocks(TextTimeline.moveToBack(textBlocks, id: id), select: selectedTextBlockID)
    }

    // MARK: Text style (operate on the selected block)

    /// Mutate the selected text block live. Discrete edits pass `commit: true`
    /// to persist immediately; slider drags pass `false` and persist on end via
    /// `commitTextEdit`.
    private func updateSelectedText(commit: Bool, _ mutate: (inout TextBlock) -> Void) {
        guard let id = selectedTextBlockID else { return }
        updateTextBlock(id, mutate)
        if commit { saveEdit() }
    }

    func setTextFontName(_ name: String) { updateSelectedText(commit: true) { $0.fontName = name } }
    func setTextFontSize(_ v: Double) { updateSelectedText(commit: false) { $0.fontSize = min(max(0.005, v), 0.5) } }
    func setTextWeight(_ w: TextWeight) { updateSelectedText(commit: true) { $0.fontWeight = w } }
    func setTextColorHex(_ hex: String) { updateSelectedText(commit: true) { $0.colorHex = hex } }
    func setTextAlignment(_ a: TextAlignmentH) { updateSelectedText(commit: true) { $0.alignment = a } }
    func setTextBoxEnabled(_ on: Bool) { updateSelectedText(commit: true) { $0.boxEnabled = on } }
    func setTextBoxHex(_ hex: String) { updateSelectedText(commit: true) { $0.boxHex = hex } }
    func setTextBoxOpacity(_ v: Double) { updateSelectedText(commit: false) { $0.boxOpacity = min(max(0, v), 1) } }
    func setTextStrokeWidth(_ v: Double) { updateSelectedText(commit: false) { $0.strokeWidth = min(max(0, v), 0.2) } }
    func setTextStrokeHex(_ hex: String) { updateSelectedText(commit: true) { $0.strokeHex = hex } }
    func setTextShadow(_ on: Bool) { updateSelectedText(commit: true) { $0.shadow = on } }
    func setTextBoxWidth(_ v: Double) { updateSelectedText(commit: false) { $0.boxWidth = min(max(0.05, v), 1.0) } }
    func setTextAutoWrap(_ on: Bool) { updateSelectedText(commit: true) { $0.autoWrap = on } }

    // MARK: - Subtitles

    /// Import an `.srt`: copy it into the bundle and parse its cues (stored raw;
    /// the track offset is applied at consumption), then show the subtitle lane.
    /// Runs off the main actor with a loader. Replacing an existing track
    /// preserves the current style and offset. No-op while already busy.
    func importSubtitles(from url: URL) {
        guard subtitleState == .idle else { return }
        subtitleState = .applying
        let bundle = self.bundle
        let duration = self.duration
        let existingStyle = subtitles?.style
        let existingOffset = subtitles?.offset ?? 0
        Task { @MainActor in
            let track: SubtitleTrack? = await Task.detached {
                guard let name = try? bundle.writeSubtitleFile(from: url) else { return nil }
                let fileURL = bundle.subtitleFileURL(name)
                let raw: String
                if let data = try? Data(contentsOf: fileURL) {
                    raw = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1)
                        ?? ""
                } else {
                    raw = ""
                }
                let parsed = SubtitleParser.parse(raw)
                guard !SubtitleTimeline.effective(parsed, offset: existingOffset,
                                                  duration: duration).isEmpty else { return nil }
                return SubtitleTrack(srtFilename: name,
                                     style: existingStyle ?? SubtitleStyle(),
                                     cues: parsed, offset: existingOffset)
            }.value

            guard let track else {
                bundle.deleteSubtitleFile()
                subtitleState = .idle
                Log.studio.error("subtitle import failed or produced no cues")
                return
            }
            subtitles = track
            subtitleSelected = true
            selectedTextBlockID = nil
            selectedBlockID = nil
            selectedZoomBlockID = nil
            cameraSelected = false
            refreshPlayerItemForCanvasChange()
            applyVideoComposition()
            saveEdit()
            subtitleState = .idle
        }
    }

    /// Remove the subtitle track + its `.srt` and hide the lane. Loader-gated.
    func removeSubtitles() {
        guard subtitleState == .idle, subtitles != nil else { return }
        subtitleState = .removing
        let bundle = self.bundle
        Task { @MainActor in
            await Task.detached { bundle.deleteSubtitleFile() }.value
            subtitles = nil
            subtitleSelected = false
            draggingSubtitle = false
            refreshPlayerItemForCanvasChange()
            applyVideoComposition()
            saveEdit()
            subtitleState = .idle
        }
    }

    /// Select the subtitle track for configuration (clears camera/text
    /// selection); pass false to deselect.
    func selectSubtitles(_ on: Bool) {
        subtitleSelected = on
        if on {
            selectedTextBlockID = nil
            selectedBlockID = nil
            selectedZoomBlockID = nil
            cameraSelected = false
        }
    }

    /// Select the home/static camera placement for editing (shows the PiP
    /// overlay). Single-selection: clears every other selection and any block.
    func selectCamera() {
        cameraSelected = true
        selectedBlockID = nil
        selectedTextBlockID = nil
        selectedZoomBlockID = nil
        subtitleSelected = false
    }

    func commitSubtitleEdit() { saveEdit() }

    /// Mutate the shared subtitle style live (applies to every cue). Discrete
    /// edits commit immediately; slider drags pass `commit: false` and persist on
    /// end via `commitSubtitleEdit`.
    private func updateSubtitleStyle(commit: Bool, _ mutate: (inout SubtitleStyle) -> Void) {
        guard subtitles != nil else { return }
        mutate(&subtitles!.style)
        applyVideoComposition()
        if commit { saveEdit() }
    }

    func setSubtitleFontName(_ name: String) { updateSubtitleStyle(commit: true) { $0.fontName = name } }
    func setSubtitleFontSize(_ v: Double) { updateSubtitleStyle(commit: false) { $0.fontSize = min(max(0.01, v), 0.5) } }
    func setSubtitleWeight(_ w: TextWeight) { updateSubtitleStyle(commit: true) { $0.fontWeight = w } }
    func setSubtitleColorHex(_ hex: String) { updateSubtitleStyle(commit: true) { $0.colorHex = hex } }
    func setSubtitleAlignment(_ a: TextAlignmentH) { updateSubtitleStyle(commit: true) { $0.alignment = a } }
    func setSubtitleBoxEnabled(_ on: Bool) { updateSubtitleStyle(commit: true) { $0.boxEnabled = on } }
    func setSubtitleBoxHex(_ hex: String) { updateSubtitleStyle(commit: true) { $0.boxHex = hex } }
    func setSubtitleBoxOpacity(_ v: Double) { updateSubtitleStyle(commit: false) { $0.boxOpacity = min(max(0, v), 1) } }
    func setSubtitleStrokeWidth(_ v: Double) { updateSubtitleStyle(commit: false) { $0.strokeWidth = min(max(0, v), 0.2) } }
    func setSubtitleStrokeHex(_ hex: String) { updateSubtitleStyle(commit: true) { $0.strokeHex = hex } }
    func setSubtitleShadow(_ on: Bool) { updateSubtitleStyle(commit: true) { $0.shadow = on } }
    func setSubtitleBoxWidth(_ v: Double) { updateSubtitleStyle(commit: false) { $0.boxWidth = min(max(0.05, v), 1.0) } }

    /// Shift every cue by `seconds` (added to begin/end). Clamped to a finite
    /// guard range — intentionally NOT tied to `duration`, so a begin-trim larger
    /// than the trimmed clip can still be corrected. Recomposites + saves.
    /// A discrete control (stepper / formatted field), so it always commits —
    /// unlike the `commit: false` slider setters; do not wrap it in a deferred
    /// commit path.
    func setSubtitleOffset(_ seconds: Double) {
        guard subtitles != nil else { return }
        subtitles!.offset = min(max(-86_400, seconds), 86_400)
        applyVideoComposition()
        saveEdit()
    }

    /// Align cue #1 (the smallest raw `begin`) to the current playhead.
    func setSubtitleOffsetFromPlayhead() {
        guard let cues = subtitles?.cues, let minBegin = cues.map(\.begin).min() else { return }
        setSubtitleOffset(currentTime - minBegin)
    }

    /// Begin a canvas position drag: select the track and suppress the baked
    /// subtitles (one recomposite) so the smooth overlay drives motion.
    func beginDraggingSubtitle() {
        selectSubtitles(true)
        draggingSubtitle = true
        applyVideoComposition()
    }

    /// Live position update during a drag — moves the shared style (all cues
    /// follow). No recomposite, so it stays smooth.
    func dragSubtitlePosition(x: Double, y: Double) {
        guard subtitles != nil else { return }
        subtitles!.style.centerX = min(max(0, x), 1)
        subtitles!.style.centerY = min(max(0, y), 1)
    }

    /// End the drag: un-suppress, recomposite at the final position, and persist.
    func endDraggingSubtitle() {
        guard draggingSubtitle else { return }
        draggingSubtitle = false
        applyVideoComposition()
        saveEdit()
    }

    /// Select a block and park the playhead at its settled (end) state so the
    /// preview shows exactly what the overlay edits. Pass nil to deselect.
    func selectBlock(_ id: UUID?) {
        selectedBlockID = id
        // camera vs text vs zoom vs subtitle: one selection at a time
        if id != nil { selectedTextBlockID = nil; selectedZoomBlockID = nil; subtitleSelected = false; cameraSelected = false }
        if let id, let b = cameraBlocks.first(where: { $0.id == id }) {
            seek(to: min(b.end, duration))
        }
    }

    /// Replace the block list. Adding the first / removing the last flips the
    /// compositor on/off (and the preview canvas cap), so refresh the player
    /// item when `needsCompositor` changes, like the camera-style path.
    private func setBlocks(_ list: [CameraBlock], select id: UUID?) {
        let was = needsCompositor
        cameraBlocks = list
        selectedBlockID = id
        // One selection at a time: the add/set paths bypass `selectBlock`, so
        // clear the other kinds here too (else add-while-other-selected = both).
        if id != nil { selectedTextBlockID = nil; selectedZoomBlockID = nil; subtitleSelected = false; cameraSelected = false }
        if needsCompositor != was {
            refreshPlayerItemForCanvasChange()
        }
        applyVideoComposition()
        saveEdit()
    }

    /// Set the home layout (the toolbar layout picker for the empty-timeline /
    /// before-first-block state).
    func setHomeLayout(_ layout: CameraLayout) {
        cameraHomeLayout = layout
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
        mutate()
        rerenderPausedFrame()
    }

    private func applyCameraStyle(_ mutate: () -> Void) {
        mutate()
        // While a slider is being dragged, use the cheap live path (smooth);
        // the reliable item-swap runs once on release (`endStyleEdit`).
        if styleEditing { liveRerenderPausedFrame() } else { rerenderPausedFrame() }
    }

    /// Marks the start of a continuous style-slider drag — switches the per-tick
    /// re-render to the cheap live path so dragging stays smooth.
    func beginStyleEdit() { styleEditing = true }

    /// Ends a style-slider drag: do one reliable (item-swap) re-render so the
    /// final frame is correct, then persist.
    func endStyleEdit() {
        styleEditing = false
        rerenderPausedFrame()
        saveEdit()
    }

    private var styleEditing = false
    private var reseekScheduled = false
    private var reseekToggle = false

    /// Re-render the current frame after a discrete style / overlay edit.
    ///
    /// The custom video compositor (`StudioCompositor`) does NOT repaint a paused
    /// frame when `videoComposition` is merely reassigned — AVFoundation only
    /// re-runs it when the player's time changes. So when the compositor is
    /// engaged (a styled camera, layout blocks, cursor/click overlays …) we swap
    /// in a fresh player item: that rebuilds the composition pipeline and renders
    /// the current frame immediately — the same path the shape toggle already
    /// used. The cheap layer-instruction path repaints on reassignment, so when
    /// the compositor isn't engaged a plain composition update suffices.
    private func rerenderPausedFrame() {
        if needsCompositor {
            refreshPlayerItemForCanvasChange()
        }
        applyVideoComposition()
    }

    /// Cheap re-render for live slider drags: reassign the composition, then
    /// (next runloop, coalesced) nudge the playhead by ~one frame so the now-
    /// applied composition re-runs — no per-tick player-item swap, so it stays
    /// smooth. Seeking in the SAME runloop as the reassignment renders against the
    /// stale pipeline, hence the deferral.
    private func liveRerenderPausedFrame() {
        applyVideoComposition()
        guard needsCompositor, player != nil, !isPlaying else { return }
        if reseekScheduled { return }
        reseekScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reseekScheduled = false
            guard self.styleEditing, let player = self.player, !self.isPlaying else { return }
            let cur = player.currentTime().seconds
            self.reseekToggle.toggle()
            let step = (self.reseekToggle ? 1.0 : -1.0) * 0.04   // ~1 frame
            var t = cur + step
            if t < 0 || t > self.duration { t = cur - step }
            t = min(max(0, t), max(0, self.duration))
            player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    // MARK: - Reframe crop

    /// Current crop rect in screen-source pixels; nil when not reframing.
    var cropRectInSource: CGRect? {
        guard let ratio = cropAspect.ratio, !cropAspect.isFit,
              sourceSize.width > 0 else { return nil }
        return CropMath.cropRect(source: sourceSize, ratio: ratio, zoom: cropZoom,
                                 centerX: cropCenterX, centerY: cropCenterY)
    }

    func setCropAspect(_ aspect: CropAspect) {
        cropAspect = aspect
        if !cropPannable { panVideoMode = false }
        templateGuideVisible = (aspect == .nineBySixteenTemplate)
        cropCenterX = 0.5
        cropCenterY = 0.5
        cropZoom = 1.0
        refreshPlayerItemForCanvasChange()
        applyVideoComposition()
        saveEdit()
    }

    /// Live pan during drag; clamps so no gap shows. In fit/template mode the
    /// fitted content pans (letterboxed axis stays centered); in cover aspects
    /// the crop stays inside the source.
    func setCropCenter(x: Double, y: Double) {
        guard sourceSize.width > 0, hasReframeCanvas else { return }
        if cropAspect.isFit {
            let canvas = renderSize
            let s0 = min(canvas.width / sourceSize.width, canvas.height / sourceSize.height)
            let s = s0 / min(max(CGFloat(cropZoom), 0.2), 1.0)
            cropCenterX = Self.clampFitCenter(drawn: sourceSize.width * s,
                                              canvas: canvas.width, raw: x)
            cropCenterY = Self.clampFitCenter(drawn: sourceSize.height * s,
                                              canvas: canvas.height, raw: y)
            applyVideoComposition()
            return
        }
        guard let ratio = cropAspect.ratio else { return }
        let maxFit = CropMath.maxFitSize(source: sourceSize, ratio: ratio)
        let size = CGSize(width: maxFit.width * cropZoom, height: maxFit.height * cropZoom)
        let c = CropMath.clampedCenter(source: sourceSize, cropSize: size,
                                       centerX: x, centerY: y)
        cropCenterX = c.x
        cropCenterY = c.y
        applyVideoComposition()
    }

    /// Valid normalized center on one axis for fit-mode pan, allowing motion on
    /// both axes (a smaller, letterboxed axis pans through its bars; a larger
    /// axis pans within its overflow). The range keeps the content flush with
    /// the canvas edges; an exactly-canvas-sized axis collapses to 0.5.
    private static func clampFitCenter(drawn: CGFloat, canvas: CGFloat, raw: Double) -> Double {
        guard drawn > 0, drawn != canvas else { return 0.5 }
        let a = canvas / (2 * drawn)
        let lo = Double(min(a, 1 - a)), hi = Double(max(a, 1 - a))
        return min(max(raw, lo), hi)
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

    // MARK: - Canvas background (template/fit mode)

    /// Switch the letterbox background fill. Toggling to/from `.black` may engage
    /// or disengage the compositor, so route through `applyOverlayChange`.
    func setCanvasBackground(_ bg: CanvasBackground) {
        applyOverlayChange { canvasBackground = bg }
        saveEdit()
    }

    /// Live blur amount during slider drag (fraction of canvas width). Bg is
    /// already on the compositor path when `.blur`, so just recompose.
    func setCanvasBackgroundBlur(_ value: Double) {
        canvasBackgroundBlur = min(max(0, value), 0.2)
        applyVideoComposition()
    }

    /// Persist the blur value; call at slider-drag end, not per tick.
    func commitCanvasBackgroundBlur() {
        saveEdit()
    }

    /// Copy an uploaded photo into the bundle and switch the background to it.
    func uploadBackgroundImage(from url: URL) {
        do {
            let name = try bundle.writeBackgroundImage(from: url)
            canvasBackgroundImage = name
            loadBackgroundImage()
            applyOverlayChange { canvasBackground = .image }
            saveEdit()
        } catch {
            Log.studio.error("background image upload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Remove the uploaded photo and revert the background to black.
    func deleteBackgroundImage() {
        bundle.deleteBackgroundImages()
        canvasBackgroundImage = nil
        backgroundCIImage = nil
        applyOverlayChange { canvasBackground = .black }
        saveEdit()
    }

    /// (Re)load the uploaded photo into a cached CIImage; on a missing file drop
    /// the reference and fall back to black so render never shows an empty bg.
    private func loadBackgroundImage() {
        guard let name = canvasBackgroundImage else { backgroundCIImage = nil; return }
        backgroundCIImage = CIImage(contentsOf: bundle.backgroundImageURL(name))
        if backgroundCIImage == nil {
            canvasBackgroundImage = nil
            if canvasBackground == .image { canvasBackground = .black }
        }
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
        let cameraShown = self.cameraShown
        guard cameraShown || hasReframeCanvas || needsCompositor else { return nil }
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
        if cropAspect.isFit {
            // Contain: scale source to fit the canvas at the current zoom/pan,
            // letterboxed; renderSize's default black background fills the bars.
            let place = CropMath.fitPlacement(source: sourceSize, canvas: canvas,
                                              zoom: CGFloat(cropZoom),
                                              centerX: CGFloat(cropCenterX),
                                              centerY: CGFloat(cropCenterY))
            if place.width > 0, sourceSize.width > 0 {
                let s = place.width / sourceSize.width
                screenLayer.setTransform(
                    CGAffineTransform(scaleX: s, y: s)
                        .concatenating(CGAffineTransform(translationX: place.minX,
                                                         y: place.minY)),
                    at: .zero
                )
            }
        } else if let crop = cropRectInSource, crop.width > 0 {
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
        videoComposition.frameDuration = CMTime(value: 1, timescale: Int32(Self.compositionFrameRate))
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
        // Fit/template placement (canvas px, top-left): the whole source scaled
        // to fit at the current zoom/pan. nil = cover/crop placement.
        if cropAspect.isFit {
            layout.screenFit = CropMath.fitPlacement(source: sourceSize, canvas: canvas,
                                                     zoom: CGFloat(cropZoom),
                                                     centerX: CGFloat(cropCenterX),
                                                     centerY: CGFloat(cropCenterY))
            layout.background = canvasBackground
            layout.backgroundBlurRadius = CGFloat(canvasBackgroundBlur) * canvas.width
        }
        // Camera styling only when a (styled) camera is actually shown.
        if cameraTrackID != nil, let oriented = cameraOrientedSize {
            let pip = pipRect(in: canvas, cameraSize: oriented)
            let feedCrop = cameraCropRectInFeed ?? CGRect(origin: .zero, size: oriented)
            layout.feedSize = oriented
            layout.feedCrop = feedCrop
            layout.pip = pip
            layout.shape = cameraShape
            layout.cornerRadiusFrac = CGFloat(cameraCornerRadius)
            layout.borderWidthFrac = CGFloat(cameraBorderWidth)
            layout.borderColor = Self.cgColor(hex: cameraBorderHex)
            layout.shadow = cameraShadow
            layout.shadowRadius = CGFloat(cameraShadowRadius)
            layout.cameraQuarterTurns = cameraRotation / 90
            // Hand the compositor the blocks + home so it can resolve the layout
            // and place/fade the camera per frame. Also provided for a non-default
            // home layout with no blocks (so the compositor suppresses the main
            // video / full-screens the camera per the static home layout).
            if cameraHasTimeline || cameraHomeLayout != .mainAndFloat {
                layout.cameraTimeline = CameraTimelineSpec(blocks: cameraBlocks, home: cameraHome)
            }
        } else {
            layout.cameraTrackID = nil
        }

        // Frame-layout timeline — set whenever blocks exist or the home layout
        // isn't the default, so the compositor suppresses the main video,
        // full-screens the camera, or blacks out gaps per the sampled layout.
        // Independent of the camera track (a gap / main-only needs it too).
        if !layoutBlocks.isEmpty || cameraHomeLayout != .mainAndFloat {
            layout.layoutTimeline = LayoutTimelineSpec(blocks: layoutBlocks,
                                                       home: cameraHomeLayout)
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
        if layout.background == .image { overlay.backgroundImage = backgroundCIImage }

        // Text/caption blocks (rendered topmost). Suppress only the block being
        // dragged (the smooth overlay drives motion); editing is off-canvas so
        // its baked text stays visible and updates live.
        if !textBlocks.isEmpty {
            layout.textTimeline = TextTimelineSpec(blocks: textBlocks)
            layout.suppressedTextBlockID = draggingTextBlockID
        }
        // Subtitle cues (rendered below text blocks). Suppressed entirely while
        // the canvas position box is being dragged — the smooth overlay drives
        // motion, the cue re-bakes at the dropped position.
        if let track = subtitles, !draggingSubtitle {
            let cues = effectiveSubtitleCues
            if !cues.isEmpty {
                layout.subtitles = SubtitleTimelineSpec(style: track.style, cues: cues)
            }
        }

        // Auto zoom/pan: pre-build the smoothed track from blocks + cursor
        // samples (cursor data is loaded regardless of the showCursor toggle).
        if !zoomBlocks.isEmpty {
            overlay.autoZoom = AutoZoomTrack.build(blocks: zoomBlocks,
                                                   cursorSamples: cursorSamples,
                                                   sourceSize: sourceSize,
                                                   config: autoZoomConfig)
        }

        let instruction = StudioCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: composition.duration),
            layout: layout,
            overlay: overlay
        )
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = StudioCompositor.self
        videoComposition.renderSize = canvas
        videoComposition.frameDuration = CMTime(value: 1, timescale: Int32(Self.compositionFrameRate))
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
            cameraHomeLayout: cameraHomeLayout,
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
            cropZoom: cropZoom,
            canvasBackground: canvasBackground,
            canvasBackgroundBlur: canvasBackgroundBlur,
            canvasBackgroundImage: canvasBackgroundImage,
            cameraBlocks: cameraBlocks,
            textBlocks: textBlocks,
            subtitles: subtitles,
            zoomBlocks: zoomBlocks,
            layoutBlocks: layoutBlocks
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
        if hasReframeCanvas {
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
            if cropAspect.isFit {
                let longSide = max(sourceSize.width, sourceSize.height)
                let shortSide = (longSide * 9.0 / 16.0 / 2).rounded() * 2
                return canvasSize(shortSide: shortSide) ?? sourceSize
            }
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
