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

/// The ramp into a contained zoom near the picture's edge: zoom and pan must
/// travel together. The old rule eased the *clamped* target by the weight, so
/// the pan lagged the zoom quadratically — the picture zoomed about the old
/// spot (pushing the pointer off screen) and only then slid over.
@Suite struct ContainedRampTests {
    private let canvas = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    /// Screen x of source point `p` during a ramp to `hold`× at progress `e`
    /// (scale and weight ramp together, as `AutoZoomTrack` emits them).
    private func screenX(of p: CGFloat, focus: CGFloat, hold: CGFloat, e: CGFloat) -> CGFloat {
        let s = 1 + (hold - 1) * e
        let t = StudioCompositor.recenterTarget(focus: CGPoint(x: focus, y: 540), weight: e,
                                                scale: s, content: canvas, region: canvas,
                                                clamp: true)
        return t.x + s * (p - focus)
    }

    @Test func aPointerAtTheEdgeStaysOnScreenAndMovesOneWay() {
        // 3× hold: the view centre the planner picks at the left edge is W/6.
        let focus: CGFloat = 320, pointer: CGFloat = 40
        var prev = screenX(of: pointer, focus: focus, hold: 3, e: 0)
        #expect(abs(prev - pointer) < 1e-6)
        for i in 1...100 {
            let x = screenX(of: pointer, focus: focus, hold: 3, e: CGFloat(i) / 100)
            #expect(x >= -1e-6)                 // never pushed off the left edge
            #expect(x >= prev - 1e-6)           // and never doubling back
            prev = x
        }
        #expect(abs(prev - 120) < 1e-6)         // 3 × 40 at the hold
    }

    @Test func thePictureAlwaysCoversTheFrameDuringTheRamp() {
        for focus in [CGFloat(320), 700, 1600] {
            for i in 0...100 {
                let e = CGFloat(i) / 100
                #expect(screenX(of: 0, focus: focus, hold: 3, e: e) <= 1e-6)
                #expect(screenX(of: 1920, focus: focus, hold: 3, e: e) >= 1920 - 1e-6)
            }
        }
    }

    @Test func thePanKeepsPaceWithTheZoom() {
        // Near the edge (3× hold, focus 320), half way through the ramp the
        // focus has covered half its way to the centre — as it does with the edge
        // free — not a quarter of it (480, the old rule).
        func half(clamp: Bool) -> CGFloat {
            StudioCompositor.recenterTarget(focus: CGPoint(x: 320, y: 540), weight: 0.5,
                                            scale: 2, content: canvas, region: canvas,
                                            clamp: clamp).x
        }
        #expect(abs(half(clamp: true) - 640) < 1e-6)
        #expect(abs(half(clamp: true) - half(clamp: false)) < 1e-6)
    }

    @Test func aFramingWindowRampIsAStraightLineToo() {
        // The frame shows only the middle of the video; the focus is far left.
        let region = CGRect(x: 480, y: 0, width: 960, height: 1080)
        var prev: CGFloat = 160
        for i in 0...100 {
            let e = CGFloat(i) / 100, s = 1 + 2 * e
            let t = StudioCompositor.recenterTarget(focus: CGPoint(x: 160, y: 540), weight: e,
                                                    scale: s, content: canvas, region: region,
                                                    clamp: true).x
            #expect(abs(t - (160 + 800 * e)) < 1e-6)        // focus → the frame's centre
            #expect(t >= prev - 1e-6)
            // The video covers the frame all the way.
            #expect(t + s * (0 - 160) <= 480 + 1e-6 && t + s * (1920 - 160) >= 1440 - 1e-6)
            prev = t
        }
    }

    @Test func aLetterboxedPictureDoesNotDoubleBack() {
        // Landscape video letterboxed off-centre on a portrait canvas, zoomed
        // past the point where it covers the frame: its centre travels one way.
        let portrait = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        let content = CGRect(x: 0, y: 413.85, width: 1080, height: 607.5)
        let f = CGPoint(x: 540, y: 717.6)
        var prev = f.y
        for i in 0...100 {
            let e = CGFloat(i) / 100, s = 1 + 3 * e
            let t = StudioCompositor.recenterTarget(focus: f, weight: e, scale: s,
                                                    content: content, region: portrait,
                                                    clamp: true)
            if i == 0 { #expect(abs(t.y - f.y) < 1e-6) }
            #expect(t.y >= prev - 1e-6)
            prev = t.y
        }
        #expect(abs(prev - 960) < 1e-6)
    }

    @Test func aDipInsideTheRampStillCoversTheFrame() {
        // Scale and weight not tied together (a zoom dip during a move).
        for i in 0...100 {
            let e = CGFloat(i) / 100, s = 1 + 2 * e * 0.8
            let t = StudioCompositor.recenterTarget(focus: CGPoint(x: 320, y: 540), weight: e,
                                                    scale: s, content: canvas, region: canvas,
                                                    clamp: true).x
            #expect(t + s * (0 - 320) <= 1e-6 && t + s * (1920 - 320) >= 1920 - 1e-6)
        }
    }

    @Test func aBlockZoomingIntoACornerGlidesStraightThere() {
        // The reported case end to end: the pointer rests near the top-left
        // corner, a contained 3× block ramps in and out. On screen the pointer
        // must travel one way on the way in, back the same way on the way out,
        // and never leave the picture.
        let hd = CGSize(width: 1920, height: 1080)
        let p = CGPoint(x: 40, y: 30)
        var cursor: [CursorSample] = []
        for k in 0...600 { cursor.append(CursorSample(t: Double(k) / 60, p: p, cursor: "arrow")) }
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 2, end: 8, scale: 3)],
                                        cursorSamples: cursor, sourceSize: hd)
        func onScreen(_ t: Double) -> CGPoint {
            let z = AutoZoomTrack.sample(at: t, track: track)
            guard z.scale > 1.0001 else { return p }
            let target = StudioCompositor.recenterTarget(
                focus: z.focus, weight: z.weight, scale: z.scale, content: canvas,
                region: canvas, clamp: true)
            return CGPoint(x: target.x + z.scale * (p.x - z.focus.x),
                           y: target.y + z.scale * (p.y - z.focus.y))
        }
        var prev = onScreen(2)
        var t = 2.0
        while t <= 5 {
            let q = onScreen(t)
            #expect(q.x >= prev.x - 0.01 && q.y >= prev.y - 0.01, "doubles back at \(t)")
            #expect(q.x >= 0 && q.y >= 0)
            prev = q
            t += 1.0 / 120
        }
        #expect(abs(prev.x - 120) < 0.5 && abs(prev.y - 90) < 0.5)
        while t <= 8 {
            let q = onScreen(t)
            #expect(q.x <= prev.x + 0.01 && q.y <= prev.y + 0.01, "doubles back at \(t)")
            #expect(q.x >= 0 && q.y >= 0)
            prev = q
            t += 1.0 / 120
        }
    }
}
