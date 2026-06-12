import Foundation

/// Studio edit state persisted as edit.json inside the bundle.
/// All edits are metadata — master files are never mutated.
struct EditState: Codable, Equatable {
    var schemaVersion: Int = 1
    /// Trim in-point, seconds on the screen-track timeline.
    var trimIn: Double = 0
    /// Trim out-point; nil means end of recording.
    var trimOut: Double?
    /// Camera PiP overlay. Position is the PiP center, normalized 0–1 in
    /// render space (top-left origin); scale is PiP width as a fraction of
    /// the screen width.
    var cameraVisible: Bool = true
    var cameraCenterX: Double = 0.85
    var cameraCenterY: Double = 0.82
    var cameraScale: Double = 0.24
    /// Per-source playback/export volume, 0–1.
    var micVolume: Double = 1.0
    var systemVolume: Double = 1.0

    init(trimIn: Double = 0, trimOut: Double? = nil,
         cameraVisible: Bool = true, cameraCenterX: Double = 0.85,
         cameraCenterY: Double = 0.82, cameraScale: Double = 0.24,
         micVolume: Double = 1.0, systemVolume: Double = 1.0) {
        self.trimIn = trimIn
        self.trimOut = trimOut
        self.cameraVisible = cameraVisible
        self.cameraCenterX = cameraCenterX
        self.cameraCenterY = cameraCenterY
        self.cameraScale = cameraScale
        self.micVolume = micVolume
        self.systemVolume = systemVolume
    }

    // Custom decode so edit.json files written before these fields existed
    // still load with defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        trimIn = try c.decodeIfPresent(Double.self, forKey: .trimIn) ?? 0
        trimOut = try c.decodeIfPresent(Double.self, forKey: .trimOut)
        cameraVisible = try c.decodeIfPresent(Bool.self, forKey: .cameraVisible) ?? true
        cameraCenterX = try c.decodeIfPresent(Double.self, forKey: .cameraCenterX) ?? 0.85
        cameraCenterY = try c.decodeIfPresent(Double.self, forKey: .cameraCenterY) ?? 0.82
        cameraScale = try c.decodeIfPresent(Double.self, forKey: .cameraScale) ?? 0.24
        micVolume = try c.decodeIfPresent(Double.self, forKey: .micVolume) ?? 1.0
        systemVolume = try c.decodeIfPresent(Double.self, forKey: .systemVolume) ?? 1.0
    }
}

extension ProjectBundle {
    func writeEdit(_ edit: EditState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(edit).write(to: editURL, options: .atomic)
    }

    func loadEdit() -> EditState {
        guard let data = try? Data(contentsOf: editURL),
              let edit = try? JSONDecoder().decode(EditState.self, from: data) else {
            return EditState()
        }
        return edit
    }
}
