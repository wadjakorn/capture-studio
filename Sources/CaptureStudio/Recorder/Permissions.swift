import Foundation
import CoreGraphics
import AppKit
import AVFoundation

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

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
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
