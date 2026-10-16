import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Per-project preview frame + duration for the Dashboard. An actor so a
/// prefetch from `RecordingSession.stop()` and a lazy Dashboard load for the
/// same bundle share one generation instead of racing on `thumbnail.jpg`.
/// Callers must only ask for finalized (`.ready`) bundles — never a screen.mp4
/// that is still being written.
actor ThumbnailStore {
    static let shared = ThumbnailStore()

    static let maxPixel: CGFloat = 480

    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    /// Bundles whose generation failed; not retried for the app's lifetime.
    private var failed: Set<String> = []
    /// Number of actual generation attempts (tests assert failures aren't retried).
    private(set) var generationCount = 0

    /// Existing thumbnail if present, else generate (joining any running task).
    func image(bundleURL: URL) async -> CGImage? {
        let key = bundleURL.standardizedFileURL.path
        let bundle = ProjectBundle(url: bundleURL)
        if let existing = Self.loadImage(at: bundle.thumbnailURL) { return existing }
        if failed.contains(key) { return nil }
        if let running = inFlight[key] { return await running.value }

        generationCount += 1
        let task = Task<CGImage?, Never> {
            await Self.generate(bundle: bundle)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if result == nil { failed.insert(key) }
        return result
    }

    nonisolated func prefetch(bundleURL: URL) {
        Task(priority: .utility) { [self] in
            _ = await image(bundleURL: bundleURL)
        }
    }

    func duration(bundleURL: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: ProjectBundle(url: bundleURL).screenURL)
        guard let d = try? await asset.load(.duration), d.isNumeric else { return nil }
        let secs = d.seconds
        return secs.isFinite && secs >= 0 ? secs : nil
    }

    // MARK: - Helpers

    private static func loadImage(at url: URL) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func generate(bundle: ProjectBundle) async -> CGImage? {
        guard FileManager.default.fileExists(atPath: bundle.screenURL.path) else { return nil }
        let asset = AVURLAsset(url: bundle.screenURL)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        let t = CMTime(seconds: min(1, max(0, duration.seconds / 2)), preferredTimescale: 600)
        guard let (image, _) = try? await gen.image(at: t) else { return nil }
        // Failing to cache on disk still yields a usable in-memory image.
        try? writeJPEG(image, to: bundle.thumbnailURL)
        return image
    }

    private static func writeJPEG(_ image: CGImage, to dest: URL) throws {
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".thumbnail-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let d = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(d, image,
            [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(d) else { throw CocoaError(.fileWriteUnknown) }
        if FileManager.default.fileExists(atPath: dest.path) {
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
    }
}
