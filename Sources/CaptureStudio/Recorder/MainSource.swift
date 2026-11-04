import Foundation
import CoreGraphics

/// What the recorder's main video track captures: a display, or a camera
/// (e.g. a phone) used as the primary source.
enum MainSource: Equatable {
    case display(CGDirectDisplayID)
    case camera(uniqueID: String)

    var displayID: CGDirectDisplayID? {
        if case .display(let id) = self { return id }
        return nil
    }

    var cameraID: String? {
        if case .camera(let id) = self { return id }
        return nil
    }

    var isCamera: Bool { cameraID != nil }

    /// Persisted form: ("display", "3") / ("camera", "<uniqueID>").
    var storage: (kind: String, id: String) {
        switch self {
        case .display(let id): return ("display", String(id))
        case .camera(let uid): return ("camera", uid)
        }
    }

    init?(kind: String, id: String) {
        switch kind {
        case "display":
            guard let n = UInt32(id) else { return nil }
            self = .display(CGDirectDisplayID(n))
        case "camera":
            self = .camera(uniqueID: id)
        default:
            return nil
        }
    }

    enum ResolveError: Equatable { case displayMissing, cameraMissing }

    /// Pure availability check used by arm() and the hotkey path.
    func resolve(cameraIDs: [String], displayIDs: [CGDirectDisplayID]) -> ResolveError? {
        switch self {
        case .display(let id):
            return displayIDs.contains(id) ? nil : .displayMissing
        case .camera(let uid):
            return cameraIDs.contains(uid) ? nil : .cameraMissing
        }
    }
}

/// Pure rules for which options are valid for a given main source.
enum RecorderSelection {
    /// All cameras except the one used as the main source (input order kept).
    static func frontCameraIDs(all: [String], main: MainSource) -> [String] {
        guard let mainCam = main.cameraID else { return all }
        return all.filter { $0 != mainCam }
    }

    /// The chosen front camera if it is still a candidate, else nil.
    static func resolvedFrontCamera(_ id: String?, candidates: [String]) -> String? {
        guard let id, candidates.contains(id) else { return nil }
        return id
    }

    static func systemAudioAllowed(for main: MainSource) -> Bool { !main.isCamera }
    static func areaAllowed(for main: MainSource) -> Bool { !main.isCamera }
    static func needsScreenPermission(for main: MainSource) -> Bool { !main.isCamera }
}
