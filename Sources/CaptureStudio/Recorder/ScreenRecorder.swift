import Foundation
import ScreenCaptureKit
import AVFoundation

/// Captures one display via SCStream and writes screen.mp4, plus system.m4a
/// when system audio is enabled (same stream, separate writer — SCStream audio
/// PTS share the host clock, so cross-track sync stays pure arithmetic).
/// Cursor is NOT rendered into the video (showsCursor = false) — cursor data
/// lives in events.jsonl so Studio can post-process it later.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    enum ScreenRecorderError: LocalizedError {
        case writerSetupFailed(String)
        case noSamplesCaptured
        case streamFailed(String)

        var errorDescription: String? {
            switch self {
            case .writerSetupFailed(let detail): return "Could not set up video writer: \(detail)"
            case .noSamplesCaptured: return "Recording produced no video frames."
            case .streamFailed(let detail): return "Screen capture stream failed: \(detail)"
            }
        }
    }

    struct StopResult {
        let screen: TrackInfo
        let systemAudio: TrackInfo?
    }

    static let targetFPS = 60.0
    /// HEVC is ~40% more efficient than H.264, so a lower bits-per-pixel keeps
    /// UI text crisp through the second encode at export time.
    private static let bitsPerPixel = 0.09
    /// Cap the longest captured side. Native retina (e.g. 5K = 5120×2880)
    /// saturates the realtime HEVC encoder at 60fps and drops most frames; a
    /// 1440p ceiling keeps a steady 60fps and is plenty sharp for export,
    /// where masters are re-encoded to 1080p/4K anyway.
    private static let maxCaptureLongSide = 2560

    /// Captured pixel size: source scaled down so the longest side fits
    /// `maxCaptureLongSide`, preserving aspect, rounded to even dimensions
    /// (the encoder requires even width/height).
    static func captureSize(forWidth w: Int, height h: Int) -> (width: Int, height: Int) {
        let longest = max(w, h)
        guard longest > maxCaptureLongSide, longest > 0 else { return (w, h) }
        let scale = Double(maxCaptureLongSide) / Double(longest)
        let sw = Int((Double(w) * scale).rounded()) & ~1
        let sh = Int((Double(h) * scale).rounded()) & ~1
        return (max(2, sw), max(2, sh))
    }

    private let display: SCDisplay
    private let item: DisplayItem
    private let outputURL: URL
    private let systemAudioURL: URL?

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var audioWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private let outputQueue = DispatchQueue(label: "capturestudio.screen.output")
    private let audioQueue = DispatchQueue(label: "capturestudio.systemaudio.output")

    /// Host-clock seconds of the first appended sample (the sync anchor).
    private(set) var sessionStartHostTime: Double?
    private var audioSessionStartHostTime: Double?

    /// Non-fatal setup problem with system audio (video keeps recording).
    private(set) var systemAudioWarning: String?

    /// Called on a background queue if the stream dies mid-recording
    /// (display sleep, lock screen). Owner should stop-and-finalize.
    var onStreamError: ((Error) -> Void)?

    init(display: SCDisplay, item: DisplayItem, outputURL: URL,
         systemAudioURL: URL? = nil) {
        self.display = display
        self.item = item
        self.outputURL = outputURL
        self.systemAudioURL = systemAudioURL
    }

    func start() async throws {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw ScreenRecorderError.writerSetupFailed(error.localizedDescription)
        }

        let capture = Self.captureSize(forWidth: item.pixelWidth, height: item.pixelHeight)
        let bitrate = Int(Double(capture.width * capture.height) * Self.targetFPS * Self.bitsPerPixel)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: capture.width,
            AVVideoHeightKey: capture.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: Int(Self.targetFPS),
                AVVideoMaxKeyFrameIntervalKey: Int(Self.targetFPS) * 2,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw ScreenRecorderError.writerSetupFailed("writer rejected video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw ScreenRecorderError.writerSetupFailed(writer.error?.localizedDescription ?? "unknown")
        }
        self.writer = writer
        self.input = input

        // System audio writer is best-effort: failure downgrades to video-only.
        if let systemAudioURL {
            do {
                try setUpSystemAudioWriter(outputURL: systemAudioURL)
            } catch {
                Log.recorder.error("system audio writer setup failed: \(error.localizedDescription, privacy: .public)")
                systemAudioWarning = "System audio not recorded: \(error.localizedDescription)"
                audioWriter = nil
                audioInput = nil
            }
        }

        let config = SCStreamConfiguration()
        config.width = capture.width
        config.height = capture.height
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.targetFPS))
        config.queueDepth = 8
        if audioWriter != nil {
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
        } else {
            config.capturesAudio = false
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        if audioWriter != nil {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    private func setUpSystemAudioWriter(outputURL: URL) throws {
        let audioWriter = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        // SCStream delivers 48kHz stereo LPCM; encode to AAC. No
        // recommendedAudioSettingsForAssetWriter here — that helper belongs
        // to AVCaptureAudioDataOutput.
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        guard audioWriter.canAdd(audioInput) else {
            throw ScreenRecorderError.writerSetupFailed("writer rejected audio input")
        }
        audioWriter.add(audioInput)
        guard audioWriter.startWriting() else {
            throw ScreenRecorderError.writerSetupFailed(audioWriter.error?.localizedDescription ?? "unknown")
        }
        self.audioWriter = audioWriter
        self.audioInput = audioInput
    }

    /// Stops capture and finalizes screen.mp4 (+ system.m4a). Video finalizes
    /// first and its failure throws; system audio is best-effort.
    func stop() async throws -> StopResult {
        if let stream {
            // Stream may already be dead (display sleep) — finalize regardless.
            try? await stream.stopCapture()
        }
        stream = nil

        guard let writer, let input else {
            throw ScreenRecorderError.writerSetupFailed("stop() before start()")
        }
        guard let startTime = sessionStartHostTime else {
            writer.cancelWriting()
            audioWriter?.cancelWriting()
            throw ScreenRecorderError.noSamplesCaptured
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            audioWriter?.cancelWriting()
            throw ScreenRecorderError.writerSetupFailed(writer.error?.localizedDescription ?? "finishWriting failed")
        }

        let screenTrack = TrackInfo(
            type: .screen,
            filename: outputURL.lastPathComponent,
            sessionStartHostTime: startTime,
            nominalFPS: Self.targetFPS,
            codec: "hevc",
            deviceName: item.name,
            deviceID: String(item.id)
        )

        var systemAudioTrack: TrackInfo?
        if let audioWriter, let audioInput, let systemAudioURL {
            if let audioStart = audioSessionStartHostTime {
                audioInput.markAsFinished()
                await audioWriter.finishWriting()
                if audioWriter.status == .failed {
                    systemAudioWarning = "System audio track lost: \(audioWriter.error?.localizedDescription ?? "finishWriting failed")"
                } else {
                    systemAudioTrack = TrackInfo(
                        type: .systemAudio,
                        filename: systemAudioURL.lastPathComponent,
                        sessionStartHostTime: audioStart,
                        nominalFPS: nil,
                        codec: "aac",
                        deviceName: "System Audio",
                        deviceID: nil
                    )
                }
            } else {
                // No audio samples ever arrived (e.g. total silence policy or
                // stream quirk) — discard the empty file, keep the video.
                audioWriter.cancelWriting()
                try? FileManager.default.removeItem(at: systemAudioURL)
                systemAudioWarning = "System audio produced no samples."
            }
        }
        return StopResult(screen: screenTrack, systemAudio: systemAudioTrack)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            handleVideo(sampleBuffer)
        case .audio:
            handleAudio(sampleBuffer)
        default:
            break
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let writer, let input, writer.status == .writing else { return }

        // Only complete frames carry image data; idle/blank frames are skipped.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if sessionStartHostTime == nil {
            // SCStream PTS are on the host clock — this anchors cross-track sync.
            writer.startSession(atSourceTime: pts)
            sessionStartHostTime = pts.seconds
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let audioWriter, let audioInput, audioWriter.status == .writing else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if audioSessionStartHostTime == nil {
            audioWriter.startSession(atSourceTime: pts)
            audioSessionStartHostTime = pts.seconds
        }
        if audioInput.isReadyForMoreMediaData {
            audioInput.append(sampleBuffer)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamError?(error)
    }
}
