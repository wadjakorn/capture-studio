import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct StudioView: View {
    @StateObject private var model: StudioModel
    @State private var showCameraStyle = false
    @State private var showTextStyle = false

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
                    if model.showsCameraOverlay {
                        CameraPipOverlay(model: model)
                    }
                    if model.selectedTextBlock != nil {
                        TextCanvasOverlay(model: model)
                    }
                    // Reels safe-area guide (studio-only).
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
            if model.showsCameraTimeline {
                laneRow("video.fill") { CameraTimelineLane(model: model) }
            }
            if !model.textBlocks.isEmpty {
                laneRow("textformat") { TextTimelineLane(model: model) }
            }
            if model.showsZoomTimeline {
                laneRow("plus.magnifyingglass") { ZoomTimelineLane(model: model) }
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

            // Row 2 — editing tools, grouped; each group wraps intact.
            FlowLayout(hSpacing: 8, vSpacing: 8) {
                if model.hasSystemAudioTrack || model.hasMicTrack {
                    toolGroup { audioControls }
                }
                toolGroup { reframeControls }
                if model.hasCameraTrack {
                    toolGroup { cameraControls }
                }
                toolGroup { textControls }
                toolGroup { zoomControls }
                toolGroup { cursorControls }
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

    @ViewBuilder private var cameraControls: some View {
        Toggle(isOn: Binding(get: { model.cameraVisible },
                             set: { _ in model.toggleCamera() })) {
            Image(systemName: "video.circle")
        }
        .toggleStyle(.button)
        .help("Show/hide camera overlay")

        // Style dropdown — all global camera config (zoom + frame style).
        Button { showCameraStyle.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .disabled(!model.cameraVisible)
        .help("Camera style — zoom, frame & shape")
        .popover(isPresented: $showCameraStyle, arrowEdge: .bottom) {
            cameraStylePopover
        }

        // Motion action group — add / delete / hide camera blocks.
        Button { model.addBlock() } label: {
            Label("Add move", systemImage: "plus.rectangle")
        }
        .disabled(!model.cameraVisible)
        .help("Add a camera move block at the playhead")

        Button {
            if let id = model.selectedBlockID { model.removeBlock(id) }
        } label: {
            Image(systemName: "minus.rectangle")
        }
        .disabled(!model.cameraVisible || model.selectedBlockID == nil)
        .help("Delete the selected move block")

        Button { model.addHideBlock() } label: {
            Image(systemName: "eye.slash")
        }
        .disabled(!model.cameraVisible || model.blockAtPlayhead != nil)
        .help("Insert a temporary hide-camera block at the playhead")
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
        .help("Edit text style, order, and delete")
        .popover(isPresented: $showTextStyle, arrowEdge: .bottom) {
            textStylePopover
        }

        // Inline caption input — shown only while a text block is selected.
        // Selecting a block (timeline or canvas) reveals it; deselecting hides it.
        if model.selectedTextBlock != nil {
            CaptionTextEditor(
                text: Binding(
                    get: { model.selectedTextBlock?.text ?? "" },
                    set: { if let id = model.selectedTextBlockID { model.setText($0, for: id) } }
                ),
                onSubmit: { model.commitTextEdit() }
            )
            .frame(width: 220, height: 44)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(.secondary.opacity(0.3), lineWidth: 1))
            .help("Edit caption text · Shift+Return for a new line")
        }
    }

    @ViewBuilder private var zoomControls: some View {
        Button { model.addZoomBlock() } label: {
            Label("Add zoom", systemImage: "plus.magnifyingglass")
        }
        .help("Add an auto zoom/pan block at the playhead")

        Button {
            if let id = model.selectedZoomBlockID { model.removeZoomBlock(id) }
        } label: {
            Image(systemName: "minus.magnifyingglass")
        }
        .disabled(model.selectedZoomBlockID == nil)
        .help("Delete the selected zoom block")

        if model.selectedZoomBlockID != nil {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { model.selectedZoomScale },
                                   set: { model.setZoomScale($0) }),
                    in: 1...6,
                    onEditingChanged: { editing in if !editing { model.commitZoomEdit() } }
                )
                .frame(width: 90)
                Text(String(format: "%.1f×", model.selectedZoomScale))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .help("Zoom magnification for the selected block")

            HStack(spacing: 4) {
                Image(systemName: "hand.draw")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { model.selectedZoomSensitivity },
                                   set: { model.setZoomSensitivity($0) }),
                    in: 0...1,
                    onEditingChanged: { editing in if !editing { model.commitZoomEdit() } }
                )
                .frame(width: 90)
                Text("\(Int((model.selectedZoomSensitivity * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .help("Follow sensitivity — how aggressively the zoom pans toward the cursor (low = calm, high = snappy)")
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
                    if !editing { model.commitCameraEdit() }
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
                if !editing { model.commitCameraEdit() }
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
                HStack(spacing: 8) {
                    Button {
                        if let id = model.selectedTextBlockID { model.sendTextBackward(id) }
                    } label: { Image(systemName: "arrow.down.square") }
                        .help("Send backward")
                    Button {
                        if let id = model.selectedTextBlockID { model.bringTextForward(id) }
                    } label: { Image(systemName: "arrow.up.square") }
                        .help("Bring forward")
                    Spacer()
                    Button(role: .destructive) {
                        if let id = model.selectedTextBlockID { model.removeTextBlock(id) }
                    } label: { Image(systemName: "trash") }
                        .help("Delete this text block")
                }

                Divider()

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
            .padding(14)
        }
        .frame(width: 280)
        .frame(maxHeight: 420)
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
