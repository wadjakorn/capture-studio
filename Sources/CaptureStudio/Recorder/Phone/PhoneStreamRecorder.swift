import AVFoundation
import CoreMedia
import Foundation
import QuartzCore

/// Records a Wi-Fi phone's H.264 (+ optional AAC) stream without re-encoding,
/// behind the same warm-up/begin/stop contract as the local `CameraRecorder`.
///
/// - `warmUp()` connects, authenticates (pairing if needed), syncs the clock
///   and sends START; preview frames flow immediately, nothing is written.
/// - `beginWriting()` only arms writing: the video writer is created lazily on
///   the first keyframe captured at or after Record (host clock), the audio
///   writer on the first access unit at or after Record.
/// - Every phone PTS is mapped onto the host clock (`ClockSync.mapToHost`), so
///   `sessionStartHostTime` is directly comparable with the screen track.
///
/// `@unchecked Sendable`: all mutable state is read and written only on
/// `queue`. Delegate callbacks arrive on `PhoneConnection.queue` and hop onto
/// `queue` (frames asynchronously, in order; loss synchronously so callbacks
/// fire off `queue`). Public getters use `queue.sync`. `layer` is only
/// configured on the main thread; enqueueing samples is thread-safe.
final class PhoneStreamRecorder: CameraSourceRecorder, PhoneConnectionDelegate, @unchecked Sendable {
    enum PhoneRecorderError: LocalizedError {
        case notWarmedUp

        var errorDescription: String? {
            switch self {
            case .notWarmedUp: return "Phone is not connected."
            }
        }
    }

    private static let maxBufferedSpan = CMTime(value: 2, timescale: 1)
    private static let drainRetryInterval: DispatchTimeInterval = .milliseconds(5)
    private static let stopDrainTimeout: TimeInterval = 2
    private static let nominalFPS: Double = 30
    /// No primary-track sample for this long after warm-up → treated as a disconnect.
    private static let frameStallTimeout: TimeInterval = 3

    private let device: PhoneDevice
    private let video: Bool
    private let audio: Bool
    private let facing: String
    private let outputURL: URL?
    private let micOutputURL: URL?
    private let pairingStore: PhonePairingStore
    private let onPairingCode: @Sendable (String?) -> Void
    private let queue = DispatchQueue(label: "capturestudio.phone.recorder")
    /// Preview layer (video recorders only). Created on the main thread.
    private let layer: AVSampleBufferDisplayLayer?
    /// `layer.sampleBufferRenderer`, captured in `init`; enqueue/flush/status are thread-safe.
    private let renderer: AVSampleBufferVideoRenderer?

    var onDeviceLost: (@Sendable (String) -> Void)?
    var onCameraLost: (@Sendable () -> Void)?

    // MARK: State (queue-confined)

    private var connection: PhoneConnection?
    private var offsetNs: Int64 = 0
    private var started = false
    private var shouldWrite = false
    private var stopping = false
    private var stopRequested = false
    private var beginHostPTS = CMTime.positiveInfinity
    private var _warmUpWarnings: [String] = []
    private var _micWarning: String?
    private var _truncated = false
    private var micTruncated = false
    private var deviceLost = false
    private var deviceLostReported = false
    /// Frame-arrival watchdog (armed after warm-up; rearmed per primary-track sample).
    private var frameWatchdog: DispatchSourceTimer?

    // Video
    private var videoFormat: CMVideoFormatDescription?
    private var videoDimensions = CGSize.zero
    private var previewTransformKey: (rotation: UInt16, mirrored: Bool)?
    private var videoWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var videoWriterFailed = false
    private var _sessionStartHostTime: Double?
    private var _writtenPixelSize: CGSize?
    private var rotationLatch = RotationLatch()
    private var latchedMirrored = false
    private var videoGate = PTSGate()
    private var videoFIFO: [CMSampleBuffer] = []
    private var videoNeedsKeyframe = false
    private var videoDrainScheduled = false
    private var warnedFormatChange = false
    private var warnedRotationChange = false
    private var warnedVideoOrder = false
    private var warnedVideoOverflow = false

