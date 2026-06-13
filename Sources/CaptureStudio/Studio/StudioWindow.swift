import SwiftUI
import UniformTypeIdentifiers

struct StudioView: View {
    @StateObject private var model: StudioModel
    @State private var showCameraStyle = false

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
                ZStack {
                    PlayerView(player: player)
                    if model.cropActive {
                        CropPanOverlay(model: model)
                    }
                    if model.hasCameraTrack && model.cameraVisible {
                        CameraPipOverlay(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            controlBar
        }
    }

    private var controlBar: some View {
        VStack(spacing: 10) {
            timeline

            FlowLayout(hSpacing: 12, vSpacing: 8) {
                // Playback cluster.
                HStack(spacing: 8) {
                    Button {
                        model.togglePlay()
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 24)
                    }
                    .keyboardShortcut(.space, modifiers: [])

                    Text("\(timecode(model.currentTime)) / \(timecode(model.duration))")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                // Trim cluster.
                HStack(spacing: 8) {
                    Button("Set In") { model.setTrimIn(model.currentTime) }
                    Button("Set Out") { model.setTrimOut(model.currentTime) }
                    Button("Reset") { model.resetTrim() }
                    Text("Trim \(timecode(model.trimIn)) – \(timecode(model.trimOut))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                // Volume cluster.
                if model.hasSystemAudioTrack || model.hasMicTrack {
                    HStack(spacing: 8) {
                        if model.hasSystemAudioTrack {
                            volumeSlider(
                                systemImage: "speaker.wave.2",
                                help: "System audio volume",
                                value: Binding(
                                    get: { model.systemVolume },
                                    set: { model.setSystemVolume($0) }
                                )
                            )
                        }
                        if model.hasMicTrack {
                            volumeSlider(
                                systemImage: "mic",
                                help: "Microphone volume (up to 300% to boost quiet voice)",
                                value: Binding(
                                    get: { model.micVolume },
                                    set: { model.setMicVolume($0) }
                                ),
                                range: 0...3,
                                showPercent: true
                            )
                        }
                    }
                }

                // Reframe cluster.
                HStack(spacing: 8) {
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

                    if model.cropActive {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.magnifyingglass")
                                .foregroundStyle(.secondary)
                            Slider(value: Binding(
                                get: { 1.2 - model.cropZoom },
                                set: { model.setCropZoom(1.2 - $0) }
                            ), in: 0.2...1.0) { editing in
                                if !editing { model.commitCropEdit() }
                            }
                            .frame(width: 80)
                            .controlSize(.small)
                        }
                        .help("Crop zoom — drag the video to pan")
                    }
                }

                // Camera cluster.
                if model.hasCameraTrack {
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { model.cameraVisible },
                            set: { _ in model.toggleCamera() }
                        )) {
                            Image(systemName: "video.circle")
                        }
                        .toggleStyle(.button)
                        .help("Show/hide camera overlay")

                        if model.cameraVisible {
                            HStack(spacing: 4) {
                                Image(systemName: "person.crop.square")
                                    .foregroundStyle(.secondary)
                                Slider(value: Binding(
                                    get: { model.cameraZoom },
                                    set: { model.setCameraZoom($0) }
                                ), in: 1.0...4.0) { editing in
                                    if !editing { model.commitCameraEdit() }
                                }
                                .frame(width: 80)
                                .controlSize(.small)
                            }
                            .help("Camera zoom — ⌥-drag the camera to pan")

                            Button {
                                showCameraStyle.toggle()
                            } label: {
                                Image(systemName: "paintbrush")
                            }
                            .help("Camera frame style")
                            .popover(isPresented: $showCameraStyle,
                                     arrowEdge: .bottom) {
                                cameraStylePopover
                            }
                        }
                    }
                }

                Button("Reveal Masters") { model.revealMastersInFinder() }

                HStack(spacing: 8) { exportControls }
            }
        }
        .padding(12)
        .background(.bar)
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

    // MARK: - Timeline

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
