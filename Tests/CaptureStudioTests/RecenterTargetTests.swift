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

    @Test func overflowCentresOnFrameNotCanvas() {
        // New semantics (defect #1 fix): overflow keeps the region = the framing
        // window, so the cursor eases to the FRAME centre — not the canvas centre —
        // and the video stays clipped to the frame with bg revealed inside it.
        let window = CGRect(x: 250, y: 250, width: 500, height: 500)
        let t = StudioCompositor.recenterTarget(focus: rightEdge, weight: 1, scale: 2,
                                                content: canvas, region: window, clamp: false)
        #expect(abs(t.x - window.midX) < 0.001)   // -> 500
        #expect(abs(t.y - window.midY) < 0.001)   // -> 500
    }

    @Test func contentSmallerThanRegionCentresContentNotSnaps() {
        // Fitted content smaller than the region on both axes (e.g. a letterboxed
        // source, or a framing window larger than the fit). The scaled content
        // can't cover the region → the clamp band inverts. The fallback must place
        // the content's CENTRE on the region centre (best coverage), not do
        // anything discontinuous.
        let content = CGRect(x: 250, y: 250, width: 500, height: 500)
        let scale: CGFloat = 1
        let t = StudioCompositor.recenterTarget(focus: rightEdge, weight: 1, scale: scale,
                                                content: content, region: canvas, clamp: true)
        // out(p) = target + scale·(p − focus); content centre must land on region centre.
        let outMidX = t.x + scale * (content.midX - rightEdge.x)
        let outMidY = t.y + scale * (content.midY - rightEdge.y)
        #expect(abs(outMidX - canvas.midX) < 0.001)
        #expect(abs(outMidY - canvas.midY) < 0.001)
    }

    @Test func clampedZoomOutIsContinuousAcrossCoveringBoundary() {
        // Regression for the "weird jump": as the auto zoom-out ramp lowers the
        // scale past the exact covering scale, the clamped target must stay
        // CONTINUOUS (no snap to region centre). Content 500 wide, region 1000
        // wide → covering scale is 2. Sample either side of it and require the
        // target barely moves.
        let content = CGRect(x: 250, y: 250, width: 500, height: 500)
        let covering: CGFloat = canvas.width / content.width   // 2
        let eps: CGFloat = 1e-3
        func target(at scale: CGFloat) -> CGPoint {
            StudioCompositor.recenterTarget(focus: rightEdge, weight: 1, scale: scale,
                                            content: content, region: canvas, clamp: true)
        }
        let above = target(at: covering + eps)
        let below = target(at: covering - eps)
        // Continuous: the step across the boundary is on the order of the local
        // slope × 2·eps (≈ 1px here), NOT the ~1000px snap the old region-centre
        // fallback produced (clamped band edge ≈ 1500 vs region centre 500).
        #expect(abs(above.x - below.x) < 5)
        #expect(abs(above.y - below.y) < 5)
    }

    @Test func zeroWeightIsAnInPlaceZoom() {
        // weight 0 (block edge / un-zoomed) → target == focus regardless of mode.
        let free = StudioCompositor.recenterTarget(focus: rightEdge, weight: 0, scale: 2,
                                                   content: canvas, region: canvas, clamp: false)
        #expect(abs(free.x - rightEdge.x) < 0.001)
    }
}
