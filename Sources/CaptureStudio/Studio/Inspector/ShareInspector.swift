import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Export/share inspector — the "Share" rail tab. Mirrors the bottom bar's
/// reveal-masters button + `exportControls`.
struct ShareInspector: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Export").font(.caption).foregroundStyle(.secondary)
                HStack { exportControls }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Masters").font(.caption).foregroundStyle(.secondary)
                Button { model.revealMastersInFinder() } label: {
                    Label("Reveal master files in Finder", systemImage: "folder")
                }
                .help("Reveal master files in Finder")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Share").font(.caption).foregroundStyle(.secondary)
                Button { } label: {
                    Label("Share / upload", systemImage: "square.and.arrow.up")
                }
                .comingSoon()
            }
        }
        .padding(16)
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
