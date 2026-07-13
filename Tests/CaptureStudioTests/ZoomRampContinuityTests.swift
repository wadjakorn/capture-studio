import Testing
import Foundation
import CoreGraphics
@testable import CaptureStudio

/// Regression for the reported "position jump in the first/last second" of a
/// follow zoom block with Overflow inside frame OFF (#31). The real captured log
/// showed the pan sitting ~242px off the natural placement at the last zoomed
/// frame, then snapping the instant `magnify` cuts off at scale ≤ 1.0001.
///
/// Root cause: `recenterTarget` did not reduce to an in-place zoom as the ramp's
/// `weight → 0`. The cover clamp (and its midpoint fallback when the letterboxed
/// content can't cover the full-canvas region) pulled `target` far from `focus`
/// even at weight 0, so the magnify translation `(target − focus)` never vanished
/// and snapped when the zoom ended. These tests pin `target → focus` at weight 0
/// and the composed centre converging to natural across the whole ramp.
@Suite struct ZoomRampContinuityTests {
    // Portrait canvas with a letterboxed landscape source: `content` is shorter
    // than the full-canvas `region` in Y and vertically off-centre — the captured
    // #31 scenario (region centre 960, content centre ≈ 717.6).
    private let canvas = CGSize(width: 1080, height: 1920)
    private let content = CGRect(x: 0, y: 413.85, width: 1080, height: 607.5)
    private var region: CGRect { CGRect(origin: .zero, size: canvas) }
    private let focus = CGPoint(x: 243.7, y: 592.7)

    /// Composed on-screen position of the canvas centre, modelling
    /// `CameraCompositor.magnify`'s `scale <= 1.0001` early-return (below the
    /// threshold the frame is drawn at its natural placement = canvas centre).
    private func outputCentre(scale: CGFloat, weight: CGFloat) -> CGPoint {
        let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        guard scale > 1.0001 else { return c }
        let t = StudioCompositor.recenterTarget(focus: focus, weight: weight, scale: scale,
                                                content: content, region: region, clamp: true)
        return CGPoint(x: t.x + scale * (c.x - focus.x), y: t.y + scale * (c.y - focus.y))
    }

    @Test func recenterIsInPlaceAtZeroWeight() {
        // At weight 0 (a block edge) the recenter must be a pure in-place zoom —
        // target == focus — regardless of the cover geometry, so the frame lines up
        // with the un-zoomed natural placement. The off-centre letterbox case is
        // exactly where the old midpoint fallback broke this.
        let t = StudioCompositor.recenterTarget(focus: focus, weight: 0, scale: 1.001,
                                                content: content, region: region, clamp: true)
        #expect(abs(t.x - focus.x) < 1, "target.x \(t.x) should equal focus.x \(focus.x)")
        #expect(abs(t.y - focus.y) < 1, "target.y \(t.y) should equal focus.y \(focus.y)")
    }

    @Test func composedCentreConvergesToNaturalAcrossRamp() {
        // Sweep the whole ramp (scale 1.30 → 1.00, weight ≈ scale−1 for a 2× block)
        // in fine steps that straddle the magnify cut-off, and require the composed
        // centre never to jump — in particular no snap as the zoom ends.
        var prev: CGPoint?
        var maxJump: CGFloat = 0, atScale: CGFloat = 0
        var s: CGFloat = 1.30
        while s >= 0.9999 {
            let o = outputCentre(scale: s, weight: max(0, s - 1))
            if let p = prev {
                let d = hypot(o.x - p.x, o.y - p.y)
                if d > maxJump { maxJump = d; atScale = s }
            }
            prev = o
            s -= 0.0005
        }
        #expect(maxJump < 2, "composed centre jumped \(maxJump)px near scale=\(atScale)")
    }

    @Test func coverPreservedForContentCoveringRegionMidRamp() {
        // The common case: content covers the region (content == region == canvas).
        // Contained mode must keep the region covered at every point of the ramp —
        // the recenter easing must not open a background gap here. Cursor at the
        // edge, sampled across the ramp.
        let full = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let edge = CGPoint(x: 900, y: 500)
        for i in 0...20 {
            let w = CGFloat(i) / 20
            let s = 1 + w                      // 2× block: scale = 1 + weight
            let t = StudioCompositor.recenterTarget(focus: edge, weight: w, scale: s,
                                                    content: full, region: full, clamp: true)
            let left = t.x + s * (full.minX - edge.x)
            let right = t.x + s * (full.maxX - edge.x)
            #expect(left <= full.minX + 0.01, "left \(left) uncovers at weight \(w)")
            #expect(right >= full.maxX - 0.01, "right \(right) uncovers at weight \(w)")
        }
    }

    @Test func targetContinuousAcrossCoverThreshold() {
        // Sub-region content (500 in 1000) with a 3× block: the cover band flips
        // inverted→valid as scale crosses 2× at weight 0.5. The target must stay
        // continuous through that flip — no snap mid-ramp (codex regression).
        let c = CGRect(x: 250, y: 0, width: 500, height: 1000)
        let r = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let f = CGPoint(x: 750, y: 500)
        var prev: CGFloat?
        var maxJump: CGFloat = 0
        for i in stride(from: 0, through: 200, by: 1) {
            let w = CGFloat(i) / 200
            let s = 1 + 2 * w                  // 3× block: scale = 1 + 2·weight
            let t = StudioCompositor.recenterTarget(focus: f, weight: w, scale: s,
                                                    content: c, region: r, clamp: true)
            if let p = prev { maxJump = max(maxJump, abs(t.x - p)) }
            prev = t.x
        }
        // Adjacent step is ~1px of smooth motion; a threshold snap would be >>5.
        #expect(maxJump < 5, "target jumped \(maxJump)px across the cover threshold")
    }

    @Test func recenterAppliesWeightOnceWhenClampInactive() {
        // When the cover clamp doesn't bind (focus near the centre), the recenter
        // must be exactly the requested weight — not weight² — so the pan tracks the
        // zoom envelope. Focus (520,500) in a full canvas, weight 0.5 → 50% toward
        // the centre (510), not 25% (515).
        let full = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let near = CGPoint(x: 520, y: 500)
        let t = StudioCompositor.recenterTarget(focus: near, weight: 0.5, scale: 1.5,
                                                content: full, region: full, clamp: true)
        #expect(abs(t.x - 510) < 0.001, "expected weight-once (510), got \(t.x)")
    }

    @Test func recenterErasesClampOffsetAsWeightFalls() {
        // The clamp offset (target − focus) must scale down with weight so it fades
        // out with the zoom — monotonically, reaching ≈0 at weight 0.
        var prevOffset: CGFloat = .infinity
        for i in stride(from: 100, through: 0, by: -1) {
            let w = CGFloat(i) / 100
            let t = StudioCompositor.recenterTarget(focus: focus, weight: w, scale: 1 + w,
                                                    content: content, region: region, clamp: true)
            let offset = hypot(t.x - focus.x, t.y - focus.y)
            #expect(offset <= prevOffset + 1, "offset grew as weight fell: \(offset) > \(prevOffset)")
            prevOffset = offset
        }
        #expect(prevOffset < 1)   // reached ≈0 at weight 0
    }
}
