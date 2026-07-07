import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct StudioView: View {
    @StateObject private var model: StudioModel
    @State private var showCameraStyle = false
    @State private var showTextStyle = false
    @State private var showShapeStyle = false
    @State private var showSubtitleStyle = false
    @State private var showZoomStyle = false
    @State private var confirmRemoveSubtitles = false

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

    private var editorView: some View {
        VStack(spacing: 0) {
            if let player = model.player {
                canvas(player: player)
                    // Hard-lock the preview/editing surface while exporting.
                    .disabled(model.isExporting)
            }
            controlBar
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

    private var controlBar: some View {
        VStack(spacing: 8) {
            // Stacked lanes share a fixed leading icon gutter so every track
            // starts at the same x — keeping the playheads vertically aligned.
            // Locked during export (all but the output/Stop group below).
            Group {
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
            .disabled(model.isExporting)

            Divider().padding(.vertical, 2)

            // Row 1 — transport + trim (left, wraps when narrow) and output
            // pinned right. Output stays live during export so Stop is reachable.
            HStack(alignment: .top, spacing: 12) {
                FlowLayout(hSpacing: 8, vSpacing: 8) {
                    toolGroup { transportControls }
                    toolGroup { trimControls }
                }
                .disabled(model.isExporting)
                Spacer(minLength: 12)
                toolGroup { outputControls }
            }

            // Row 2 — editing tools, grouped; each group wraps intact. Order:
            // sound · main video · mouse · camera · subtitle · cursor-follow · text.
            FlowLayout(hSpacing: 8, vSpacing: 8) {
                if model.hasSystemAudioTrack || model.hasMicTrack {
                    toolGroup { AudioInspector(model: model) }
                }
                toolGroup { reframeControls }
                toolGroup { cursorControls }            // mouse appearance
                if model.hasCameraTrack {
                    toolGroup { cameraControls }
                }
                toolGroup { subtitleControls }
                    .onChange(of: model.subtitles == nil) { _, nowNil in
                        if nowNil { showSubtitleStyle = false }
                    }
                toolGroup { zoomControls }              // cursor follow (auto zoom/pan)
                    .onChange(of: model.selectedZoomBlockID == nil) { _, nowNil in
                        if nowNil { showZoomStyle = false }
                    }
                toolGroup { textControls }              // text
                toolGroup { shapeControls }             // shapes — last group
            }
            .disabled(model.isExporting)
        }
        .padding(12)
        .background(.bar)
    }

    /// A labelled cluster of related controls with a subtle rounded backing, so
    /// groups read as units and wrap intact as the window resizes.
    private func toolGroup<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }

    // MARK: - Control groups

    @ViewBuilder private var transportControls: some View {
        Button { model.togglePlay() } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 22)
        }
        .keyboardShortcut(.space, modifiers: [])
        .help(model.isPlaying ? "Pause" : "Play")

        Text("\(timecode(model.currentTime)) / \(timecode(model.duration))")
            .font(.body.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var trimControls: some View {
        Button("Set In") { model.setTrimIn(model.currentTime) }
        Button("Set Out") { model.setTrimOut(model.currentTime) }
        Button { model.resetTrim() } label: { Image(systemName: "arrow.uturn.backward") }
            .help("Reset trim")
        Button { model.applyTrim() } label: { Image(systemName: "scissors") }
            .disabled(!model.canApplyTrim)
            .help("Apply trim — cut everything outside In/Out off the timeline")
        Text("\(timecode(model.trimIn)) – \(timecode(model.trimOut))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var outputControls: some View {
        Button { model.revealMastersInFinder() } label: {
            Image(systemName: "folder")
        }
        .help("Reveal master files in Finder")
        exportControls
    }

    @ViewBuilder private var reframeControls: some View {
        Menu {
            ForEach(CropAspect.allCases, id: \.self) { aspect in
                Button {
                    model.setCropAspect(aspect)
                } label: {
                    if model.cropAspect == aspect {
                        Label(aspect.displayName, systemImage: "checkmark")
                    } else {
                        Text(aspect.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "aspectratio")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Reframe aspect ratio")

        Toggle(isOn: Binding(get: { model.panVideoMode },
                             set: { model.panVideoMode = $0 })) {
            Image(systemName: "hand.draw")
        }
        .toggleStyle(.button)
        .disabled(!model.cropPannable)
        .help("Move/pan the reframed video — drag the canvas to reposition it")

        Toggle(isOn: Binding(get: { model.templateGuideVisible },
                             set: { model.templateGuideVisible = $0 })) {
            Image(systemName: "rectangle.dashed")
        }
        .toggleStyle(.button)
        .disabled(model.cropAspect != .nineBySixteenTemplate)
        .help("Toggle reels safe-area guide")

        // Framing window: mask the main video to a static rectangle.
        Toggle(isOn: Binding(get: { model.frameEnabled },
                             set: { model.setFrameEnabled($0) })) {
            Image(systemName: "inset.filled.rectangle")
        }
        .toggleStyle(.button)
        .help("Framing window — mask the main video to a static rectangle it pans behind")

        if model.frameEnabled {
            Toggle(isOn: Binding(get: { model.frameEditMode },
                                 set: { model.frameEditMode = $0 })) {
                Image(systemName: "slider.horizontal.below.rectangle")
            }
            .toggleStyle(.button)
            .help("Show framing window transform handles")

            Button { model.resetFrame() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("Reset framing window to full center")
        }

        if model.cropPannable {
            HStack(spacing: 4) {
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: Binding(get: { 1.2 - model.cropZoom },
                                      set: { model.setCropZoom(1.2 - $0) }),
                       in: 0.2...1.0) { editing in
                    if !editing { model.commitCropEdit() }
                }
                .frame(width: 80)
                .controlSize(.small)
            }
            .help("Crop zoom — drag the video to pan")
        }

        if model.cropAspect.isFit {
            backgroundControls
        }
    }

    /// Letterbox-bar background controls, shown only in template/fit mode:
    /// pick Black / Blur / Photo, a blur-amount slider, and a delete button.
    @ViewBuilder private var backgroundControls: some View {
        Menu {
            Button { model.setCanvasBackground(.black) } label: {
                if model.canvasBackground == .black {
                    Label("Black", systemImage: "checkmark")
                } else { Text("Black") }
            }
            Button { model.setCanvasBackground(.blur) } label: {
                if model.canvasBackground == .blur {
                    Label("Blur", systemImage: "checkmark")
                } else { Text("Blur") }
            }
            Button { pickBackgroundImage() } label: {
                if model.canvasBackground == .image {
                    Label("Photo…", systemImage: "checkmark")
                } else { Text("Photo…") }
            }
        } label: {
            Image(systemName: "photo.artframe")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Background fill for the letterbox bars")

        if model.canvasBackground == .blur {
            HStack(spacing: 4) {
                Image(systemName: "drop").foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.canvasBackgroundBlur },
                                      set: { model.setCanvasBackgroundBlur($0) }),
                       in: 0...0.2) { editing in
                    if !editing { model.commitCanvasBackgroundBlur() }
                }
                .frame(width: 80)
                .controlSize(.small)
            }
            .help("Background blur amount")
        }

        if model.canvasBackground == .image {
            Button(role: .destructive) { model.deleteBackgroundImage() } label: {
                Image(systemName: "trash")
            }
            .help("Remove background photo")
        }
    }

    /// Pick an image file and set it as the canvas background.
    private func pickBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.uploadBackgroundImage(from: url)
        }
    }

    /// The layout the toolbar picker edits: the selected block's, else the home
    /// (empty-timeline / before-first-block) layout.
    private var layoutBinding: Binding<CameraLayout> {
        Binding(
            get: { model.selectedLayoutBlock?.layout ?? model.cameraHomeLayout },
            set: { newValue in
                if let id = model.selectedLayoutBlockID { model.setLayoutBlockLayout(id, newValue) }
                else { model.setHomeLayout(newValue) }
            })
    }

    @ViewBuilder private var cameraControls: some View {
        // Layout picker — picks the frame layout for the selected layout block
        // (or the home/default state when no layout block is selected).
        Picker("Layout", selection: layoutBinding) {
            ForEach(CameraLayout.allCases, id: \.self) { layout in
                Label(layout.label, systemImage: layout.symbol).tag(layout)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 150)
        .disabled(model.selectedLayoutBlockID == nil)
        .help(model.selectedLayoutBlockID == nil
              ? "Select a layout block to change its frame layout"
              : "Frame layout for the selected layout block")

        // Add / remove layout blocks — a layout block sets the frame layout over
        // a span; gaps render blank. Add is disabled when the timeline is full.
        Button { model.addLayoutBlock() } label: {
            Label("Add layout", systemImage: "rectangle.stack.badge.plus")
        }
        .disabled(!model.canAddLayoutBlock)
        .help("Add a layout block at the playhead")

        Button {
            if let id = model.selectedLayoutBlockID { model.removeLayoutBlock(id) }
        } label: {
            Image(systemName: "rectangle.stack.badge.minus")
        }
        .disabled(model.selectedLayoutBlockID == nil)
        .help("Delete the selected layout block")

        Divider().frame(height: 16)

        // Style dropdown — global camera config (zoom + frame style), editable
        // in every layout per the design (applies wherever the camera renders).
        Button { showCameraStyle.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .help("Camera style — zoom, frame & shape")
        .popover(isPresented: $showCameraStyle, arrowEdge: .bottom) {
            CameraInspector(model: model)
        }

        // Camera move keyframes — position/scale only; only meaningful while the
        // camera floats (main+float / float-camera) at the playhead.
        Button { model.addBlock() } label: {
            Label("Add move", systemImage: "plus.rectangle")
        }
        .disabled(!model.layoutAtPlayhead.cameraFloats)
        .help("Add a camera move block at the playhead")

        Button {
            if let id = model.selectedBlockID { model.removeBlock(id) }
        } label: {
            Image(systemName: "minus.rectangle")
        }
        .disabled(model.selectedBlockID == nil)
        .help("Delete the selected camera move block")
    }

    @ViewBuilder private var textControls: some View {
        Button { model.addTextBlock() } label: {
            Image(systemName: "text.badge.plus")
        }
        .help("Add a text/caption block at the playhead")

        Button { showTextStyle.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .disabled(model.selectedTextBlock == nil)
        .help("Edit text style")
        .popover(isPresented: $showTextStyle, arrowEdge: .bottom) {
            CaptionsInspector.TextSection(model: model)
        }

        // Z-order + delete for the selected block — always shown, disabled
        // until a block is selected.
        Button {
            if let id = model.selectedTextBlockID { model.sendTextBackward(id) }
        } label: { Image(systemName: "arrow.down.square") }
            .disabled(model.selectedTextBlock == nil)
            .help("Send backward")
        Button {
            if let id = model.selectedTextBlockID { model.bringTextForward(id) }
        } label: { Image(systemName: "arrow.up.square") }
            .disabled(model.selectedTextBlock == nil)
            .help("Bring forward")
        Button(role: .destructive) {
            if let id = model.selectedTextBlockID { model.removeTextBlock(id) }
        } label: { Image(systemName: "trash") }
            .disabled(model.selectedTextBlock == nil)
            .help("Delete this text block")

        // Inline caption input — always shown; editable only while a text block
        // is selected (timeline or canvas), greyed out otherwise. Bigger so
        // multi-line captions are comfortable to edit.
        CaptionTextEditor(
            text: Binding(
                get: { model.selectedTextBlock?.text ?? "" },
                set: { if let id = model.selectedTextBlockID { model.setText($0, for: id) } }
            ),
            isEnabled: model.selectedTextBlock != nil,
            focusToken: model.selectedTextBlockID,
            onSubmit: { model.commitTextEdit() },
            onCancel: { model.deselectAll() }
        )
        .frame(width: 320, height: 56)
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(.secondary.opacity(0.3), lineWidth: 1))
        .opacity(model.selectedTextBlock == nil ? 0.55 : 1)
        .help(model.selectedTextBlock == nil
              ? "Select a text block to edit its caption"
              : "Edit caption text · Shift+Return for a new line")
    }

    @ViewBuilder private var shapeControls: some View {
        Menu {
            Button { model.addShapeBlock(kind: .rectangle) } label: {
                Label("Rectangle", systemImage: "rectangle")
            }
            Button { model.addShapeBlock(kind: .ellipse) } label: {
                Label("Ellipse", systemImage: "oval")
            }
            Button { model.addShapeBlock(kind: .blur) } label: {
                Label("Blur (censor)", systemImage: "drop.halffull")
            }
        } label: {
            Image(systemName: "square.on.circle")
        }
        .menuIndicator(.hidden)
        .frame(width: 44)
        .help("Add a shape overlay (rectangle / ellipse / blur) at the playhead")

        Button { showShapeStyle.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .disabled(model.selectedShapeBlock == nil)
        .help("Edit shape style")
        .popover(isPresented: $showShapeStyle, arrowEdge: .bottom) {
            ShapeInspector(model: model)
        }

        // Z-order + delete for the selected block — always shown, disabled until
        // a block is selected.
        Button {
            if let id = model.selectedShapeBlockID { model.sendShapeBackward(id) }
        } label: { Image(systemName: "arrow.down.square") }
            .disabled(model.selectedShapeBlock == nil)
            .help("Send backward")
        Button {
            if let id = model.selectedShapeBlockID { model.bringShapeForward(id) }
        } label: { Image(systemName: "arrow.up.square") }
            .disabled(model.selectedShapeBlock == nil)
            .help("Bring forward")
        Button(role: .destructive) {
            if let id = model.selectedShapeBlockID { model.removeShapeBlock(id) }
        } label: { Image(systemName: "trash") }
            .disabled(model.selectedShapeBlock == nil)
            .help("Delete this shape block")
    }

    @ViewBuilder private var zoomControls: some View {
        Button { model.addZoomBlock() } label: {
            Label("Add zoom", systemImage: "plus.magnifyingglass")
        }
        .help("Add an auto zoom/pan block at the playhead")

        // Per-block scale + sensitivity live in the popover — only meaningful
        // with a zoom block selected, so the button is gated on selection.
        Button { showZoomStyle.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .disabled(model.selectedZoomBlockID == nil)
        .help("Zoom magnification & follow sensitivity for the selected block")
        .popover(isPresented: $showZoomStyle, arrowEdge: .bottom) {
            ZoomInspector(model: model)
        }

        Button(role: .destructive) {
            if let id = model.selectedZoomBlockID { model.removeZoomBlock(id) }
        } label: {
            Image(systemName: "trash")
        }
        .disabled(model.selectedZoomBlockID == nil)
        .help("Delete the selected zoom block")
    }

    @ViewBuilder private var subtitleControls: some View {
        if model.subtitles == nil {
            Button { pickSubtitleFile() } label: {
                Image(systemName: "captions.bubble")
            }
            .disabled(model.subtitleState != .idle)
            .help("Import subtitles from an .srt file")
        } else {
            Button {
                model.selectSubtitles(true)
                showSubtitleStyle.toggle()
            } label: {
                Image(systemName: "captions.bubble.fill")
            }
            .disabled(model.subtitleState != .idle)
            .help("Subtitle style & position")
            .popover(isPresented: $showSubtitleStyle, arrowEdge: .bottom) {
                CaptionsInspector.SubtitleSection(model: model)
            }
        }

        // Bin always shown; disabled until a track exists, mirroring the other
        // delete controls. Confirms before removing (destructive).
        Button(role: .destructive) { confirmRemoveSubtitles = true } label: {
            Image(systemName: "trash")
        }
        .disabled(model.subtitles == nil || model.subtitleState != .idle)
        .help("Remove subtitles")
        .confirmationDialog("Remove subtitles?", isPresented: $confirmRemoveSubtitles,
                            titleVisibility: .visible) {
            Button("Remove Subtitles", role: .destructive) { model.removeSubtitles() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the imported subtitle track from this project.")
        }

        if model.subtitleState != .idle {
            ProgressView().controlSize(.small)
        }
    }

    /// Pick a `.srt` file and apply it as the subtitle track.
    private func pickSubtitleFile() {
        let panel = NSOpenPanel()
        if let srt = UTType(filenameExtension: "srt") {
            panel.allowedContentTypes = [srt, .text]
        } else {
            panel.allowedContentTypes = [.text]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.importSubtitles(from: url)
        }
    }

    @ViewBuilder private var cursorControls: some View {
        Toggle(isOn: Binding(get: { model.showCursor },
                             set: { model.setShowCursor($0) })) {
            Image(systemName: "cursorarrow")
        }
        .toggleStyle(.button)
        .help("Show the recorded cursor")

        Toggle(isOn: Binding(get: { model.clickFeedback },
                             set: { model.setClickFeedback($0) })) {
            Image(systemName: "cursorarrow.click")
        }
        .toggleStyle(.button)
        .help("Show click feedback rings")
    }

    // MARK: - Timeline

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

    // MARK: - Export

    @ViewBuilder
    private var exportControls: some View {
        switch model.exportState {
        case .exporting(let progress):
            ProgressView(value: progress)
                .frame(width: 120)
            Text("\(Int(progress * 100))%")
                .font(.caption.monospacedDigit())
            Button { model.cancelExport() } label: {
                Image(systemName: "stop.fill")
            }
            .tint(.red)
            .help("Stop export")
        case .done(let url):
            Button("Show Export") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                model.dismissExportResult()
            }
            .tint(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
            Button("OK") { model.dismissExportResult() }
        case .idle:
            Menu("Export") {
                ForEach(ExportPreset.allCases) { preset in
                    Button(preset.rawValue) { runExport(preset) }
                }
            }
            .menuStyle(.button)
            .fixedSize()
        }
    }

    private func runExport(_ preset: ExportPreset) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = model.bundle.url
            .deletingPathExtension().lastPathComponent + ".mp4"
        panel.canCreateDirectories = true
        let exportDir = ProjectBundle.defaultRecordingsDirectory()
            .appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        panel.directoryURL = exportDir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.export(preset: preset, to: url)
    }

    private func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00.0" }
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let secs = total - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, secs)
    }
}