    // Audio
    private var audioFormat: CMAudioFormatDescription?
    private var audioWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var audioWriterFailed = false
    private var audioStartHostTime: Double?
    private var audioGate = PTSGate()
    private var audioFIFO: [CMSampleBuffer] = []
    private var audioDrainScheduled = false
    private var warnedAudioOrder = false
    private var warnedAudioOverflow = false
    /// True until the phone's first AU since START/AUDIO_CONFIG has been seen.
    private var awaitingStreamFirstAU = true
    /// Priming still to trim from the head of the written audio (spec rule 5).
    private var primingTrimRemaining = CMTime.zero
    /// Host time of the last KEYFRAME_REQ sent from a recovery path (rate limit).
    private var lastRecoveryKeyframeRequest: CMTime?
    private static let keyframeRequestMinInterval = CMTime(value: 1, timescale: 2)

    // MARK: Public getters

    var previewSurface: PreviewSurface? { layer.map { .displayLayer($0) } }
    var sessionStartHostTime: Double? { queue.sync { _sessionStartHostTime } }
    var truncated: Bool { queue.sync { _truncated } }
    var micWarning: String? { queue.sync { _micWarning } }
    var warmUpWarnings: [String] { queue.sync { _warmUpWarnings } }
    var writtenPixelSize: CGSize? { queue.sync { _writtenPixelSize } }
    var isCameraLost: Bool { queue.sync { video && deviceLost } }

    /// Call on the main thread (`RecordingSession` does): the preview layer is a CALayer.
    init(device: PhoneDevice, video: Bool, audio: Bool, facing: String, outputURL: URL?, micOutputURL: URL?,
         pairingStore: PhonePairingStore, onPairingCode: @escaping @Sendable (String?) -> Void) {
        self.device = device
        self.video = video
        self.audio = audio
        self.facing = facing
        self.outputURL = outputURL
        self.micOutputURL = micOutputURL
        self.pairingStore = pairingStore
        self.onPairingCode = onPairingCode
        if video {
            let layer = AVSampleBufferDisplayLayer()
            layer.videoGravity = .resizeAspect
            self.layer = layer
            self.renderer = layer.sampleBufferRenderer
        } else {
            self.layer = nil
            self.renderer = nil
        }
    }

    // MARK: - Warm-up

    /// connect → authenticate/pair → clock sync → START (rule 1). Errors propagate;
    /// the connection is closed on failure.
    func warmUp() async throws {
        let pairing = pairingStore.pairing(for: device.id)
        let conn = PhoneConnection(device: device, pairing: pairing,
                                   macName: Host.current().localizedName ?? "Mac")
        conn.delegate = self
        queue.sync { connection = conn }
        do {
            let presented = try await conn.connect()
            let token: Data?
            do {
                let onPairingCode = self.onPairingCode
                defer { onPairingCode(nil) }
                token = try await conn.authenticate(onCode: { code in onPairingCode(code) })
            }
            if let token {
                do {
                    try pairingStore.save(PhonePairing(fingerprint: presented, token: token, name: device.name),
                                          for: device.id)
                } catch {
                    Log.recorder.error("phone pairing save failed: \(error.localizedDescription, privacy: .public)")
                    addWarmUpWarning("Could not save pairing with \(device.name); you will be asked to pair again.")
                }
            }
            let clock = try await conn.syncClock()
            queue.sync { offsetNs = clock.offsetNs }
            if clock.minRTTNs > ClockSync.slowRTTThresholdNs {
                let ms = clock.minRTTNs / 1_000_000
                addWarmUpWarning("Slow Wi-Fi to \(device.name) (\(ms) ms round trip); expect latency.")
            }
            Log.recorder.info("phone clock sync: offset=\(clock.offsetNs) ns minRTT=\(clock.minRTTNs) ns")
            try await conn.start(StartConfig(video: video, audio: audio, facing: facing,
                                             width: 1920, height: 1080, fps: 30, bitrate: 8_000_000))
            queue.sync {
                started = true
                armFrameWatchdog()
            }
        } catch {
            Log.recorder.error("phone warm-up failed: \(error.localizedDescription, privacy: .public)")
            conn.close()
            throw error
        }
    }

