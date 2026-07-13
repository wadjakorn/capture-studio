import SwiftUI
import AVFoundation

struct StudioView: View {
    @StateObject private var model: StudioModel
    @State private var activeTab: RailTab = .frame

    init(bundleURL: URL) {
        _model = StateObject(wrappedValue: StudioModel(bundleURL: bundleURL))
    }

    var body: some View {
        Group {
            switch model.loadState {
            case .loading:
                ProgressView("Opening recording…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView(
                    "Can't open recording",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .ready:
                editorView
            }
        }
        .frame(minWidth: 480, minHeight: 480)
        .task { await model.load() }
        .navigationTitle(model.bundle.url.deletingPathExtension().lastPathComponent)
    }

    // MARK: - Selection → inspector context

    private var selectionSummary: StudioSelectionSummary {
        StudioSelectionSummary(
            textSelected: model.selectedTextBlockID != nil,
            shapeSelected: model.selectedShapeBlockID != nil,
            zoomSelected: model.selectedZoomBlockID != nil,
            cameraMoveSelected: model.selectedBlockID != nil,
            layoutSelected: model.selectedLayoutBlockID != nil,
            subtitleSelected: model.subtitleSelected,
            cameraSelected: model.cameraSelected)
    }

    private var inspectorContext: InspectorContext {
        InspectorContext.resolve(selection: selectionSummary, activeTab: activeTab)
    }

    // MARK: - Four-zone editor shell

    private var editorView: some View {
        VStack(spacing: 0) {
            StudioAppBar(model: model)
            Divider()
            StudioCanvasToolbar(model: model,
                                maskAction: { model.addShapeBlock(kind: .rectangle) },
                                zoomAction: { model.addZoomBlock() })
                .disabled(model.isExporting)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if let player = model.player {
                        canvas(player: player).disabled(model.isExporting)
                    }
                }
                Divider()
                InspectorRail(active: $activeTab, context: inspectorContext, model: model)
                    .disabled(model.isExporting)
            }
            Divider()
            StudioTransportBar(model: model).disabled(model.isExporting)
            timelineStack.disabled(model.isExporting)
        }
        // Esc deselects any selected block (the text input owns Esc while open).
        .background {
            // Click any inert region of the editor (toolbar gaps, group/lane
            // padding) to deselect — not just the empty canvas. Interactive
            // controls (buttons, sliders, lanes, canvas overlays) consume their
            // own clicks, so only "still parts" fall through to here.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.deselectAll() }
            // The inline caption field owns Esc while a text block is selected.
            if model.selectedTextBlock == nil {
                Button("") { model.deselectAll() }
                    .keyboardShortcut(.cancelAction).opacity(0)
            }
            // Block window close while exporting (minimize stays allowed).
            StudioWindowCloseGuard(isExporting: { model.isExporting })
        }
    }

    /// Preview canvas: the player + editing overlays, wrapped in a view-only
    /// pan/zoom transform (for inspecting high-res frames) with a transparent
    /// scroll/pinch/middle-drag catcher on top and a reset badge.
    private func canvas(player: AVPlayer) -> some View {
        GeometryReader { geo in
            ZStack {
                ZStack {
                    PlayerView(player: player)
                    // Bottom: tap deselects, left-drag pans the inspection view.
                    CanvasNavigationLayer(model: model)
                    // Click a visible caption to select it (above navigation).
                    TextSelectHitLayer(model: model)
                    // Click a visible shape to select it.
                    ShapeSelectHitLayer(model: model)
                    // Click the camera to select it; the full overlay (handles)
                    // only appears once selected, so it can be deselected.
                    if model.cameraOverlayEditableAtPlayhead && !model.showsCameraOverlay {
                        CameraSelectHitLayer(model: model)
                    }
                    if model.showsCameraOverlay {
                        CameraPipOverlay(model: model)
                    }
                    if model.selectedTextBlock != nil {
                        TextCanvasOverlay(model: model)
                    }
                    if model.selectedShapeBlock != nil {
                        ShapeCanvasOverlay(model: model)
                    }
                    // Reticle to reposition a manual zoom block's held frame.
                    if model.selectedZoomMode == .manual {
                        ZoomCanvasOverlay(model: model)
                    }
                    if model.subtitleSelected {
                        SubtitleCanvasOverlay(model: model)
                    }
                    // Framing window transform handles (studio-only, edit mode).
                    if model.frameEnabled && model.frameEditMode {
                        FrameCanvasOverlay(model: model)
                    }
                    // Topmost: reels safe-area guide (studio-only).
                    ReelsSafeAreaOverlay(model: model)
                    // Pan-video mode: a top grab layer that wins all drags in the
                    // video rect while the mode is on.
                    if model.panVideoMode {
                        CropPanOverlay(model: model)
                    }
                }
                .scaleEffect(model.canvasZoom)
                .offset(x: model.canvasPanX, y: model.canvasPanY)

                // Trackpad/mouse pan + zoom — transparent to clicks.
                CanvasEventCatcher(model: model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .overlay(alignment: .topTrailing) { zoomBadge }
            .onChange(of: geo.size, initial: true) { _, size in
                model.setCanvasViewSize(size)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Zoom indicator + reset, shown only while the canvas is zoomed in.
    @ViewBuilder private var zoomBadge: some View {
        if model.canvasZoomed {
            Button { model.resetCanvasView() } label: {
                HStack(spacing: 4) {
                    Text("\(Int((model.canvasZoom * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Reset zoom (fit)")
            .padding(8)
        }
    }

    // MARK: - Timeline

    /// Stacked timeline lanes: the main display scrubber plus each track lane,
    /// gated by its own `model.shows*` condition. Lanes share a fixed leading
    /// icon gutter so every track starts at the same x — keeping the playheads
    /// vertically aligned.
    @ViewBuilder private var timelineStack: some View {
        VStack(spacing: 8) {
            laneRow("display") { timeline }
            if model.showsLayoutTimeline {
                laneRow("rectangle.on.rectangle") { LayoutTimelineLane(model: model) }
            }
            if model.showsCameraTimeline {
                laneRow("video.fill") { CameraTimelineLane(model: model) }
            }
            if !model.textBlocks.isEmpty {
                laneRow("textformat") { TextTimelineLane(model: model) }
            }
            if model.showsShapeTimeline {
                laneRow("square.on.circle") { ShapeTimelineLane(model: model) }
            }
            if model.showsZoomTimeline {
                laneRow("plus.magnifyingglass") { ZoomTimelineLane(model: model) }
            }
            if model.showsSubtitleTimeline {
                laneRow("captions.bubble") { SubtitleTimelineLane(model: model) }
            }
        }
        .padding(12)
        .background(.bar)
    }

    /// One timeline lane: a fixed-width leading icon gutter + the track. Shared
    /// by the main scrubber and the camera lane so their time axes line up.
    private func laneRow<Track: View>(_ systemImage: String,
                                      @ViewBuilder track: () -> Track) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            track()
        }
    }

    private var timeline: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                    .frame(height: 6)
                // Kept (trimmed) region.
                if model.duration > 0 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.tint)
                        .frame(width: max(0, fraction(model.trimOut - model.trimIn) * width), height: 6)
                        .offset(x: fraction(model.trimIn) * width)
                    // Cut (hidden) segments: greyed over the kept region; split
                    // boundaries: hairline ticks. Non-destructive — Reset restores.
                    ForEach(model.segments) { seg in
                        if seg.hidden {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.black.opacity(0.45))
                                .frame(width: max(0, fraction(seg.end - seg.start) * width), height: 6)
                                .offset(x: fraction(seg.start) * width)
                        }
                        if seg.start > 0.0001 {
                            Rectangle()
                                .fill(.secondary)
                                .frame(width: 1, height: 10)
                                .offset(x: fraction(seg.start) * width)
                        }
                    }
                    // Playhead.
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2, height: 16)
                        .offset(x: fraction(model.currentTime) * width - 1)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let t = Double(value.location.x / width) * model.duration
                        model.seek(to: t)
                    }
            )
        }
        .frame(height: 18)
    }

    private func fraction(_ seconds: Double) -> CGFloat {
        guard model.duration > 0 else { return 0 }
        return CGFloat(min(max(0, seconds / model.duration), 1))
    }
}
