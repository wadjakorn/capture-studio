import Testing
import CoreGraphics
@testable import CaptureStudio

@Suite struct ScrubMathTests {
    @Test func swipeRightRewinds() {
        // Positive dx (swipe right) moves backward in time.
        let t = StudioModel.scrubbedTime(from: 5.0, scrollDX: 100, viewWidth: 1000, duration: 10)
        #expect(t == 4.0)   // 5 - (100/1000)*10
    }

    @Test func swipeLeftAdvances() {
        let t = StudioModel.scrubbedTime(from: 5.0, scrollDX: -200, viewWidth: 1000, duration: 10)
        #expect(t == 7.0)   // 5 - (-200/1000)*10
    }

    @Test func clampsToBounds() {
        #expect(StudioModel.scrubbedTime(from: 0.5, scrollDX: 5000, viewWidth: 1000, duration: 10) == 0)
        #expect(StudioModel.scrubbedTime(from: 9.5, scrollDX: -5000, viewWidth: 1000, duration: 10) == 10)
    }

    @Test func zeroWidthOrDurationIsNoop() {
        #expect(StudioModel.scrubbedTime(from: 3, scrollDX: 100, viewWidth: 0, duration: 10) == 3)
        #expect(StudioModel.scrubbedTime(from: 3, scrollDX: 100, viewWidth: 1000, duration: 0) == 3)
    }
}
