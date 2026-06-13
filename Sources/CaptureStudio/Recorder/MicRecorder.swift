import Foundation
import AVFoundation

/// Records one microphone to mic.m4a (AAC) via its own AVCaptureSession.
final class MicRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    enum MicError: LocalizedError {
        case deviceUnavailable
        case writerSetupFailed(String)
        case noSamplesCaptured

        var errorDescription: String? {
            switch self {
            case .deviceUnavailable: return "Microphone is unavailable."
            case .writerSetupFailed(let detail): return "Microphone writer failed: \(detail)"
            case .noSamplesCaptured: return "Microphone produced no audio."
            }
        }
    }

    private let device: AVCaptureDevice
    private let outputURL: URL
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "capturestudio.mic.output")

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private(set) var sessionStartHostTime: Double?
    private(set) var truncated = false

    init(device: AVCaptureDevice, outputURL: URL) {
        self.device = device
        self.outputURL = outputURL
        super.init()
    }

    /// Warms up the session (opens the device, starts running) without creating
    /// a writer — buffers flow to the delegate but are discarded while `writer`
    /// is nil. Lets the mic be ready before the countdown.
    func warmUp() async throws {
        let deviceInput: AVCaptureDeviceInput
        do {
            deviceInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw MicError.deviceUnavailable
        }
        session.beginConfiguration()
        guard session.canAddInput(deviceInput), session.canAddOutput(output) else {
            throw MicError.deviceUnavailable
        }
        session.addInput(deviceInput)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()

        await withCheckedContinuation { continuation in
            queue.async {
                self.session.startRunning()
                continuation.resume()
            }
        }
    }

    /// Creates the writer and begins accepting samples. Call after `warmUp()`.
    func beginWriting() throws {
        guard let settings = output.recommendedAudioSettingsForAssetWriter(writingTo: .m4a) else {
            throw MicError.writerSetupFailed("no recommended settings")
        }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw MicError.writerSetupFailed("writer rejected input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw MicError.writerSetupFailed(writer.error?.localizedDescription ?? "unknown")
        }
        queue.sync {
            self.writer = writer
            self.input = input
        }
    }

    /// Tears down without finalizing — for Cancel from the armed state.
    func discard() async {
        session.stopRunning()
        queue.sync { self.writer?.cancelWriting() }
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
            throw MicError.writerSetupFailed("stop() before start()")
        }
        guard let startTime else {
            writer.cancelWriting()
            throw MicError.noSamplesCaptured
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw MicError.writerSetupFailed(writer.error?.localizedDescription ?? "finishWriting failed")
        }

        return TrackInfo(
            type: .mic,
            filename: outputURL.lastPathComponent,
            sessionStartHostTime: startTime,
            nominalFPS: nil,
            codec: "aac",
            deviceName: device.localizedName,
            deviceID: device.uniqueID,
            truncated: truncated
        )
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

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
