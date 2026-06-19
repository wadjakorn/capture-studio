import Testing
import CoreGraphics
@testable import CaptureStudio

/// Pure geometry for the editable area-selection overlay. Coordinates are
/// top-left origin, y-down, within `bounds` (the screen size in points).
@Suite struct RegionEditStateTests {
    private let bounds = CGSize(width: 1000, height: 800)

    private func state(_ rect: CGRect, aspect: AspectRatio = .free) -> RegionEditState {
        RegionEditState(bounds: bounds, rect: rect, aspect: aspect, minSize: 20)
    }

    // MARK: drawFrom

    @Test func drawFromCreatesRectBetweenPoints() {
        var s = state(.zero)
        s.drawFrom(CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        #expect(s.rect == CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    @Test func drawFromNormalizesReversedDrag() {
        var s = state(.zero)
        s.drawFrom(CGPoint(x: 300, y: 250), to: CGPoint(x: 100, y: 100))
        #expect(s.rect == CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    @Test func drawFromWithAspectLocksRatioWidthDriven() {
        var s = state(.zero, aspect: .r16x9)
        // Pointer y is ignored; height derives from width / ratio.
        s.drawFrom(CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 999))
        #expect(s.rect.width == 200)
        #expect(abs(s.rect.height - 200 * 9.0 / 16.0) < 0.001)
        #expect(s.rect.origin == CGPoint(x: 100, y: 100))
    }

    // MARK: move

    @Test func moveTranslatesWithinBounds() {
        var s = state(CGRect(x: 100, y: 100, width: 200, height: 150))
        s.move(by: CGSize(width: 50, height: 30))
        #expect(s.rect == CGRect(x: 150, y: 130, width: 200, height: 150))
    }

    @Test func moveClampsToBounds() {
        var s = state(CGRect(x: 900, y: 700, width: 200, height: 150))
        s.move(by: CGSize(width: 500, height: 500))
        // Clamped so the rect stays fully inside 1000x800.
        #expect(s.rect == CGRect(x: 800, y: 650, width: 200, height: 150))
    }

    // MARK: resize (free)

    @Test func resizeBottomRightGrows() {
        var s = state(CGRect(x: 100, y: 100, width: 200, height: 150))
        s.resize(.bottomRight, to: CGPoint(x: 350, y: 300))
        #expect(s.rect == CGRect(x: 100, y: 100, width: 250, height: 200))
    }

    @Test func resizeTopLeftMovesOriginKeepsFarCorner() {
        var s = state(CGRect(x: 100, y: 100, width: 200, height: 150))
        // Far corner (maxX=300, maxY=250) stays fixed.
        s.resize(.topLeft, to: CGPoint(x: 50, y: 40))
        #expect(s.rect == CGRect(x: 50, y: 40, width: 250, height: 210))
    }

    @Test func resizeTopEdgeMovesOnlyY() {
        var s = state(CGRect(x: 100, y: 100, width: 200, height: 150))
        s.resize(.top, to: CGPoint(x: 999, y: 60))
        #expect(s.rect == CGRect(x: 100, y: 60, width: 200, height: 190))
    }

    @Test func resizeClampsToBounds() {
        var s = state(CGRect(x: 100, y: 100, width: 200, height: 150))
        s.resize(.bottomRight, to: CGPoint(x: 5000, y: 5000))
        #expect(s.rect.maxX == 1000)
        #expect(s.rect.maxY == 800)
    }

    @Test func resizeRespectsMinSize() {
        var s = state(CGRect(x: 100, y: 100, width: 200, height: 150))
        // Drag bottom-right back past the top-left → width/height pinned to min.
        s.resize(.bottomRight, to: CGPoint(x: 105, y: 105))
        #expect(s.rect.width == 20)
        #expect(s.rect.height == 20)
        #expect(s.rect.origin == CGPoint(x: 100, y: 100))
    }

    @Test func resizeBottomRightWithAspectLocksRatio() {
        var s = state(CGRect(x: 100, y: 100, width: 100, height: 100), aspect: .r1x1)
        s.resize(.bottomRight, to: CGPoint(x: 400, y: 250))
        // Square: width drives, height forced equal, top-left fixed.
        #expect(s.rect == CGRect(x: 100, y: 100, width: 300, height: 300))
    }

    // MARK: applyAspect

