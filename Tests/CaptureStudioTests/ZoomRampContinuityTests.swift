import Testing
import Foundation
import CoreGraphics
@testable import CaptureStudio

/// Reproduces the reported "position jump in the first/last second" of a follow
/// zoom block with Overflow inside frame OFF. Composes the on-screen position of
/// the source centre exactly the way `CameraCompositor` does (recenter, clamped
/// when overflow is off, then magnify) and walks it densely across the block,
/// asserting the framing never jumps between adjacent frames.
@Suite struct ZoomRampContinuityTests {
    private let source = CGSize(width: 1000, height: 1000)

    /// Cursor parked near the right edge for the whole clip (a stationary, edge-
    /// offset pan — the worst case for the clamp).
    private func edgeCursor(x: Double = 900) -> [CursorSample] {
        (0...360).map { CursorSample(t: Double($0) / 60, p: CGPoint(x: x, y: 500), cursor: "arrow") }
    }

    /// On-screen position of the content centre for a sampled zoom state, modelling
    /// `CameraCompositor.magnify`'s `scale <= 1.0001` early-return: below the
    /// threshold the frame is drawn at its natural placement (content centre),
    /// above it the recenter+magnify maps out(p) = target + scale·(p − focus).
    private func outputCentre(_ s: (scale: CGFloat, focus: CGPoint, weight: CGFloat, overflow: Bool),
                              region: CGRect, content: CGRect) -> CGPoint {
        let c = CGPoint(x: content.midX, y: content.midY)
        guard s.scale > 1.0001 else { return c }        // magnify early-return: raw frame
        let target = StudioCompositor.recenterTarget(focus: s.focus, weight: s.weight,
                                                     scale: s.scale, content: content,
                                                     region: region, clamp: !s.overflow)
        return CGPoint(x: target.x + s.scale * (c.x - s.focus.x),
                       y: target.y + s.scale * (c.y - s.focus.y))
    }

    /// Largest adjacent-frame move of the composed centre across the block, and
    /// when it happens.
    private func maxAdjacentJump(overflow: Bool, region: CGRect, content: CGRect) -> (px: Double, t: Double) {
        let block = ZoomBlock(begin: 0.5, end: 3.5, scale: 2, sensitivity: 1, overflow: overflow)
        let track = AutoZoomTrack.build(blocks: [block], cursorSamples: edgeCursor(),
                                        sourceSize: source)
        return scanJump(track: track, region: region, content: content)
    }

    /// Walk the composed centre densely from BEFORE the block to AFTER it (so the
    /// identity→ramp and ramp→identity boundaries are included) and return the
    /// largest adjacent-frame move.
    private func scanJump(track: [ZoomKeyframe], region: CGRect, content: CGRect) -> (px: Double, t: Double) {
        var prev: CGPoint?
        var maxJump = 0.0, at = 0.0
        var t = 0.3
        while t <= 3.7 {
            let o = outputCentre(AutoZoomTrack.sample(at: t, track: track),
                                 region: region, content: content)
            if let p = prev {
                let d = hypot(o.x - p.x, o.y - p.y)
                if d > maxJump { maxJump = d; at = t }
            }
            prev = o
            t += 1.0 / 120.0
        }
        return (maxJump, at)
    }

    @Test func followRampNoJumpWithFrameOverflowOff() {
        let content = CGRect(origin: .zero, size: source)
        let region = CGRect(x: 200, y: 200, width: 600, height: 600)
        let j = maxAdjacentJump(overflow: false, region: region, content: content)
        // A smooth ramp moves the centre a few px per 1/120s frame; a jump is >>25.
        #expect(j.px < 25, "position jump \(j.px)px at t=\(j.t)")
    }

    @Test func followRampNoJumpNoFrameOverflowOff() {
        // No framing window (region == content == full canvas).
        let full = CGRect(origin: .zero, size: source)
        let j = maxAdjacentJump(overflow: false, region: full, content: full)
        #expect(j.px < 25, "position jump \(j.px)px at t=\(j.t)")
    }

    @Test func followRampNoJumpFitContentNarrowerThanFrame() {
        // Letterbox/fit: the fitted content is NARROWER than the framing window, so
        // at 1× the clamp band inverts (can't cover) and the ramp CROSSES the
        // covering threshold as it zooms in — the spot the midpoint fallback must
        // stay continuous through. Cursor centred in the content.
        let content = CGRect(x: 300, y: 0, width: 400, height: 1000)
        let region = CGRect(x: 200, y: 200, width: 600, height: 600)
        let j = maxAdjacentJump(overflow: false, region: region, content: content)
        #expect(j.px < 25, "position jump \(j.px)px at t=\(j.t)")
    }

    @Test func followRampNoJumpOffCentreFrame() {
        let content = CGRect(origin: .zero, size: source)
        let region = CGRect(x: 550, y: 550, width: 400, height: 400)   // toward the corner
        let j = maxAdjacentJump(overflow: false, region: region, content: content)
        #expect(j.px < 25, "position jump \(j.px)px at t=\(j.t)")
    }

    @Test func followRampNoJumpMovingCursorDefaultSensitivity() {
        // Default sensitivity (dwell + deadzone active) with the cursor drifting
        // toward the edge during the ramp — exercises the focus settle/ease path.
        let cur: [CursorSample] = (0...360).map {
            let t = Double($0) / 60
            let x = 500 + min(400, t * 130)   // drifts right, rests near the edge
            return CursorSample(t: t, p: CGPoint(x: x, y: 500), cursor: "arrow")
        }
        let block = ZoomBlock(begin: 0.5, end: 3.5, scale: 2, overflow: false)
        let track = AutoZoomTrack.build(blocks: [block], cursorSamples: cur, sourceSize: source)
        let content = CGRect(origin: .zero, size: source)
        let region = CGRect(x: 200, y: 200, width: 600, height: 600)
        let j = scanJump(track: track, region: region, content: content)
        #expect(j.px < 25, "position jump \(j.px)px at t=\(j.t)")
    }
}