    private func addWarmUpWarning(_ w: String) {
        queue.sync { _warmUpWarnings.append(w) }
    }

    // MARK: - Begin

    /// Arms writing (rule 2): no writer is created here.
    func beginWriting() throws {
        let conn: PhoneConnection = try queue.sync {
            guard started, let connection else { throw PhoneRecorderError.notWarmedUp }
            beginHostPTS = CMClockGetTime(CMClockGetHostTimeClock())
            shouldWrite = true
            return connection
        }
        conn.requestKeyframe()
    }

    // MARK: - Delegate (connection.queue → queue)

    func phoneConnection(_ c: PhoneConnection, videoConfig: VideoConfigPayload) {
        queue.async { self.handleVideoConfig(videoConfig) }
    }

    func phoneConnection(_ c: PhoneConnection, videoFrame: VideoFramePayload) {
        queue.async { self.handleVideoFrame(videoFrame) }
    }

    func phoneConnection(_ c: PhoneConnection, audioConfig asc: Data) {
        queue.async { self.handleAudioConfig(asc) }
    }

    func phoneConnection(_ c: PhoneConnection, audioFrame: AudioFramePayload) {
        queue.async { self.handleAudioFrame(audioFrame) }
    }

    /// Connection lost mid-stream (rule 9): mark truncated, report once; the
    /// writers keep what they have and are finalized by `stop()`.
    func phoneConnection(_ c: PhoneConnection, didFail message: String) {
        Log.recorder.error("phone connection failed: \(message, privacy: .public)")
        let (firstReport, firstCameraLoss) = queue.sync { markLostLocked() }
        reportLoss(firstReport: firstReport, firstCameraLoss: firstCameraLoss)
    }

    /// Queue. Marks the stream lost (truncated, device lost); returns which
    /// callbacks are due (each fires once per recorder).
    private func markLostLocked() -> (firstReport: Bool, firstCameraLoss: Bool) {
        cancelFrameWatchdog()
        _truncated = true
        micTruncated = true
        let firstCameraLoss = video && !deviceLost
        deviceLost = true
        guard !deviceLostReported else { return (false, firstCameraLoss) }
        deviceLostReported = true
        return (true, firstCameraLoss)
    }

    /// Off `queue` (callers may read the recorder's getters synchronously).
    private func reportLoss(firstReport: Bool, firstCameraLoss: Bool) {
        if firstReport { onDeviceLost?("Phone disconnected.") }
        if firstCameraLoss { onCameraLost?() }
    }

    // MARK: - Frame-arrival watchdog (queue)

