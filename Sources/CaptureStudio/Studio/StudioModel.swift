import Foundation
import AVFoundation
import AppKit

/// Loads a bundle, builds the preview composition (screen video + mic audio,
/// offset-aligned on the shared host-clock anchors), and owns trim/export state.
@MainActor
final class StudioModel: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum ExportState: Equatable {
        case idle
        case exporting(Double) // progress 0...1
        case done(URL)
        case failed(String)
    }

    let bundle: ProjectBundle

    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var meta: ProjectMeta?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var duration: Double = 0
    @Published var currentTime: Double = 0
    @Published private(set) var trimIn: Double = 0
    @Published private(set) var trimOut: Double = 0
    @Published private(set) var exportState: ExportState = .idle

    // Camera PiP — center normalized 0–1 in render space, scale = width
    // fraction of screen width. Persisted to edit.json.
    @Published var cameraVisible = true
    @Published var cameraCenterX = 0.85
    @Published var cameraCenterY = 0.82
    @Published var cameraScale = 0.24
    private(set) var renderSize: CGSize = .zero
    private(set) var cameraNaturalSize: CGSize?
    var hasCameraTrack: Bool { cameraTrackID != nil }
    var hasMicTrack: Bool { micTrackID != nil }
    var hasSystemAudioTrack: Bool { systemTrackID != nil }

    // Per-source volumes, 0–1. Applied live via AVAudioMix; persisted to edit.json.
    @Published var micVolume = 1.0
    @Published var systemVolume = 1.0

    private var screenTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    private var cameraTrackID: CMPersistentTrackID?
    private var micTrackID: CMPersistentTrackID?
    private var systemTrackID: CMPersistentTrackID?
    private var playerItem: AVPlayerItem?

    private var composition: AVMutableComposition?
    /// Removes the periodic time observer; nonisolated so deinit can call it.
    nonisolated(unsafe) private var observerCleanup: (() -> Void)?

    init(bundleURL: URL) {
        self.bundle = ProjectBundle(url: bundleURL)
    }

    deinit {
        observerCleanup?()
    }

    func load() async {
        guard loadState == .loading else { return }
        Log.studio.info("StudioModel.load: \(self.bundle.url.lastPathComponent, privacy: .public)")
        do {
            guard bundle.isFinalized else {
                Log.studio.error("StudioModel.load failed: bundle not finalized")
                loadState = .failed("Recording is incomplete (no meta.json).")
                return
            }
            let meta = try bundle.loadMeta()
            let built = try await Self.makeComposition(bundle: bundle, meta: meta)
            let item = AVPlayerItem(asset: built.composition)
            let player = AVPlayer(playerItem: item)

            self.meta = meta
            self.composition = built.composition
            self.renderSize = built.renderSize
            self.screenTrackID = built.screenTrackID
            self.cameraTrackID = built.cameraTrackID
            self.micTrackID = built.micTrackID
            self.systemTrackID = built.systemTrackID
            self.cameraNaturalSize = built.cameraSize
            self.playerItem = item
            self.player = player
            self.duration = built.composition.duration.seconds

            let edit = bundle.loadEdit()
            trimIn = min(max(0, edit.trimIn), duration)
            trimOut = min(edit.trimOut ?? duration, duration)
            if trimOut <= trimIn { trimIn = 0; trimOut = duration }
            cameraVisible = edit.cameraVisible
            cameraCenterX = edit.cameraCenterX
            cameraCenterY = edit.cameraCenterY
            cameraScale = edit.cameraScale
            micVolume = min(max(0, edit.micVolume), 1)
            systemVolume = min(max(0, edit.systemVolume), 1)
            applyVideoComposition()
            applyAudioMix()

            let token = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 30),
                queue: .main
            ) { [weak self] time in
                Task { @MainActor in self?.currentTime = time.seconds }
            }
            observerCleanup = { player.removeTimeObserver(token) }
            loadState = .ready
            Log.studio.info("StudioModel.load OK: duration=\(self.duration, format: .fixed(precision: 2))s tracks=\(meta.tracks.count)")
        } catch {
            Log.studio.error("StudioModel.load failed: \(error.localizedDescription, privacy: .public)")
            loadState = .failed(error.localizedDescription)
        }
    }

    private struct BuiltComposition {
        let composition: AVMutableComposition
        let renderSize: CGSize
        let screenTrackID: CMPersistentTrackID
        let cameraTrackID: CMPersistentTrackID?
        let micTrackID: CMPersistentTrackID?
        let systemTrackID: CMPersistentTrackID?
        let cameraSize: CGSize?
    }

    /// screen video at t=0; camera video, mic and system audio inserted at
    /// their host-clock offsets. Camera renders as PiP via the video composition.
    private static func makeComposition(bundle: ProjectBundle,
                                        meta: ProjectMeta) async throws -> BuiltComposition {
        guard let screenInfo = meta.tracks.first(where: { $0.type == .screen }) else {
            throw NSError(domain: "CaptureStudio", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Bundle has no screen track."
            ])
        }
        let composition = AVMutableComposition()
        var renderSize = CGSize(width: 1920, height: 1080)
        var screenTrackID = kCMPersistentTrackID_Invalid
        var cameraTrackID: CMPersistentTrackID?
        var micTrackID: CMPersistentTrackID?
        var systemTrackID: CMPersistentTrackID?
        var cameraSize: CGSize?

        let screenAsset = AVURLAsset(url: bundle.screenURL)
        let screenDuration = try await screenAsset.load(.duration)
        if let videoTrack = try await screenAsset.loadTracks(withMediaType: .video).first,
           let compTrack = composition.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: screenDuration),
                of: videoTrack, at: .zero
            )
            renderSize = try await videoTrack.load(.naturalSize)
            screenTrackID = compTrack.trackID
        }

        if let cameraInfo = meta.tracks.first(where: { $0.type == .camera }),
           FileManager.default.fileExists(atPath: bundle.cameraURL.path) {
            let offset = cameraInfo.sessionStartHostTime - screenInfo.sessionStartHostTime
            let cameraAsset = AVURLAsset(url: bundle.cameraURL)
            let cameraDuration = try await cameraAsset.load(.duration)
            if let videoTrack = try await cameraAsset.loadTracks(withMediaType: .video).first,
               let compTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: cameraDuration),
                    of: videoTrack,
                    at: CMTime(seconds: max(0, offset), preferredTimescale: 600)
                )
                cameraTrackID = compTrack.trackID
                cameraSize = try await videoTrack.load(.naturalSize)
            }
        }

        if let micInfo = meta.tracks.first(where: { $0.type == .mic }),
           FileManager.default.fileExists(atPath: bundle.micURL.path) {
            let offset = micInfo.sessionStartHostTime - screenInfo.sessionStartHostTime
            let micAsset = AVURLAsset(url: bundle.micURL)
            let micDuration = try await micAsset.load(.duration)
            if let audioTrack = try await micAsset.loadTracks(withMediaType: .audio).first,
               let compTrack = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: micDuration),
                    of: audioTrack,
                    at: CMTime(seconds: max(0, offset), preferredTimescale: 600)
                )
                micTrackID = compTrack.trackID
            }
        }

        if let systemInfo = meta.tracks.first(where: { $0.type == .systemAudio }),
           FileManager.default.fileExists(atPath: bundle.systemAudioURL.path) {
            let offset = systemInfo.sessionStartHostTime - screenInfo.sessionStartHostTime
            let systemAsset = AVURLAsset(url: bundle.systemAudioURL)
            let systemDuration = try await systemAsset.load(.duration)
            if let audioTrack = try await systemAsset.loadTracks(withMediaType: .audio).first,
               let compTrack = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: systemDuration),
                    of: audioTrack,
                    at: CMTime(seconds: max(0, offset), preferredTimescale: 600)
                )
                systemTrackID = compTrack.trackID
            }
        }
        return BuiltComposition(
            composition: composition,
            renderSize: renderSize,
            screenTrackID: screenTrackID,
            cameraTrackID: cameraTrackID,
            micTrackID: micTrackID,
            systemTrackID: systemTrackID,
            cameraSize: cameraSize
        )
    }

    // MARK: - Camera PiP

    /// PiP rect in render-space pixels for the current camera settings.
    var cameraPipRect: CGRect? {
        guard let cameraNaturalSize, renderSize.width > 0 else { return nil }
        let width = renderSize.width * cameraScale
        let scale = width / cameraNaturalSize.width
        let height = cameraNaturalSize.height * scale
        return CGRect(
            x: cameraCenterX * renderSize.width - width / 2,
            y: cameraCenterY * renderSize.height - height / 2,
            width: width, height: height
        )
    }

    /// Rebuilds the video composition (PiP transform) and applies it to the
    /// player item. Cheap — instructions only, no re-encode.
    func applyVideoComposition() {
        playerItem?.videoComposition = buildVideoComposition()
    }

    /// Persist camera PiP settings; call at gesture end, not per drag tick.
    func commitCameraEdit() {
        saveEdit()
    }

    func toggleCamera() {
        cameraVisible.toggle()
        applyVideoComposition()
        saveEdit()
    }

    private func buildVideoComposition() -> AVMutableVideoComposition? {
        guard cameraVisible,
              let composition,
              let cameraTrackID,
              let cameraNaturalSize,
              let cameraTrack = composition.track(withTrackID: cameraTrackID),
              let screenTrack = composition.track(withTrackID: screenTrackID),
              let pip = cameraPipRect, cameraNaturalSize.width > 0 else {
            return nil
        }
        let scale = pip.width / cameraNaturalSize.width

        let cameraLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: cameraTrack)
        cameraLayer.setTransform(
            CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: pip.minX, y: pip.minY)),
            at: .zero
        )
        let screenLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: screenTrack)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        // First layer instruction renders topmost.
        instruction.layerInstructions = [cameraLayer, screenLayer]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)
        videoComposition.instructions = [instruction]
        return videoComposition
    }

    // MARK: - Audio mix (per-source volume)

    /// Live volume change during slider drag; persist via commitVolumeEdit().
    func setMicVolume(_ value: Double) {
        micVolume = min(max(0, value), 1)
        applyAudioMix()
    }

    func setSystemVolume(_ value: Double) {
        systemVolume = min(max(0, value), 1)
        applyAudioMix()
    }

    /// Persist volumes; call at slider gesture end, not per tick.
    func commitVolumeEdit() {
        saveEdit()
    }

    /// Reapplies per-source volumes to the player item. Cheap — mix
    /// parameters only, no re-encode.
    private func applyAudioMix() {
        playerItem?.audioMix = buildAudioMix()
    }

    private func buildAudioMix() -> AVAudioMix? {
        guard let composition else { return nil }
        var parameters: [AVMutableAudioMixInputParameters] = []
        if let micTrackID, let track = composition.track(withTrackID: micTrackID) {
            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolume(Float(micVolume), at: .zero)
            parameters.append(params)
        }
        if let systemTrackID, let track = composition.track(withTrackID: systemTrackID) {
            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolume(Float(systemVolume), at: .zero)
            parameters.append(params)
        }
        guard !parameters.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    // MARK: - Playback

    func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            if currentTime >= duration - 0.05 { seek(to: trimIn) }
            player.play()
        }
    }

    var isPlaying: Bool { player?.timeControlStatus == .playing }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), duration)
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }

    // MARK: - Trim (persisted to edit.json; masters untouched)

    func setTrimIn(_ value: Double) {
        trimIn = min(max(0, value), trimOut - 0.1)
        saveEdit()
    }

    func setTrimOut(_ value: Double) {
        trimOut = max(min(duration, value), trimIn + 0.1)
        saveEdit()
    }

    func resetTrim() {
        trimIn = 0
        trimOut = duration
        saveEdit()
    }

    private func saveEdit() {
        let edit = EditState(
            trimIn: trimIn,
            trimOut: trimOut >= duration - 0.001 ? nil : trimOut,
            cameraVisible: cameraVisible,
            cameraCenterX: cameraCenterX,
            cameraCenterY: cameraCenterY,
            cameraScale: cameraScale,
            micVolume: micVolume,
            systemVolume: systemVolume
        )
        try? bundle.writeEdit(edit)
    }

    // MARK: - Export

    func export(preset: ExportPreset, to destination: URL) {
        guard let composition else { return }
        if case .exporting = exportState { return }
        exportState = .exporting(0)
        let range = CMTimeRange(
            start: CMTime(seconds: trimIn, preferredTimescale: 600),
            end: CMTime(seconds: trimOut, preferredTimescale: 600)
        )
        Task {
            do {
                let url = try await Exporter.export(
                    composition: composition,
                    videoComposition: buildVideoComposition(),
                    audioMix: buildAudioMix(),
                    timeRange: range,
                    preset: preset,
                    to: destination
                ) { [weak self] progress in
                    Task { @MainActor in
                        if case .exporting = self?.exportState {
                            self?.exportState = .exporting(progress)
                        }
                    }
                }
                exportState = .done(url)
            } catch {
                exportState = .failed(error.localizedDescription)
            }
        }
    }

    func dismissExportResult() {
        exportState = .idle
    }

    func revealMastersInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([bundle.screenURL])
    }
}
