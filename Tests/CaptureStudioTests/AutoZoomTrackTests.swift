import Testing
import Foundation
import CoreGraphics
@testable import CaptureStudio

@Suite struct AutoZoomTrackTests {
    private let source = CGSize(width: 1000, height: 1000)

    // A cursor that sits at x=200 until t=2, then ramps to x=800 by t=3.
    private func movingCursor() -> [CursorSample] {
        var s: [CursorSample] = []
        var t = 0.0
        while t <= 5.0 {
            let x: Double = t < 2 ? 200 : min(800, 200 + (t - 2) * 600)
            s.append(CursorSample(t: t, p: CGPoint(x: x, y: 500), cursor: "arrow"))
            t += 1.0 / 60.0
        }
        return s
    }

    private func sampleScale(_ track: [ZoomKeyframe], at t: Double) -> CGFloat {
        AutoZoomTrack.sample(at: t, track: track).scale
    }

    // MARK: - Scale ramp (unchanged behavior)

    @Test func emptyBlocksProduceEmptyTrack() {
        let track = AutoZoomTrack.build(blocks: [], cursorSamples: movingCursor(),
                                        sourceSize: source)
        #expect(track.isEmpty)
        let s = AutoZoomTrack.sample(at: 1, track: track)
        #expect(s.scale == 1)
    }

