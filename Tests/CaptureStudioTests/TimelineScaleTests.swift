import Testing
import Foundation
import CoreGraphics
@testable import CaptureStudio

@Suite struct TimelineScaleTests {
    @Test func clampZoomBounds() {
        #expect(TimelineScale.clampZoom(0.2) == TimelineScale.minZoom)
        #expect(TimelineScale.clampZoom(1000) == TimelineScale.maxZoom)
        #expect(TimelineScale.clampZoom(3) == 3)
    }

    @Test func contentWidthFitsViewportAtZoomOne() {
        #expect(TimelineScale.contentWidth(viewport: 800, zoom: 1) == 800)
        #expect(TimelineScale.contentWidth(viewport: 800, zoom: 2) == 1600)
        // Zoom below 1 is clamped to fit.
        #expect(TimelineScale.contentWidth(viewport: 800, zoom: 0.5) == 800)
    }

    @Test func pixelsPerSecondScalesWithContent() {
        #expect(TimelineScale.pixelsPerSecond(contentWidth: 1000, duration: 10) == 100)
        #expect(TimelineScale.pixelsPerSecond(contentWidth: 0, duration: 0) == 0)
    }

    @Test func scrollXAnchorsTimeUnderPointer() {
        // 10s clip, content 2000px (pps 200), viewport 800. Keep t=5 (x=1000)
        // under viewportX=400 → scrollX = 1000 - 400 = 600.
        let x = TimelineScale.scrollX(keepingTime: 5, atViewportX: 400,
                                      viewport: 800, contentWidth: 2000, duration: 10)
        #expect(x == 600)
    }

    @Test func scrollXClampsToRange() {
        // Anchor near the start can't produce a negative offset.
        let lo = TimelineScale.scrollX(keepingTime: 0.5, atViewportX: 400,
                                       viewport: 800, contentWidth: 2000, duration: 10)
        #expect(lo == 0)
        // Anchor near the end clamps to contentWidth - viewport = 1200.
        let hi = TimelineScale.scrollX(keepingTime: 9.5, atViewportX: 100,
                                       viewport: 800, contentWidth: 2000, duration: 10)
        #expect(hi == 1200)
    }

    @Test func scrollToRevealOnlyWhenOffscreen() {
        // pps 200, viewport 800. Playhead at t=2 (x=400) already visible at scroll 0.
        #expect(TimelineScale.scrollToReveal(time: 2, currentScrollX: 0, viewport: 800,
                                             contentWidth: 2000, duration: 10) == nil)
        // Playhead at t=9 (x=1800) past the right edge → scroll to reveal.
        let s = TimelineScale.scrollToReveal(time: 9, currentScrollX: 0, viewport: 800,
                                             contentWidth: 2000, duration: 10, margin: 24)
        #expect(s != nil)
        #expect(s! == 1024)          // 1800 - 800 + 24, within [0, 1200]
    }

    @Test func zoomSliderRoundTrips() {
        for z in [1.0, 2.0, 7.5, 30.0, 60.0] {
            let t = TimelineScale.zoomSliderPosition(z)
            #expect(abs(TimelineScale.zoomForSlider(t) - z) < 1e-6)
        }
        // Endpoints map to 0 and 1.
        #expect(abs(TimelineScale.zoomSliderPosition(1) - 0) < 1e-9)
        #expect(abs(TimelineScale.zoomSliderPosition(60) - 1) < 1e-9)
    }

    @Test func packedHeightCapsAtMaxRows() {
        let one = TimelineLaneMetrics.packedHeight(rowCount: 1)
        let three = TimelineLaneMetrics.packedHeight(rowCount: 3)
        let ten = TimelineLaneMetrics.packedHeight(rowCount: 10)
        let expectedThree: CGFloat = 72   // 3*22 + 2*3
        #expect(one == 22)
        #expect(three == expectedThree)
        #expect(ten == three)          // capped at maxVisibleRows
    }
}
