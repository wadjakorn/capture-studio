import Testing
import CoreGraphics
@testable import CaptureStudio

@Suite struct CropMathTests {
    let source = CGSize(width: 3456, height: 2234) // 16:10-ish Retina display

    @Test func maxFitVerticalCropLimitedByHeight() {
        // 9:16 in a landscape source: full height, width = h * 9/16.
        let size = CropMath.maxFitSize(source: source, ratio: 9.0 / 16.0)
        #expect(size.height == 2234)
        #expect(abs(size.width - 2234 * 9.0 / 16.0) < 0.001)
    }

    @Test func maxFitWideCropLimitedByWidth() {
        // 21:9 crop of a 16:10 source: full width, reduced height.
        let ratio: CGFloat = 21.0 / 9.0
        let size = CropMath.maxFitSize(source: source, ratio: ratio)
        #expect(size.width == 3456)
        #expect(abs(size.height - 3456 / ratio) < 0.001)
    }

    @Test func fullZoomCenteredRectIsCentered() {
        let rect = CropMath.cropRect(source: source, ratio: 1.0, zoom: 1.0,
                                     centerX: 0.5, centerY: 0.5)
        #expect(rect.width == 2234)
        #expect(rect.height == 2234)
        #expect(abs(rect.midX - source.width / 2) < 0.001)
        #expect(abs(rect.midY - source.height / 2) < 0.001)
    }

    @Test func fullZoomCenterIsForcedToFit() {
        // At zoom 1.0 a 1:1 crop fills the full height — vertical pan impossible.
        let rect = CropMath.cropRect(source: source, ratio: 1.0, zoom: 1.0,
                                     centerX: 0.0, centerY: 0.0)
        #expect(rect.minY == 0)
        #expect(rect.maxY == source.height)
        #expect(rect.minX >= 0)
    }

    @Test func pannedRectStaysInsideSource() {
        let rect = CropMath.cropRect(source: source, ratio: 9.0 / 16.0, zoom: 0.5,
                                     centerX: 0.95, centerY: 0.05)
        #expect(rect.minX >= 0)
        #expect(rect.minY >= 0)
        #expect(rect.maxX <= source.width)
        #expect(rect.maxY <= source.height)
    }

    @Test func zoomIsClamped() {
        let tiny = CropMath.cropRect(source: source, ratio: 1.0, zoom: 0.01,
                                     centerX: 0.5, centerY: 0.5)
        let floor = CropMath.cropRect(source: source, ratio: 1.0, zoom: 0.2,
                                      centerX: 0.5, centerY: 0.5)
        #expect(tiny.size == floor.size)
    }

    @Test func cameraFeedNativeAspectZoomCenters() {
        // Camera feed: native aspect, zoom 0.5 (= cameraZoom 2) → half-size
        // crop centered, no distortion (crop aspect == feed aspect).
        let feed = CGSize(width: 1280, height: 720)
        let ratio = feed.width / feed.height
        let rect = CropMath.cropRect(source: feed, ratio: ratio, zoom: 0.5,
                                     centerX: 0.5, centerY: 0.5)
        #expect(abs(rect.width - 640) < 0.001)
        #expect(abs(rect.height - 360) < 0.001)
        #expect(abs(rect.midX - 640) < 0.001)
        #expect(abs(rect.midY - 360) < 0.001)
    }

    @Test func degenerateSourceYieldsZero() {
        #expect(CropMath.maxFitSize(source: .zero, ratio: 1.0) == .zero)
        #expect(CropMath.cropRect(source: .zero, ratio: 1.0, zoom: 1.0,
                                  centerX: 0.5, centerY: 0.5) == .zero)
    }
}
