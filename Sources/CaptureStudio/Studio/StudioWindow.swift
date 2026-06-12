import SwiftUI
import UniformTypeIdentifiers

struct StudioView: View {
    @StateObject private var model: StudioModel

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
        .frame(minWidth: 720, minHeight: 480)
        .task { await model.load() }
        .navigationTitle(model.bundle.url.deletingPathExtension().lastPathComponent)
    }

    private var editorView: some View {
        VStack(spacing: 0) {
            if let player = model.player {
                ZStack {
                    PlayerView(player: player)
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

            HStack(spacing: 12) {
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

                Divider().frame(height: 16)

                Button("Set In") { model.setTrimIn(model.currentTime) }
                Button("Set Out") { model.setTrimOut(model.currentTime) }
                Button("Reset") { model.resetTrim() }
                Text("Trim \(timecode(model.trimIn)) – \(timecode(model.trimOut))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

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
                        help: "Microphone volume",
                        value: Binding(
                            get: { model.micVolume },
                            set: { model.setMicVolume($0) }
                        )
                    )
                }

                if model.hasCameraTrack {
                    Toggle(isOn: Binding(
                        get: { model.cameraVisible },
                        set: { _ in model.toggleCamera() }
                    )) {
                        Image(systemName: "video.circle")
                    }
                    .toggleStyle(.button)
                    .help("Show/hide camera overlay")
                }

                Button("Reveal Masters") { model.revealMastersInFinder() }

                exportControls
            }
        }
        .padding(12)
        .background(.bar)
    }

    private func volumeSlider(systemImage: String, help: String,
                              value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Slider(value: value, in: 0...1) { editing in
                if !editing { model.commitVolumeEdit() }
            }
            .frame(width: 80)
            .controlSize(.small)
        }
        .help(help)
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
