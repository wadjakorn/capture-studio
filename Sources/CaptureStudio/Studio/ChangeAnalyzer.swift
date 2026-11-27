import AVFoundation
import CoreVideo

/// The cached result of analysing a recording's main video for on-screen
/// change. Derived data: safe to delete, recomputed on the next "Auto zoom".
struct ChangeAnalysis: Codable, Equatable {
    static let currentVersion = 1
    var version: Int = ChangeAnalysis.currentVersion
    /// Size in bytes of the analysed video file. Masters are never rewritten, so
    /// a cache whose size differs belongs to another video and is ignored.
    var videoBytes: Int64
    var events: [ChangeEvent]

    func matches(videoBytes: Int64) -> Bool {
        version == Self.currentVersion && self.videoBytes == videoBytes
    }

    static func fileBytes(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value
    }
}

/// Reads a video once at low resolution and reports what changed on screen.
/// Thin AVFoundation glue around `LumaDiff` + `ChangeGrouper`.
enum ChangeAnalyzer {
    /// Width of the luma frames that are compared.
    static let analysisWidth = 192

    /// Decode every frame of `url` and group what changed. `splitTimes` are the
    /// mouse-down times (see `ChangeGrouper.splitTimes`). `progress` receives
    /// 0…1 on the calling task's thread. Blocking work — call from a detached
    /// task. Throws `CancellationError` when the task is cancelled.
    static func analyze(url: URL, splitTimes: [Double],
                        progress: @Sendable (Double) -> Void) async throws -> ChangeAnalysis {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        guard size.width > 0, size.height > 0, duration > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let w = analysisWidth
        let h = max(2, Int((Double(w) * Double(size.height) / Double(size.width)).rounded()))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CocoaError(.fileReadCorruptFile) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        var grouper = ChangeGrouper(splitTimes: splitTimes)
        var previous: [UInt8] = []
        var current = [UInt8](repeating: 0, count: w * h)
        var lastReported = -1.0

        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            // Asset time == composition time: the screen track is inserted at
            // zero from asset time zero.
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard t.isFinite else { continue }

            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                let pw = min(w, CVPixelBufferGetWidthOfPlane(buffer, 0))
                let ph = min(h, CVPixelBufferGetHeightOfPlane(buffer, 0))
                let src = base.assumingMemoryBound(to: UInt8.self)
                current.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<ph {
                        (dst.baseAddress! + y * w).update(from: src + y * stride, count: pw)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)

            // The first frame only seeds the comparison.
            if !previous.isEmpty {
                grouper.add(t: t, mask: LumaDiff.changedCells(previous: previous, current: current,
                                                              width: w, height: h))
            }
            previous = current

            let p = min(max(t / duration, 0), 1)
            if p - lastReported >= 0.01 { lastReported = p; progress(p) }
        }
        if Task.isCancelled { throw CancellationError() }
        guard reader.status == .completed else {
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }
        progress(1)
        return ChangeAnalysis(videoBytes: ChangeAnalysis.fileBytes(url) ?? -1,
                              events: grouper.finish())
    }
}
