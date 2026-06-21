import Foundation

/// A `.capturestudio` document package on disk. Recorder writes it, Studio
/// reads it — this type is the only contract between the two modules.
struct ProjectBundle {
    static let pathExtension = "capturestudio"

    let url: URL

    var metaURL: URL { url.appendingPathComponent("meta.json") }
    var screenURL: URL { url.appendingPathComponent("screen.mp4") }
    var cameraURL: URL { url.appendingPathComponent("camera.mp4") }
    var micURL: URL { url.appendingPathComponent("mic.m4a") }
    var systemAudioURL: URL { url.appendingPathComponent("system.m4a") }
    var eventsURL: URL { url.appendingPathComponent("events.jsonl") }
    var editURL: URL { url.appendingPathComponent("edit.json") }

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
}
