import AVFoundation
import CoreGraphics

/// What a camera-source recorder offers for the live preview panel: the local
/// camera's own `AVCaptureSession`, or a display layer fed decoded frames
/// (e.g. a Wi-Fi phone stream).
enum PreviewSurface {
    case captureSession(AVCaptureSession)
    case displayLayer(AVSampleBufferDisplayLayer)
}

/// Result of a camera-source recording. `camera` is nil when the source
/// produced no video (or is mic-only); `mic` when no audio was captured.
struct CameraSourceResult {
    var camera: TrackInfo?
    var mic: TrackInfo?
}

/// A warm-up/begin/stop camera (+ optional hosted mic) source that
/// `RecordingSession` drives — the local `CameraRecorder` or a remote phone.
/// Same Preview/Record split: `warmUp()` starts buffers flowing with no
/// writers; `beginWriting()` flips writers on.
protocol CameraSourceRecorder: AnyObject {
    /// nil for a mic-only source (no preview panel).
    var previewSurface: PreviewSurface? { get }
    var sessionStartHostTime: Double? { get }
    var truncated: Bool { get }
    var micWarning: String? { get }
    /// Non-fatal problems found during `warmUp()`; the caller surfaces them.
    var warmUpWarnings: [String] { get }
    var writtenPixelSize: CGSize? { get }
    /// Fired once, on an arbitrary thread, when the camera or hosted mic is lost.
    var onDeviceLost: (@Sendable (String) -> Void)? { get set }
    /// Fired once, on an arbitrary thread, when the CAMERA itself is lost.
    var onCameraLost: (@Sendable () -> Void)? { get set }
    /// True once the camera has been lost (sticky). Safe from any thread.
    var isCameraLost: Bool { get }

    func warmUp() async throws
    func beginWriting() throws
    func stop() async throws -> CameraSourceResult
    func discard() async
}
