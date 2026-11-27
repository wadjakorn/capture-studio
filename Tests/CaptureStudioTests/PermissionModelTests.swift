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
