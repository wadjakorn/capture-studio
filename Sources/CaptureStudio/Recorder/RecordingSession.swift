import Foundation
import ScreenCaptureKit
import AVFoundation
import AppKit

/// What the preview's area controls do for this recording. Full Display and Area
/// mode both reach `arm()` with `region == nil` when no area is saved, so the mode
/// has to be carried explicitly — inferring it from the region is what let a
/// Full-Display preview demand an area selection.
enum AreaSelection {
    /// Full Display: the HUD offers no Select Area toggle, and no region is needed.
    case unavailable
    /// Area mode with an area already saved: Select Area is offered, Record is live.
    case optional
    /// Area mode with no area yet: Record stays blocked until one is chosen, so it
    /// can never silently fall through to capturing the whole display.
    case required
}

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

    /// Whether Record may fire. Always true for non-interactive paths; for
    /// interactive area it mirrors the live overlay's validity.
    @Published private(set) var canBeginArmed: Bool = true
    /// Live size of the interactive-area selection, for the armed view. nil
    /// outside interactive area or before a valid drag.
    @Published private(set) var armedAreaSize: CGSize?

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
    private var areaOverlay: AreaSelectionOverlay?
    private var previewHUD: PreviewHUD?
    /// System-audio choice stashed for the deferred screen-recorder build.
    private var armedSystemAudio = false
    /// Capture mode this session armed in — drives both the HUD's Select Area
    /// toggle and the Record gate. `.required` (Area mode, first use) blocks
    /// recording until an area is picked. A deliberately-chosen full-display area
    /// (region clamps to nil but the display is saved) is `.optional`, not
    /// `.required` — it's recordable as-is.
    private var armedAreaSelection: AreaSelection = .unavailable
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
             previewControls: Bool = false,
             areaSelection: AreaSelection = .unavailable) async {
        guard state == .idle || isFailed else { return }
        state = .arming
        warnings = []
        Log.recorder.info("arm: display=\(displayID) camera=\(cameraID ?? "none", privacy: .public) mic=\(micID ?? "none", privacy: .public) systemAudio=\(systemAudio) region=\(region != nil) controls=\(previewControls) area=\(String(describing: areaSelection), privacy: .public)")

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
                    let panel = CameraPreviewPanel(
                        session: recorder.captureSession,
                        onDisplay: displayID,
                        onCancel: { [weak self] in
                            Task { @MainActor in await self?.cancelCountdownOrArming() }
                        })
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

            self.bundle = bundle
            self.screenRecorder = screen
            self.displayInfo = item.displayInfo(region: region)
            self.armedRegion = region
            self.armedDisplayID = displayID
            self.armedSystemAudio = systemAudio
            self.armedAreaSelection = areaSelection
            // Block Record until the user picks an area (Area mode, first use).
            self.refreshCanBeginArmed()

            // Persistent preview HUD (passive default). Carries Record — the tray
            // popover closes as soon as this panel takes key, so the HUD is the
            // only way to start a recording once the preview is up. Its Select Area
            // toggle live-swaps into the modal area selector, and only exists in
            // Area mode. App-owned → excluded from capture.
            if previewControls {
                let hud = PreviewHUD(
                    onDisplay: displayID,
                    offersAreaSelection: areaSelection != .unavailable,
                    canRecord: canBeginArmed,
                    onToggleDragMode: { [weak self] on in
                        Task { @MainActor in
                            if on { self?.enterDragMode() } else { self?.exitDragMode() }
                        }
                    },
                    onRecord: { [weak self] in
                        Task { await self?.startCountdownThenBegin() }
                    },
                    onCancel: { [weak self] in
                        Task { @MainActor in await self?.cancelCountdownOrArming() }
                    })
                hud.show()
                previewHUD = hud
            }

            state = .armed
            Log.recorder.info("armed: \(bundle.url.lastPathComponent, privacy: .public)")
        } catch {
            Log.recorder.error("arm failed: \(error.localizedDescription, privacy: .public)")
            await tearDownArmed()
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Live drag mode (passive preview ⇄ modal area selection)

    /// Whether Record may fire. A region is only ever required in `.required` —
    /// Full Display captures the whole screen and an already-saved area is
    /// recordable as-is, so an empty live selection must not block either.
    nonisolated static func canBegin(areaSelection: AreaSelection, region: CGRect?) -> Bool {
        areaSelection != .required || region != nil
    }

    /// The display an armed session targets after a live selection change. The
    /// overlay reports no display until a valid region exists; adopting that nil
    /// would erase the display the session armed on, leaving
    /// `buildDeferredScreenRecorder()` nothing to rebuild from. Only a selection
    /// that names a display may move the target.
    nonisolated static func adoptedDisplay(current: CGDirectDisplayID?,
                                           reported: CGDirectDisplayID?) -> CGDirectDisplayID? {
        reported ?? current
    }

    /// Applies `canBegin` to the live state and mirrors it onto the HUD's Record
    /// button. Every path that changes the armed region routes through here, so the
    /// rule has one definition and the HUD can't disagree with the tray.
    private func refreshCanBeginArmed() {
        canBeginArmed = Self.canBegin(areaSelection: armedAreaSelection, region: armedRegion)
        previewHUD?.setCanRecord(canBeginArmed)
    }

    /// Toggle ON: swap the passive preview for the modal `AreaSelectionOverlay`,
    /// seeded with the current region. The eager screen recorder is dropped —
    /// the region is now non-final, so it rebuilds at record time via
    /// `buildDeferredScreenRecorder()`. Camera/mic stay warm; no re-arm.
    func enterDragMode() {
        guard isArmed, !counting, areaOverlay == nil else { return }

        // Region is no longer final while dragging → defer the recorder. Drop
        // the eager one so `startCountdownThenBegin` rebuilds it at record time.
        screenRecorder = nil
        displayInfo = nil

        // The passive outline is replaced by the selection overlay's live rect.
        regionOutline?.close()
        regionOutline = nil

        let overlay = AreaSelectionOverlay()
        overlay.onChange = { [weak self] region, did, valid in
            guard let self else { return }
            self.armedRegion = region
            self.armedDisplayID = Self.adoptedDisplay(current: self.armedDisplayID, reported: did)
            self.armedAreaSize = valid ? region?.size : nil
            self.refreshCanBeginArmed()
        }
        // Esc / right-click in the overlay exits drag mode back to passive.
        overlay.onCancel = { [weak self] in
            Task { @MainActor in self?.exitDragMode() }
        }
        overlay.onStart = { [weak self] in
            Task { await self?.startCountdownThenBegin() }
        }
        areaOverlay = overlay
        armedAreaSize = nil
        refreshCanBeginArmed()
        previewHUD?.setDragMode(true)
        overlay.present(initialRegion: armedRegion, initialDisplayID: armedDisplayID)
        Log.recorder.info("drag mode: on")
    }

    /// Toggle OFF: tear down the selection overlay (restores prior-app focus),
    /// adopt the chosen region, and restore the passive outline. The recorder
    /// stays deferred (region was made non-final by entering drag mode).
    func exitDragMode() {
        guard let overlay = areaOverlay else { return }
        overlay.dismiss()
        areaOverlay = nil
        previewHUD?.setDragMode(false)
        // dismiss() restored the recorded app as active; re-key the HUD so ESC
        // cancels the preview again without re-focusing the tray.
        previewHUD?.show()

        // Show the passive outline for the newly chosen region (if any).
        if let region = armedRegion, let displayID = armedDisplayID {
            let outline = RegionOutlineOverlay(region: region, onDisplay: displayID)
            outline?.show()
            regionOutline = outline
        }
        refreshCanBeginArmed()
        Log.recorder.info("drag mode: off region=\(self.armedRegion != nil)")
    }

    /// Builds the screen recorder from the final interactive-area selection at
    /// record time. Returns false (and sets `.failed`) if the display vanished.
    private func buildDeferredScreenRecorder() async -> Bool {
        guard let bundle, let displayID = armedDisplayID else {
            state = .failed("No area selected.")
            return false
        }
        do {
            let (items, scDisplays) = try await DeviceDiscovery.displays()
            guard let item = items.first(where: { $0.id == displayID }),
                  let scDisplay = scDisplays[displayID] else {
                state = .failed("Selected display is no longer available.")
                return false
            }
            // nil here means the drag covered the whole display → full-display
            // capture, which is valid (just no region outline).
            let region = item.clampedRegion(armedRegion)

            let screen = ScreenRecorder(
                display: scDisplay, item: item, outputURL: bundle.screenURL,
                systemAudioURL: armedSystemAudio ? bundle.systemAudioURL : nil,
                region: region
            )
            screen.onStreamError = { [weak self] error in
                Task { @MainActor in await self?.stop(streamError: error) }
            }

            self.screenRecorder = screen
            self.displayInfo = item.displayInfo(region: region)
            self.armedRegion = region

            AppSettings.captureRegion = region
            AppSettings.captureRegionDisplayID = displayID

            areaOverlay?.dismiss()
            areaOverlay = nil
            // Refresh the outline for the final region (replaces any passive one).
            regionOutline?.close()
            regionOutline = nil
            if let region {
                let outline = RegionOutlineOverlay(region: region, onDisplay: displayID)
                outline?.show()
                regionOutline = outline
            }
            return true
        } catch {
            Log.recorder.error("deferred screen recorder build failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
            return false
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
        // A hotkey can't open the area selector. If Area mode has NO saved area
        // at all (no region and no saved display — a full-display area keeps its
        // display), ignore a start rather than silently grabbing the whole
        // display. A saved area (region, or a full-display area) records as usual.
        if (state == .idle || isFailed), area, region == nil,
           AppSettings.captureRegionDisplayID == nil { return }
        // The guard above already rejected `.required`, so a hotkey start is
        // either Full Display or Area mode with an area saved.
        await toggle(displayID: displayID,
                     cameraID: AppSettings.lastCameraID,
                     micID: AppSettings.lastMicID,
                     systemAudio: AppSettings.recordSystemAudio,
                     region: region,
                     activateForPrompts: true,
                     areaSelection: area ? .optional : .unavailable)
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
                previewFirst: Bool = false,
                areaSelection: AreaSelection = .unavailable) async {
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
                                previewFirst: previewFirst,
                                areaSelection: areaSelection)
        case .arming, .preparing, .finishing:
            return
        }
    }

    private func startFromIdle(displayID: CGDirectDisplayID?, cameraID: String?,
                               micID: String?, systemAudio: Bool, region: CGRect?,
                               activateForPrompts: Bool, previewFirst: Bool,
                               areaSelection: AreaSelection = .unavailable) async {
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

        // Show the preview HUD (drag-mode toggle) whenever we'll pause on the
        // preview (camera flow, or the GUI's previewFirst). Screen-only records
        // start directly with no preview → no HUD.
        let willPreview = camera != nil || previewFirst
        await arm(displayID: displayID, cameraID: camera, micID: mic,
                  systemAudio: systemAudio, region: region,
                  previewControls: willPreview,
                  areaSelection: areaSelection)

        // Screen-only normally records directly. Camera (or `previewFirst`, the
        // GUI button) stays armed with its preview, awaiting the Record button /
        // a second trigger — for area mode this is the user's chance to adjust
        // the live selection before capture starts.
        if camera == nil, !previewFirst, isArmed {
            await startCountdownThenBegin()
        }
    }

    /// Runs the countdown overlay then begins recording. Stored as a task so a
    /// second trigger (or Cancel) can abort mid-countdown.
    func startCountdownThenBegin() async {
        // `canBeginArmed` gates every start path (Record button, global hotkey,
        // second trigger, drag-mode Return) — Area mode must not record a
        // full display when no region is selected yet.
        guard isArmed, !counting, canBeginArmed else { return }
        counting = true

        // Interactive area defers the screen recorder until the region is final.
        if screenRecorder == nil {
            guard await buildDeferredScreenRecorder() else {
                counting = false
                return
            }
        }

        // Preview's over — drop the HUD before the countdown / recording shows.
        previewHUD?.close()
        previewHUD = nil
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
        previewHUD?.close()
        previewHUD = nil
        areaOverlay?.dismiss()
        areaOverlay = nil
        canBeginArmed = true
        armedAreaSize = nil
        armedSystemAudio = false
        armedAreaSelection = .unavailable
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
        previewHUD?.close()
        previewHUD = nil
        areaOverlay?.dismiss()
        areaOverlay = nil
        canBeginArmed = true
        armedAreaSize = nil
        armedAreaSelection = .unavailable
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
        previewHUD?.close()
        previewHUD = nil
        areaOverlay?.dismiss()
        areaOverlay = nil
        if !isRecording, let url = bundle?.url {
            // Armed but not yet recording → the bundle is empty; drop it.
            try? FileManager.default.removeItem(at: url)
        }
    }
}
