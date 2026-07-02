import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Reports the natural (padded) height of a style popover's content so the
/// popover frame can fit it up to a cap instead of using a fixed height.
private struct StylePopoverHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct StudioView: View {
    @StateObject private var model: StudioModel
    @State private var showCameraStyle = false
    @State private var showTextStyle = false
    @State private var showShapeStyle = false
    @State private var showSubtitleStyle = false
    @State private var showZoomStyle = false
    @State private var confirmRemoveSubtitles = false
    // Measured content heights for the style popovers; drive a content-fitting,
    // capped frame so they never clip their last row or leave empty slack.
    @State private var textPopoverHeight: CGFloat = 0
    @State private var shapePopoverHeight: CGFloat = 0
    @State private var subtitlePopoverHeight: CGFloat = 0

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

            Divider().padding(.vertical, 2)

            // Row 1 — transport + trim (left, wraps when narrow) and output
            // pinned right.
            HStack(alignment: .top, spacing: 12) {
                FlowLayout(hSpacing: 8, vSpacing: 8) {
                    toolGroup { transportControls }
                    toolGroup { trimControls }
                }
                Spacer(minLength: 12)
                toolGroup { outputControls }
            }

            // Row 2 — editing tools, grouped; each group wraps intact. Order:
            // sound · main video · mouse · camera · subtitle · cursor-follow · text.
            FlowLayout(hSpacing: 8, vSpacing: 8) {
                if model.hasSystemAudioTrack || model.hasMicTrack {
                    toolGroup { audioControls }
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

    @ViewBuilder private var audioControls: some View {
        if model.hasSystemAudioTrack {
            volumeSlider(systemImage: "speaker.wave.2", help: "System audio volume",
                         value: Binding(get: { model.systemVolume },
                                        set: { model.setSystemVolume($0) }))
        }
        if model.hasMicTrack {
            volumeSlider(systemImage: "mic",
                         help: "Microphone volume (up to 300% to boost quiet voice)",
                         value: Binding(get: { model.micVolume },
                                        set: { model.setMicVolume($0) }),
                         range: 0...3, showPercent: true)
        }
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
            cameraStylePopover
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
            textStylePopover
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
            shapeStylePopover
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

    @ViewBuilder
    private var shapeStylePopover: some View {
        let block = model.selectedShapeBlock
        let kind = block?.kind ?? .rectangle
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Kind", selection: Binding(
                    get: { kind },
                    set: { model.setShapeKind($0) }
                )) {
                    ForEach(ShapeKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()

                if kind == .blur {
                    Picker("Blur style", selection: Binding(
                        get: { block?.blurStyle ?? .gaussian },
                        set: { model.setShapeBlurStyle($0) }
                    )) {
                        ForEach(ShapeBlurStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()

                    styleSliderText("Strength", value: Binding(
                        get: { block?.blurStrength ?? 0.04 },
                        set: { model.setShapeBlurStrength($0) }
                    ), range: 0.005...0.2)
                } else {
                    styleSliderText("Fill opacity", value: Binding(
                        get: { block?.fillOpacity ?? 0 },
                        set: { model.setShapeFillOpacity($0) }
                    ), range: 0...1)
                    if (block?.fillOpacity ?? 0) > 0 {
                        textColorRow("Fill color", hex: block?.fillHex ?? "#000000") {
                            model.setShapeFillHex($0)
                        }
                    }

                    styleSliderText("Outline", value: Binding(
                        get: { block?.strokeWidth ?? 0 },
                        set: { model.setShapeStrokeWidth($0) }
                    ), range: 0...0.1)
                    if (block?.strokeWidth ?? 0) > 0 {
                        textColorRow("Outline color", hex: block?.strokeHex ?? "#FF3B30") {
                            model.setShapeStrokeHex($0)
                        }
                    }

                    if kind == .rectangle {
                        styleSliderText("Corner radius", value: Binding(
                            get: { block?.cornerRadius ?? 0 },
                            set: { model.setShapeCornerRadius($0) }
                        ), range: 0...0.5)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 20)
            .background(GeometryReader { g in
                Color.clear.preference(key: StylePopoverHeightKey.self, value: g.size.height)
            })
        }
        .frame(width: 320, height: min(shapePopoverHeight == 0 ? 320 : shapePopoverHeight, 500))
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(StylePopoverHeightKey.self) { shapePopoverHeight = $0 }
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
            zoomStylePopover
        }

        Button(role: .destructive) {
            if let id = model.selectedZoomBlockID { model.removeZoomBlock(id) }
        } label: {
            Image(systemName: "trash")
        }
        .disabled(model.selectedZoomBlockID == nil)
        .help("Delete the selected zoom block")
    }

    /// Per-block zoom controls (scale + follow sensitivity) — the two scalers
    /// that used to sit inline, now wrapped in a popover since they operate on
    /// the selected move/zoom block.
    private var zoomStylePopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Zoom", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f×", model.selectedZoomScale))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(get: { model.selectedZoomScale },
                                   set: { model.setZoomScale($0) }),
                    in: 1...6,
                    onEditingChanged: { editing in if !editing { model.commitZoomEdit() } }
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Follow sensitivity", systemImage: "hand.draw")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((model.selectedZoomSensitivity * 100).rounded()))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(get: { model.selectedZoomSensitivity },
                                   set: { model.setZoomSensitivity($0) }),
                    in: 0...1,
                    onEditingChanged: { editing in if !editing { model.commitZoomEdit() } }
                )
                Text("How aggressively the zoom pans toward the cursor — low = calm, high = snappy.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 280)
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
                subtitleStylePopover
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

    private func volumeSlider(systemImage: String, help: String,
                              value: Binding<Double>,
                              range: ClosedRange<Double> = 0...1,
                              showPercent: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range) { editing in
                if !editing { model.commitVolumeEdit() }
            }
            .frame(width: 80)
            .controlSize(.small)
            if showPercent {
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .help(help)
    }

    // MARK: - Camera style

    /// Common border colors offered as one-tap swatches.
    private static let borderPresets = [
        "#FFFFFF", "#000000", "#FF3B30", "#FF9500",
        "#34C759", "#007AFF", "#AF52DE", "#8E8E93",
    ]

    private var cameraStylePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Zoom").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.cameraZoom },
                                      set: { model.setCameraZoom($0) }),
                       in: 1.0...4.0) { editing in
                    if editing { model.beginStyleEdit() } else { model.endStyleEdit() }
                }
            }

            Picker("Shape", selection: Binding(
                get: { model.cameraShape },
                set: { model.setCameraShape($0) }
            )) {
                ForEach(CameraShape.allCases, id: \.self) { shape in
                    Text(shape.displayName).tag(shape)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                Button {
                    model.rotateCamera()
                } label: {
                    Label("Rotate", systemImage: "rotate.right")
                }
                .help("Rotate camera 90°")
                if model.cameraRotation != 0 {
                    Text("\(model.cameraRotation)°")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            // Aspect only applies to rectangles; a circle is forced to 1:1.
            if model.cameraShape == .rectangle {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aspect").font(.caption).foregroundStyle(.secondary)
                    Picker("Aspect", selection: Binding(
                        get: { model.cameraAspect },
                        set: { model.setCameraAspect($0) }
                    )) {
                        ForEach(CameraAspect.allCases, id: \.self) { a in
                            Text(a.displayName).tag(a)
                        }
                    }
                    .labelsHidden()
                }

                styleSlider("Corner radius", value: Binding(
                    get: { model.cameraCornerRadius },
                    set: { model.setCameraCornerRadius($0) }
                ), range: 0...1)
            }

            styleSlider("Border", value: Binding(
                get: { model.cameraBorderWidth },
                set: { model.setCameraBorderWidth($0) }
            ), range: 0...0.1)

            if model.cameraBorderWidth > 0 {
                borderColorControls
            }

            Toggle("Shadow", isOn: Binding(
                get: { model.cameraShadow },
                set: { model.setCameraShadow($0) }
            ))

            if model.cameraShadow {
                styleSlider("Shadow", value: Binding(
                    get: { model.cameraShadowRadius },
                    set: { model.setCameraShadowRadius($0) }
                ), range: 0...1)
            }
        }
        .padding(14)
        .frame(width: 240)
    }

    /// Preset swatches plus a compact custom picker. Tapping a swatch sets the
    /// border color inline; only the custom picker opens the system panel.
    private var borderColorControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Border color").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(Self.borderPresets, id: \.self) { hex in
                    let selected = hex.caseInsensitiveCompare(model.cameraBorderHex) == .orderedSame
                    Circle()
                        .fill(Color(hexString: hex))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
                        .overlay(
                            Circle().strokeBorder(Color.accentColor,
                                                  lineWidth: selected ? 2.5 : 0)
                                .padding(-2)
                        )
                        .onTapGesture { model.setCameraBorderHex(hex) }
                }
            }
            ColorPicker("Custom", selection: Binding(
                get: { Color(hexString: model.cameraBorderHex) },
                set: { model.setCameraBorderHex($0.hexString()) }
            ), supportsOpacity: false)
            .labelsHidden()
        }
    }

    private func styleSlider(_ title: String, value: Binding<Double>,
                             range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: range) { editing in
                if editing { model.beginStyleEdit() } else { model.endStyleEdit() }
            }
        }
    }

    // MARK: - Text style

    /// Curated font families (Core Text resolves by family name; unknown names
    /// fall back to the system font).
    private static let fontFamilies = [
        "Helvetica", "Helvetica Neue", "Arial", "Avenir Next",
        "Georgia", "Futura", "Menlo", "Times New Roman",
    ]

    @ViewBuilder
    private var textStylePopover: some View {
        let block = model.selectedTextBlock
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Font", selection: Binding(
                    get: { block?.fontName ?? "Helvetica" },
                    set: { model.setTextFontName($0) }
                )) {
                    ForEach(Self.fontFamilies, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()

                Picker("Weight", selection: Binding(
                    get: { block?.fontWeight ?? .semibold },
                    set: { model.setTextWeight($0) }
                )) {
                    ForEach(TextWeight.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()

                Picker("Align", selection: Binding(
                    get: { block?.alignment ?? .center },
                    set: { model.setTextAlignment($0) }
                )) {
                    Image(systemName: "text.alignleft").tag(TextAlignmentH.leading)
                    Image(systemName: "text.aligncenter").tag(TextAlignmentH.center)
                    Image(systemName: "text.alignright").tag(TextAlignmentH.trailing)
                }
                .pickerStyle(.segmented).labelsHidden()

                textSizeRow(block)

                Toggle("Auto-wrap lines", isOn: Binding(
                    get: { block?.autoWrap ?? true },
                    set: { model.setTextAutoWrap($0) }
                ))
                if block?.autoWrap ?? true {
                    styleSliderText("Box width", value: Binding(
                        get: { block?.boxWidth ?? 0.9 },
                        set: { model.setTextBoxWidth($0) }
                    ), range: 0.05...1.0)
                }

                textColorRow("Color", hex: block?.colorHex ?? "#FFFFFF") {
                    model.setTextColorHex($0)
                }

                Toggle("Background box", isOn: Binding(
                    get: { block?.boxEnabled ?? false },
                    set: { model.setTextBoxEnabled($0) }
                ))
                if block?.boxEnabled == true {
                    textColorRow("Box color", hex: block?.boxHex ?? "#000000") {
                        model.setTextBoxHex($0)
                    }
                    styleSliderText("Box opacity", value: Binding(
                        get: { block?.boxOpacity ?? 0.5 },
                        set: { model.setTextBoxOpacity($0) }
                    ), range: 0...1)
                }

                styleSliderText("Outline", value: Binding(
                    get: { block?.strokeWidth ?? 0 },
                    set: { model.setTextStrokeWidth($0) }
                ), range: 0...0.2)
                if (block?.strokeWidth ?? 0) > 0 {
                    textColorRow("Outline color", hex: block?.strokeHex ?? "#000000") {
                        model.setTextStrokeHex($0)
                    }
                }

                Toggle("Shadow", isOn: Binding(
                    get: { block?.shadow ?? true },
                    set: { model.setTextShadow($0) }
                ))
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 20)
            .background(GeometryReader { g in
                Color.clear.preference(key: StylePopoverHeightKey.self, value: g.size.height)
            })
        }
        // Fit the content up to a cap; scroll only past it. Sizing to content
        // keeps collapsed states slack-free and stops the last row from being
        // clipped by the popover's rounded bottom edge.
        .frame(width: 320, height: min(textPopoverHeight == 0 ? 500 : textPopoverHeight, 500))
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(StylePopoverHeightKey.self) { textPopoverHeight = $0 }
    }

    private func styleSliderText(_ title: String, value: Binding<Double>,
                                 range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: range) { editing in
                if !editing { model.commitTextEdit() }
            }
        }
    }

    // MARK: - Subtitle style (one shared config applied to every cue)

    @ViewBuilder
    private var subtitleStylePopover: some View {
        let style = model.subtitles?.style
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Applies to all subtitles").font(.caption).foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Time offset (s)").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("", value: Binding(
                            get: { model.subtitles?.offset ?? 0 },
                            set: { model.setSubtitleOffset($0) }
                        ), format: .number.precision(.fractionLength(2)))
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                        Stepper("", value: Binding(
                            get: { model.subtitles?.offset ?? 0 },
                            set: { model.setSubtitleOffset($0) }
                        ), in: -86_400...86_400, step: 0.1)
                            .labelsHidden()
                        Spacer()
                        Button("Set from playhead") { model.setSubtitleOffsetFromPlayhead() }
                            .controlSize(.small)
                    }
                    Text("SRT made from the raw (untrimmed) video? Nudge or set from the playhead to re-sync.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .disabled(model.subtitleState != .idle)

                Divider()

                Picker("Font", selection: Binding(
                    get: { style?.fontName ?? "Helvetica" },
                    set: { model.setSubtitleFontName($0) }
                )) {
                    ForEach(Self.fontFamilies, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()

                Picker("Weight", selection: Binding(
                    get: { style?.fontWeight ?? .semibold },
                    set: { model.setSubtitleWeight($0) }
                )) {
                    ForEach(TextWeight.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()

                Picker("Align", selection: Binding(
                    get: { style?.alignment ?? .center },
                    set: { model.setSubtitleAlignment($0) }
                )) {
                    Image(systemName: "text.alignleft").tag(TextAlignmentH.leading)
                    Image(systemName: "text.aligncenter").tag(TextAlignmentH.center)
                    Image(systemName: "text.alignright").tag(TextAlignmentH.trailing)
                }
                .pickerStyle(.segmented).labelsHidden()

                styleSliderSubtitle("Size", value: Binding(
                    get: { style?.fontSize ?? 0.05 },
                    set: { model.setSubtitleFontSize($0) }
                ), range: 0.02...0.2)

                styleSliderSubtitle("Box width (wrap)", value: Binding(
                    get: { style?.boxWidth ?? 0.9 },
                    set: { model.setSubtitleBoxWidth($0) }
                ), range: 0.05...1.0)

                textColorRow("Color", hex: style?.colorHex ?? "#FFFFFF") {
                    model.setSubtitleColorHex($0)
                }

                Toggle("Background box", isOn: Binding(
                    get: { style?.boxEnabled ?? false },
                    set: { model.setSubtitleBoxEnabled($0) }
                ))
                if style?.boxEnabled == true {
                    textColorRow("Box color", hex: style?.boxHex ?? "#000000") {
                        model.setSubtitleBoxHex($0)
                    }
                    styleSliderSubtitle("Box opacity", value: Binding(
                        get: { style?.boxOpacity ?? 0.5 },
                        set: { model.setSubtitleBoxOpacity($0) }
                    ), range: 0...1)
                }

                styleSliderSubtitle("Outline", value: Binding(
                    get: { style?.strokeWidth ?? 0 },
                    set: { model.setSubtitleStrokeWidth($0) }
                ), range: 0...0.2)
                if (style?.strokeWidth ?? 0) > 0 {
                    textColorRow("Outline color", hex: style?.strokeHex ?? "#000000") {
                        model.setSubtitleStrokeHex($0)
                    }
                }

                Toggle("Shadow", isOn: Binding(
                    get: { style?.shadow ?? true },
                    set: { model.setSubtitleShadow($0) }
                ))

                Divider()

                Text("Scrub to a subtitle, then drag it on the canvas to reposition.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 20)
            .background(GeometryReader { g in
                Color.clear.preference(key: StylePopoverHeightKey.self, value: g.size.height)
            })
        }
        // Fit the content up to a cap; scroll only past it. Sizing to content
        // keeps collapsed states slack-free and stops the last row from being
        // clipped by the popover's rounded bottom edge.
        .frame(width: 320, height: min(subtitlePopoverHeight == 0 ? 500 : subtitlePopoverHeight, 500))
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(StylePopoverHeightKey.self) { subtitlePopoverHeight = $0 }
    }

    private func styleSliderSubtitle(_ title: String, value: Binding<Double>,
                                     range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: range) { editing in
                if !editing { model.commitSubtitleEdit() }
            }
        }
    }

    /// Font-size control showing the rendered px height, with a ±1px stepper and
    /// a slider. `fontSize` is a fraction of canvas height, so px = fontSize ×
    /// renderSize.height (falls back to 1080 before the canvas size is known).
    @ViewBuilder
    private func textSizeRow(_ block: TextBlock?) -> some View {
        let h = model.renderSize.height > 0 ? model.renderSize.height : 1080
        let frac = block?.fontSize ?? 0.06
        let px = Int((frac * h).rounded())
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Size").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(px) px").font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
                Stepper("", value: Binding(
                    get: { Double(px) },
                    set: { model.setTextFontSize($0 / h); model.commitTextEdit() }
                ), in: 1...(h * 0.5), step: 1)
                .labelsHidden()
            }
            Slider(value: Binding(
                get: { block?.fontSize ?? 0.06 },
                set: { model.setTextFontSize($0) }
            ), in: 0.005...0.2) { editing in
                if !editing { model.commitTextEdit() }
            }
        }
    }

    /// Preset swatches + custom picker for a text color field.
    private func textColorRow(_ title: String, hex: String,
                              set: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            FlowLayout(hSpacing: 6, vSpacing: 6) {
                ForEach(Self.borderPresets, id: \.self) { h in
                    let selected = h.caseInsensitiveCompare(hex) == .orderedSame
                    Circle()
                        .fill(Color(hexString: h))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
                        .overlay(Circle().strokeBorder(Color.accentColor,
                                                       lineWidth: selected ? 2.5 : 0).padding(-2))
                        .onTapGesture { set(h) }
                }
                ColorPicker("", selection: Binding(
                    get: { Color(hexString: hex) },
                    set: { set($0.hexString()) }
                ), supportsOpacity: false)
                .labelsHidden()
            }
        }
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

extension Color {
    /// Parses "#RRGGBB" (or "RRGGBB"); falls back to white.
    init(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0xFFFFFF
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    func hexString() -> String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X",
                      Int((ns.redComponent * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()))
    }
}
