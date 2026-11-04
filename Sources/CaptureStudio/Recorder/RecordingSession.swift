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

extension RecordingSession.State {
    /// Whether the session owns an on-disk bundle it is still writing (or about
    /// to). `.idle`/`.failed` never do: by the time `stop()` flips to `.idle`
    /// meta.json is written, so the bundle is safe to open.
    var holdsActiveBundle: Bool {
        switch self {
        case .arming, .armed, .preparing, .recording, .finishing: return true
        case .idle, .failed: return false
        }
    }

    /// Whether quitting may delete the session's bundle. Only before writers
    /// flip on is it empty; `.recording`/`.finishing` hold a real take (finishing
    /// is mid-finalize, and deleting it would lose the recording).
    var bundleIsDisposableOnQuit: Bool {
        switch self {
        case .arming, .armed, .preparing: return true
        case .idle, .recording, .finishing, .failed: return false
        }
    }
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

    init() {
        Self.shared = self
        CaptureContentWindows.shared.onChange = { [weak self] in
            self?.requestFilterRefresh()
        }
    }

    /// Serializes `ScreenRecorder.refreshFilter()` passes; see `RefreshCoalescer`.
    private var filterRefresh = RefreshCoalescer()

    /// Re-applies the content-window allowlist to the live stream. Only while
    /// recording: before that the stream doesn't exist (start() builds its
    /// filter fresh), after it the stream is being finalized.
    private func requestFilterRefresh() {
        guard isRecording, filterRefresh.request() else { return }
        Task { @MainActor [weak self] in
            var again = true
            while again {
                guard let self else { return }
                // Re-read each pass: a rerun may outlive the recording that
                // queued it, and must not touch a later session's recorder
                // outside `.recording`.
                if self.isRecording, let recorder = self.screenRecorder {
                    await recorder.refreshFilter()
                }
                again = self.filterRefresh.finish()
            }
        }
    }

    private var bundle: ProjectBundle?
    /// URL of the bundle this session created, set the moment the directory
    /// exists. Unlike `bundle` (only assigned once arming completes) it covers
    /// the warm-up window, so teardown can delete it and Studio can refuse it.
    private var pendingBundleURL: URL?
    /// Bumped by every `arm()` and `cancelArming()`. An in-flight arm compares
    /// it after each await: a mismatch means it was cancelled (or superseded)
    /// while suspended and must abandon its local work. `state == .arming` alone
    /// isn't enough — cancel's own teardown awaits while state is still `.arming`.
    private var armGeneration = 0

