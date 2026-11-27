import Foundation

/// A `.capturestudio` document package on disk. Recorder writes it, Studio
/// reads it — this type is the only contract between the two modules.
struct ProjectBundle {
    static let pathExtension = "capturestudio"

    let url: URL

    var metaURL: URL { url.appendingPathComponent("meta.json") }
    var screenURL: URL { url.appendingPathComponent("screen.mp4") }
    var cameraURL: URL { url.appendingPathComponent("camera.mp4") }
    var mainCameraURL: URL { url.appendingPathComponent("main-camera.mp4") }
    var micURL: URL { url.appendingPathComponent("mic.m4a") }
    var systemAudioURL: URL { url.appendingPathComponent("system.m4a") }
    var eventsURL: URL { url.appendingPathComponent("events.jsonl") }
    var editURL: URL { url.appendingPathComponent("edit.json") }
    /// Dashboard preview frame. Derived cache, regenerated on demand; its name
    /// must not start with `background.` (see `deleteBackgroundImages`).
    var thumbnailURL: URL { url.appendingPathComponent("thumbnail.jpg") }

    func url(for track: TrackInfo) -> URL { url.appendingPathComponent(track.filename) }

    /// A bundle is valid once meta.json exists (it is written last).
    var isFinalized: Bool { FileManager.default.fileExists(atPath: metaURL.path) }

    static func defaultRecordingsDirectory() -> URL {
        FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Capture Studio", isDirectory: true)
    }

    /// Creates a new empty bundle directory named by timestamp,
    /// e.g. "Recording 2026-06-12 at 14.30.05.capturestudio".
    static func createNew(in directory: URL = defaultRecordingsDirectory(),
                          date: Date = Date()) throws -> ProjectBundle {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Recording \(formatter.string(from: date)).\(pathExtension)"
        let bundleURL = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        return ProjectBundle(url: bundleURL)
    }

    private static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func writeMeta(_ meta: ProjectMeta) throws {
        try Self.jsonEncoder().encode(meta).write(to: metaURL, options: .atomic)
    }

    func loadMeta() throws -> ProjectMeta {
        try Self.jsonDecoder().decode(ProjectMeta.self, from: Data(contentsOf: metaURL))
    }

    // MARK: - Canvas background image

    /// URL of a background image file (kept inside the bundle so it travels with
    /// the project). `name` is the file name stored in `EditState`.
    func backgroundImageURL(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    /// Copy an uploaded image into the bundle as `background.<ext>`, replacing
    /// any previous one. Returns the file name to persist in `EditState`.
    func writeBackgroundImage(from source: URL) throws -> String {
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let name = "background.\(ext)"
        let dest = url.appendingPathComponent(name)
        deleteBackgroundImages()          // clear any prior file (extension may differ)
        try FileManager.default.copyItem(at: source, to: dest)
        return name
    }

    /// Remove every `background.*` file in the bundle.
    func deleteBackgroundImages() {
        let files = (try? FileManager.default.contentsOfDirectory(at: url,
                     includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix("background.") {
            try? FileManager.default.removeItem(at: f)
        }
    }

    // MARK: - Subtitles (.srt)

    /// URL of the imported subtitle file inside the bundle (so it travels with
    /// the project). `name` is the file name stored in `EditState.subtitles`.
    func subtitleFileURL(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    /// Copy an imported `.srt` into the bundle as `subtitles.srt`, replacing any
    /// previous one. Returns the file name to persist in `EditState`.
    @discardableResult
    func writeSubtitleFile(from source: URL) throws -> String {
        let name = "subtitles.srt"
        let dest = url.appendingPathComponent(name)
        deleteSubtitleFile()
        try FileManager.default.copyItem(at: source, to: dest)
        return name
    }

    // MARK: - Derived analysis cache

    /// Cached on-screen change analysis of the main video. Derived data: safe to
    /// delete; "Auto zoom" recomputes it.
    var changesURL: URL { url.appendingPathComponent("analysis/changes.json") }

    /// The cached analysis for `video`, or nil when there is none, it cannot be
    /// read, or it was made from a different file / format version.
    func loadChanges(for video: URL) -> ChangeAnalysis? {
        guard let bytes = ChangeAnalysis.fileBytes(video),
              let data = try? Data(contentsOf: changesURL),
              let analysis = try? JSONDecoder().decode(ChangeAnalysis.self, from: data),
              analysis.matches(videoBytes: bytes) else { return nil }
        return analysis
    }

    /// Best-effort: never recreates a bundle that was moved or deleted while
    /// the analysis ran.
    func writeChanges(_ analysis: ChangeAnalysis) {
        guard isFinalized else { return }
        let dir = changesURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        guard let data = try? JSONEncoder().encode(analysis) else { return }
        try? data.write(to: changesURL, options: .atomic)
    }

    /// Remove the imported subtitle file, if any.
    func deleteSubtitleFile() {
        try? FileManager.default.removeItem(at: url.appendingPathComponent("subtitles.srt"))
    }
}
