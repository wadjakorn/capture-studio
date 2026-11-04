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

/// Where the microphone is recorded when phones are involved.
enum MicHost: Equatable {
    /// On the main video's phone connection.
    case mainRecorder
    /// On the overlay camera's phone connection.
    case overlayRecorder
    /// A phone connection carrying audio only.
    case standalonePhone
    /// A local mic (or no mic): the existing local path.
    case local
    /// Not recorded: a phone mic from a different phone than the phone video.
    case none
}

/// Which phones a selection uses, and who hosts the mic.
struct PhonePlan: Equatable {
    var mainPhone: String?
    var overlayPhone: String?
    var micPhone: String?
    var micHost: MicHost
}

extension RecorderSelection {
    static let differentPhonesWarning = "Use one phone for both video and microphone."

    /// Pure. A phone mic rides on the same phone's video connection (one
    /// connection per phone); a phone mic with no phone video gets its own
    /// audio-only connection; a mic from another phone than the video is rejected.
    static func phonePlan(main: MainSource, cameraID: String?, micID: String?) -> PhonePlan {
        let mainPhone = main.cameraID.flatMap(PhoneDeviceID.phoneID(fromCamera:))
        let overlayPhone = cameraID.flatMap(PhoneDeviceID.phoneID(fromCamera:))
        let micPhone = micID.flatMap(PhoneDeviceID.phoneID(fromMic:))
        let host: MicHost
        if let micPhone {
            if micPhone == mainPhone { host = .mainRecorder }
            else if micPhone == overlayPhone { host = .overlayRecorder }
            else if mainPhone == nil && overlayPhone == nil { host = .standalonePhone }
            else { host = .none }
        } else {
            host = .local
        }
        return PhonePlan(mainPhone: mainPhone, overlayPhone: overlayPhone,
                         micPhone: micPhone, micHost: host)
    }
}
