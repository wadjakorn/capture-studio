import Foundation
import CoreGraphics
import AppKit
import AVFoundation

enum PermissionKind: String, CaseIterable, Sendable {
    case screenRecording, microphone, camera, localNetwork

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .microphone: return "Microphone"
        case .camera: return "Camera"
        case .localNetwork: return "Local Network"
        }
    }

    var settingsURL: URL {
        let pane: String
        switch self {
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .microphone: pane = "Privacy_Microphone"
        case .camera: pane = "Privacy_Camera"
        case .localNetwork: pane = "Privacy_LocalNetwork"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

enum PermissionStatus: Equatable, Sendable {
    case granted, notDetermined, denied, unknown

    static func fromAV(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    /// Preflight alone can't tell "never asked" from "denied"; `requestedBefore` splits them.
    static func screen(preflight: Bool, requestedBefore: Bool) -> PermissionStatus {
        if preflight { return .granted }
        return requestedBefore ? .denied : .notDetermined
    }

    static func localNetwork(policyDenied: Bool, hasSeenPhone: Bool) -> PermissionStatus {
        if policyDenied { return .denied }
        return hasSeenPhone ? .granted : .unknown
    }
}

enum Permissions {
    /// True if Screen Recording TCC permission is already granted.
    static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt (first time) or returns current status.
    /// After the user grants in System Settings, the app must be relaunched.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// macOS lists an app under Screen Recording only once it has requested access
    /// (and a TCC reset or a re-signed build removes it again), so the pane alone can
    /// leave nothing to toggle. `AppSettings.screenRecordingRequested` can't tell,
    /// so every not-granted open requests first: it shows the system prompt if no
    /// decision exists yet, or does nothing if one does.
    static func requestsBeforeOpeningSettings(_ kind: PermissionKind, screenGranted: Bool) -> Bool {
        kind == .screenRecording && !screenGranted
    }

    static func openSettings(_ kind: PermissionKind) {
        if requestsBeforeOpeningSettings(kind, screenGranted: screenRecordingGranted()) {
            AppSettings.screenRecordingRequested = true
            requestScreenRecording()
        }
        NSWorkspace.shared.open(kind.settingsURL)
    }

    /// Camera / microphone TCC. Returns true if granted (prompting if needed).
    static func requestCapture(_ mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: mediaType)
        default: return false
        }
    }
}
