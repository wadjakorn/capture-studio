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

    // MARK: - tuning mapping

    @Test func tuningEndpointsClampAndMonotonic() {
        let lo = AutoZoomTrack.tuning(0)
        let hi = AutoZoomTrack.tuning(1)
        #expect(abs(lo.deadzone - 0.10) < 1e-9)
        #expect(abs(lo.dwell - 0.6) < 1e-9)
        #expect(abs(lo.smoothing - 0.30) < 1e-9)
        #expect(abs(hi.deadzone - 0.0) < 1e-9)
        #expect(abs(hi.dwell - 0.0) < 1e-9)
        #expect(abs(hi.smoothing - 0.05) < 1e-9)
        // Higher sensitivity → smaller ignore-zone, shorter delay, less lag.
        #expect(hi.deadzone < lo.deadzone)
        #expect(hi.dwell < lo.dwell)
        #expect(hi.smoothing < lo.smoothing)
        // Clamps out-of-range input.
        #expect(AutoZoomTrack.tuning(-1).deadzone == 0.10)
        #expect(AutoZoomTrack.tuning(2).deadzone == 0.0)
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
        // A large (300px > deadzone) but brief (0.1s < dwell) flick must be
        // ignored — this is the reported "little/fast move still pans" bug.
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

    @Test func restingAtNewSpotPansAfterDwell() {
        // Low sensitivity: dwell ~0.6s. Before the dwell elapses the canvas holds;
        // after it, the canvas gently pans toward the rested spot.
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2, sensitivity: 0)],
                                        cursorSamples: moveAndRestCursor(), sourceSize: source)
        #expect(AutoZoomTrack.sample(at: 1.2, track: track).focus.x < 260)   // not yet
        #expect(AutoZoomTrack.sample(at: 3.8, track: track).focus.x > 360)   // settled → panned
    }

    @Test func highSensitivityFollowsWithoutWaiting() {
        // s=1: no dwell, no deadzone → focus tracks the moved cursor quickly.
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
        // The cursor reaches x=700 at t=2 but never holds still → no pan.
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
}