    @Test func applyAspectUsesDefaultSizeCentered() {
        // Large bounds so the default size fits without clamping; the default is
        // placed centered on the current rect's center, not shrink-fit into it.
        var s = RegionEditState(bounds: CGSize(width: 3000, height: 2000),
                                rect: CGRect(x: 1400, y: 900, width: 50, height: 50))
        s.applyAspect(.r16x9)
        #expect(s.rect.width == 1280)
        #expect(s.rect.height == 720)
        #expect(abs(s.rect.midX - 1425) < 0.001)   // center of (1400,900,50,50)
        #expect(abs(s.rect.midY - 925) < 0.001)
        #expect(s.aspect == .r16x9)
    }

    @Test func applyAspectRepeatedDoesNotShrink() {
        // Re-picking ratios must not progressively shrink — each pick is the
        // ratio's own default size.
        var s = RegionEditState(bounds: CGSize(width: 3000, height: 2000),
                                rect: CGRect(x: 100, y: 100, width: 400, height: 400))
        s.applyAspect(.r16x9)
        s.applyAspect(.r9x16)
        s.applyAspect(.r1x1)
        #expect(s.rect.width == 720)
        #expect(s.rect.height == 720)
    }

    @Test func applyAspectScalesDownToFitBounds() {
        // Default 1280x720 won't fit a 600x400 space → scaled down, ratio kept.
        var s = RegionEditState(bounds: CGSize(width: 600, height: 400),
                                rect: CGRect(x: 10, y: 10, width: 50, height: 50))
        s.applyAspect(.r16x9)
        #expect(s.rect.maxX <= 600)
        #expect(s.rect.maxY <= 400)
        #expect(s.rect.width <= 600 * 0.9 + 0.001)
        #expect(abs(s.rect.width / s.rect.height - 16.0 / 9.0) < 0.001)
    }

    @Test func aspectDefaultSizes() {
        #expect(AspectRatio.free.defaultSize == nil)
        #expect(AspectRatio.r1x1.defaultSize == CGSize(width: 720, height: 720))
        #expect(AspectRatio.r16x9.defaultSize == CGSize(width: 1280, height: 720))
        #expect(AspectRatio.r9x16.defaultSize == CGSize(width: 405, height: 720))
    }

    @Test func applyFreeAspectLeavesRectUnchanged() {
        var s = state(CGRect(x: 100, y: 100, width: 333, height: 211), aspect: .r16x9)
        s.applyAspect(.free)
        #expect(s.rect == CGRect(x: 100, y: 100, width: 333, height: 211))
        #expect(s.aspect == .free)
    }

    // MARK: hitTest

    @Test func hitTestInsideReturnsMove() {
        let s = state(CGRect(x: 100, y: 100, width: 200, height: 150))
        #expect(s.hitTest(CGPoint(x: 200, y: 175), handleRadius: 8) == .move)
    }

    @Test func hitTestCornerReturnsHandle() {
        let s = state(CGRect(x: 100, y: 100, width: 200, height: 150))
        #expect(s.hitTest(CGPoint(x: 100, y: 100), handleRadius: 8) == .handle(.topLeft))
        #expect(s.hitTest(CGPoint(x: 300, y: 250), handleRadius: 8) == .handle(.bottomRight))
    }

    @Test func hitTestOutsideReturnsNil() {
        let s = state(CGRect(x: 100, y: 100, width: 200, height: 150))
        #expect(s.hitTest(CGPoint(x: 500, y: 500), handleRadius: 8) == nil)
    }

    // MARK: isValid

    @Test func isValidTrueWhenAtLeastMinSize() {
        let s = state(CGRect(x: 0, y: 0, width: 20, height: 20))  // minSize == 20
        #expect(s.isValid)
    }

    @Test func isValidFalseWhenNarrowerThanMinSize() {
        let s = state(CGRect(x: 0, y: 0, width: 19, height: 200))
        #expect(!s.isValid)
    }

    @Test func isValidFalseWhenShorterThanMinSize() {
        let s = state(CGRect(x: 0, y: 0, width: 200, height: 19))
        #expect(!s.isValid)
    }

    @Test func isValidFalseForZeroRect() {
        let s = state(.zero)
        #expect(!s.isValid)
    }

    // MARK: AspectRatio table

    @Test func aspectRatioValuesCorrect() {
        #expect(AspectRatio.free.value == nil)
        #expect(near(AspectRatio.r16x9.value, 16.0 / 9.0))
        #expect(near(AspectRatio.r9x16.value, 9.0 / 16.0))
        #expect(near(AspectRatio.r1x1.value, 1.0))
        #expect(near(AspectRatio.r4x5.value, 4.0 / 5.0))
        #expect(near(AspectRatio.r4x3.value, 4.0 / 3.0))
        #expect(AspectRatio.all.first == .free)
    }

    private func near(_ a: CGFloat?, _ b: CGFloat) -> Bool {
        guard let a else { return false }
        return abs(a - b) < 0.0001
    }
}
