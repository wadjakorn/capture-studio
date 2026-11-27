import Testing
@testable import CaptureStudio

@Test func bannerHiddenWhenAllGranted() {
    #expect(PermissionBanner.message(status: { _ in .granted }) == nil)
}
@Test func bannerPrefersScreen() {
    #expect(PermissionBanner.message(status: { _ in .denied })
            == "Screen Recording is off — Capture Studio can't record your screen.")
    #expect(PermissionBanner.message(status: { $0 == .screenRecording ? .notDetermined : .granted })
            == "Screen Recording is off — Capture Studio can't record your screen.")
}
@Test func bannerIgnoresEverythingButScreen() {
    #expect(PermissionBanner.message(status: { $0 == .screenRecording ? .granted : .denied }) == nil)
}
