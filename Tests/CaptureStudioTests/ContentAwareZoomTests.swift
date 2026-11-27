import Testing
import Foundation
import CoreGraphics
@testable import CaptureStudio

/// Content hints (what clicks revealed, whole-screen redraws) feeding the shot
/// planner, the track builder and the auto-zoom suggester.
@Suite struct ContentAwareZoomTests {
    private let hd = CGSize(width: 1920, height: 1080)
    // 1920×1080 viewed at 2×.
    private let half = CGSize(width: 480, height: 270)
    private let reach = CGRect(x: 480, y: 270, width: 960, height: 540)
    private let step = 1.0 / 60.0
    private var tuning: FollowTuning { ZoomShotPlanner.followTuning(0.5) }   // safe ±336 × ±189

    private func samples(end: Double, _ path: (Double) -> CGPoint) -> [CursorSample] {
        var s: [CursorSample] = []
        var k = 0
        while Double(k) / 60 <= end {
            s.append(CursorSample(t: Double(k) / 60, p: path(Double(k) / 60), cursor: "arrow"))
            k += 1
        }
        return s
    }

    private func focus(_ track: [ZoomKeyframe], _ t: Double) -> CGPoint {
        AutoZoomTrack.sample(at: t, track: track).focus
    }

    // MARK: - leanedAim

    @Test func leanStopsWhereThePointerWouldLeaveTheLeanZone() {
        let box = CGRect(x: 900, y: 500, width: 100, height: 40)
        let aim = ZoomShotPlanner.leanedAim(box: box, toward: CGPoint(x: 1500, y: 520),
                                            safeW: 336, safeH: 189, half: half)
        // The box's left edge sits 0.6 · 336 left of the aim.
        #expect(abs(aim.x - (900 + 0.6 * 336)) < 1e-6)
        #expect(abs(aim.y - 520) < 1e-6)
    }

    @Test func leanReachesANearbyTarget() {
        let box = CGRect(x: 900, y: 500, width: 100, height: 40)
        let aim = ZoomShotPlanner.leanedAim(box: box, toward: CGPoint(x: 1040, y: 560),
                                            safeW: 336, safeH: 189, half: half)
        #expect(aim == CGPoint(x: 1040, y: 560))
    }

    @Test func tinyLeanIsNotMade() {
        let box = CGRect(x: 900, y: 500, width: 100, height: 40)
        let aim = ZoomShotPlanner.leanedAim(box: box, toward: CGPoint(x: 970, y: 525),
                                            safeW: 336, safeH: 189, half: half)
        #expect(aim == CGPoint(x: 950, y: 520))
    }

    @Test func aBoxTooLargeForTheLeanZoneKeepsItsCentre() {
        // 500 wide > 2 · 0.6 · 336: no room to lean horizontally.
        let box = CGRect(x: 700, y: 500, width: 500, height: 40)
        let aim = ZoomShotPlanner.leanedAim(box: box, toward: CGPoint(x: 1500, y: 640),
                                            safeW: 336, safeH: 189, half: half)
        #expect(abs(aim.x - 950) < 1e-6)
        #expect(aim.y > 520)
    }

    // MARK: - Planner

    private func plan(_ cursor: (Double) -> CGPoint, end: Double,
                      lean: ((Double) -> CGRect?)?) -> [PlannedShot] {
        ZoomShotPlanner.shots(cursor: cursor, begin: 0, end: end, start: nil, half: half,
                              tuning: tuning, reach: reach, breaks: [], step: step, lean: lean)
    }

    @Test func shotLeansTowardContentAndHoldsThroughJitter() {
        let content = CGRect(x: 1100, y: 440, width: 200, height: 200)
        let cursor: (Double) -> CGPoint = { t in
            CGPoint(x: 960 + 5 * sin(t * 40), y: 540 + 5 * cos(t * 31))
        }
        let shots = plan(cursor, end: 8) { _ in content }
        #expect(shots.count == 1)
        guard let s = shots.first else { return }
        #expect(s.aim.x > 960 + 150 && s.aim.x < 1200 + 1)
        // The pointer never leaves the safe zone of the leaned frame.
        var t = 0.0
        while t < 8 {
            #expect(abs(Double(cursor(t).x - s.aim.x)) <= 336)
            t += step
        }
    }

    @Test func leanTargetBeyondReachIsLimitedToTheReach() {
        // Content hard against the right edge: the view centre cannot pass 1440.
        let content = CGRect(x: 1800, y: 500, width: 120, height: 80)
        let shots = plan({ _ in CGPoint(x: 1400, y: 540) }, end: 4) { _ in content }
        #expect(shots.count == 1)
        #expect(abs((shots.first?.aim.x ?? 0) - 1400) < 0.05 * 960 + 1)
    }

    @Test func noContentIsIdenticalToPointerOnlyPlanning() {
        let cursor: (Double) -> CGPoint = { t in
            CGPoint(x: 600 + 900 * (t > 3 ? 1 : 0), y: 400 + 80 * sin(t))
        }
        #expect(plan(cursor, end: 8) { _ in nil } == plan(cursor, end: 8, lean: nil))
    }

