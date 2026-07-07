import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Top app-bar chrome: filename, undo/redo + presets + preview/speed
/// placeholders, and the real export control (kept live so Stop is reachable
/// mid-export). Not yet wired into `StudioView` — Task 5 swaps the layout to
/// use this.
struct StudioAppBar: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        HStack(spacing: 12) {
            Text(model.bundle.url.deletingPathExtension().lastPathComponent)
                .font(.headline)
                .lineLimit(1)

            Spacer(minLength: 12)

            HStack(spacing: 4) {
                Button { } label: { Image(systemName: "arrow.uturn.backward") }
                    .comingSoon()
                Button { } label: { Image(systemName: "arrow.uturn.forward") }
                    .comingSoon()
            }

            Button("Presets") { }.comingSoon()

            HStack(spacing: 4) {
                Button { } label: { Image(systemName: "play.circle") }
                    .comingSoon()
                Text("1×").font(.caption.monospacedDigit()).comingSoon()
            }

            exportControls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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
}
