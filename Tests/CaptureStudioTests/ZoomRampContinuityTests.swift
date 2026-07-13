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
        var maxJump = 0.0, atScale = 0.0
        var s = 1.30
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

    @Test func recenterErasesClampOffsetAsWeightFalls() {
        // The clamp offset (target − focus) must scale down with weight so it fades
        // out with the zoom — monotonically, reaching ≈0 at weight 0.
        var prevOffset = Double.infinity
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
