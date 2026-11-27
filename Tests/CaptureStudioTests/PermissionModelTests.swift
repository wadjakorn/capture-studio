import Testing
import AVFoundation
@testable import CaptureStudio

@Test func avStatusMapping() {
    #expect(PermissionStatus.fromAV(.authorized) == .granted)
    #expect(PermissionStatus.fromAV(.notDetermined) == .notDetermined)
    #expect(PermissionStatus.fromAV(.denied) == .denied)
    #expect(PermissionStatus.fromAV(.restricted) == .denied)
}

@Test func screenStatusMapping() {
    #expect(PermissionStatus.screen(preflight: true, requestedBefore: false) == .granted)
    #expect(PermissionStatus.screen(preflight: true, requestedBefore: true) == .granted)
    #expect(PermissionStatus.screen(preflight: false, requestedBefore: false) == .notDetermined)
    // Asked before and still not granted: denied, or granted-pending-relaunch.
    #expect(PermissionStatus.screen(preflight: false, requestedBefore: true) == .denied)
}

@Test func localNetworkStatusMapping() {
    #expect(PermissionStatus.localNetwork(policyDenied: true, hasSeenPhone: true) == .denied)
    #expect(PermissionStatus.localNetwork(policyDenied: false, hasSeenPhone: true) == .granted)
    #expect(PermissionStatus.localNetwork(policyDenied: false, hasSeenPhone: false) == .unknown)
}

@Test func settingsURLsTargetPrivacyPanes() {
    let base = "x-apple.systempreferences:com.apple.preference.security?"
    #expect(PermissionKind.screenRecording.settingsURL.absoluteString == base + "Privacy_ScreenCapture")
    #expect(PermissionKind.microphone.settingsURL.absoluteString == base + "Privacy_Microphone")
    #expect(PermissionKind.camera.settingsURL.absoluteString == base + "Privacy_Camera")
    #expect(PermissionKind.localNetwork.settingsURL.absoluteString == base + "Privacy_LocalNetwork")
}

// macOS lists an app under Screen Recording only after it has requested access, so
// opening that pane without requesting first can leave nothing to toggle.
@Test func screenSettingsRegisterTheAppFirstWhenNotGranted() {
    #expect(Permissions.requestsBeforeOpeningSettings(.screenRecording, screenGranted: false))
    #expect(!Permissions.requestsBeforeOpeningSettings(.screenRecording, screenGranted: true))
    #expect(!Permissions.requestsBeforeOpeningSettings(.microphone, screenGranted: false))
    #expect(!Permissions.requestsBeforeOpeningSettings(.camera, screenGranted: false))
    #expect(!Permissions.requestsBeforeOpeningSettings(.localNetwork, screenGranted: false))
}
