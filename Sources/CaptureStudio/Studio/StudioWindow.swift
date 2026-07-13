import SwiftUI
import AVFoundation
import AppKit

struct StudioView: View {
    @StateObject private var model: StudioModel
    @State private var activeTab: RailTab = .frame
    @State private var timelineScroll = ScrollPosition(edge: .leading)
    @State private var timelineScrollX: CGFloat = 0

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

    private let gutterIconWidth: CGFloat = 20
    private let gutterSpacing: CGFloat = 6
    private let laneSpacing: CGFloat = 8

    /// Stacked timeline lanes. A fixed leading icon gutter, then one shared
    /// horizontal ScrollView holding every track framed to the same
    /// `contentWidth` (= viewport × timelineZoom), so the lanes stay aligned and
    /// scroll together. At zoom 1 the content is exactly the viewport (classic
    /// fit-to-window); higher zoom widens it and it scrolls.
    @ViewBuilder private var timelineStack: some View {
        GeometryReader { geo in
            let viewport = max(0, geo.size.width - gutterIconWidth - gutterSpacing)
            let contentWidth = TimelineScale.contentWidth(viewport: viewport, zoom: model.timelineZoom)
            HStack(alignment: .top, spacing: gutterSpacing) {
                gutterColumn
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(spacing: laneSpacing) {
                        ForEach(visibleLanes, id: \.self) { lane in
                            laneTrack(lane, contentWidth: contentWidth)
                                .frame(width: contentWidth, height: laneHeight(lane), alignment: .leading)
                        }
                    }
                }
                .scrollPosition($timelineScroll)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
                    timelineScrollX = x
                }
                .overlay {
                    // Ctrl + scroll zooms at the pointer; other scrolls pass
                    // through to the ScrollView for normal panning.
                    ScrollWheelZoomCatcher { localX, delta in
                        ctrlZoom(atLocalX: localX, delta: delta,
                                 viewport: viewport, contentWidth: contentWidth)
                    }
                }
                .onChange(of: model.currentTime) { _, _ in
                    revealPlayhead(viewport: viewport, contentWidth: contentWidth)
                }
                .onChange(of: model.timelineZoom) { _, _ in
                    revealPlayhead(viewport: viewport, contentWidth: contentWidth)
                }
            }
        }
        .frame(height: timelineTotalHeight)
        .padding(12)
        .background(.bar)
    }

    /// The fixed icon gutter, one icon per visible lane at that lane's height so
    /// the icons line up with their tracks.
    private var gutterColumn: some View {
        VStack(spacing: laneSpacing) {
            ForEach(visibleLanes, id: \.self) { lane in
                Image(systemName: laneIcon(lane))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: gutterIconWidth, height: laneHeight(lane))
            }
        }
    }

    private enum Lane: Hashable { case display, layout, camera, text, shape, zoom, subtitle }

    /// The lanes to show, in stacking order, gated by the same `shows*`
    /// conditions the old per-row layout used.
    private var visibleLanes: [Lane] {
        var out: [Lane] = [.display]
        if model.showsLayoutTimeline { out.append(.layout) }
        if model.showsCameraTimeline { out.append(.camera) }
        if !model.textBlocks.isEmpty { out.append(.text) }
        if model.showsShapeTimeline { out.append(.shape) }
        if model.showsZoomTimeline { out.append(.zoom) }
        if model.showsSubtitleTimeline { out.append(.subtitle) }
        return out
    }

    private func laneIcon(_ lane: Lane) -> String {
        switch lane {
        case .display: return "display"
        case .layout: return "rectangle.on.rectangle"
        case .camera: return "video.fill"
        case .text: return "textformat"
        case .shape: return "square.on.circle"
        case .zoom: return "plus.magnifyingglass"
        case .subtitle: return "captions.bubble"
        }
    }

    /// Each lane's height — fixed for the scrubber/block lanes, packed-row height
    /// for the dynamic (overlap) lanes. Shared with `gutterColumn` so icons and
    /// tracks stay aligned (uses the same packing the lane bodies use).
    private func laneHeight(_ lane: Lane) -> CGFloat {
        switch lane {
        case .display: return TimelineLaneMetrics.scrubberHeight
        case .layout, .camera, .zoom: return TimelineLaneMetrics.blockLaneHeight
        case .text:
            return TimelineLaneMetrics.packedHeight(rowCount: TextTimeline.subRows(model.textBlocks).count)
        case .shape:
            return TimelineLaneMetrics.packedHeight(rowCount: ShapeTimeline.subRows(model.shapeBlocks).count)
        case .subtitle:
            return TimelineLaneMetrics.packedHeight(rowCount: SubtitleTimeline.subRows(model.effectiveSubtitleCues).count)
        }
    }

    @ViewBuilder private func laneTrack(_ lane: Lane, contentWidth: CGFloat) -> some View {
        switch lane {
        case .display: timeline
        case .layout: LayoutTimelineLane(model: model)
        case .camera: CameraTimelineLane(model: model)
        case .text: TextTimelineLane(model: model)
        case .shape: ShapeTimelineLane(model: model)
        case .zoom: ZoomTimelineLane(model: model)
        case .subtitle: SubtitleTimelineLane(model: model)
        }
    }

    /// Height of the stacked lanes (sum of visible lane heights + spacing). The
    /// surrounding `.padding(12)` adds the chrome, so this must NOT include it.
    private var timelineTotalHeight: CGFloat {
        let lanes = visibleLanes
        let heights = lanes.map(laneHeight).reduce(0, +)
        let spacing = CGFloat(max(0, lanes.count - 1)) * laneSpacing
        return heights + spacing
    }

    /// Zoom anchored at the pointer (from a Ctrl+scroll): the time under the
    /// pointer stays put as the content grows/shrinks.
    private func ctrlZoom(atLocalX localX: CGFloat, delta: CGFloat,
                          viewport: CGFloat, contentWidth: CGFloat) {
        guard model.duration > 0, viewport > 0 else { return }
        let pps = TimelineScale.pixelsPerSecond(contentWidth: contentWidth, duration: model.duration)
        guard pps > 0 else { return }
        let anchorTime = Double((timelineScrollX + localX) / pps)
        model.zoomTimeline(by: 1 + Double(delta) * 0.01)
        let newContent = TimelineScale.contentWidth(viewport: viewport, zoom: model.timelineZoom)
        let x = TimelineScale.scrollX(keepingTime: anchorTime, atViewportX: localX,
                                      viewport: viewport, contentWidth: newContent,
                                      duration: model.duration)
        timelineScroll.scrollTo(x: x)
    }

    /// Keep the playhead on screen while zoomed (no-op at fit or when already
    /// visible).
    private func revealPlayhead(viewport: CGFloat, contentWidth: CGFloat) {
        guard model.isTimelineZoomed, viewport > 0, contentWidth > viewport else { return }
        if let x = TimelineScale.scrollToReveal(time: model.currentTime,
                                                currentScrollX: timelineScrollX,
                                                viewport: viewport, contentWidth: contentWidth,
                                                duration: model.duration) {
            timelineScroll.scrollTo(x: x)
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

/// A transparent overlay that reports Ctrl+scroll gestures (for zoom-at-pointer)
/// while letting every other mouse/scroll event fall through to the ScrollView
/// underneath. `hitTest` returns nil so clicks/drags (scrub, block edits) pass
/// through; a local scroll-wheel monitor intercepts ONLY Ctrl+scroll within the
/// view's bounds and consumes it, leaving plain scroll/pan to the ScrollView.
private struct ScrollWheelZoomCatcher: NSViewRepresentable {
    /// (pointer x within the view, dominant scroll delta).
    let onCtrlScroll: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView(onCtrlScroll: onCtrlScroll) }
    func updateNSView(_ view: CatcherView, context: Context) { view.onCtrlScroll = onCtrlScroll }

    final class CatcherView: NSView {
        var onCtrlScroll: (CGFloat, CGFloat) -> Void
        private var monitor: Any?

        init(onCtrlScroll: @escaping (CGFloat, CGFloat) -> Void) {
            self.onCtrlScroll = onCtrlScroll
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { return nil }

        // Pass all pointer hits through to the ScrollView below.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard monitor == nil, window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      event.modifierFlags.contains(.control) else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
                if delta != 0 { self.onCtrlScroll(p.x, delta) }
                return nil   // consume Ctrl+scroll so the ScrollView doesn't pan
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
