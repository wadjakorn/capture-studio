import Foundation

/// Output aspect for reframing exports (social clips). `original` means no
/// crop. Stored as the raw string in edit.json; unknown values written by a
/// future version decode as `original`.
enum CropAspect: String, Codable, CaseIterable, Equatable {
    case original
    case nineBySixteen = "9:16"
    case square = "1:1"
    case fourByFive = "4:5"
    case sixteenByNine = "16:9"
    case fourByThree = "4:3"

    /// Width / height of the output canvas; nil for `original`.
    var ratio: Double? {
        switch self {
        case .original: return nil
        case .nineBySixteen: return 9.0 / 16.0
        case .square: return 1.0
        case .fourByFive: return 4.0 / 5.0
        case .sixteenByNine: return 16.0 / 9.0
        case .fourByThree: return 4.0 / 3.0
        }
    }

    var displayName: String {
        self == .original ? "Original" : rawValue
    }
}

/// Camera PiP frame shape. Unknown raw strings (future versions) decode as
/// `rectangle`.
enum CameraShape: String, Codable, CaseIterable, Equatable {
    case rectangle
    case circle

    var displayName: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .circle: return "Circle"
        }
    }
}

/// Camera feed crop aspect. `original` keeps the camera's native aspect.
/// Unknown raw strings (future versions) decode as `original`.
enum CameraAspect: String, Codable, CaseIterable, Equatable {
    case original
    case square = "1:1"
    case threeByFour = "3:4"
    case fourByThree = "4:3"
    case sixteenByNine = "16:9"
    case nineBySixteen = "9:16"

    /// Width / height of the crop; nil for `original` (use native aspect).
    var ratio: Double? {
        switch self {
        case .original: return nil
        case .square: return 1.0
        case .threeByFour: return 3.0 / 4.0
        case .fourByThree: return 4.0 / 3.0
        case .sixteenByNine: return 16.0 / 9.0
        case .nineBySixteen: return 9.0 / 16.0
        }
    }

    var displayName: String {
        self == .original ? "Original" : rawValue
    }
}

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
    /// Camera feed reframe. Zoom is the crop tightness (1 = whole feed,
    /// >1 zooms in; clamp 1…4); feed center is normalized 0–1 in the camera
    /// feed's own space.
    var cameraZoom: Double = 1.0
    var cameraFeedX: Double = 0.5
    var cameraFeedY: Double = 0.5
    /// Camera PiP frame styling. Corner radius and border width are fractions
    /// of the PiP's shorter side / width; border color is "#RRGGBB".
    var cameraShape: CameraShape = .rectangle
    var cameraCornerRadius: Double = 0
    var cameraBorderWidth: Double = 0
    var cameraBorderHex: String = "#FFFFFF"
    var cameraShadow: Bool = false
    /// Shadow intensity 0–1 (scales blur/offset/opacity together).
    var cameraShadowRadius: Double = 0.5
    /// Camera feed crop aspect; `original` keeps the native aspect.
    var cameraAspect: CameraAspect = .original
    /// Per-source playback/export volume. System is 0–1 (attenuation). Mic is
    /// 0–3: values >1 boost gain for quiet voice. Older bundles (mic ≤ 1) load
    /// unchanged.
    var micVolume: Double = 1.0
    var systemVolume: Double = 1.0
    /// Reframe crop. Center is normalized 0–1 in screen-source space; zoom is
    /// the crop size as a fraction of the largest crop of that aspect that
    /// fits the source (1.0 = widest).
    var cropAspect: CropAspect = .original
    var cropCenterX: Double = 0.5
    var cropCenterY: Double = 0.5
    var cropZoom: Double = 1.0

    init(trimIn: Double = 0, trimOut: Double? = nil,
         cameraVisible: Bool = true, cameraCenterX: Double = 0.85,
         cameraCenterY: Double = 0.82, cameraScale: Double = 0.24,
         cameraZoom: Double = 1.0, cameraFeedX: Double = 0.5,
         cameraFeedY: Double = 0.5,
         cameraShape: CameraShape = .rectangle, cameraCornerRadius: Double = 0,
         cameraBorderWidth: Double = 0, cameraBorderHex: String = "#FFFFFF",
         cameraShadow: Bool = false, cameraShadowRadius: Double = 0.5,
         cameraAspect: CameraAspect = .original,
         micVolume: Double = 1.0, systemVolume: Double = 1.0,
         cropAspect: CropAspect = .original, cropCenterX: Double = 0.5,
         cropCenterY: Double = 0.5, cropZoom: Double = 1.0) {
        self.trimIn = trimIn
        self.trimOut = trimOut
        self.cameraVisible = cameraVisible
        self.cameraCenterX = cameraCenterX
        self.cameraCenterY = cameraCenterY
        self.cameraScale = cameraScale
        self.cameraZoom = cameraZoom
        self.cameraFeedX = cameraFeedX
        self.cameraFeedY = cameraFeedY
        self.cameraShape = cameraShape
        self.cameraCornerRadius = cameraCornerRadius
        self.cameraBorderWidth = cameraBorderWidth
        self.cameraBorderHex = cameraBorderHex
        self.cameraShadow = cameraShadow
        self.cameraShadowRadius = cameraShadowRadius
        self.cameraAspect = cameraAspect
        self.micVolume = micVolume
        self.systemVolume = systemVolume
        self.cropAspect = cropAspect
        self.cropCenterX = cropCenterX
        self.cropCenterY = cropCenterY
        self.cropZoom = cropZoom
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
        cameraZoom = try c.decodeIfPresent(Double.self, forKey: .cameraZoom) ?? 1.0
        cameraFeedX = try c.decodeIfPresent(Double.self, forKey: .cameraFeedX) ?? 0.5
        cameraFeedY = try c.decodeIfPresent(Double.self, forKey: .cameraFeedY) ?? 0.5
        let shapeRaw = try c.decodeIfPresent(String.self, forKey: .cameraShape)
        cameraShape = shapeRaw.flatMap(CameraShape.init(rawValue:)) ?? .rectangle
        cameraCornerRadius = try c.decodeIfPresent(Double.self, forKey: .cameraCornerRadius) ?? 0
        cameraBorderWidth = try c.decodeIfPresent(Double.self, forKey: .cameraBorderWidth) ?? 0
        cameraBorderHex = try c.decodeIfPresent(String.self, forKey: .cameraBorderHex) ?? "#FFFFFF"
        cameraShadow = try c.decodeIfPresent(Bool.self, forKey: .cameraShadow) ?? false
        cameraShadowRadius = try c.decodeIfPresent(Double.self, forKey: .cameraShadowRadius) ?? 0.5
        let camAspectRaw = try c.decodeIfPresent(String.self, forKey: .cameraAspect)
        cameraAspect = camAspectRaw.flatMap(CameraAspect.init(rawValue:)) ?? .original
        micVolume = try c.decodeIfPresent(Double.self, forKey: .micVolume) ?? 1.0
        systemVolume = try c.decodeIfPresent(Double.self, forKey: .systemVolume) ?? 1.0
        // Raw-string decode so an unknown future aspect degrades to no crop.
        let aspectRaw = try c.decodeIfPresent(String.self, forKey: .cropAspect)
        cropAspect = aspectRaw.flatMap(CropAspect.init(rawValue:)) ?? .original
        cropCenterX = try c.decodeIfPresent(Double.self, forKey: .cropCenterX) ?? 0.5
        cropCenterY = try c.decodeIfPresent(Double.self, forKey: .cropCenterY) ?? 0.5
        cropZoom = try c.decodeIfPresent(Double.self, forKey: .cropZoom) ?? 1.0
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
