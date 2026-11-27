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

    // MARK: - Shot-based follow (1920×1080 source)

    private let hd = CGSize(width: 1920, height: 1080)

    /// 60 Hz samples of `path` over `[0, end]`, optionally offset so they are not
    /// aligned to the keyframe step.
    private func samples(end: Double, offset: Double = 0,
                         _ path: (Double) -> CGPoint) -> [CursorSample] {
        var s: [CursorSample] = []
        var k = 0
        while Double(k) / 60 + offset <= end {
            let t = Double(k) / 60 + offset
            s.append(CursorSample(t: t, p: path(t), cursor: "arrow"))
            k += 1
        }
        return s
    }

    /// Rest at `a` until `at`, fly for `flight` seconds, rest at `b`.
    private func hop(from a: CGPoint, to b: CGPoint, at: Double, flight: Double = 0.2)
        -> (Double) -> CGPoint {
        { t in
            let f = min(max((t - at) / flight, 0), 1)
            return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
        }
    }

    private func focus(_ track: [ZoomKeyframe], _ t: Double) -> CGPoint {
        AutoZoomTrack.sample(at: t, track: track).focus
    }

    private func close(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat = 1) -> Bool {
        abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol
    }

    @Test func focusConstantWhileCursorInsideSafeZone() {
        let s = samples(end: 6) { t in CGPoint(x: 900 + 80 * sin(t * 2), y: 500 + 40 * cos(t * 3)) }
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 6, scale: 2)],
                                        cursorSamples: s, sourceSize: hd)
        #expect(close(focus(track, 1), focus(track, 5), 0.01))
    }

    @Test func relocationMovesOnceAndStartsBeforeExit() {
        let a = CGPoint(x: 600, y: 400), b = CGPoint(x: 1300, y: 700)
        let s = samples(end: 6, hop(from: a, to: b, at: 2))
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 6, scale: 2)],
                                        cursorSamples: s, sourceSize: hd)
        #expect(close(focus(track, 1.0), focus(track, 1.5), 0.01))   // holding
        #expect(close(focus(track, 4), b, 3))                         // landed on the new spot
        #expect(close(focus(track, 4), focus(track, 5), 0.01))        // and holds there
        // Anticipation: by the time the cursor is mid-flight the camera is under way.
        #expect(focus(track, 2.1).x > focus(track, 1.0).x + 20)
    }

    @Test func cursorInsideHardMarginWhileHolding() {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        let half = CGSize(width: 480, height: 270)
        for _ in 0..<5 {
            // Rest ~2 s, jump, rest… between random points.
            var points: [CGPoint] = []
            for _ in 0..<8 { points.append(CGPoint(x: 100 + rnd() * 1720, y: 80 + rnd() * 920)) }
            let path: (Double) -> CGPoint = { t in
                let i = min(Int(t / 2), points.count - 2)
                let f = min(max((t - Double(i) * 2 - 1.8) / 0.2, 0), 1)
                return CGPoint(x: points[i].x + (points[i + 1].x - points[i].x) * f,
                               y: points[i].y + (points[i + 1].y - points[i].y) * f)
            }
            let s = samples(end: 14, path)
            let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 14, scale: 2)],
                                            cursorSamples: s, sourceSize: hd)
            for i in 0..<(track.count - 1) where track[i].weight == 1 {
                let k = track[i], n = track[i + 1]
                guard k.focusX == n.focusX, k.focusY == n.focusY else { continue }  // moving
                let c = path(k.t)
                // Skip an axis pinned at the reach limit (the view is at the edge there).
                if k.focusX > 480.5 && k.focusX < 1439.5 {
                    #expect(abs(c.x - k.focusX) <= 0.92 * half.width + 1)
                }
                if k.focusY > 270.5 && k.focusY < 809.5 {
                    #expect(abs(c.y - k.focusY) <= 0.92 * half.height + 1)
                }
            }
        }
    }

    @Test func restingCursorStaysInFrameUntilItLeaves() {
        // 4× (half 240×135): a 1400 px hop. The camera must not leave so early
        // that the still-resting cursor (the moment of a click) falls out of frame.
        let path = hop(from: CGPoint(x: 300, y: 540), to: CGPoint(x: 1700, y: 540), at: 3,
                       flight: 0.25)
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 8, scale: 4)],
                                        cursorSamples: samples(end: 8, path), sourceSize: hd)
        for k in track where k.t <= 3 {
            #expect(abs(path(k.t).x - k.focusX) <= 0.92 * 240 + 1)
        }
    }

    @Test func longHopDipsScaleAndRecovers() {
        let path = hop(from: CGPoint(x: 300, y: 540), to: CGPoint(x: 1700, y: 540), at: 3,
                       flight: 0.25)
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 8, scale: 4)],
                                        cursorSamples: samples(end: 8, path), sourceSize: hd)
        let during = track.filter { $0.t > 2 && $0.t < 5.5 }.map(\.scale)
        #expect((during.min() ?? 9) < 3.0)
        #expect((during.min() ?? 0) >= 1.1)
        #expect(abs(sampleScale(track, at: 2.0) - 4) < 0.02)
        #expect(abs(sampleScale(track, at: 5.5) - 4) < 0.02)
    }

    @Test func shortHopDoesNotDip() {
        let path = hop(from: CGPoint(x: 800, y: 540), to: CGPoint(x: 1100, y: 540), at: 3)
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 8, scale: 2)],
                                        cursorSamples: samples(end: 8, path), sourceSize: hd)
        for k in track where k.t > 1.5 && k.t < 6.5 { #expect(abs(k.scale - 2) < 0.01) }
    }

    @Test func fullWidthHopAtTwoTimesDoesNotDip() {
        let path = hop(from: CGPoint(x: 200, y: 540), to: CGPoint(x: 1800, y: 540), at: 3)
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 8, scale: 2)],
                                        cursorSamples: samples(end: 8, path), sourceSize: hd)
        for k in track where k.t > 1.5 && k.t < 6.5 { #expect(abs(k.scale - 2) < 0.01) }
    }

    @Test func containedCentreStaysInReach() {
        let s = samples(end: 4) { _ in CGPoint(x: 1900, y: 1060) }
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2)],
                                        cursorSamples: s, sourceSize: hd)
        #expect(close(focus(track, 2), CGPoint(x: 1440, y: 810)))
    }

    @Test func offsetContentRectBoundsFocus() {
        var cfg = AutoZoomConfig()
        cfg.contentRect = CGRect(x: 400, y: 0, width: 1120, height: 1080)
        cfg.viewSize = CGSize(width: 1120, height: 1080)
        for x in [0.0, 1900.0] {
            let s = samples(end: 4) { _ in CGPoint(x: x, y: 540) }
            let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2)],
                                            cursorSamples: s, sourceSize: hd, config: cfg)
            let f = focus(track, 2)
            #expect(f.x >= 680 - 0.01 && f.x <= 1240 + 0.01)
        }
    }

    @Test func framingWindowCanPanAcrossWholeContent() {
        // A half-size framing window sees 960×540 source px at 1×, but the picture
        // behind it can still pan across the whole source.
        var cfg = AutoZoomConfig()
        cfg.viewSize = CGSize(width: 960, height: 540)
        let s = samples(end: 4) { _ in CGPoint(x: 1800, y: 1000) }
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2)],
                                        cursorSamples: s, sourceSize: hd, config: cfg)
        #expect(close(focus(track, 2), CGPoint(x: 1680, y: 945), 2))
    }

    @Test func letterboxAxisNeverPans() {
        // 16:9 source fitted in a 9:16 canvas: at 2× the view is still taller than
        // the source, so the picture cannot pan vertically — plan nothing there.
        var cfg = AutoZoomConfig()
        cfg.viewSize = CGSize(width: 1920, height: 3413)
        let s = samples(end: 10) { t in CGPoint(x: 960, y: Int(t / 2) % 2 == 0 ? 60 : 1020) }
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 10, scale: 2)],
                                        cursorSamples: s, sourceSize: hd, config: cfg)
        for k in track where k.t > 1 && k.t < 9 {
            #expect(abs(k.focusY - 540) < 0.01)
            #expect(abs(k.scale - 2) < 0.01)
        }
    }

    @Test func cursorOutsideContentRectDoesNotPullPastEdge() {
        var cfg = AutoZoomConfig()
        cfg.contentRect = CGRect(x: 400, y: 0, width: 1120, height: 1080)
        cfg.viewSize = CGSize(width: 1120, height: 1080)
        let s = samples(end: 6, hop(from: CGPoint(x: 900, y: 540), to: CGPoint(x: 5000, y: 540),
                                    at: 2))
        let track = AutoZoomTrack.build(
            blocks: [ZoomBlock(begin: 0, end: 6, scale: 2, overflow: false)],
            cursorSamples: s, sourceSize: hd, config: cfg)
        #expect(focus(track, 5).x <= 1240 + 0.01)
    }

    @Test func followBlockWithoutSamplesCentresOnContent() {
        var cfg = AutoZoomConfig()
        cfg.contentRect = CGRect(x: 400, y: 100, width: 1000, height: 800)
        cfg.viewSize = CGSize(width: 1000, height: 800)
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2)],
                                        cursorSamples: [], sourceSize: hd, config: cfg)
        let f = focus(track, 2)
        #expect(f.x.isFinite && f.y.isFinite)
        #expect(close(f, CGPoint(x: 900, y: 500), 0.01))
    }

    @Test func noDriftAcrossFollowBlocksOfDifferentScale() {
        // Cursor parked near the right edge: each block shows its own reach limit.
        // A change of centre without a move would offset everything after it.
        let s = samples(end: 8) { _ in CGPoint(x: 1700, y: 540) }
        let blocks = [ZoomBlock(begin: 0, end: 4, scale: 3), ZoomBlock(begin: 4, end: 8, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: s, sourceSize: hd)
        #expect(abs(focus(track, 2).x - 1600) < 1)
        #expect(abs(focus(track, 7).x - 1440) < 1)
    }

    @Test func manualWithoutTargetHoldsIncomingCentre() {
        let s = samples(end: 9) { _ in CGPoint(x: 700, y: 500) }
        let blocks = [ZoomBlock(begin: 0, end: 3, scale: 2),
                      ZoomBlock(begin: 3, end: 6, scale: 2, mode: .manual),
                      ZoomBlock(begin: 6, end: 9, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: s, sourceSize: hd)
        for t in [1.0, 2.9, 3.1, 4.5, 5.9, 6.1, 8.0] {
            #expect(close(focus(track, t), CGPoint(x: 700, y: 500), 0.01))
        }
    }

    @Test func manualSeamMovesStayInsideManualBlock() {
        let s = samples(end: 9) { _ in CGPoint(x: 600, y: 400) }
        let blocks = [ZoomBlock(begin: 0, end: 3, scale: 2),
                      ZoomBlock(begin: 3, end: 6, scale: 2, mode: .manual,
                                focusX: 0.6, focusY: 0.6),
                      ZoomBlock(begin: 6, end: 9, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: s, sourceSize: hd)
        let rest = focus(track, 1)
        #expect(close(focus(track, 2.99), rest, 0.01))                    // follow untouched
        #expect(close(focus(track, 4.5), CGPoint(x: 1152, y: 648), 0.5))  // on the target
        #expect(close(focus(track, 6.02), rest, 0.5))                     // back by the seam
        #expect(close(focus(track, 8), rest, 0.01))
    }

    @Test func shortManualBlockStillReachesTarget() {
        let s = samples(end: 6) { _ in CGPoint(x: 600, y: 400) }
        let blocks = [ZoomBlock(begin: 0, end: 3, scale: 2),
                      ZoomBlock(begin: 3, end: 3.3, scale: 2, mode: .manual,
                                focusX: 0.6, focusY: 0.6),
                      ZoomBlock(begin: 3.3, end: 6, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: s, sourceSize: hd)
        #expect(close(focus(track, 3.15), CGPoint(x: 1152, y: 648), 2))
        #expect(close(focus(track, 2.99), focus(track, 1), 0.01))
        #expect(close(focus(track, 3.32), focus(track, 5), 2))
    }

    @Test func discontinuityStepsFocusInstantly() {
        // Samples deliberately not aligned to the keyframe step: interpolating
        // across the cut would invent a midpoint, a glide and a dip.
        let s = samples(end: 5, offset: 0.007) { t in
            t < 2 ? CGPoint(x: 600, y: 400) : CGPoint(x: 1300, y: 700)
        }
        var cfg = AutoZoomConfig()
        cfg.discontinuities = [2]
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 5, scale: 2)],
                                        cursorSamples: s, sourceSize: hd, config: cfg)
        let step = 1.0 / 60
        #expect(abs(focus(track, 2 + step).x - focus(track, 2 - step).x) > 200)
        #expect(close(focus(track, 1.5), focus(track, 2 - step), 0.01))
        #expect(close(focus(track, 2 + step), focus(track, 3), 0.01))
        for k in track where k.t >= 1.5 && k.t <= 3 { #expect(abs(k.scale - 2) < 0.001) }
    }

    @Test func trackContinuousAcrossBlocksInRun() {
        let s = samples(end: 9, hop(from: CGPoint(x: 500, y: 400), to: CGPoint(x: 1400, y: 700),
                                    at: 4.4))
        let blocks = [ZoomBlock(begin: 0, end: 3, scale: 2),
                      ZoomBlock(begin: 3, end: 6, scale: 2.5, sensitivity: 0.9),
                      ZoomBlock(begin: 6, end: 9, scale: 2, mode: .manual,
                                focusX: 0.3, focusY: 0.3)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: s, sourceSize: hd)
        for i in 0..<(track.count - 1) {
            #expect(abs(track[i + 1].focusX - track[i].focusX) < 40)
            #expect(abs(track[i + 1].focusY - track[i].focusY) < 40)
        }
    }

    @Test func viewSizeHelper() {
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(AutoZoomTrack.viewSize(sourceRect: full, placedAt: full,
                                       region: CGRect(x: 480, y: 0, width: 960, height: 1080))
                == CGSize(width: 960, height: 1080))
        #expect(AutoZoomTrack.viewSize(sourceRect: CGRect(x: 200, y: 100, width: 1000, height: 800),
                                       placedAt: CGRect(x: 0, y: 0, width: 500, height: 400),
                                       region: CGRect(x: 0, y: 0, width: 250, height: 400))
                == CGSize(width: 500, height: 800))
        let letterbox = AutoZoomTrack.viewSize(
            sourceRect: full, placedAt: CGRect(x: 0, y: 656.25, width: 1080, height: 607.5),
            region: CGRect(x: 0, y: 0, width: 1080, height: 1920))
        #expect(abs(letterbox.width - 1920) < 0.01)
        #expect(abs(letterbox.height - 3413.33) < 0.01)
    }

    @Test func collapsedCutTimesMapEachCutStart() {
        #expect(AutoZoomTrack.collapsedCutTimes([2..<3, 5..<7]) == [2, 4])
        #expect(AutoZoomTrack.collapsedCutTimes([0..<1]) == [])
        #expect(AutoZoomTrack.collapsedCutTimes([]) == [])
    }

    @Test func dipNeverReachesScaleOneAcrossSeamOrRamp() {
        // A corner-to-corner hop late in a 4× block dips hard and runs past the
        // seam into a 1.2× block; another hop sits inside the run's ramp-out.
        // Scale 1 with a non-zero weight would un-recentre the frame (a snap).
        let path: (Double) -> CGPoint = { t in
            if t < 3.6 { return CGPoint(x: 200, y: 150) }
            if t < 7.5 { return CGPoint(x: 1750, y: 950) }
            return CGPoint(x: 200, y: 150)
        }
        let blocks = [ZoomBlock(begin: 0, end: 4, scale: 4, overflow: true),
                      ZoomBlock(begin: 4, end: 8, scale: 1.2, overflow: true)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: samples(end: 8, path),
                                        sourceSize: hd)
        for k in track where k.weight > 0.999 { #expect(k.scale >= 1.1 - 1e-9) }
        for k in track where k.weight > 0 { #expect(k.scale > 1) }
    }

    @Test func cutOnBlockBoundaryCutsTheCamera() {
        // Two follow blocks either side of a removed range collapse to touch at
        // t = 4, with the cursor somewhere else entirely after the cut.
        let s = samples(end: 8, offset: 0.007) { t in
            t < 4 ? CGPoint(x: 600, y: 400) : CGPoint(x: 1300, y: 700)
        }
        var cfg = AutoZoomConfig()
        cfg.discontinuities = [4]
        let blocks = [ZoomBlock(begin: 0, end: 4, scale: 2), ZoomBlock(begin: 4, end: 8, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: s, sourceSize: hd,
                                        config: cfg)
        #expect(close(focus(track, 3.9), CGPoint(x: 600, y: 400), 1))
        #expect(close(focus(track, 4.05), CGPoint(x: 1300, y: 700), 1))   // no glide
        #expect(close(focus(track, 6), CGPoint(x: 1300, y: 700), 1))
    }

    @Test func cutBetweenKeyframesIsNotBlended() {
        // The cut falls between two 60 Hz keyframes: a frame sampled just before
        // it must show the old framing and one just after it the new one.
        let s = samples(end: 5, offset: 0.003) { t in
            t < 2.005 ? CGPoint(x: 600, y: 400) : CGPoint(x: 1300, y: 700)
        }
        var cfg = AutoZoomConfig()
        cfg.discontinuities = [2.005]
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 5, scale: 2)],
                                        cursorSamples: s, sourceSize: hd, config: cfg)
        #expect(close(focus(track, 2.0045), CGPoint(x: 600, y: 400), 1))
        #expect(close(focus(track, 2.0055), CGPoint(x: 1300, y: 700), 1))
        for i in 1..<track.count { #expect(track[i].t > track[i - 1].t) }
    }

    @Test func followMoveDoesNotReachIntoManualBlock() {
        // The cursor leaves 0.1 s before the follow block ends; its move must not
        // run on into the manual block, and a later follow move must not start
        // back inside it.
        let path: (Double) -> CGPoint = { t in
            if t < 2.9 { return CGPoint(x: 600, y: 400) }
            if t < 6.1 { return CGPoint(x: 1400, y: 760) }
            return CGPoint(x: 620, y: 420)
        }
        let blocks = [ZoomBlock(begin: 0, end: 3, scale: 2),
                      ZoomBlock(begin: 3, end: 6, scale: 2, mode: .manual,
                                focusX: 0.5, focusY: 0.5),
                      ZoomBlock(begin: 6, end: 6.2, scale: 2),
                      ZoomBlock(begin: 6.2, end: 10, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: samples(end: 10, path),
                                        sourceSize: hd)
        // Once the entering move is done the manual block sits exactly on its
        // target until its leaving move starts.
        #expect(close(focus(track, 4.5), CGPoint(x: 960, y: 540), 0.5))
        #expect(close(focus(track, 5.0), CGPoint(x: 960, y: 540), 0.5))
    }
}