    // MARK: - Track

    @Test func trackLeansTowardARevealAndKeepsThePointerInFrame() {
        let p = CGPoint(x: 960, y: 540)
        let s = samples(end: 6) { _ in p }
        let block = [ZoomBlock(begin: 0, end: 6, scale: 2)]
        var cfg = AutoZoomConfig()
        cfg.reveals = [Reveal(t: 1.5, click: p, rect: CGRect(x: 1150, y: 450, width: 200, height: 200))]
        let leaned = AutoZoomTrack.build(blocks: block, cursorSamples: s, sourceSize: hd, config: cfg)
        let plain = AutoZoomTrack.build(blocks: block, cursorSamples: s, sourceSize: hd)
        #expect(abs(focus(plain, 3).x - 960) < 1)
        #expect(focus(leaned, 3).x > 960 + 100)
        for k in leaned {
            #expect(abs(k.focusX - 960) <= 0.92 * 480 + 1)
            #expect(abs(k.focusY - 540) <= 0.92 * 270 + 1)
        }
    }

    @Test func aRevealTooLargeForTheViewChangesNothing() {
        let p = CGPoint(x: 960, y: 540)
        let s = samples(end: 6) { t in CGPoint(x: 960 + 300 * sin(t), y: 540) }
        let block = [ZoomBlock(begin: 0, end: 6, scale: 2)]
        var cfg = AutoZoomConfig()
        cfg.reveals = [Reveal(t: 1.5, click: p, rect: CGRect(x: 200, y: 100, width: 1500, height: 800))]
        #expect(AutoZoomTrack.build(blocks: block, cursorSamples: s, sourceSize: hd, config: cfg)
                == AutoZoomTrack.build(blocks: block, cursorSamples: s, sourceSize: hd))
    }

    @Test func aRevealIsNotPairedAcrossAPictureCut() {
        let p = CGPoint(x: 960, y: 540)
        let s = samples(end: 6) { _ in p }
        var cfg = AutoZoomConfig()
        cfg.discontinuities = [1.0]
        cfg.reveals = [Reveal(t: 1.5, click: p, rect: CGRect(x: 1150, y: 450, width: 200, height: 200))]
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 6, scale: 2)],
                                        cursorSamples: s, sourceSize: hd, config: cfg)
        #expect(abs(focus(track, 0.5).x - 960) < 1)      // before the cut: other footage
        #expect(focus(track, 3).x > 960 + 100)           // after it: leans
    }

    // MARK: - Suggester

    private var config: AutoZoomSuggestConfig {
        var c = AutoZoomSuggestConfig(rampIn: 0.475, rampOut: 0.475)
        c.viewSize = hd
        return c
    }

    private func clicks(_ times: [Double], at p: CGPoint = CGPoint(x: 900, y: 500)) -> ZoomActivity {
        ZoomActivity(clicks: times.map { ClickSample(t: $0, p: p) })
    }

    private func suggest(_ activity: ZoomActivity, config: AutoZoomSuggestConfig? = nil,
                         reveals: [Reveal] = [], wide: [Double] = []) -> [ZoomBlock] {
        AutoZoomSuggester.suggest(activity: activity, cursorSamples: [], span: 0...60,
                                  sourceSize: hd, cuts: [], config: config ?? self.config,
                                  reveals: reveals, wideMoments: wide)
    }

    private func covered(_ blocks: [ZoomBlock], _ t: Double) -> Bool {
        blocks.contains { $0.begin <= t && t <= $0.end }
    }

    private func shape(_ blocks: [ZoomBlock]) -> [[Double]] {
        blocks.map { [$0.begin, $0.end, $0.scale ?? -1, $0.mode == .manual ? 1 : 0] }
    }

    @Test func wholeScreenRedrawZoomsOut() {
        let a = clicks([2, 3, 4.5, 6])
        #expect(covered(suggest(a), 5.7))
        let blocks = suggest(a, wide: [5.0])
        // Out by the end of the ramp after the redraw, and still out a second on.
        #expect(!covered(blocks, 5.6) && !covered(blocks, 6.3))
        // The zoom is still in while the click before the redraw happens.
        #expect(covered(blocks, 4.5))
        #expect(blocks.allSatisfy { $0.end <= 5.0 + 0.475 + 1e-9 || $0.begin >= 6.475 - 1e-9 })
        // The click during the wall is not lost: its block starts when the wall ends.
        #expect(blocks.count == 2)
        #expect(abs((blocks.last?.begin ?? 0) - 6.475) < 1e-6)
    }

    @Test func aClickSoonAfterARedrawStillGetsABlock() {
        let blocks = suggest(clicks([2.0, 5.9]), wide: [5.0])
        #expect(blocks.count == 2)
        #expect(covered(blocks, 2.0) && covered(blocks, 7.0))
    }

    @Test func typingThatStartsAfterARedrawDoesNotCancelIt() {
        var a = clicks([9.9])
        a.typing = [TimeSpan(begin: 11.2, end: 14)]
        let blocks = suggest(a, wide: [10.0])
        #expect(!covered(blocks, 10.6))
        #expect(covered(blocks, 12.5))
    }

    @Test func aPressedButtonDoesNotSetTheScale() {
        let p = CGPoint(x: 900, y: 500)
        let blocks = suggest(clicks([2, 3], at: p),
                             reveals: [Reveal(t: 2, click: p,
                                              rect: CGRect(x: 860, y: 462, width: 80, height: 77))])
        #expect(blocks.map(\.scale) == [nil])
    }

    @Test func redrawInsideADragIsIgnored() {
        var a = clicks([2])
        a.drags = [TimeSpan(begin: 4, end: 7)]
        #expect(covered(suggest(a, wide: [5.0]), 5.6))
    }

    @Test func runScaleFitsWhatWasRevealed() {
        let p = CGPoint(x: 900, y: 500)
        let a = clicks([2, 3], at: p)
        func scales(_ rect: CGRect) -> [Double?] {
            suggest(a, reveals: [Reveal(t: 2, click: p, rect: rect)]).map(\.scale)
        }
        // Small menu: fit would be 1080 / 260 = 4.15 → capped.
        #expect(scales(CGRect(x: 850, y: 450, width: 200, height: 200)) == [3.0])
        // Panel: min(1920 / 780, 1080 / 650) = 1.66 → 1.65.
        #expect(scales(CGRect(x: 600, y: 300, width: 600, height: 500)) == [1.65])
        // Most of the screen: floor.
        #expect(scales(CGRect(x: 100, y: 100, width: 1700, height: 900)) == [1.5])
        // The click is part of the subject: a small box far from it fits less.
        #expect(scales(CGRect(x: 1650, y: 900, width: 200, height: 150)) == [1.5])
    }

    @Test func allBlocksOfARunShareTheScale() {
        let p = CGPoint(x: 900, y: 500)
        var a = clicks([2], at: p)
        a.typing = [TimeSpan(begin: 3, end: 6)]
        let blocks = suggest(a, reveals: [Reveal(t: 2, click: p,
                                                 rect: CGRect(x: 850, y: 450, width: 200, height: 200))])
        #expect(blocks.count >= 2)
        #expect(blocks.contains { $0.mode == .manual })
        #expect(blocks.allSatisfy { $0.scale == 3.0 })
    }

    @Test func noRevealsLeavesTheScaleUnset() {
        let a = clicks([2, 3, 20])
        #expect(suggest(a).allSatisfy { $0.scale == nil })
        // A reveal in one run does not touch another run.
        let p = CGPoint(x: 900, y: 500)
        let blocks = suggest(a, reveals: [Reveal(t: 20, click: p,
                                                 rect: CGRect(x: 850, y: 450, width: 200, height: 200))])
        #expect(blocks.map(\.scale) == [nil, 3.0])
    }

    @Test func withoutHintsTheResultIsThePointerOnlyResult() {
        var a = clicks([2, 3, 9, 15.5])
        a.drags = [TimeSpan(begin: 20, end: 22)]
        a.typing = [TimeSpan(begin: 30, end: 34)]
        let plain = AutoZoomSuggester.suggest(
            activity: a, cursorSamples: [], span: 0...60, sourceSize: hd, cuts: [],
            config: AutoZoomSuggestConfig(rampIn: 0.475, rampOut: 0.475))
        #expect(shape(suggest(a)) == shape(plain))
        // No view size: reveals cannot set a scale.
        let p = CGPoint(x: 900, y: 500)
        let noView = suggest(a, config: AutoZoomSuggestConfig(rampIn: 0.475, rampOut: 0.475),
                             reveals: [Reveal(t: 2, click: p,
                                              rect: CGRect(x: 850, y: 450, width: 200, height: 200))])
        #expect(shape(noView) == shape(plain))
    }

    @Test func revealInsideACutIsDropped() {
        let p = CGPoint(x: 900, y: 500)
        let a = clicks([2, 3], at: p)
        let blocks = AutoZoomSuggester.suggest(
            activity: a, cursorSamples: [], span: 0...60, sourceSize: hd, cuts: [10..<20],
            config: config,
            reveals: [Reveal(t: 15, click: p, rect: CGRect(x: 850, y: 450, width: 200, height: 200))])
        #expect(blocks.allSatisfy { $0.scale == nil })
    }

    // MARK: - Merge

    @Test func blockScopeKeepsAUserScaleButLetsAGeneratedOneThrough() {
        let custom = ZoomBlock(begin: 5, end: 9, scale: 2.4)
        let unset = ZoomBlock(begin: 5, end: 9)
        let g = ZoomBlock(begin: 6, end: 8, scale: 3.0)
        #expect(AutoZoomSuggester.merge(existing: [custom], generated: [g],
                                        scope: .block(custom.id)).first?.scale == 2.4)
        #expect(AutoZoomSuggester.merge(existing: [unset], generated: [g],
                                        scope: .block(unset.id)).first?.scale == 3.0)
    }
}
