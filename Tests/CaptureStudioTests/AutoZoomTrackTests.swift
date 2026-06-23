import Testing
import Foundation
import CoreGraphics
@testable import CaptureStudio

@Suite struct AutoZoomTrackTests {
    private let source = CGSize(width: 1000, height: 1000)

    // A cursor that sits at x=200 until t=2, then jumps to x=800 by t=3.
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
        // Mid-block, past the entry ramp: full target scale.
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

    @Test func focusAnticipatesUpcomingMovement() {
        // Lead should pull focus toward the upcoming x=800 before t=2 (when the
        // cursor is still physically at x=200). Max sensitivity = snappy + tiny
        // deadzone, so the drift is clearly visible.
        var cfg = AutoZoomConfig(); cfg.lead = 0.4; cfg.defaultSensitivity = 1.0
        let blocks = [ZoomBlock(begin: 0, end: 4, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: movingCursor(),
                                        sourceSize: source, config: cfg)
        let focusJustBeforeMove = AutoZoomTrack.sample(at: 1.95, track: track).focus.x
        let focusAtStart = AutoZoomTrack.sample(at: 0.5, track: track).focus.x
        #expect(focusJustBeforeMove > focusAtStart + 1)   // already drifting toward 800
    }

    @Test func focusFreezesWhileCursorStill() {
        // From t=0 to ~1.5 the cursor is still (x=200): focus should be ~constant.
        let blocks = [ZoomBlock(begin: 0, end: 4, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: movingCursor(),
                                        sourceSize: source)
        let a = AutoZoomTrack.sample(at: 0.8, track: track).focus.x
        let b = AutoZoomTrack.sample(at: 1.4, track: track).focus.x
        #expect(abs(a - b) < 5)
    }

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

    @Test func tuningEndpointsClampAndMonotonic() {
        let lo = AutoZoomTrack.tuning(0)
        let hi = AutoZoomTrack.tuning(1)
        #expect(abs(lo.idleSpeed - 200) < 1e-9)
        #expect(abs(lo.smoothing - 0.30) < 1e-9)
        #expect(abs(hi.idleSpeed - 10) < 1e-9)
        #expect(abs(hi.smoothing - 0.05) < 1e-9)
        // Higher sensitivity → smaller deadzone and less lag.
        #expect(hi.idleSpeed < lo.idleSpeed)
        #expect(hi.smoothing < lo.smoothing)
        // Clamps out-of-range input.
        #expect(AutoZoomTrack.tuning(-1).idleSpeed == 200)
        #expect(AutoZoomTrack.tuning(2).idleSpeed == 10)
    }

    // Cursor drifts slowly: 200 → 260 over 4s ≈ 15 px/s.
    private func slowDriftCursor() -> [CursorSample] {
        var s: [CursorSample] = []
        var t = 0.0
        while t <= 5.0 {
            let x = 200 + min(60, t * 15)
            s.append(CursorSample(t: t, p: CGPoint(x: x, y: 500), cursor: "arrow"))
            t += 1.0 / 60.0
        }
        return s
    }

    @Test func lowSensitivityIgnoresSlowMoveHighFollows() {
        let cursor = slowDriftCursor()
        // s=0 → deadzone 200 px/s, well above the 15 px/s drift → frozen.
        let low = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2, sensitivity: 0)],
                                      cursorSamples: cursor, sourceSize: source)
        // s=1 → deadzone 10 px/s, below the drift → follows.
        let high = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2, sensitivity: 1)],
                                       cursorSamples: cursor, sourceSize: source)
        let lowFocus = AutoZoomTrack.sample(at: 3.0, track: low).focus.x
        let highFocus = AutoZoomTrack.sample(at: 3.0, track: high).focus.x
        #expect(lowFocus < 215)               // stayed near start (ignored slow drift)
        #expect(highFocus > lowFocus + 10)    // followed the drift
    }

    @Test func perBlockSensitivityOverridesDefault() {
        let cursor = slowDriftCursor()
        var cfg = AutoZoomConfig(); cfg.defaultSensitivity = 0   // global = calm
        // Per-block override to snappy should follow despite the calm default.
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2, sensitivity: 1)],
                                        cursorSamples: cursor, sourceSize: source, config: cfg)
        #expect(AutoZoomTrack.sample(at: 3.0, track: track).focus.x > 215)
    }
}
