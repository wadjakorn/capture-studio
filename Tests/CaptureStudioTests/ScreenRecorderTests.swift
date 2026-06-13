import Testing
@testable import CaptureStudio

@Suite struct ScreenRecorderTests {
    @Test func capsRetina5KToLongSide2560() {
        // 5120×2880 retina: longest side scaled to 2560, aspect preserved.
        let s = ScreenRecorder.captureSize(forWidth: 5120, height: 2880)
        #expect(s.width == 2560)
        #expect(s.height == 1440)
    }

    @Test func capsByLongestSideOnPortrait() {
        // Portrait: height is the longest side and gets clamped to 2560.
        let s = ScreenRecorder.captureSize(forWidth: 2880, height: 5120)
        #expect(s.height == 2560)
        #expect(s.width == 1440)
    }

    @Test func leavesSmallDisplayUntouched() {
        let s = ScreenRecorder.captureSize(forWidth: 1920, height: 1080)
        #expect(s.width == 1920)
        #expect(s.height == 1080)
    }

    @Test func resultDimensionsAreEven() {
        // 3:2 at 3456 wide → scaled, both sides must be even for the encoder.
        let s = ScreenRecorder.captureSize(forWidth: 3456, height: 2234)
        #expect(s.width % 2 == 0)
        #expect(s.height % 2 == 0)
        #expect(max(s.width, s.height) == 2560)
    }
}
