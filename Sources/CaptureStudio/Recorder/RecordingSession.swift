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
        case arming                       // warming up sources (sessions starting)
        case armed                        // sources warm, preview shown, awaiting Record
        case preparing                    // beginRecording flipping writers on
        case recording(startedAt: Date)
        case finishing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastBundleURL: URL?
    /// Non-fatal problems from the last recording (camera died, mic failed…).
    @Published private(set) var warnings: [String] = []
    /// True while the 3-2-1 countdown is running (before writers flip on).
    /// Drives the "Starting…" UI and blocks a double countdown.
    @Published private(set) var counting = false

    private var countdownTask: Task<Void, Never>?

    /// The live session, exposed so the app delegate can tear down on quit.
    /// There is only ever one.
    static weak var shared: RecordingSession?

    init() { Self.shared = self }

    private var bundle: ProjectBundle?
    private var screenRecorder: ScreenRecorder?
    private var cameraRecorder: CameraRecorder?
    private var micRecorder: MicRecorder?
    private var previewPanel: CameraPreviewPanel?
    private var regionOutline: RegionOutlineOverlay?
    private var dimOverlay: CaptureDimOverlay?
    private let eventTracker = EventTracker()
    private var displayInfo: DisplayInfo?
    /// Region being recorded (display-local points), stashed at arm time so the
    /// countdown overlay can center on it. nil = full display.
    private var armedRegion: CGRect?
    /// Display the recording is armed on, stashed at arm time. The countdown must
    /// target this — NOT a displayID re-derived from the UI at the second trigger,
    /// which can drift to another screen (the region stays display-2 but the param
    /// arrives as display-3). Pairs with `armedRegion`.
    private var armedDisplayID: CGDirectDisplayID?

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var isArmed: Bool {
        if case .armed = state { return true }
        return false
    }

    /// Warms up all sources (camera + mic AVCaptureSessions start running) and
    /// shows the live camera preview, WITHOUT writing anything. The screen
    /// SCStream is deferred to `beginRecording()` so no screen-recording
    /// indicator appears during preview. Moves the slow warm-up before the
    /// countdown so Record begins near-instantly. → `.armed`.
    func arm(displayID: CGDirectDisplayID,
             cameraID: String? = nil,
             micID: String? = nil,
             systemAudio: Bool = false,
             region: CGRect? = nil,
             previewDim: Bool = false) async {
        guard state == .idle || isFailed else { return }
        state = .arming
        warnings = []
        Log.recorder.info("arm: display=\(displayID) camera=\(cameraID ?? "none", privacy: .public) mic=\(micID ?? "none", privacy: .public) systemAudio=\(systemAudio) region=\(region != nil)")

        do {
            let (items, scDisplays) = try await DeviceDiscovery.displays()
            guard let item = items.first(where: { $0.id == displayID }),
                  let scDisplay = scDisplays[displayID] else {
                state = .failed("Selected display is no longer available.")
                return
            }
            // Clamp the region to the live display bounds (defends against a
            // region saved for a different/resized display). nil → full display.
            let region = item.clampedRegion(region)

            try FileManager.default.createDirectory(
                at: ProjectBundle.defaultRecordingsDirectory(),
                withIntermediateDirectories: true
            )
            let bundle = try ProjectBundle.createNew()

            // Construct the screen recorder but DO NOT start it yet — the
            // SCStream starts in beginRecording(). System audio rides it.
            let screen = ScreenRecorder(
                display: scDisplay, item: item, outputURL: bundle.screenURL,
                systemAudioURL: systemAudio ? bundle.systemAudioURL : nil,
                region: region
            )
            screen.onStreamError = { [weak self] error in
                Task { @MainActor in await self?.stop(streamError: error) }
            }

            // Camera/mic are best-effort — failure becomes a warning.
            let micDevice = micID.flatMap { id in
                DeviceDiscovery.microphones().first { $0.uniqueID == id }
            }
            let cameraDevice = cameraID.flatMap { id in
                DeviceDiscovery.cameras().first { $0.uniqueID == id }
            }

            if let cameraDevice {
                // Host the mic on the camera's session: a camera's own mic
                // can't stream to a rival capture session (it gets no buffers).
                let recorder = CameraRecorder(
                    device: cameraDevice, outputURL: bundle.cameraURL,
                    micDevice: micDevice,
                    micOutputURL: micDevice != nil ? bundle.micURL : nil
                )
                do {
                    try await recorder.warmUp()
                    cameraRecorder = recorder
                    // Live preview off the recorder's own session — excluded
                    // from screen.mp4 because the whole app is excluded.
                    let panel = CameraPreviewPanel(session: recorder.captureSession,
                                                   onDisplay: displayID)
                    panel.show()
                    previewPanel = panel
                    if let w = recorder.micWarning {
                        Log.recorder.error("mic on camera session failed: \(w, privacy: .public)")
                        // Mic couldn't attach to the camera session — try a
                        // standalone session for an unrelated mic device.
                        if let micDevice { await warmUpStandaloneMic(micDevice, bundle: bundle) }
                    }
                } catch {
                    Log.recorder.error("camera warm-up failed: \(error.localizedDescription, privacy: .public)")
                    warnings.append("Camera not recorded: \(error.localizedDescription)")
                    if let micDevice { await warmUpStandaloneMic(micDevice, bundle: bundle) }
                }
            } else if let micDevice {
                await warmUpStandaloneMic(micDevice, bundle: bundle)
            }

            // Outline the captured region so the user sees the bounds during
            // preview and through recording. Owned by the app → excluded from
            // capture. nil region (full display) → no outline.
            if let region {
                let outline = RegionOutlineOverlay(region: region, onDisplay: displayID)
                outline?.show()
                regionOutline = outline
            }

            // Dim everything outside the capture target during the preview only
            // (removed before the countdown). App-owned → excluded from capture.
            if previewDim {
                let dim = CaptureDimOverlay(region: region, capturedDisplay: displayID)
                dim.show()
                dimOverlay = dim
            }

            self.bundle = bundle
            self.screenRecorder = screen
            self.displayInfo = item.displayInfo(region: region)
            self.armedRegion = region
            self.armedDisplayID = displayID
            state = .armed
            Log.recorder.info("armed: \(bundle.url.lastPathComponent, privacy: .public)")
        } catch {
            Log.recorder.error("arm failed: \(error.localizedDescription, privacy: .public)")
            await tearDownArmed()
            state = .failed(error.localizedDescription)
        }
    }

    /// Flips the warmed sources into recording: starts the screen SCStream
    /// (mandatory) and the camera/mic writers (best-effort). Called by the view
    /// after the countdown. → `.recording`.
    func beginRecording() async {
        guard isArmed, let bundle, let screenRecorder, let displayInfo else { return }
        state = .preparing

        do {
            // Screen is mandatory — failure here aborts the recording.
            try await screenRecorder.start()
            if let warning = screenRecorder.systemAudioWarning {
                warnings.append(warning)
            }
        } catch {
            Log.recorder.error("screen start failed: \(error.localizedDescription, privacy: .public)")
            await tearDownArmed()
            state = .failed(error.localizedDescription)
            return
        }

        // Warmed camera/mic now begin writing; the next frame anchors their
        // host-clock start time. Best-effort: failure is a warning.
        if let cameraRecorder {
            do { try cameraRecorder.beginWriting() }
            catch {
                Log.recorder.error("camera beginWriting failed: \(error.localizedDescription, privacy: .public)")
                warnings.append("Camera not recorded: \(error.localizedDescription)")
            }
        }
        if let micRecorder {
            do { try micRecorder.beginWriting() }
            catch {
                Log.recorder.error("mic beginWriting failed: \(error.localizedDescription, privacy: .public)")
                warnings.append("Microphone not recorded: \(error.localizedDescription)")
            }
        }

        eventTracker.start()
        _ = displayInfo  // retained for stop(); already stored
        _ = bundle
        state = .recording(startedAt: Date())
        Log.recorder.info("recording: \(bundle.url.lastPathComponent, privacy: .public)")
    }

    /// Cancels from the armed state: tears down warmed sessions, closes the
    /// preview, deletes the abandoned bundle. → `.idle`.
    func cancelArming() async {
        guard isArmed || state == .arming else { return }
        await tearDownArmed()
        state = .idle
    }

    // MARK: - Shared toggle (popup button + global hotkey)

    /// Hotkey entry point: resolves devices from the last-used selections in
    /// AppSettings and toggles. `activateForPrompts` brings the app frontmost so
    /// any camera/mic TCC dialog is visible when triggered while unfocused.
    func toggleFromHotkey() async {
        // Area mode can't pop an interactive selector from a hotkey → reuse the
        // last saved region on its saved display. Full mode uses the picker's last
        // display. If the saved area display is gone, arm() no-ops gracefully.
        let area = AppSettings.captureAreaEnabled
        let region = area ? AppSettings.captureRegion : nil
        let displayID = area ? AppSettings.captureRegionDisplayID : AppSettings.lastDisplayID
        await toggle(displayID: displayID,
                     cameraID: AppSettings.lastCameraID,
                     micID: AppSettings.lastMicID,
                     systemAudio: AppSettings.recordSystemAudio,
                     region: region,
                     activateForPrompts: true)
    }

    /// One action shared by the popup's primary button and the global hotkey.
    /// Behavior depends on state and on whether a camera is selected:
    /// - recording → stop
    /// - armed (counting) → cancel the countdown / armed sources
    /// - armed → countdown + begin (camera flow's second trigger)
    /// - idle/failed → arm; screen-only goes straight to countdown + record,
    ///   camera stays armed (preview shown) awaiting a second trigger
    /// - arming/preparing/finishing → ignored (transient; natural debounce)
    /// `previewFirst` forces the armed/preview step even for screen-only configs
    /// (the GUI button uses this so every mode confirms before recording; the
    /// hotkey leaves it false to keep its one-press screen-only record).
    func toggle(displayID: CGDirectDisplayID?, cameraID: String?, micID: String?,
                systemAudio: Bool, region: CGRect? = nil, activateForPrompts: Bool,
                previewFirst: Bool = false) async {
        switch state {
        case .recording:
            await stop()
        case .armed where counting:
            await cancelCountdownOrArming()
        case .armed:
            await startCountdownThenBegin()
        case .idle, .failed:
            await startFromIdle(displayID: displayID, cameraID: cameraID, micID: micID,
                                systemAudio: systemAudio, region: region,
                                activateForPrompts: activateForPrompts,
                                previewFirst: previewFirst)
        case .arming, .preparing, .finishing:
            return
        }
    }

    private func startFromIdle(displayID: CGDirectDisplayID?, cameraID: String?,
                               micID: String?, systemAudio: Bool, region: CGRect?,
                               activateForPrompts: Bool, previewFirst: Bool) async {
        // Can't usefully prompt for screen recording from a hotkey — no-op.
        guard Permissions.screenRecordingGranted() else { return }
        guard let displayID else { return }

        var camera = cameraID
        var mic = micID
        if camera != nil || mic != nil, activateForPrompts {
            NSApp.activate(ignoringOtherApps: true)  // TCC dialog frontmost
        }
        if camera != nil, await !Permissions.requestCapture(.video) { camera = nil }
        if mic != nil, await !Permissions.requestCapture(.audio) { mic = nil }

        // Dim the non-captured area whenever we'll pause on the preview (camera
        // flow, or the GUI's previewFirst) — not when recording starts directly.
        let willPreview = camera != nil || previewFirst
        await arm(displayID: displayID, cameraID: camera, micID: mic,
                  systemAudio: systemAudio, region: region, previewDim: willPreview)

        // Screen-only normally records directly. Camera (or `previewFirst`, the
        // GUI button) stays armed with its preview, awaiting the Record button /
        // a second trigger — for area mode this is the user's chance to check the
        // region outline before capture starts.
        if camera == nil, !previewFirst, isArmed {
            await startCountdownThenBegin()
        }
    }

    /// Runs the countdown overlay then begins recording. Stored as a task so a
    /// second trigger (or Cancel) can abort mid-countdown.
    func startCountdownThenBegin() async {
        guard isArmed, !counting else { return }
        counting = true
        // Preview's over — drop the dim before the countdown / recording shows.
        dimOverlay?.close()
        dimOverlay = nil
        // Target the armed display + region (the recording's own target), not a
        // UI-derived displayID that can point at the wrong screen.
        let region = armedRegion
        let displayID = armedDisplayID
        let task = Task {
            await CountdownOverlay.run(seconds: AppSettings.countdownSeconds,
                                       displayID: displayID, region: region)
            guard !Task.isCancelled else { return }
            await self.beginRecording()
        }
        countdownTask = task
        await task.value
        counting = false
        countdownTask = nil
    }

    /// Cancels an in-progress countdown (if any), then tears down the armed
    /// sources back to idle.
    func cancelCountdownOrArming() async {
        if counting {
            countdownTask?.cancel()
            countdownTask = nil
            counting = false
        }
        await cancelArming()
    }

    /// Stops warmed (never-finalized) recorders, closes preview, deletes bundle.
    /// Used by cancel and by arm/begin failure paths.
    private func tearDownArmed() async {
        previewPanel?.close()
        previewPanel = nil
        regionOutline?.close()
        regionOutline = nil
        dimOverlay?.close()
        dimOverlay = nil
        eventTracker.cancel()
        await cameraRecorder?.discard()
        await micRecorder?.discard()
        if let url = bundle?.url {
            try? FileManager.default.removeItem(at: url)
        }
        bundle = nil
        screenRecorder = nil
        cameraRecorder = nil
        micRecorder = nil
        displayInfo = nil
        armedRegion = nil
        armedDisplayID = nil
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
                do {
                    let result = try await cameraRecorder.stop()
                    tracks.append(result.camera)
                    if let micTrack = result.mic { tracks.append(micTrack) }
                    if let w = cameraRecorder.micWarning { warnings.append(w) }
                } catch {
                    warnings.append("Camera track lost: \(error.localizedDescription)")
                }
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

        previewPanel?.close()
        previewPanel = nil
        regionOutline?.close()
        regionOutline = nil
        dimOverlay?.close()
        dimOverlay = nil
        self.bundle = nil
        self.screenRecorder = nil
        self.cameraRecorder = nil
        self.micRecorder = nil
        self.displayInfo = nil
        self.armedRegion = nil
        self.armedDisplayID = nil
    }

    func resetFailure() {
        if isFailed { state = .idle }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// Warms up a mic on its own session (no camera, or camera-hosted mic
    /// failed to attach). Best-effort: failure is a warning. The writer is
    /// created later in `beginRecording()`.
    private func warmUpStandaloneMic(_ device: AVCaptureDevice, bundle: ProjectBundle) async {
        let recorder = MicRecorder(device: device, outputURL: bundle.micURL)
        do {
            try await recorder.warmUp()
            micRecorder = recorder
        } catch {
            Log.recorder.error("mic warm-up failed: \(error.localizedDescription, privacy: .public)")
            warnings.append("Microphone not recorded: \(error.localizedDescription)")
        }
    }

    /// Best-effort synchronous teardown for app termination while armed or
    /// recording: stop sessions and remove an unfinalized bundle.
    func tearDownForQuit() {
        previewPanel?.close()
        previewPanel = nil
        regionOutline?.close()
        regionOutline = nil
        dimOverlay?.close()
        dimOverlay = nil
        if !isRecording, let url = bundle?.url {
            // Armed but not yet recording → the bundle is empty; drop it.
            try? FileManager.default.removeItem(at: url)
        }
    }
}