    /// The connection can stay open for a long time after Wi-Fi drops (TCP
    /// keepalive). No video (or, audio-only, no audio) for 3 s → same as `didFail`.
    private func armFrameWatchdog() {
        guard frameWatchdog == nil, !stopping, !stopRequested, !deviceLost else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.frameStallTimeout)
        timer.setEventHandler { [weak self] in self?.frameWatchdogFired() }
        frameWatchdog = timer
        timer.resume()
    }

    private func rearmFrameWatchdog() {
        frameWatchdog?.schedule(deadline: .now() + Self.frameStallTimeout)
    }

    private func cancelFrameWatchdog() {
        frameWatchdog?.cancel()
        frameWatchdog = nil
    }

    private func frameWatchdogFired() {
        guard frameWatchdog != nil, !stopping, !stopRequested else { return }
        Log.recorder.error("phone stream stalled: no \(self.video ? "video" : "audio", privacy: .public) for \(Self.frameStallTimeout) s; treating as disconnected")
        let (firstReport, firstCameraLoss) = markLostLocked()
        connection?.close()
        DispatchQueue.global(qos: .userInitiated).async {
            self.reportLoss(firstReport: firstReport, firstCameraLoss: firstCameraLoss)
        }
    }

    func markTruncated() {
        queue.sync { _truncated = true; micTruncated = true }
    }

    // MARK: - Video

    private func handleVideoConfig(_ config: VideoConfigPayload) {
        guard video else { return }
        if videoWriter != nil {
            if !warnedFormatChange {
                warnedFormatChange = true
                Log.recorder.warning("Phone changed video format mid-recording; ignoring.")
            }
            return
        }
        do {
            let format = try MediaPassthrough.videoFormat(parameterSets: config.parameterSets)
            videoFormat = format
            videoDimensions = MediaPassthrough.dimensions(of: format)
            Log.recorder.info("phone video config: \(Int(self.videoDimensions.width))x\(Int(self.videoDimensions.height))")
        } catch {
            Log.recorder.error("phone video config rejected: \(String(describing: error), privacy: .public)")
        }
    }

    private func handleVideoFrame(_ frame: VideoFramePayload) {
        guard video else { return }
        rearmFrameWatchdog()
        guard !stopping, let format = videoFormat else { return }
        let hostPTS = ClockSync.mapToHost(ptsNs: frame.ptsNs, offsetNs: offsetNs)
        let sample: CMSampleBuffer
        do {
            sample = try MediaPassthrough.videoSample(frame, format: format, pts: hostPTS)
        } catch {
            Log.recorder.error("phone video sample failed: \(String(describing: error), privacy: .public)")
            return
        }
        enqueuePreview(sample, frame: frame)
        writeVideo(sample, frame: frame, hostPTS: hostPTS, format: format)
    }

    /// Rule 7: a DisplayImmediately copy per frame; rotation/mirror as a layer
    /// transform. This recorder owns `layer.transform`; the preview panel hosts the
    /// layer in a container (its mirror toggle flips the container, and it lays the
    /// layer out with swapped bounds for 90/270).
    private func enqueuePreview(_ sample: CMSampleBuffer, frame: VideoFramePayload) {
        guard let layer, let renderer else { return }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            Log.recorder.error("phone preview renderer failed: \(renderer.error?.localizedDescription ?? "unknown", privacy: .public); flushing")
            renderer.flush()
            requestRecoveryKeyframe()
        }
        do {
            renderer.enqueue(try MediaPassthrough.previewCopy(sample))
        } catch {
            Log.recorder.error("phone preview copy failed: \(String(describing: error), privacy: .public)")
        }
        if previewTransformKey?.rotation != frame.rotationDeg || previewTransformKey?.mirrored != frame.mirrored {
            previewTransformKey = (frame.rotationDeg, frame.mirrored)
            let radians = -CGFloat(frame.rotationDeg % 360) * .pi / 180
            let transform = CATransform3DConcat(CATransform3DMakeRotation(radians, 0, 0, 1),
                                                CATransform3DMakeScale(frame.mirrored ? -1 : 1, 1, 1))
            DispatchQueue.main.async {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.transform = transform
                CATransaction.commit()
            }
        }
    }

    private func writeVideo(_ sample: CMSampleBuffer, frame: VideoFramePayload, hostPTS: CMTime,
                            format: CMVideoFormatDescription) {
        guard shouldWrite, !videoWriterFailed else { return }
        if videoWriter == nil {
            // Rule 3: the first written frame is a keyframe captured at/after Record.
            guard frame.keyframe, PTSFloor(floor: beginHostPTS).accept(hostPTS) else { return }
            guard startVideoWriter(frame: frame, hostPTS: hostPTS, format: format) else { return }
        } else if !warnedRotationChange,
                  frame.rotationDeg != rotationLatch.value || frame.mirrored != latchedMirrored {
            warnedRotationChange = true
            Log.recorder.warning("Phone rotation changed mid-recording; keeping the initial orientation.")
        }
        guard videoGate.accept(hostPTS) else {
            if !warnedVideoOrder {
                warnedVideoOrder = true
                Log.recorder.warning("phone video PTS not increasing; dropping frame")
            }
            return
        }
        // After an overflow trimmed the buffer empty, resume only at a keyframe.
        if videoNeedsKeyframe {
            guard frame.keyframe else { return }
            videoNeedsKeyframe = false
        }
        videoFIFO.append(sample)
        trimVideoOverflow()
        drainVideo()
    }

    private func startVideoWriter(frame: VideoFramePayload, hostPTS: CMTime,
                                  format: CMVideoFormatDescription) -> Bool {
        guard let outputURL else { videoWriterFailed = true; return false }
        var created = false
        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            created = true
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = true
            let rotation = rotationLatch.latch(frame.rotationDeg)
            latchedMirrored = frame.mirrored
            // The transform must be set before startWriting. Rotation only: `mirrored`
            // affects the preview, never the file (always unmirrored, like the local camera).
            input.transform = MediaPassthrough.transform(rotationDeg: rotation, mirrored: false,
                                                         size: videoDimensions)
            guard writer.canAdd(input) else {
                throw PhoneWriterError("writer rejected video input")
            }
            writer.add(input)
            guard writer.startWriting() else {
                throw PhoneWriterError(writer.error?.localizedDescription ?? "startWriting failed")
            }
            writer.startSession(atSourceTime: hostPTS)
            videoWriter = writer
            videoInput = input
            _sessionStartHostTime = hostPTS.seconds
            // Rule 6: post-rotation size, i.e. what the viewer sees.
            _writtenPixelSize = MediaPassthrough.rotatedSize(videoDimensions, rotationDeg: rotation)
            Log.recorder.info("phone video writer started: rotation=\(rotation) mirrored=\(frame.mirrored)")
            return true
        } catch {
            Log.recorder.error("phone video writer failed: \(error.localizedDescription, privacy: .public)")
            if created { try? FileManager.default.removeItem(at: outputURL) }
            videoWriterFailed = true
            return false
        }
    }

    /// Rule 4 overflow: drop the oldest frames, then any leading non-keyframes
    /// (they reference the dropped ones) so the buffer always starts at a keyframe.
    private func trimVideoOverflow() {
        guard Self.overflows(videoFIFO) else { return }
        while Self.overflows(videoFIFO) { videoFIFO.removeFirst() }
        while let head = videoFIFO.first, !Self.isKeyframe(head) { videoFIFO.removeFirst() }
        if videoFIFO.isEmpty { videoNeedsKeyframe = true }
        _truncated = true
        requestRecoveryKeyframe()
        if !warnedVideoOverflow {
            warnedVideoOverflow = true
            Log.recorder.warning("Wi-Fi could not keep up; video was truncated.")
        }
    }

    /// KEYFRAME_REQ from the overflow/renderer-recovery paths, at most once per 500 ms.
    private func requestRecoveryKeyframe() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if let last = lastRecoveryKeyframeRequest, now - last < Self.keyframeRequestMinInterval { return }
        lastRecoveryKeyframeRequest = now
        connection?.requestKeyframe()
    }

    // MARK: - Audio

    private func handleAudioConfig(_ asc: Data) {
        guard audio else { return }
        if audioWriter != nil {
            Log.recorder.warning("Phone changed audio format mid-recording; ignoring.")
            return
        }
        do {
            audioFormat = try MediaPassthrough.audioFormat(asc: asc)
            awaitingStreamFirstAU = true
        } catch {
            Log.recorder.error("phone audio config rejected: \(String(describing: error), privacy: .public)")
            if _micWarning == nil { _micWarning = "Phone microphone format is unsupported." }
        }
    }

    /// Rule 5: own anchor from the first accepted AU (`hostPTS ≥ beginHostPTS`).
    private func handleAudioFrame(_ frame: AudioFramePayload) {
        guard audio else { return }
        if !video { rearmFrameWatchdog() }
        let isStreamFirstAU = awaitingStreamFirstAU
        awaitingStreamFirstAU = false
        guard !stopping, shouldWrite, !audioWriterFailed, let format = audioFormat else { return }
        let hostPTS = ClockSync.mapToHost(ptsNs: frame.ptsNs, offsetNs: offsetNs)
        guard PTSFloor(floor: beginHostPTS).accept(hostPTS) else { return }
        if audioWriter == nil {
            guard startAudioWriter(hostPTS: hostPTS, format: format) else { return }
            // Spec rule 5, as ruled: encoder priming exists only at the head of the
            // phone's stream. The encoder starts at warm-up, so the first AU after
            // Record is normally mid-stream and must not be trimmed; trim only when
            // it is also the first AU since START/AUDIO_CONFIG.
            primingTrimRemaining = isStreamFirstAU ? Self.primingTrim(for: format) : .zero
        }
        guard audioGate.accept(hostPTS) else {
            if !warnedAudioOrder {
                warnedAudioOrder = true
                Log.recorder.warning("phone audio PTS not increasing; dropping access unit")
            }
            return
        }
        let sample: CMSampleBuffer
        do {
            sample = try MediaPassthrough.audioSample(frame, format: format, pts: hostPTS,
                                                      trimAtStart: nextPrimingTrim(format: format))
        } catch {
            Log.recorder.error("phone audio sample failed: \(String(describing: error), privacy: .public)")
            return
        }
        audioFIFO.append(sample)
        if Self.overflows(audioFIFO) {
            while Self.overflows(audioFIFO) { audioFIFO.removeFirst() }
            micTruncated = true
            if !warnedAudioOverflow {
                warnedAudioOverflow = true
                Log.recorder.warning("Wi-Fi could not keep up; phone audio was truncated.")
            }
        }
        drainAudio()
    }

    /// The priming (`aacPrimingTrim`'s frame count) at the format's sample rate.
    private static func primingTrim(for format: CMAudioFormatDescription) -> CMTime {
        guard let rate = sampleRate(of: format) else { return .zero }
        return CMTime(value: MediaPassthrough.aacPrimingTrim.value, timescale: rate)
    }

    /// Trim for the next written AU: the remaining priming capped to one AU
    /// (1024 frames) — a trim may not exceed its sample; the rest carries over.
    private func nextPrimingTrim(format: CMAudioFormatDescription) -> CMTime? {
        guard primingTrimRemaining > .zero, let rate = Self.sampleRate(of: format) else { return nil }
        let trim = CMTimeMinimum(primingTrimRemaining, CMTime(value: 1024, timescale: rate))
        primingTrimRemaining = primingTrimRemaining - trim
        return trim
    }

    private static func sampleRate(of format: CMAudioFormatDescription) -> CMTimeScale? {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mSampleRate > 0 else { return nil }
        return CMTimeScale(asbd.mSampleRate.rounded())
    }

    private func startAudioWriter(hostPTS: CMTime, format: CMAudioFormatDescription) -> Bool {
        guard let micOutputURL else { audioWriterFailed = true; return false }
        var created = false
        do {
            let writer = try AVAssetWriter(outputURL: micOutputURL, fileType: .m4a)
            created = true
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw PhoneWriterError("writer rejected audio input")
            }
            writer.add(input)
            guard writer.startWriting() else {
                throw PhoneWriterError(writer.error?.localizedDescription ?? "startWriting failed")
            }
            writer.startSession(atSourceTime: hostPTS)
            audioWriter = writer
            audioInput = input
            audioStartHostTime = hostPTS.seconds
            return true
        } catch {
            Log.recorder.error("phone audio writer failed: \(error.localizedDescription, privacy: .public)")
            if created { try? FileManager.default.removeItem(at: micOutputURL) }
            audioWriterFailed = true
            if _micWarning == nil { _micWarning = "Phone microphone recording failed." }
            return false
        }
    }

    // MARK: - Writing (bounded FIFOs, queue)

    // Each FIFO is drained on every arrival while the input is ready; if the input
    // is busy, a short timed retry drains it (requestMediaDataWhenReady re-invokes
    // its block continuously while ready and the buffer is empty, which would spin
    // between frames). No sample is ever dropped because the input was not ready —
    // only on 2 s overflow.

    private func drainVideo() {
        guard let writer = videoWriter, let input = videoInput else { return }
        if !Self.drain(&videoFIFO, writer: writer, input: input) {
            Log.recorder.error("phone video append failed: \(writer.error?.localizedDescription ?? "unknown", privacy: .public)")
            videoWriterFailed = true
            videoFIFO.removeAll()
            return
        }
        if !videoFIFO.isEmpty, !videoDrainScheduled {
            videoDrainScheduled = true
            queue.asyncAfter(deadline: .now() + Self.drainRetryInterval) {
                self.videoDrainScheduled = false
                if !self.stopping { self.drainVideo() }
            }
        }
    }

    private func drainAudio() {
        guard let writer = audioWriter, let input = audioInput else { return }
        if !Self.drain(&audioFIFO, writer: writer, input: input) {
            Log.recorder.error("phone audio append failed: \(writer.error?.localizedDescription ?? "unknown", privacy: .public)")
            audioWriterFailed = true
            audioFIFO.removeAll()
            return
        }
        if !audioFIFO.isEmpty, !audioDrainScheduled {
            audioDrainScheduled = true
            queue.asyncAfter(deadline: .now() + Self.drainRetryInterval) {
                self.audioDrainScheduled = false
                if !self.stopping { self.drainAudio() }
            }
        }
    }

    /// Appends from the head while the input is ready. False if the writer failed.
    private static func drain(_ fifo: inout [CMSampleBuffer], writer: AVAssetWriter,
                              input: AVAssetWriterInput) -> Bool {
        guard writer.status == .writing else { return false }
        while let head = fifo.first, input.isReadyForMoreMediaData {
            guard input.append(head) else { return false }
            fifo.removeFirst()
        }
        return true
    }

    private static func overflows(_ fifo: [CMSampleBuffer]) -> Bool {
        guard let first = fifo.first, let last = fifo.last else { return false }
        let span = CMSampleBufferGetPresentationTimeStamp(last) - CMSampleBufferGetPresentationTimeStamp(first)
        return span > maxBufferedSpan
    }

    private static func isKeyframe(_ s: CMSampleBuffer) -> Bool {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: false) as? [[String: Any]],
              let attachments = array.first else { return true }
        return (attachments[kCMSampleAttachmentKey_NotSync as String] as? Bool) != true
    }

    // MARK: - Stop

    func stop() async throws -> CameraSourceResult {
        let conn: PhoneConnection = try queue.sync {
            // Once only: a second stop (or stop after discard) must not touch finished writers.
            guard let connection, !stopRequested, !stopping else { throw PhoneRecorderError.notWarmedUp }
            stopRequested = true
            cancelFrameWatchdog()
            return connection
        }
        await conn.stop()
        // Runs after every frame the connection delivered before closing.
        let writers: (video: AVAssetWriter?, audio: AVAssetWriter?) = await withCheckedContinuation { cont in
            queue.async {
                self.stopping = true
                self.flushFIFOsForStop()
                let video = self.videoFailedOrNil()
                let audio = self.audioFailedOrNil()
                if video != nil { self.videoInput?.markAsFinished() }
                if audio != nil { self.audioInput?.markAsFinished() }
                cont.resume(returning: (video, audio))
            }
        }
        if let w = writers.video { await w.finishWriting() }
        if let w = writers.audio { await w.finishWriting() }
        renderer?.flush()
        return queue.sync { buildResult(videoWriter: writers.video, audioWriter: writers.audio) }
    }

    /// The video writer to finish, or nil (none started / failed — its file is removed).
    private func videoFailedOrNil() -> AVAssetWriter? {
        guard let writer = videoWriter else { return nil }
        guard !videoWriterFailed, writer.status == .writing else {
            if writer.status == .writing { writer.cancelWriting() }
            if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
            Log.recorder.error("phone video writer failed; dropping camera track")
            return nil
        }
        return writer
    }

    private func audioFailedOrNil() -> AVAssetWriter? {
        guard let writer = audioWriter else { return nil }
        guard !audioWriterFailed, writer.status == .writing else {
            if writer.status == .writing { writer.cancelWriting() }
            if let micOutputURL { try? FileManager.default.removeItem(at: micOutputURL) }
            Log.recorder.error("phone audio writer failed; dropping mic track")
            if _micWarning == nil { _micWarning = "Phone microphone recording failed." }
            return nil
        }
        return writer
    }

    /// Appends everything still buffered, waiting (bounded) for the inputs to accept it.
    private func flushFIFOsForStop() {
        let deadline = Date().addingTimeInterval(Self.stopDrainTimeout)
        while !videoFIFO.isEmpty || !audioFIFO.isEmpty {
            drainVideoForStop()
            drainAudioForStop()
            guard !videoFIFO.isEmpty || !audioFIFO.isEmpty else { break }
            guard Date() < deadline else {
                if !videoFIFO.isEmpty { _truncated = true }
                if !audioFIFO.isEmpty { micTruncated = true }
                Log.recorder.warning("phone stop: inputs not ready; dropping \(self.videoFIFO.count + self.audioFIFO.count) buffered samples")
                videoFIFO.removeAll()
                audioFIFO.removeAll()
                break
            }
            usleep(2_000)
        }
    }

    private func drainVideoForStop() {
        guard let writer = videoWriter, let input = videoInput, !videoWriterFailed else { videoFIFO.removeAll(); return }
        if !Self.drain(&videoFIFO, writer: writer, input: input) {
            videoWriterFailed = true
            videoFIFO.removeAll()
        }
    }

    private func drainAudioForStop() {
        guard let writer = audioWriter, let input = audioInput, !audioWriterFailed else { audioFIFO.removeAll(); return }
        if !Self.drain(&audioFIFO, writer: writer, input: input) {
            audioWriterFailed = true
            audioFIFO.removeAll()
        }
    }

    private func buildResult(videoWriter: AVAssetWriter?, audioWriter: AVAssetWriter?) -> CameraSourceResult {
        var camera: TrackInfo?
        if video, let videoWriter, let outputURL, let start = _sessionStartHostTime {
            if videoWriter.status == .completed {
                camera = TrackInfo(type: .camera, filename: outputURL.lastPathComponent,
                                   sessionStartHostTime: start, nominalFPS: Self.nominalFPS, codec: "h264",
                                   deviceName: device.name, deviceID: PhoneDeviceID.camera(device.id),
                                   truncated: _truncated)
            } else {
                Log.recorder.error("phone video finish failed: \(videoWriter.error?.localizedDescription ?? "unknown", privacy: .public)")
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        var mic: TrackInfo?
        if audio, let audioWriter, let micOutputURL, let start = audioStartHostTime {
            if audioWriter.status == .completed {
                mic = TrackInfo(type: .mic, filename: micOutputURL.lastPathComponent,
                                sessionStartHostTime: start, codec: "aac",
                                deviceName: device.name, deviceID: PhoneDeviceID.mic(device.id),
                                truncated: micTruncated)
            } else {
                Log.recorder.error("phone audio finish failed: \(audioWriter.error?.localizedDescription ?? "unknown", privacy: .public)")
                try? FileManager.default.removeItem(at: micOutputURL)
                if _micWarning == nil { _micWarning = "Phone microphone recording failed." }
            }
        } else if audio, audioStartHostTime == nil, _micWarning == nil {
            _micWarning = "Phone microphone produced no audio."
        }
        return CameraSourceResult(camera: camera, mic: mic)
    }

    // MARK: - Discard

    func discard() async {
        let conn: PhoneConnection? = queue.sync {
            stopping = true
            shouldWrite = false
            cancelFrameWatchdog()
            videoFIFO.removeAll()
            audioFIFO.removeAll()
            if let videoWriter {
                if videoWriter.status == .writing { videoWriter.cancelWriting() }
                if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
            }
            if let audioWriter {
                if audioWriter.status == .writing { audioWriter.cancelWriting() }
                if let micOutputURL { try? FileManager.default.removeItem(at: micOutputURL) }
            }
            videoWriter = nil
            videoInput = nil
            audioWriter = nil
            audioInput = nil
            return connection
        }
        conn?.close()
        renderer?.flush()
    }
}

private struct PhoneWriterError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
