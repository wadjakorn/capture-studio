import Testing
import CoreGraphics
@testable import CaptureStudio

@Suite struct ScreenRecorderTests {
    /// A 2x retina display for region-geometry tests.
    private func retina2x() -> DisplayItem {
        DisplayItem(id: 1, name: "Test", pointWidth: 1920, pointHeight: 1080,
                    pixelWidth: 3840, pixelHeight: 2160, originX: 100, originY: 50)
    }

    @Test func regionDisplayInfoIsRegionRelative() {
        let item = retina2x()  // scaleFactor 2.0
        let region = CGRect(x: 200, y: 100, width: 640, height: 360)
        let info = item.displayInfo(region: region)
        // Origin = display origin + region origin (global points).
        #expect(info.originX == 300)
        #expect(info.originY == 150)
        // Point size = region size; pixel size = region × scaleFactor.
        #expect(info.pointWidth == 640)
        #expect(info.pointHeight == 360)
        #expect(info.pixelWidth == 1280)
        #expect(info.pixelHeight == 720)
        #expect(info.scaleFactor == 2.0)
    }

    @Test func nilRegionMatchesFullDisplayInfo() {
        let item = retina2x()
        #expect(item.displayInfo(region: nil) == item.displayInfo)
    }

    @Test func capturePixelSizeScalesRegionByDisplayScale() {
        let item = retina2x()  // 2x
        let px = item.capturePixelSize(region: CGRect(x: 0, y: 0, width: 500, height: 300))
        #expect(px.width == 1000)
        #expect(px.height == 600)
    }

    @Test func clampedRegionRejectsFullAndOutOfBounds() {
        let item = retina2x()
        // Full-display region → nil (no point cropping).
        #expect(item.clampedRegion(CGRect(x: 0, y: 0, width: 1920, height: 1080)) == nil)
        // Off-screen region → nil.
        #expect(item.clampedRegion(CGRect(x: 5000, y: 5000, width: 100, height: 100)) == nil)
        // Partly out → clipped to bounds.
        let clamped = item.clampedRegion(CGRect(x: 1800, y: 1000, width: 400, height: 400))
        #expect(clamped == CGRect(x: 1800, y: 1000, width: 120, height: 80))
    }

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
