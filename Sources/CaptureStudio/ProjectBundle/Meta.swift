import Foundation

/// Versioned metadata describing a recording bundle. Written last during
/// finalization — its presence marks the bundle as valid.
struct ProjectMeta: Codable, Equatable {
    var schemaVersion: Int = 1
    var app: AppInfo
    var display: DisplayInfo
    var tracks: [TrackInfo]
    var recordedAt: Date
    /// "display" | "camera". nil in legacy bundles (== "display").
    var mainSource: String? = nil

    init(schemaVersion: Int = 1, app: AppInfo, display: DisplayInfo, tracks: [TrackInfo],
         recordedAt: Date, mainSource: String? = nil) {
        self.schemaVersion = schemaVersion
        self.app = app
        self.display = display
        self.tracks = tracks
        self.recordedAt = recordedAt
        self.mainSource = mainSource
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, app, display, tracks, recordedAt, mainSource
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        app = try c.decode(AppInfo.self, forKey: .app)
        display = try c.decode(DisplayInfo.self, forKey: .display)
        tracks = try c.decode([TrackInfo].self, forKey: .tracks)
        recordedAt = try c.decode(Date.self, forKey: .recordedAt)
        mainSource = try c.decodeIfPresent(String.self, forKey: .mainSource)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(app, forKey: .app)
        try c.encode(display, forKey: .display)
        try c.encode(tracks, forKey: .tracks)
        try c.encode(recordedAt, forKey: .recordedAt)
        try c.encodeIfPresent(mainSource, forKey: .mainSource)
    }

    /// The track that drives the canvas: explicit `.main` role, else first screen.
    var mainTrack: TrackInfo? {
        tracks.first { $0.role == .main } ?? tracks.first { $0.type == .screen }
    }
    /// First camera track that is not the main track.
    var overlayCameraTrack: TrackInfo? {
        tracks.first { $0.type == .camera && $0.role != .main }
    }
    var isCameraMain: Bool { mainTrack?.type == .camera }
}

struct AppInfo: Codable, Equatable {
    var version: String
    var macOSVersion: String

    static func current() -> AppInfo {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return AppInfo(
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        )
    }
}

/// Captured display geometry. Coordinates in events.jsonl are global screen
/// points; Studio maps them into video pixels using this.
struct DisplayInfo: Codable, Equatable {
    var displayID: UInt32
    var pixelWidth: Int
    var pixelHeight: Int
    var pointWidth: Double
    var pointHeight: Double
    var scaleFactor: Double
    /// Global bounds origin in points (multi-display coordinate mapping).
    var originX: Double
    var originY: Double
}

extension DisplayInfo {
    /// Placeholder geometry for camera-main bundles (no display captured):
    /// points == pixels, scale 1, origin 0.
    static func synthetic(width: Int, height: Int) -> DisplayInfo {
        DisplayInfo(displayID: 0, pixelWidth: width, pixelHeight: height,
                    pointWidth: Double(width), pointHeight: Double(height),
                    scaleFactor: 1, originX: 0, originY: 0)
    }
}

enum TrackRole: String, Codable {
    case main, overlay
}

enum TrackType: String, Codable {
    case screen, camera, mic, systemAudio
}

struct TrackInfo: Codable, Equatable {
    var type: TrackType
    var filename: String
    /// Host-clock time (seconds) of the track's first sample. THE sync anchor:
    /// offset(track) = track.sessionStartHostTime - screen.sessionStartHostTime
    var sessionStartHostTime: Double
    var nominalFPS: Double?
    var codec: String
    var deviceName: String?
    var deviceID: String?
    var truncated: Bool = false
    var role: TrackRole? = nil

    init(type: TrackType, filename: String, sessionStartHostTime: Double,
         nominalFPS: Double? = nil, codec: String, deviceName: String? = nil,
         deviceID: String? = nil, truncated: Bool = false, role: TrackRole? = nil) {
        self.type = type
        self.filename = filename
        self.sessionStartHostTime = sessionStartHostTime
        self.nominalFPS = nominalFPS
        self.codec = codec
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.truncated = truncated
        self.role = role
    }

    private enum CodingKeys: String, CodingKey {
        case type, filename, sessionStartHostTime, nominalFPS, codec, deviceName, deviceID, truncated, role
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(TrackType.self, forKey: .type)
        filename = try c.decode(String.self, forKey: .filename)
        sessionStartHostTime = try c.decode(Double.self, forKey: .sessionStartHostTime)
        nominalFPS = try c.decodeIfPresent(Double.self, forKey: .nominalFPS)
        codec = try c.decode(String.self, forKey: .codec)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        role = try c.decodeIfPresent(TrackRole.self, forKey: .role)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(filename, forKey: .filename)
        try c.encode(sessionStartHostTime, forKey: .sessionStartHostTime)
        try c.encodeIfPresent(nominalFPS, forKey: .nominalFPS)
        try c.encode(codec, forKey: .codec)
        try c.encodeIfPresent(deviceName, forKey: .deviceName)
        try c.encodeIfPresent(deviceID, forKey: .deviceID)
        try c.encode(truncated, forKey: .truncated)
        try c.encodeIfPresent(role, forKey: .role)
    }
}
