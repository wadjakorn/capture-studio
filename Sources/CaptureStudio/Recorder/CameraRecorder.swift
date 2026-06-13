import Foundation
import AVFoundation

/// Records one camera device to camera.mp4 via its own AVCaptureSession.
/// Sample buffer PTS are on the host clock — same timebase as the screen
/// track, so alignment is pure offset arithmetic.
///
/// Optionally also captures a microphone to mic.m4a **on the same session**.
/// A camera's built-in mic (e.g. a USB webcam) cannot stream audio to a rival
/// AVCaptureSession while this session owns the device — the audio session
/// gets zero buffers. Hosting the mic here avoids that contention.
final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                            AVCaptureAudioDataOutputSampleBufferDelegate {
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

    /// Result of a camera recording: the camera track plus, when a mic was
    /// hosted on this session and produced audio, its track too.
    struct Result {
        var camera: TrackInfo
        var mic: TrackInfo?
    }

    private let device: AVCaptureDevice
    private let outputURL: URL
    private let micDevice: AVCaptureDevice?
    private let micOutputURL: URL?
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "capturestudio.camera.output")

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private(set) var sessionStartHostTime: Double?
    /// Set true if the device disappeared mid-recording.
    private(set) var truncated = false
    /// Count of startup frames dropped while waiting for a host-clock PTS.
    private var videoWarmupDrops = 0
    private var audioWarmupDrops = 0
    /// After this many drops, accept the next frame regardless (safety net so
    /// an unexpected clock never loses the whole track).
    private static let maxWarmupDrops = 30

    // Mic captured on this same session (best-effort).
    private let audioOutput = AVCaptureAudioDataOutput()
    private let audioQueue = DispatchQueue(label: "capturestudio.camera.audio")
    private var audioWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var audioStartHostTime: Double?
    private var micAttached = false
    /// Non-fatal mic setup problem; surfaced so the caller can fall back.
    private(set) var micWarning: String?

    init(device: AVCaptureDevice, outputURL: URL,
         micDevice: AVCaptureDevice? = nil, micOutputURL: URL? = nil) {
        self.device = device
        self.outputURL = outputURL
        self.micDevice = micDevice
        self.micOutputURL = micOutputURL
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

        // Add the mic to this same session (best-effort). Audio setup failures
        // become a warning, never abort the camera.
        if let micDevice {
            attachMic(micDevice)
        }

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
        if micAttached { startAudioWriter() }
    }

    /// Adds the mic device's input + an audio output to the session. On any
    /// failure, records a warning and leaves the mic unattached.
    private func attachMic(_ micDevice: AVCaptureDevice) {
        guard micOutputURL != nil else { return }
        let micInput: AVCaptureDeviceInput
        do {
            micInput = try AVCaptureDeviceInput(device: micDevice)
        } catch {
            micWarning = "Microphone unavailable: \(error.localizedDescription)"
            return
        }
        guard session.canAddInput(micInput), session.canAddOutput(audioOutput) else {
            micWarning = "Microphone could not be added to the camera session."
            return
        }
        session.addInput(micInput)
        session.addOutput(audioOutput)
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        micAttached = true
    }

    private func startAudioWriter() {
        guard let micOutputURL else { return }
        guard let settings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .m4a) else {
            micWarning = "Microphone settings unavailable."
            return
        }
        do {
            let writer = try AVAssetWriter(outputURL: micOutputURL, fileType: .m4a)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                micWarning = "Microphone writer rejected input."
                return
            }
            writer.add(input)
            guard writer.startWriting() else {
                micWarning = writer.error?.localizedDescription ?? "Microphone writer failed to start."
                return
            }
            audioQueue.sync {
                self.audioWriter = writer
                self.audioInput = input
            }
        } catch {
            micWarning = "Microphone writer failed: \(error.localizedDescription)"
        }
    }

    func markTruncated() {
        queue.sync { truncated = true }
    }

    func stop() async throws -> Result {
        session.stopRunning()
        let (writer, input, startTime): (AVAssetWriter?, AVAssetWriterInput?, Double?) = queue.sync {
            (self.writer, self.input, self.sessionStartHostTime)
        }
        guard let writer, let input else {
            throw CameraError.writerSetupFailed("stop() before start()")
        }
        guard let startTime else {
            writer.cancelWriting()
            await finishAudio()  // tear down the audio writer too
            throw CameraError.noSamplesCaptured
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw CameraError.writerSetupFailed(writer.error?.localizedDescription ?? "finishWriting failed")
        }

        let fps = device.activeFormat.videoSupportedFrameRateRanges.first?.maxFrameRate
        let cameraTrack = TrackInfo(
            type: .camera,
            filename: outputURL.lastPathComponent,
            sessionStartHostTime: startTime,
            nominalFPS: fps,
            codec: "h264",
            deviceName: device.localizedName,
            deviceID: device.uniqueID,
            truncated: truncated
        )
        let micTrack = await finishAudio()
        return Result(camera: cameraTrack, mic: micTrack)
    }

    /// Finalizes the audio writer if it captured samples. Returns the mic
    /// TrackInfo, or nil (no mic, no samples, or failure — the camera survives).
    @discardableResult
    private func finishAudio() async -> TrackInfo? {
        let (writer, input, startTime): (AVAssetWriter?, AVAssetWriterInput?, Double?) = audioQueue.sync {
            (self.audioWriter, self.audioInput, self.audioStartHostTime)
        }
        guard let writer, let input, let micDevice, let startTime else {
            writer?.cancelWriting()
            if micAttached, micWarning == nil, audioStartHostTime == nil {
                micWarning = "Microphone produced no audio."
            }
            return nil
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            micWarning = writer.error?.localizedDescription ?? "Microphone finish failed."
            return nil
        }
        return TrackInfo(
            type: .mic,
            filename: (micOutputURL ?? outputURL).lastPathComponent,
            sessionStartHostTime: startTime,
            nominalFPS: nil,
            codec: "aac",
            deviceName: micDevice.localizedName,
            deviceID: micDevice.uniqueID,
            truncated: truncated
        )
    }

    // MARK: - Sample buffer delegate (video + audio share this callback)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === audioOutput {
            appendAudio(sampleBuffer)
        } else {
            appendVideo(sampleBuffer)
        }
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let writer, let input, writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if sessionStartHostTime == nil {
            // Adding a mic makes AVCaptureSession's master clock switch to the
            // audio device clock once at startup, so the first few frames can
            // be stamped on a transient clock (PTS near 0) before it settles
            // on host time. Anchoring on such a frame corrupts the track
            // timeline. Drop startup frames until the PTS matches wall-clock
            // host time; that frame's PTS is then a valid host-clock anchor.
            guard isHostClockPTS(pts, drops: &videoWarmupDrops) else { return }
            writer.startSession(atSourceTime: pts)
            sessionStartHostTime = pts.seconds
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    /// True if `pts` looks like it is on the host-time clock (within a few
    /// seconds of now), or if we have dropped enough frames that we accept it
    /// regardless. Increments `drops` while rejecting.
    private func isHostClockPTS(_ pts: CMTime, drops: inout Int) -> Bool {
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        if abs(pts.seconds - hostNow) < 5 { return true }
        drops += 1
        return drops > Self.maxWarmupDrops
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let writer = audioWriter, let input = audioInput,
              writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if audioStartHostTime == nil {
            guard isHostClockPTS(pts, drops: &audioWarmupDrops) else { return }
            writer.startSession(atSourceTime: pts)
            audioStartHostTime = pts.seconds
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
}