    @Test func scaleIsOneOutsideBlocks() {
        let blocks = [ZoomBlock(begin: 1, end: 3, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: movingCursor(),
                                        sourceSize: source)
        #expect(sampleScale(track, at: 0.5) == 1)   // before
        #expect(sampleScale(track, at: 4.0) == 1)   // after
    }

    @Test func scaleReachesTargetMidBlock() {
        let blocks = [ZoomBlock(begin: 0, end: 4, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: movingCursor(),
                                        sourceSize: source)
        #expect(abs(sampleScale(track, at: 2.0) - 2.0) < 0.05)
    }

    @Test func perBlockScaleOverridesGlobalDefault() {
        var cfg = AutoZoomConfig(); cfg.defaultScale = 3
        let overridden = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2)],
                                             cursorSamples: movingCursor(),
                                             sourceSize: source, config: cfg)
        let usingDefault = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: nil)],
                                               cursorSamples: movingCursor(),
                                               sourceSize: source, config: cfg)
        #expect(abs(sampleScale(overridden, at: 2.0) - 2.0) < 0.05)
        #expect(abs(sampleScale(usingDefault, at: 2.0) - 3.0) < 0.05)
    }

    // MARK: - Sensitivity-driven zoom-in/out ramp

    @Test func rampForMapsSensitivity() {
        #expect(abs(AutoZoomTrack.rampFor(0) - 0.80) < 1e-9)   // calm → long ramp
        #expect(abs(AutoZoomTrack.rampFor(1) - 0.15) < 1e-9)   // snappy → short ramp
        #expect(AutoZoomTrack.rampFor(1) < AutoZoomTrack.rampFor(0))
        #expect(abs(AutoZoomTrack.rampFor(-1) - 0.80) < 1e-9)  // clamps
        #expect(abs(AutoZoomTrack.rampFor(2) - 0.15) < 1e-9)
    }

    @Test func lowSensitivityRampsInSlowerThanHigh() {
        // Same block; shortly after it starts the low-sensitivity zoom has ramped
        // in less than the snappy one (sensitivity now drives the zoom ramp).
        let calm = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2, sensitivity: 0)],
                                       cursorSamples: movingCursor(), sourceSize: source)
        let snappy = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2, sensitivity: 1)],
                                         cursorSamples: movingCursor(), sourceSize: source)
        let sCalm = AutoZoomTrack.sample(at: 0.15, track: calm).scale
        let sSnappy = AutoZoomTrack.sample(at: 0.15, track: snappy).scale
        #expect(sSnappy > sCalm)          // snappy reaches the zoom faster
        #expect(sCalm < 2)                // calm still ramping in
    }

    // MARK: - Recenter weight (drives focus → frame-centre blend)

    @Test func weightIsZeroOutsideAndAtBlockEdges() {
        let blocks = [ZoomBlock(begin: 1, end: 3, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: movingCursor(),
                                        sourceSize: source)
        #expect(AutoZoomTrack.sample(at: 0.5, track: track).weight == 0)   // before
        #expect(AutoZoomTrack.sample(at: 4.0, track: track).weight == 0)   // after
        // At the very start/end of the block the scale is 1, so weight ≈ 0.
        #expect(AutoZoomTrack.sample(at: 1.02, track: track).weight < 0.2)
        #expect(AutoZoomTrack.sample(at: 2.98, track: track).weight < 0.2)
    }

    @Test func weightReachesOneAtFullHold() {
        let blocks = [ZoomBlock(begin: 0, end: 4, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: movingCursor(),
                                        sourceSize: source)
        // Mid-block the scale is held at target → fully recentered.
        #expect(abs(AutoZoomTrack.sample(at: 2.0, track: track).weight - 1) < 0.02)
    }

    @Test func weightTracksScaleRampIndependentOfTarget() {
        // weight is normalized (scale-1)/(target-1), so a 1.5× and a 3× block
        // both hit weight≈1 at hold even though their scales differ.
        let a = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 1.5)],
                                    cursorSamples: movingCursor(), sourceSize: source)
        let b = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 3)],
                                    cursorSamples: movingCursor(), sourceSize: source)
        #expect(abs(AutoZoomTrack.sample(at: 2.0, track: a).weight - 1) < 0.02)
        #expect(abs(AutoZoomTrack.sample(at: 2.0, track: b).weight - 1) < 0.02)
    }

    @Test func overflowFlagPropagatesFromBlock() {
        let on = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2, overflow: true)],
                                     cursorSamples: movingCursor(), sourceSize: source)
        let off = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2)],
                                      cursorSamples: movingCursor(), sourceSize: source)
        #expect(AutoZoomTrack.sample(at: 2.0, track: on).overflow == true)
        #expect(AutoZoomTrack.sample(at: 2.0, track: off).overflow == false)
        // Outside any block there is no zoom → overflow reads false.
        #expect(AutoZoomTrack.sample(at: 9.0, track: on).overflow == false)
    }

    // MARK: - tuning mapping

    @Test func tuningMapsSensitivityToFollowKnobs() {
        let lo = AutoZoomTrack.tuning(0)
        let mid = AutoZoomTrack.tuning(0.5)
        let hi = AutoZoomTrack.tuning(1)
        #expect(abs(lo.deadzone - 0.08) < 1e-9)
        #expect(abs(lo.dwell - 0.80) < 1e-9)
        #expect(abs(lo.smoothing - 0.60) < 1e-9)
        // 50% ≈ the old snappiest-calm feel (dwell 0.2s, ease 0.315s).
        #expect(abs(mid.dwell - 0.20) < 1e-9)
        #expect(abs(mid.smoothing - 0.315) < 1e-9)
        #expect(abs(hi.deadzone) < 1e-9)
        #expect(abs(hi.dwell) < 1e-9)
        #expect(abs(hi.smoothing - 0.03) < 1e-9)
        // Higher sensitivity → smaller ignore-zone, shorter delay, faster ease.
        #expect(hi.deadzone < lo.deadzone)
        #expect(hi.dwell < lo.dwell)
        #expect(hi.smoothing < lo.smoothing)
        // Clamps out-of-range input.
        #expect(abs(AutoZoomTrack.tuning(-1).dwell - 0.80) < 1e-9)
        #expect(abs(AutoZoomTrack.tuning(2).dwell) < 1e-9)
    }

    // MARK: - Settle-based follow

    @Test func focusFreezesWhileCursorStill() {
        // Cursor still at x=200 through t<2: focus should stay put.
        let blocks = [ZoomBlock(begin: 0, end: 4, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: movingCursor(),
                                        sourceSize: source)
        let a = AutoZoomTrack.sample(at: 0.8, track: track).focus.x
        let b = AutoZoomTrack.sample(at: 1.4, track: track).focus.x
        #expect(abs(a - b) < 5)
    }

    // Cursor at x=200, with a brief 300px flick to x=500 for [2, 2.1), back to 200.
    private func flickCursor() -> [CursorSample] {
        var s: [CursorSample] = []
        var t = 0.0
        while t <= 5.0 {
            let x: Double = (t >= 2 && t < 2.1) ? 500 : 200
            s.append(CursorSample(t: t, p: CGPoint(x: x, y: 500), cursor: "arrow"))
            t += 1.0 / 60.0
        }
        return s
    }

    @Test func transientFlickDoesNotPanAtLowSensitivity() {
        // A large (300px) but brief (0.1s ≪ dwell) flick never fills the settle
        // timer, so the focus holds — the reported "little/fast move still pans" bug.
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2, sensitivity: 0)],
                                        cursorSamples: flickCursor(), sourceSize: source)
        #expect(abs(AutoZoomTrack.sample(at: 2.2, track: track).focus.x - 200) < 5)
        #expect(abs(AutoZoomTrack.sample(at: 3.5, track: track).focus.x - 200) < 5)
    }

    // Cursor at x=200, then moves to x=500 at t=1 and rests there.
    private func moveAndRestCursor() -> [CursorSample] {
        var s: [CursorSample] = []
        var t = 0.0
        while t <= 5.0 {
            let x: Double = t < 1 ? 200 : 500
            s.append(CursorSample(t: t, p: CGPoint(x: x, y: 500), cursor: "arrow"))
            t += 1.0 / 60.0
        }
        return s
    }

    @Test func restingAtNewSpotPansAfterDelay() {
        // Low sensitivity: long dwell. Before it elapses the canvas holds; after,
        // the focus eases toward the rested spot (stopping within the ignore-zone).
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2, sensitivity: 0)],
                                        cursorSamples: moveAndRestCursor(), sourceSize: source)
        #expect(AutoZoomTrack.sample(at: 1.05, track: track).focus.x < 260)   // not yet (dwell)
        #expect(AutoZoomTrack.sample(at: 3.8, track: track).focus.x > 400)    // settled → eased over
    }

    @Test func highSensitivityFollowsWithoutWaiting() {
        // s=1: no dwell, no deadzone, short ease → focus tracks the moved cursor.
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2, sensitivity: 1)],
                                        cursorSamples: moveAndRestCursor(), sourceSize: source)
        #expect(AutoZoomTrack.sample(at: 1.5, track: track).focus.x > 360)
    }

    // Cursor sweeps 200 → 700 → 200 continuously over the block (never rests).
    private func sweepCursor() -> [CursorSample] {
        var s: [CursorSample] = []
        var t = 0.0
        while t <= 5.0 {
            let phase = t < 2 ? t / 2 : (4 - t) / 2       // 0 → 1 → 0 over [0, 4]
            let x = 200 + 500 * max(0, min(1, phase))
            s.append(CursorSample(t: t, p: CGPoint(x: x, y: 500), cursor: "arrow"))
            t += 1.0 / 60.0
        }
        return s
    }

    @Test func passingThroughWithoutRestingDoesNotPan() {
        // The cursor reaches x=700 at t=2 but never holds still → the settle timer
        // never fills → no pan.
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2, sensitivity: 0)],
                                        cursorSamples: sweepCursor(), sourceSize: source)
        #expect(abs(AutoZoomTrack.sample(at: 2.0, track: track).focus.x - 200) < 20)
    }

    // MARK: - Edge cases

    @Test func emptyCursorSamplesCenterFocus() {
        let blocks = [ZoomBlock(begin: 0, end: 4, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: [],
                                        sourceSize: source)
        let f = AutoZoomTrack.sample(at: 2.0, track: track).focus
        #expect(abs(f.x - 500) < 1)
        #expect(abs(f.y - 500) < 1)
    }

    @Test func focusClampedToSourceBounds() {
        // Cursor far off the right edge; focus must not exceed source width.
        let s = [CursorSample(t: 0, p: CGPoint(x: 5000, y: 500), cursor: "arrow"),
                 CursorSample(t: 4, p: CGPoint(x: 5000, y: 500), cursor: "arrow")]
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2)],
                                        cursorSamples: s, sourceSize: source)
        let f = AutoZoomTrack.sample(at: 2.0, track: track).focus
        #expect(f.x <= 1000)
        #expect(f.x >= 0)
    }

    // MARK: - Manual mode (ignores the cursor, holds a fixed target)

    @Test func manualBlockHoldsFixedTargetIgnoringCursor() {
        // Manual target at (0.7, 0.3) of source; cursor sweeps elsewhere. The focus
        // must sit on the target and never follow the cursor.
        let block = ZoomBlock(begin: 0, end: 4, scale: 2, mode: .manual,
                              focusX: 0.7, focusY: 0.3)
        let track = AutoZoomTrack.build(blocks: [block], cursorSamples: movingCursor(),
                                        sourceSize: source)
        let f = AutoZoomTrack.sample(at: 2.0, track: track).focus
        #expect(abs(f.x - 700) < 1)
        #expect(abs(f.y - 300) < 1)
        // Still fixed later, even as the cursor has moved to x=800.
        let f2 = AutoZoomTrack.sample(at: 3.5, track: track).focus
        #expect(abs(f2.x - 700) < 1)
        #expect(abs(f2.y - 300) < 1)
    }

    // MARK: - Run continuity (touching blocks hold the zoom; gaps re-zoom)

    @Test func touchingBlocksHoldZoomAcrossBoundary() {
        // Follow then manual, touching at t=2. The zoom must stay held at the seam —
        // no dip toward 1x — because the blocks form one continuous run.
        let blocks = [ZoomBlock(begin: 0, end: 2, scale: 2),
                      ZoomBlock(begin: 2, end: 4, scale: 2, mode: .manual,
                                focusX: 0.5, focusY: 0.5)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: movingCursor(),
                                        sourceSize: source)
        #expect(sampleScale(track, at: 1.9) > 1.9)
        #expect(sampleScale(track, at: 2.0) > 1.9)   // the seam
        #expect(sampleScale(track, at: 2.1) > 1.9)
    }

    @Test func gapBetweenBlocksReturnsToOne() {
        // A real gap (block1 ends at 2, block2 starts at 3) is an intentional
        // re-zoom: mid-gap the scale returns to 1x.
        let blocks = [ZoomBlock(begin: 0, end: 2, scale: 2),
                      ZoomBlock(begin: 3, end: 5, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: movingCursor(),
                                        sourceSize: source)
        #expect(abs(sampleScale(track, at: 2.5) - 1) < 0.02)
    }

    @Test func touchingBlocksBlendDifferentScalesWithoutDip() {
        // Touching blocks with different targets (2× then 3×) interpolate across the
        // seam and never dip toward 1x.
        let blocks = [ZoomBlock(begin: 0, end: 2, scale: 2),
                      ZoomBlock(begin: 2, end: 4, scale: 3)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: movingCursor(),
                                        sourceSize: source)
        #expect(abs(sampleScale(track, at: 1.0) - 2) < 0.1)   // held near first target
        #expect(abs(sampleScale(track, at: 3.2) - 3) < 0.1)   // held near second target
        let seam = sampleScale(track, at: 2.0)
        #expect(seam > 1.9)                                   // never dips to 1
        #expect(seam > 2.0 && seam < 3.0)                     // blended between targets
    }

    @Test func followToManualFocusIsContinuousAcrossBoundary() {
        // Follow settles on a resting cursor (x=200); the next manual block targets a
        // far point (x=900). At the seam the focus must not teleport — it eases from
        // where follow left it and reaches the manual target later in the block.
        let cur = (0...300).map {
            CursorSample(t: Double($0) / 60, p: CGPoint(x: 200, y: 500), cursor: "arrow")
        }
        let blocks = [ZoomBlock(begin: 0, end: 2, scale: 2, sensitivity: 1),
                      ZoomBlock(begin: 2, end: 5, scale: 2, mode: .manual,
                                focusX: 0.9, focusY: 0.5)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: cur,
                                        sourceSize: source)
        let before = AutoZoomTrack.sample(at: 1.98, track: track).focus.x
        let after = AutoZoomTrack.sample(at: 2.05, track: track).focus.x
        #expect(before < 300)               // was following the cursor near x=200
        #expect(abs(after - before) < 60)   // continuous across the seam, no teleport
        #expect(AutoZoomTrack.sample(at: 4.5, track: track).focus.x > 700)  // reaches target
    }
}