    /// The bundle Studio must not open: the one this session is still writing.
    /// Derived from `state`, not `bundle` — `stop()` auto-opens the finished
    /// recording after `.idle` but before it clears `bundle`.
    var activeBundleURL: URL? {
        state.holdsActiveBundle ? pendingBundleURL : nil
    }
    private var screenRecorder: ScreenRecorder?
    private var cameraRecorder: CameraRecorder?
    private var micRecorder: MicRecorder?
    private var previewPanel: CameraPreviewPanel?
    /// Camera-main mode: the camera recording the main video (`main-camera.mp4`).
    /// Mandatory like the screen recorder; nil in display-main mode.
    private var mainCameraRecorder: CameraRecorder?
    /// Camera-main mode: large bottom-center live preview of the main camera.
    private var mainPreviewPanel: CameraPreviewPanel?
    /// Main source this session armed with. Set in `arm()`, cleared wherever
    /// `armedDisplayID` is. Every branch that differs for camera-main switches on
    /// it — `screenRecorder == nil` already means "area deferred" and must not
    /// double as "camera-main".
    private var armedMain: MainSource?
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
    func arm(main: MainSource,
             cameraID: String? = nil,
             micID: String? = nil,
             systemAudio: Bool = false,
             region: CGRect? = nil,
             previewControls: Bool = false,
             areaSelection: AreaSelection = .unavailable) async {
        guard state == .idle || isFailed else { return }
        RecordingSavedToast.dismiss()
        state = .arming
        armGeneration &+= 1
        let generation = armGeneration
        warnings = []
        let displayID: CGDirectDisplayID
        switch main {
        case .camera(let mainID):
            await armCameraMain(main, mainID: mainID, cameraID: cameraID, micID: micID,
                                previewControls: previewControls, generation: generation)
            return
        case .display(let id):
            displayID = id
        }
        Log.recorder.info("arm: display=\(displayID) camera=\(cameraID ?? "none", privacy: .public) mic=\(micID ?? "none", privacy: .public) systemAudio=\(systemAudio) region=\(region != nil) controls=\(previewControls) area=\(String(describing: areaSelection), privacy: .public)")

        do {
            let (items, scDisplays) = try await DeviceDiscovery.displays()
            // Cancelled while discovering — nothing local exists yet.
            guard armIsCurrent(generation) else { return }
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
            pendingBundleURL = bundle.url
            NotificationCenter.default.post(name: .projectLibraryDidChange, object: nil)

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
                recorder.onDeviceLost = { [weak self] msg in
                    Task { @MainActor in self?.warnings.append(msg) }
                }
                do {
                    try await recorder.warmUp()
                    // Cancelled during warm-up: the recorder is still local, so
                    // cancel's teardown never saw it — discard it here.
                    guard armIsCurrent(generation) else {
                        await recorder.discard()
                        abandonArm(bundle)
                        return
                    }
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
                        if let micDevice {
                            await warmUpStandaloneMic(micDevice, bundle: bundle, generation: generation)
                        }
                    }
                } catch {
                    guard armIsCurrent(generation) else {
                        abandonArm(bundle)
                        return
                    }
                    Log.recorder.error("camera warm-up failed: \(error.localizedDescription, privacy: .public)")
                    warnings.append("Camera not recorded: \(error.localizedDescription)")
                    if let micDevice {
                        await warmUpStandaloneMic(micDevice, bundle: bundle, generation: generation)
                    }
                }
            } else if let micDevice {
                await warmUpStandaloneMic(micDevice, bundle: bundle, generation: generation)
            }
            // Covers every mic warm-up above. A camera already handed to
            // `cameraRecorder` was torn down by the cancel itself.
            guard armIsCurrent(generation) else {
                abandonArm(bundle)
                return
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
            self.armedMain = main
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
            // Cancelled meanwhile → the cancel already tore down; don't clobber
            // its `.idle` (or a newer arm) with this stale failure.
            guard armIsCurrent(generation) else { return }
            Log.recorder.error("arm failed: \(error.localizedDescription, privacy: .public)")
            await tearDownArmed()
            if armIsCurrent(generation) { state = .failed(error.localizedDescription) }
        }
    }

    /// `arm()` for a camera main source. No display discovery (works without
    /// Screen Recording permission), no screen recorder, no region / area / system
    /// audio. The main camera is mandatory; the overlay camera and mic stay
    /// best-effort exactly as in display mode.
    private func armCameraMain(_ main: MainSource, mainID: String, cameraID: String?,
                               micID: String?, previewControls: Bool,
                               generation: Int) async {
        Log.recorder.info("arm: main camera=\(mainID, privacy: .public) overlay=\(cameraID ?? "none", privacy: .public) mic=\(micID ?? "none", privacy: .public) controls=\(previewControls)")
        let cameraIDs = availableCameraIDs()
        if main.resolve(cameraIDs: cameraIDs, displayIDs: []) != nil {
            state = .failed("Selected camera is no longer available.")
            return
        }
        // The main camera can't also be the overlay: drop a duplicate selection.
        let overlayID = RecorderSelection.resolvedFrontCamera(
            cameraID,
            candidates: RecorderSelection.frontCameraIDs(all: cameraIDs, main: main)
        )

        do {
            try FileManager.default.createDirectory(
                at: ProjectBundle.defaultRecordingsDirectory(),
                withIntermediateDirectories: true
            )
            let bundle = try ProjectBundle.createNew()
            pendingBundleURL = bundle.url
            NotificationCenter.default.post(name: .projectLibraryDidChange, object: nil)

            let micDevice = micID.flatMap { id in
                DeviceDiscovery.microphones().first { $0.uniqueID == id }
            }
            // Host the mic on the MAIN camera's session (same device-contention
            // reasoning as display mode); fallback is a standalone mic session.
            guard let mainRecorder = makeCameraSource(
                id: mainID, outputURL: bundle.mainCameraURL,
                micDevice: micDevice,
                micOutputURL: micDevice != nil ? bundle.micURL : nil
            ) else {
                // Vanished between the availability check and the lookup.
                await tearDownArmed()
                if armIsCurrent(generation) {
                    state = .failed("Selected camera is no longer available.")
                }
                return
            }
            mainRecorder.onDeviceLost = { [weak self] msg in
                Task { @MainActor in self?.warnings.append(msg) }
            }
            do {
                try await mainRecorder.warmUp()
            } catch {
                // Mandatory source: release the half-opened device, then fail
                // the whole arm (outer catch tears down and deletes the bundle).
                await mainRecorder.discard()
                throw error
            }
            // Cancelled during warm-up: the recorder is still local, so cancel's
            // teardown never saw it — discard it here.
            guard armIsCurrent(generation) else {
                await mainRecorder.discard()
                abandonArm(bundle)
                return
            }
            mainCameraRecorder = mainRecorder
            let mainPanel = CameraPreviewPanel(
                session: mainRecorder.captureSession,
                onDisplay: nil,
                placement: .bottomCenterLarge,
                onCancel: { [weak self] in
                    Task { @MainActor in await self?.cancelCountdownOrArming() }
                })
            mainPanel.show()
            mainPreviewPanel = mainPanel
            if let w = mainRecorder.micWarning {
                Log.recorder.error("mic on main camera session failed: \(w, privacy: .public)")
                if let micDevice {
                    await warmUpStandaloneMic(micDevice, bundle: bundle, generation: generation)
                }
            }
            guard armIsCurrent(generation) else {
                abandonArm(bundle)
                return
            }

            // Overlay camera: best-effort, no mic (the mic lives on the main
            // camera or a standalone session).
            if let overlayID,
               let recorder = makeCameraSource(id: overlayID, outputURL: bundle.cameraURL,
                                               micDevice: nil, micOutputURL: nil) {
                recorder.onDeviceLost = { [weak self] msg in
                    Task { @MainActor in self?.warnings.append(msg) }
                }
                do {
                    try await recorder.warmUp()
                    guard armIsCurrent(generation) else {
                        await recorder.discard()
                        abandonArm(bundle)
                        return
                    }
                    cameraRecorder = recorder
                    let panel = CameraPreviewPanel(
                        session: recorder.captureSession,
                        onDisplay: nil,
                        placement: .corner,
                        onCancel: { [weak self] in
                            Task { @MainActor in await self?.cancelCountdownOrArming() }
                        })
                    panel.show()
                    previewPanel = panel
                } catch {
                    guard armIsCurrent(generation) else {
                        abandonArm(bundle)
                        return
                    }
                    Log.recorder.error("overlay camera warm-up failed: \(error.localizedDescription, privacy: .public)")
                    warnings.append("Camera not recorded: \(error.localizedDescription)")
                }
            }

            self.bundle = bundle
            self.screenRecorder = nil
            self.displayInfo = nil
            self.armedRegion = nil
            self.armedDisplayID = nil
            self.armedMain = main
            self.armedSystemAudio = false
            self.armedAreaSelection = .unavailable
            self.refreshCanBeginArmed()

            // Same HUD as display mode, minus Select Area; on NSScreen.main.
            if previewControls {
                let hud = PreviewHUD(
                    onDisplay: nil,
                    offersAreaSelection: false,
                    canRecord: canBeginArmed,
                    onToggleDragMode: { _ in },
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
            Log.recorder.info("armed (camera main): \(bundle.url.lastPathComponent, privacy: .public)")
        } catch {
            guard armIsCurrent(generation) else { return }
            Log.recorder.error("arm (camera main) failed: \(error.localizedDescription, privacy: .public)")
            await tearDownArmed()
            if armIsCurrent(generation) { state = .failed(error.localizedDescription) }
        }
    }

    /// Unique IDs of cameras that can be armed right now. Single source for
    /// availability checks (Part C appends Wi-Fi phone sources here).
    private func availableCameraIDs() -> [String] {
        DeviceDiscovery.cameras().map(\.uniqueID)
    }

    /// Builds a camera recorder for a source id, or nil if it vanished. Single
    /// factory so Part C can branch on non-AVCaptureDevice sources.
    private func makeCameraSource(id: String, outputURL: URL,
                                  micDevice: AVCaptureDevice?,
                                  micOutputURL: URL?) -> CameraRecorder? {
        guard let device = DeviceDiscovery.cameras().first(where: { $0.uniqueID == id }) else {
            return nil
        }
        return CameraRecorder(device: device, outputURL: outputURL,
                              micDevice: micDevice, micOutputURL: micOutputURL)
    }

    /// True while the arm() that took `generation` is still the live one.
    private func armIsCurrent(_ generation: Int) -> Bool {
        state == .arming && armGeneration == generation
    }

    /// A cancelled arm's own cleanup: drop its bundle directory (cancel's
    /// teardown may already have) without touching state, which the cancel owns.
    private func abandonArm(_ bundle: ProjectBundle) {
        Log.recorder.info("arm abandoned (cancelled during warm-up)")
        try? FileManager.default.removeItem(at: bundle.url)
        if pendingBundleURL == bundle.url { pendingBundleURL = nil }
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
        // Camera-main has no area to select.
        if armedMain?.isCamera == true { return }

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
    /// record time. Returns false (tearing the armed session down, then
    /// `.failed`) if the display vanished, or quietly if a cancel won the race.
    private func buildDeferredScreenRecorder() async -> Bool {
        // Camera-main never builds a screen recorder.
        if armedMain?.isCamera == true { return false }
        guard let bundle, let displayID = armedDisplayID else {
            await failArmed("No area selected.")
            return false
        }
        do {
            let (items, scDisplays) = try await DeviceDiscovery.displays()
            // Cancelled while discovering: the cancel tore down already, so
            // building now would resurrect a recorder + outline on an idle session.
            guard isArmed else { return false }
            guard let item = items.first(where: { $0.id == displayID }),
                  let scDisplay = scDisplays[displayID] else {
                await failArmed("Selected display is no longer available.")
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
            await failArmed(error.localizedDescription)
            return false
        }
    }

    /// Fails an armed session without leaking it: warmed camera/mic, preview
    /// panels and the empty bundle all go before `.failed`. Skips entirely if a
    /// cancel (or a newer arm) already owns the session.
    private func failArmed(_ message: String) async {
        guard isArmed else { return }
        await tearDownArmed()
        if isArmed { state = .failed(message) }
    }

    /// Flips the warmed sources into recording: starts the screen SCStream
    /// (mandatory) and the camera/mic writers (best-effort). Called by the view
    /// after the countdown. → `.recording`.
    func beginRecording() async {
        guard isArmed, let bundle, let armedMain else { return }

        if armedMain.isCamera {
            guard let mainCameraRecorder else { return }
            state = .preparing
            do {
                // Main camera is mandatory — failure here aborts the recording.
                try mainCameraRecorder.beginWriting()
            } catch {
                Log.recorder.error("main camera beginWriting failed: \(error.localizedDescription, privacy: .public)")
                await tearDownArmed()
                state = .failed(error.localizedDescription)
                return
            }
        } else {
            guard let screenRecorder, displayInfo != nil else { return }
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

        // Cursor/click events only make sense against a captured display.
        if !armedMain.isCamera {
            eventTracker.start()
        }
        _ = bundle
        state = .recording(startedAt: Date())
        // Content windows that opened/closed during `.preparing` changed after
        // start() built its filter and their notifications were ignored then.
        requestFilterRefresh()
        Log.recorder.info("recording: \(bundle.url.lastPathComponent, privacy: .public)")
    }

    /// Cancels from the armed state: tears down warmed sessions, closes the
    /// preview, deletes the abandoned bundle. → `.idle`.
    func cancelArming() async {
        guard isArmed || state == .arming else { return }
        // Invalidate any in-flight arm() before the first await, so it can't
        // resume and repopulate the session being torn down.
        armGeneration &+= 1
        let generation = armGeneration
        await tearDownArmed()
        // A later cancel or arm took over while we awaited → it owns `state`.
        if armGeneration == generation { state = .idle }
    }

    // MARK: - Shared toggle (popup button + global hotkey)

    /// Hotkey entry point: resolves devices from the last-used selections in
    /// AppSettings and toggles. `activateForPrompts` brings the app frontmost so
    /// any camera/mic TCC dialog is visible when triggered while unfocused.
    func toggleFromHotkey() async {
        // The main source wins: a stored camera main ignores the Area toggle and
        // the saved region entirely (camera-main has no area).
        let stored = AppSettings.lastMainSource
        let main: MainSource?
        let region: CGRect?
        let areaSelection: AreaSelection
        var cameraID = AppSettings.lastCameraID
        if let stored, stored.isCamera {
            main = stored
            region = nil
            areaSelection = .unavailable
            // The main camera can't double as the overlay camera.
            cameraID = RecorderSelection.resolvedFrontCamera(
                cameraID,
                candidates: RecorderSelection.frontCameraIDs(all: availableCameraIDs(), main: stored)
            )
        } else {
            // Area mode can't pop an interactive selector from a hotkey → reuse the
            // last saved region on its saved display. Full mode uses the picker's last
            // display. If the saved area display is gone, arm() no-ops gracefully.
            let area = AppSettings.captureAreaEnabled
            region = area ? AppSettings.captureRegion : nil
            main = area ? AppSettings.captureRegionDisplayID.map(MainSource.display) : stored
            // A hotkey can't open the area selector. If Area mode has NO saved area
            // at all (no region and no saved display — a full-display area keeps its
            // display), ignore a start rather than silently grabbing the whole
            // display. A saved area (region, or a full-display area) records as usual.
            if (state == .idle || isFailed), area, region == nil,
               AppSettings.captureRegionDisplayID == nil { return }
            // The guard above already rejected `.required`, so a hotkey start is
            // either Full Display or Area mode with an area saved.
            areaSelection = area ? .optional : .unavailable
        }
        await toggle(main: main,
                     cameraID: cameraID,
                     micID: AppSettings.lastMicID,
                     systemAudio: AppSettings.recordSystemAudio,
                     region: region,
                     activateForPrompts: true,
                     areaSelection: areaSelection)
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
    func toggle(main: MainSource?, cameraID: String?, micID: String?,
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
            await startFromIdle(main: main, cameraID: cameraID, micID: micID,
                                systemAudio: systemAudio, region: region,
                                activateForPrompts: activateForPrompts,
                                previewFirst: previewFirst,
                                areaSelection: areaSelection)
        case .arming, .preparing, .finishing:
            return
        }
    }

    private func startFromIdle(main: MainSource?, cameraID: String?,
                               micID: String?, systemAudio: Bool, region: CGRect?,
                               activateForPrompts: Bool, previewFirst: Bool,
                               areaSelection: AreaSelection = .unavailable) async {
        guard let main else { return }
        // Can't usefully prompt for screen recording from a hotkey — no-op.
        // Camera-main never touches the screen, so it doesn't need the grant.
        if RecorderSelection.needsScreenPermission(for: main) {
            guard Permissions.screenRecordingGranted() else { return }
        }

        var camera = cameraID
        var mic = micID
        if main.isCamera || camera != nil || mic != nil, activateForPrompts {
            NSApp.activate(ignoringOtherApps: true)  // TCC dialog frontmost
        }
        if main.isCamera || camera != nil, await !Permissions.requestCapture(.video) {
            // Camera-main without camera access can't record anything.
            if main.isCamera { return }
            camera = nil
        }
        if mic != nil, await !Permissions.requestCapture(.audio) { mic = nil }

        // Show the preview HUD (drag-mode toggle) whenever we'll pause on the
        // preview (camera flow, or the GUI's previewFirst). Screen-only records
        // start directly with no preview → no HUD.
        let willPreview = main.isCamera || camera != nil || previewFirst
        await arm(main: main, cameraID: camera, micID: mic,
                  systemAudio: systemAudio, region: region,
                  previewControls: willPreview,
                  areaSelection: areaSelection)

        // Screen-only normally records directly. Camera (or `previewFirst`, the
        // GUI button) stays armed with its preview, awaiting the Record button /
        // a second trigger — for area mode this is the user's chance to adjust
        // the live selection before capture starts.
        if !main.isCamera, camera == nil, !previewFirst, isArmed {
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
        // Camera-main has no screen recorder at all — never rebuild one.
        if armedMain?.isCamera == false, screenRecorder == nil {
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
        mainPreviewPanel?.close()
        mainPreviewPanel = nil
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
        // Detach everything before the first await: a concurrent teardown (cancel
        // racing a failure path) then finds nothing left, so nothing is discarded
        // or deleted twice. The bundle is deleted via `pendingBundleURL` because
        // `bundle` is still nil during warm-up.
        let mainCamera = mainCameraRecorder
        let camera = cameraRecorder
        let mic = micRecorder
        let bundleURL = pendingBundleURL
        bundle = nil
        pendingBundleURL = nil
        screenRecorder = nil
        mainCameraRecorder = nil
        cameraRecorder = nil
        micRecorder = nil
        displayInfo = nil
        armedRegion = nil
        armedDisplayID = nil
        armedMain = nil
        await mainCamera?.discard()
        await camera?.discard()
        await mic?.discard()
        if let bundleURL {
            try? FileManager.default.removeItem(at: bundleURL)
            NotificationCenter.default.post(name: .projectLibraryDidChange, object: nil)
        }
    }

    /// Stops all recorders, finalizes files, writes meta.json LAST
    /// (its presence marks the bundle valid).
    func stop(streamError: Error? = nil) async {
        guard isRecording else { return }
        state = .finishing

        if armedMain?.isCamera == true {
            guard let bundle, let mainCameraRecorder else {
                state = .failed("Internal error: no active recording.")
                return
            }
            await finishCameraMain(bundle: bundle, mainRecorder: mainCameraRecorder,
                                   streamError: streamError)
            clearAfterStop()
            return
        }

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
                recordedAt: Date(),
                mainSource: "display"
            )
            try completeSave(bundle: bundle, meta: meta, streamError: streamError)
        } catch {
            Log.recorder.error("stop failed: \(error.localizedDescription, privacy: .public)")
            eventTracker.cancel()
            state = .failed(error.localizedDescription)
        }

        clearAfterStop()
    }

    /// Camera-main `stop()`: finalizes the main camera (anchor), overlay camera
    /// and standalone mic, then writes a v2 meta with synthetic display geometry
    /// sized to the main video. No events.jsonl — there is no captured display.
    private func finishCameraMain(bundle: ProjectBundle, mainRecorder: CameraRecorder,
                                  streamError: Error?) async {
        let mainResult: CameraRecorder.Result
        do {
            mainResult = try await mainRecorder.stop()
        } catch {
            // The anchor track is lost — nothing to save. Release the other
            // still-running capture sessions instead of leaking them.
            Log.recorder.error("stop (camera main) failed: \(error.localizedDescription, privacy: .public)")
            await cameraRecorder?.discard()
            await micRecorder?.discard()
            state = .failed(error.localizedDescription)
            return
        }
        do {
            var mainTrack = mainResult.camera
            mainTrack.role = .main
            var tracks = [mainTrack]
            if let micTrack = mainResult.mic { tracks.append(micTrack) }
            if let w = mainRecorder.micWarning, !warnings.contains(w) { warnings.append(w) }

            if let cameraRecorder {
                do {
                    let result = try await cameraRecorder.stop()
                    var overlayTrack = result.camera
                    overlayTrack.role = .overlay
                    tracks.append(overlayTrack)
                    if let micTrack = result.mic { tracks.append(micTrack) }
                } catch {
                    warnings.append("Camera track lost: \(error.localizedDescription)")
                }
            }
            if let micRecorder {
                do { tracks.append(try await micRecorder.stop()) }
                catch { warnings.append("Microphone track lost: \(error.localizedDescription)") }
            }

            let size = mainRecorder.writtenPixelSize ?? CGSize(width: 1920, height: 1080)
            let meta = ProjectMeta(
                schemaVersion: 2,
                app: .current(),
                display: .synthetic(width: Int(size.width), height: Int(size.height)),
                tracks: tracks,
                recordedAt: Date(),
                mainSource: "camera"
            )
            try completeSave(bundle: bundle, meta: meta, streamError: streamError)
        } catch {
            Log.recorder.error("stop (camera main) failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Writes meta.json LAST (its presence marks the bundle valid), then runs the
    /// post-recording action. Shared by display- and camera-main `stop()`.
    private func completeSave(bundle: ProjectBundle, meta: ProjectMeta,
                              streamError: Error?) throws {
        try bundle.writeMeta(meta)
        // Fire-and-forget: warms the Dashboard thumbnail without delaying stop().
        ThumbnailStore.shared.prefetch(bundleURL: bundle.url)
        Log.recorder.info("stop OK: \(bundle.url.lastPathComponent, privacy: .public) tracks=\(meta.tracks.count) warnings=\(self.warnings.count)")
        lastBundleURL = bundle.url
        RecentProjectsStore.shared.noteRecorded(bundle.url)
        state = .idle
        switch PostRecordingAction.decide(
            openStudioAfterRecording: AppSettings.openStudioAfterRecording,
            studioWindowVisible: StudioLauncher.hasVisibleStudioWindow
        ) {
        case .openStudio: StudioLauncher.open(bundleURL: bundle.url)
        case .openStudioBehind: StudioLauncher.open(bundleURL: bundle.url, placement: .behindCurrent)
        case .showSavedToast: RecordingSavedToast.show(bundleURL: bundle.url)
        }
        if let streamError {
            state = .failed("Recording saved, but capture stopped early: \(streamError.localizedDescription)")
        }
    }

    /// Post-stop cleanup (success and failure alike): close every panel/overlay
    /// and drop all recorders and armed state.
    private func clearAfterStop() {
        previewPanel?.close()
        previewPanel = nil
        mainPreviewPanel?.close()
        mainPreviewPanel = nil
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
        self.pendingBundleURL = nil
        self.screenRecorder = nil
        self.mainCameraRecorder = nil
        self.cameraRecorder = nil
        self.micRecorder = nil
        self.displayInfo = nil
        self.armedRegion = nil
        self.armedDisplayID = nil
        self.armedMain = nil
        NotificationCenter.default.post(name: .projectLibraryDidChange, object: nil)
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
    /// Only runs inside `arm()`: if that arm is cancelled during warm-up the
    /// recorder is discarded here instead of being handed to an idle session.
    private func warmUpStandaloneMic(_ device: AVCaptureDevice, bundle: ProjectBundle,
                                     generation: Int) async {
        let recorder = MicRecorder(device: device, outputURL: bundle.micURL)
        do {
            try await recorder.warmUp()
            guard armIsCurrent(generation) else {
                await recorder.discard()
                return
            }
            micRecorder = recorder
        } catch {
            guard armIsCurrent(generation) else { return }
            Log.recorder.error("mic warm-up failed: \(error.localizedDescription, privacy: .public)")
            warnings.append("Microphone not recorded: \(error.localizedDescription)")
        }
    }

    /// Best-effort synchronous teardown for app termination while armed or
    /// recording: stop sessions and remove a bundle that never got writers.
    func tearDownForQuit() {
        previewPanel?.close()
        previewPanel = nil
        mainPreviewPanel?.close()
        mainPreviewPanel = nil
        regionOutline?.close()
        regionOutline = nil
        previewHUD?.close()
        previewHUD = nil
        areaOverlay?.dismiss()
        areaOverlay = nil
        if state.bundleIsDisposableOnQuit, let url = pendingBundleURL {
            // Arming/armed/preparing → the bundle is empty; drop it. Never while
            // finishing: that bundle is a real recording being finalized.
            // `pendingBundleURL`, not `bundle`: the latter is nil during warm-up.
            try? FileManager.default.removeItem(at: url)
        }
    }
}
