import Foundation
import AVFoundation

enum ExportPreset: String, CaseIterable, Identifiable {
    case hd1080 = "1080p"
    case uhd4K = "4K"
    case source = "Source"

    var id: String { rawValue }

    var avPreset: String {
        switch self {
        case .hd1080: return AVAssetExportPreset1920x1080
        case .uhd4K: return AVAssetExportPreset3840x2160
        case .source: return AVAssetExportPresetHighestQuality
        }
    }
}

enum Exporter {
    /// Exports the trimmed composition to an MP4. Masters are read-only inputs.
    /// `avPresetOverride` replaces the preset's session preset — used when
    /// reframing, where output size comes from the video composition's
    /// renderSize and the session preset must not impose its own dimensions.
    static func export(composition: AVMutableComposition,
                       videoComposition: AVVideoComposition? = nil,
                       audioMix: AVAudioMix? = nil,
                       timeRange: CMTimeRange,
                       preset: ExportPreset,
                       avPresetOverride: String? = nil,
                       to destination: URL,
                       onProgress: @escaping (Double) -> Void) async throws -> URL {
        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: avPresetOverride ?? preset.avPreset) else {
            throw NSError(domain: "CaptureStudio", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Export preset \(preset.rawValue) is not supported for this recording."
            ])
        }
        session.timeRange = timeRange
        session.videoComposition = videoComposition
        session.audioMix = audioMix
        try? FileManager.default.removeItem(at: destination)

        let monitor = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let progress) = state {
                    onProgress(progress.fractionCompleted)
                }
            }
        }
        defer { monitor.cancel() }
        do {
            // The async export honors task cancellation: cancelling the caller's
            // Task (see StudioModel.cancelExport) throws CancellationError here.
            try await session.export(to: destination, as: .mp4)
        } catch {
            // Cancel or failure — never leave a truncated file behind.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        onProgress(1.0)
        return destination
    }
}
