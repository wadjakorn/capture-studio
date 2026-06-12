import Foundation

/// Versioned metadata describing a recording bundle. Written last during
/// finalization — its presence marks the bundle as valid.
struct ProjectMeta: Codable, Equatable {
    var schemaVersion: Int = 1
    var app: AppInfo
    var display: DisplayInfo
    var tracks: [TrackInfo]
    var recordedAt: Date
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
}
