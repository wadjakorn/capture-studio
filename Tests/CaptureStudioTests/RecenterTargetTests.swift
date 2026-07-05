import Testing
import Foundation
import CoreGraphics
@testable import CaptureStudio

/// Pure geometry of `StudioCompositor.recenterTarget` — where the focus (cursor)
/// lands after the zoom, for the contained (clamped) and overflow (free) modes.
@Suite struct RecenterTargetTests {
    private let canvas = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    // Cursor at the source's right edge, 2× zoom, fully ramped in.
    private let rightEdge = CGPoint(x: 1000, y: 500)

    @Test func overflowCentresCursorOnCanvas() {
        // Free pan → the focus lands exactly on the canvas centre, so the video's
        // right edge is pulled to the middle and the right half shows background.
        let t = StudioCompositor.recenterTarget(focus: rightEdge, weight: 1, scale: 2,
                                                content: canvas, region: canvas, clamp: false)
        #expect(abs(t.x - 500) < 0.001)
        #expect(abs(t.y - 500) < 0.001)
    }

    @Test func containedClampsToKeepVideoCoveringCanvas() {
        // Clamped → the target can't move enough to uncover the canvas, so the
        // right edge stays pinned (target.x == 1000) and no background shows.
        let t = StudioCompositor.recenterTarget(focus: rightEdge, weight: 1, scale: 2,
                                                content: canvas, region: canvas, clamp: true)
        #expect(abs(t.x - 1000) < 0.001)
        // The scaled content still fully covers the region.
        let maxX = t.x + 2 * (canvas.maxX - rightEdge.x)   // right edge of scaled video
        let minX = t.x + 2 * (canvas.minX - rightEdge.x)   // left edge
        #expect(maxX >= canvas.maxX - 0.001)
        #expect(minX <= canvas.minX + 0.001)
    }

    @Test func containedRecentresWhenSlackAllows() {
        // Cursor near the centre: the clamp band is wide, so the focus fully
        // recentres onto the region centre.
        let t = StudioCompositor.recenterTarget(focus: CGPoint(x: 520, y: 500), weight: 1,
                                                scale: 2, content: canvas, region: canvas, clamp: true)
        #expect(abs(t.x - 500) < 0.001)
    }

    @Test func containedToASmallFramingWindowStaysCovered() {
        // A 500×500 window centred in the canvas; cursor at the source right edge.
        let window = CGRect(x: 250, y: 250, width: 500, height: 500)
        let t = StudioCompositor.recenterTarget(focus: rightEdge, weight: 1, scale: 2,
                                                content: canvas, region: window, clamp: true)
        // Pulled toward centre but stopped so the window stays covered.
        #expect(t.x > 500)          // moved in from the pinned edge...
        #expect(t.x < 1000)         // ...but not all the way to the window centre
        let maxX = t.x + 2 * (canvas.maxX - rightEdge.x)
        let minX = t.x + 2 * (canvas.minX - rightEdge.x)
        #expect(maxX >= window.maxX - 0.001)
        #expect(minX <= window.minX + 0.001)
    }

    @Test func zeroWeightIsAnInPlaceZoom() {
        // weight 0 (block edge / un-zoomed) → target == focus regardless of mode.
        let free = StudioCompositor.recenterTarget(focus: rightEdge, weight: 0, scale: 2,
                                                   content: canvas, region: canvas, clamp: false)
        #expect(abs(free.x - rightEdge.x) < 0.001)
    }
}
