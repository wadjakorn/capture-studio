import Foundation
import AVFoundation

/// Records one camera device to camera.mp4 via its own AVCaptureSession.
/// Sample buffer PTS are on the host clock — same timebase as the screen
/// track, so alignment is pure offset arithmetic.
final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum CameraError: LocalizedError {
        case deviceUnavailable
        case writerSetupFailed(String)
        case noSamplesCaptured

        var errorDescription: String? {
            switch self {
            case .deviceUnavailable: return "Camera is unavailable."
            case .writerSetupFailed(let detail): return "Camera writer failed: \(detail)"
            case .noSamplesCaptured: return "Camera produced no frames."
            }
        }
    }

    private let device: AVCaptureDevice
    private let outputURL: URL
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "capturestudio.camera.output")

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private(set) var sessionStartHostTime: Double?
    /// Set true if the device disappeared mid-recording.
    private(set) var truncated = false

    init(device: AVCaptureDevice, outputURL: URL) {
        self.device = device
        self.outputURL = outputURL
        super.init()
    }

    func start() async throws {
        let deviceInput: AVCaptureDeviceInput
        do {
            deviceInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraError.deviceUnavailable
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        guard session.canAddInput(deviceInput), session.canAddOutput(output) else {
            throw CameraError.deviceUnavailable
        }
        session.addInput(deviceInput)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()

        // startRunning blocks; keep it off the main thread.
        await withCheckedContinuation { continuation in
            queue.async {
                self.session.startRunning()
                continuation.resume()
            }
        }

        guard let settings = output.recommendedVideoSettingsForAssetWriter(writingTo: .mp4) else {
            session.stopRunning()
            throw CameraError.writerSetupFailed("no recommended settings")
        }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            session.stopRunning()
            throw CameraError.writerSetupFailed("writer rejected input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            session.stopRunning()
            throw CameraError.writerSetupFailed(writer.error?.localizedDescription ?? "unknown")
        }
        // Publish writer/input to the capture queue before accepting buffers.
        queue.sync {
            self.writer = writer
            self.input = input
        }
    }

    func markTruncated() {
        queue.sync { truncated = true }
    }

    func stop() async throws -> TrackInfo {
        session.stopRunning()
        let (writer, input, startTime): (AVAssetWriter?, AVAssetWriterInput?, Double?) = queue.sync {
            (self.writer, self.input, self.sessionStartHostTime)
        }
        guard let writer, let input else {
            throw CameraError.writerSetupFailed("stop() before start()")
        }
        guard let startTime else {
            writer.cancelWriting()
            throw CameraError.noSamplesCaptured
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw CameraError.writerSetupFailed(writer.error?.localizedDescription ?? "finishWriting failed")
        }

        let fps = device.activeFormat.videoSupportedFrameRateRanges.first?.maxFrameRate
        return TrackInfo(
            type: .camera,
            filename: outputURL.lastPathComponent,
            sessionStartHostTime: startTime,
            nominalFPS: fps,
            codec: "h264",
            deviceName: device.localizedName,
            deviceID: device.uniqueID,
            truncated: truncated
        )
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let writer, let input, writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if sessionStartHostTime == nil {
            writer.startSession(atSourceTime: pts)
            sessionStartHostTime = pts.seconds
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
}
