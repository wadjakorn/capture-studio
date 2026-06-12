import Foundation
import ScreenCaptureKit
import AVFoundation
import AppKit

/// Orchestrates a recording: owns the bundle, all recorders, and the
/// state machine. Screen track is mandatory; camera/mic/events degrade
/// independently — a partial bundle beats a lost recording.
@MainActor
final class RecordingSession: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case recording(startedAt: Date)
        case finishing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastBundleURL: URL?
    /// Non-fatal problems from the last recording (camera died, mic failed…).
    @Published private(set) var warnings: [String] = []

    private var bundle: ProjectBundle?
    private var screenRecorder: ScreenRecorder?
    private var cameraRecorder: CameraRecorder?
    private var micRecorder: MicRecorder?
    private let eventTracker = EventTracker()
    private var displayInfo: DisplayInfo?

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    func start(displayID: CGDirectDisplayID,
               cameraID: String? = nil,
               micID: String? = nil,
               systemAudio: Bool = false) async {
        guard state == .idle || isFailed else { return }
        state = .preparing
        warnings = []
        Log.recorder.info("start: display=\(displayID) camera=\(cameraID ?? "none", privacy: .public) mic=\(micID ?? "none", privacy: .public) systemAudio=\(systemAudio)")

        do {
            let (items, scDisplays) = try await DeviceDiscovery.displays()
            guard let item = items.first(where: { $0.id == displayID }),
                  let scDisplay = scDisplays[displayID] else {
                state = .failed("Selected display is no longer available.")
                return
            }

            try FileManager.default.createDirectory(
                at: ProjectBundle.defaultRecordingsDirectory(),
                withIntermediateDirectories: true
            )
            let bundle = try ProjectBundle.createNew()

            // Screen is mandatory — failure here aborts the recording.
            // System audio rides the same stream and degrades to a warning.
            let screen = ScreenRecorder(
                display: scDisplay, item: item, outputURL: bundle.screenURL,
                systemAudioURL: systemAudio ? bundle.systemAudioURL : nil
            )
            screen.onStreamError = { [weak self] error in
                Task { @MainActor in await self?.stop(streamError: error) }
            }
            try await screen.start()
            if let warning = screen.systemAudioWarning {
                warnings.append(warning)
            }

            // Camera/mic are best-effort — failure becomes a warning.
            if let cameraID, let device = DeviceDiscovery.cameras().first(where: { $0.uniqueID == cameraID }) {
                let recorder = CameraRecorder(device: device, outputURL: bundle.cameraURL)
                do {
                    try await recorder.start()
                    cameraRecorder = recorder
                } catch {
                    Log.recorder.error("camera start failed: \(error.localizedDescription, privacy: .public)")
                    warnings.append("Camera not recorded: \(error.localizedDescription)")
                }
            }
            if let micID, let device = DeviceDiscovery.microphones().first(where: { $0.uniqueID == micID }) {
                let recorder = MicRecorder(device: device, outputURL: bundle.micURL)
                do {
                    try await recorder.start()
                    micRecorder = recorder
                } catch {
                    Log.recorder.error("mic start failed: \(error.localizedDescription, privacy: .public)")
                    warnings.append("Microphone not recorded: \(error.localizedDescription)")
                }
            }

            eventTracker.start()

            self.bundle = bundle
            self.screenRecorder = screen
            self.displayInfo = item.displayInfo
            state = .recording(startedAt: Date())
            Log.recorder.info("recording: \(bundle.url.lastPathComponent, privacy: .public)")
        } catch {
            Log.recorder.error("start failed: \(error.localizedDescription, privacy: .public)")
            cleanupAbandonedBundle()
            state = .failed(error.localizedDescription)
        }
    }

    /// Stops all recorders, finalizes files, writes meta.json LAST
    /// (its presence marks the bundle valid).
    func stop(streamError: Error? = nil) async {
        guard isRecording else { return }
        state = .finishing

        guard let bundle, let screenRecorder, let displayInfo else {
            state = .failed("Internal error: no active recording.")
            return
        }

        do {
            // Screen first — its anchor time is needed for events.
            let screenResult = try await screenRecorder.stop()
            let screenTrack = screenResult.screen
            var tracks = [screenTrack]
            if let systemAudioTrack = screenResult.systemAudio {
                tracks.append(systemAudioTrack)
            } else if let warning = screenRecorder.systemAudioWarning,
                      !warnings.contains(warning) {
                warnings.append(warning)
            }

            if let cameraRecorder {
                do { tracks.append(try await cameraRecorder.stop()) }
                catch { warnings.append("Camera track lost: \(error.localizedDescription)") }
            }
            if let micRecorder {
                do { tracks.append(try await micRecorder.stop()) }
                catch { warnings.append("Microphone track lost: \(error.localizedDescription)") }
            }

            do {
                try eventTracker.stopAndWrite(
                    to: bundle.eventsURL,
                    screenAnchorHostTime: screenTrack.sessionStartHostTime
                )
            } catch {
                warnings.append("Event data lost: \(error.localizedDescription)")
            }

            let meta = ProjectMeta(
                app: .current(),
                display: displayInfo,
                tracks: tracks,
                recordedAt: Date()
            )
            try bundle.writeMeta(meta)
            Log.recorder.info("stop OK: \(bundle.url.lastPathComponent, privacy: .public) tracks=\(tracks.count) warnings=\(self.warnings.count)")
            lastBundleURL = bundle.url
            state = .idle
            StudioLauncher.open(bundleURL: bundle.url)
            if let streamError {
                state = .failed("Recording saved, but capture stopped early: \(streamError.localizedDescription)")
            }
        } catch {
            Log.recorder.error("stop failed: \(error.localizedDescription, privacy: .public)")
            eventTracker.cancel()
            state = .failed(error.localizedDescription)
        }

        self.bundle = nil
        self.screenRecorder = nil
        self.cameraRecorder = nil
        self.micRecorder = nil
        self.displayInfo = nil
    }

    func resetFailure() {
        if isFailed { state = .idle }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func cleanupAbandonedBundle() {
        eventTracker.cancel()
        if let url = bundle?.url {
            try? FileManager.default.removeItem(at: url)
        }
        bundle = nil
        screenRecorder = nil
        cameraRecorder = nil
        micRecorder = nil
        displayInfo = nil
    }
}
