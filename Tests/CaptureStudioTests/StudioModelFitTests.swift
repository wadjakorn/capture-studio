import Testing
import CoreGraphics
@testable import CaptureStudio

struct StudioModelFitTests {
    // 9:16 canvas at 1080 short side is portrait 1080x1920 — the math the
    // template's renderSize/export canvas depends on.
    @Test func templateCanvasIsPortrait1080() {
        let ratio = CropAspect.nineBySixteenTemplate.ratio!
        let shortSide: CGFloat = 1080
        let height = (CGFloat(1.0) / CGFloat(ratio) * shortSide / 2).rounded() * 2
        #expect(shortSide == 1080)
        #expect(height == 1920)
    }

    // Contain placement: a 16:9 source fits a 9:16 canvas by width, centered,
    // with black bars top + bottom.
    @Test func landscapeFitsNineBySixteenWithBars() {
        let fit = CropMath.aspectFitRect(CGSize(width: 1920, height: 1080),
                                         in: CGSize(width: 1080, height: 1920))
        #expect(fit.width == 1080)
        #expect(fit.height == 607.5)
        #expect(fit.minX == 0)
        #expect(fit.minY == (1920 - 607.5) / 2)
    }

    // A 9:16 source fills the 9:16 canvas — no bars.
    @Test func portraitFillsNineBySixteen() {
        let fit = CropMath.aspectFitRect(CGSize(width: 1080, height: 1920),
                                         in: CGSize(width: 1080, height: 1920))
        #expect(fit == CGRect(x: 0, y: 0, width: 1080, height: 1920))
    }

    // Fit placement at zoom 1 / centered = full letterbox (whole frame, bars).
    @Test func fitPlacementDefaultIsFullLetterbox() {
        let place = CropMath.fitPlacement(source: CGSize(width: 1920, height: 1080),
                                          canvas: CGSize(width: 1080, height: 1920),
                                          zoom: 1, centerX: 0.5, centerY: 0.5)
        #expect(place == CGRect(x: 0, y: 656.25, width: 1080, height: 607.5))
    }

    // Zooming in (zoom < 1) scales the content up; the wide axis pans, clamped
    // flush to the canvas edge (no gap), the short axis stays centered.
    @Test func fitPlacementZoomInScalesAndClamps() {
        let place = CropMath.fitPlacement(source: CGSize(width: 1920, height: 1080),
                                          canvas: CGSize(width: 1080, height: 1920),
                                          zoom: 0.5, centerX: 0.5, centerY: 0.5)
        #expect(place.width == 2160)
        #expect(place.height == 1215)
        #expect(place.minX == -540)        // centered horizontally, content overflows
        #expect(place.minY == 352.5)       // still letterboxed vertically
    }

    // A letterboxed (smaller) axis pans through its black bars: pushing centerY
    // past the top slides the content flush to the top edge (all bar at bottom),
    // and past the bottom slides it flush to the bottom — not locked to center.
    @Test func fitPlacementPansThroughBars() {
        let source = CGSize(width: 1920, height: 1080)
        let canvas = CGSize(width: 1080, height: 1920)
        let top = CropMath.fitPlacement(source: source, canvas: canvas,
                                        zoom: 1, centerX: 0.5, centerY: 2.0)
        #expect(top.minY == 0)                              // flush top
        let bottom = CropMath.fitPlacement(source: source, canvas: canvas,
                                           zoom: 1, centerX: 0.5, centerY: -1.0)
        #expect(bottom.minY == canvas.height - bottom.height)  // flush bottom
    }
}
