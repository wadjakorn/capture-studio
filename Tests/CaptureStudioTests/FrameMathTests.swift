import Testing
import CoreGraphics
@testable import CaptureStudio

@Suite struct FrameMathTests {
    let canvas = CGSize(width: 1920, height: 1080)

    @Test func identityStaysUnclamped() {
        let f = FrameMath.clamped(centerX: 0.5, centerY: 0.5, width: 0.6, height: 0.6)
        #expect(f.centerX == 0.5)
        #expect(f.centerY == 0.5)
        #expect(f.width == 0.6)
        #expect(f.height == 0.6)
    }

    @Test func sizeClampedToMinAndFull() {
        let tiny = FrameMath.clamped(centerX: 0.5, centerY: 0.5, width: 0.001, height: -2)
        #expect(tiny.width == FrameMath.minSize)
        #expect(tiny.height == FrameMath.minSize)
        let huge = FrameMath.clamped(centerX: 0.5, centerY: 0.5, width: 3, height: 1.5)
        #expect(huge.width == 1)
        #expect(huge.height == 1)
    }

    @Test func centerPulledInsideCanvas() {
        // A 0.4-wide frame centered at x = 0.05 would spill left; the center is
        // pulled in so the rect's minX lands at 0.
        let f = FrameMath.clamped(centerX: 0.05, centerY: 0.99, width: 0.4, height: 0.2)
        #expect(f.centerX == 0.2)
        #expect(f.centerY == 0.9)
    }

    @Test func fullSizeFrameCentersItself() {
        // width == 1 leaves exactly one legal center (0.5) regardless of input.
        let f = FrameMath.clamped(centerX: 0.1, centerY: 0.9, width: 1, height: 1)
        #expect(f.centerX == 0.5)
        #expect(f.centerY == 0.5)
    }

    @Test func rectInCanvasMapsNormalizedToPixels() {
        let r = FrameMath.rectInCanvas(canvas, centerX: 0.5, centerY: 0.5,
                                       width: 0.5, height: 0.5)
        #expect(abs(r.minX - 480) < 0.001)
        #expect(abs(r.minY - 270) < 0.001)
        #expect(abs(r.width - 960) < 0.001)
        #expect(abs(r.height - 540) < 0.001)
    }

    @Test func rectInCanvasClampsOutOfRangeValues() {
        // Garbage persisted values still produce a rect fully inside the canvas.
        let r = FrameMath.rectInCanvas(canvas, centerX: 5, centerY: -5,
                                       width: 0.5, height: 0.5)
        #expect(r.minX >= 0)
        #expect(r.minY >= 0)
        #expect(r.maxX <= canvas.width + 0.001)
        #expect(r.maxY <= canvas.height + 0.001)
    }

    @Test func resizedFromOppositeCornerAnchor() {
        // Anchor bottom-right at (0.8, 0.8), drag the top-left corner to
        // (0.2, 0.4) → rect spans [0.2, 0.8] × [0.4, 0.8].
        let f = FrameMath.resized(anchor: CGPoint(x: 0.8, y: 0.8),
                                  dragged: CGPoint(x: 0.2, y: 0.4))
        #expect(abs(f.centerX - 0.5) < 1e-9)
        #expect(abs(f.centerY - 0.6) < 1e-9)
        #expect(abs(f.width - 0.6) < 1e-9)
        #expect(abs(f.height - 0.4) < 1e-9)
    }

    @Test func resizedHandlesCornerCrossover() {
        // Dragging past the anchor flips the rect instead of going negative.
        let f = FrameMath.resized(anchor: CGPoint(x: 0.5, y: 0.5),
                                  dragged: CGPoint(x: 0.7, y: 0.3))
        #expect(abs(f.width - 0.2) < 1e-9)
        #expect(abs(f.height - 0.2) < 1e-9)
        #expect(abs(f.centerX - 0.6) < 1e-9)
        #expect(abs(f.centerY - 0.4) < 1e-9)
    }

    @Test func resizedRespectsMinSize() {
        let f = FrameMath.resized(anchor: CGPoint(x: 0.5, y: 0.5),
                                  dragged: CGPoint(x: 0.5001, y: 0.5001))
        #expect(f.width == FrameMath.minSize)
        #expect(f.height == FrameMath.minSize)
    }
}
