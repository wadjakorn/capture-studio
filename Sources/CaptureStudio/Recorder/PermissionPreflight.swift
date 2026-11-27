import Foundation

/// A permission problem found before recording starts.
struct PermissionIssue: Equatable, Sendable {
    let kind: PermissionKind
    /// Blocking issues stop recording; non-blocking ones only warn.
    let blocking: Bool
    let message: String
}

/// Pure pre-record permission rules. Statuses are injected so tests need no TCC.
enum PermissionPreflight {
    static let screenOff = "Screen Recording access is off. Allow it in System Settings to record your screen."
    static let cameraMainOff = "Camera access is off. Allow it in System Settings to record your camera."
    static let cameraOverlayOff = "Camera access is off — this recording won't include your camera."
    static let micOff = "Microphone access is off — this recording won't include your microphone."
    static let phoneMainOff = "Local Network access is off. Allow it in System Settings to use your phone."
    static let phoneOptionalOff = "Local Network access is off — your phone camera or microphone can't connect."

    /// Blocking issues first, then non-blocking; each group ordered
    /// screen, camera, microphone, local network.
    static func issues(main: MainSource, cameraID: String?, micID: String?,
                       status: (PermissionKind) -> PermissionStatus) -> [PermissionIssue] {
        var found: [PermissionIssue] = []

        if RecorderSelection.needsScreenPermission(for: main), status(.screenRecording) != .granted {
            found.append(PermissionIssue(kind: .screenRecording, blocking: true, message: screenOff))
        }

        let mainIsLocalCamera = main.cameraID.map { PhoneDeviceID.phoneID(fromCamera: $0) == nil } ?? false
        let overlayIsLocalCamera = cameraID.map { PhoneDeviceID.phoneID(fromCamera: $0) == nil } ?? false
        if status(.camera) == .denied {
            if mainIsLocalCamera {
                found.append(PermissionIssue(kind: .camera, blocking: true, message: cameraMainOff))
            } else if overlayIsLocalCamera {
                found.append(PermissionIssue(kind: .camera, blocking: false, message: cameraOverlayOff))
            }
        }

        if let micID, PhoneDeviceID.phoneID(fromMic: micID) == nil, status(.microphone) == .denied {
            found.append(PermissionIssue(kind: .microphone, blocking: false, message: micOff))
        }

        if status(.localNetwork) == .denied {
            let mainIsPhone = main.cameraID.flatMap(PhoneDeviceID.phoneID(fromCamera:)) != nil
            let overlayIsPhone = cameraID.flatMap(PhoneDeviceID.phoneID(fromCamera:)) != nil
            let micIsPhone = micID.flatMap(PhoneDeviceID.phoneID(fromMic:)) != nil
            if mainIsPhone {
                found.append(PermissionIssue(kind: .localNetwork, blocking: true, message: phoneMainOff))
            } else if overlayIsPhone || micIsPhone {
                found.append(PermissionIssue(kind: .localNetwork, blocking: false, message: phoneOptionalOff))
            }
        }

        return found.filter(\.blocking) + found.filter { !$0.blocking }
    }

    /// Maps one of the six messages above back to its permission kind.
    static func kind(forMessage message: String) -> PermissionKind? {
        switch message {
        case screenOff: return .screenRecording
        case cameraMainOff, cameraOverlayOff: return .camera
        case micOff: return .microphone
        case phoneMainOff, phoneOptionalOff: return .localNetwork
        default: return nil
        }
    }
}
