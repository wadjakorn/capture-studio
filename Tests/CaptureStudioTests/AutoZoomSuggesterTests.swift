import Testing
import Foundation
import CoreGraphics
@testable import CaptureStudio

@Suite struct ZoomActivityTests {
    private let source = CGSize(width: 1920, height: 1080)
    // Points == pixels, origin 0.
    private let display = DisplayInfo(displayID: 1, pixelWidth: 1920, pixelHeight: 1080,
                                      pointWidth: 1920, pointHeight: 1080,
                                      scaleFactor: 1, originX: 0, originY: 0)

    private func ev(_ t: Double, _ kind: EventLine.Kind, x: Double = 500, y: Double = 500,
                    mods: [String]? = nil) -> EventLine {
        EventLine(t: t, e: kind, x: x, y: y, mods: mods)
    }

    private func activity(_ events: [EventLine]) -> ZoomActivity {
        ZoomActivity.from(events: events, display: display, sourceSize: source)
    }

    @Test func clicksOutsideSourceAreDropped() {
        let a = activity([ev(1, .down, x: 500), ev(1.05, .up, x: 500),
                          ev(2, .down, x: 3000), ev(2.05, .up, x: 3000)])
        #expect(a.clicks.count == 1)
        #expect(a.clicks[0].t == 1)
    }

    @Test func downUpWithTravelIsADragNotAClick() {
        let a = activity([ev(1, .down, x: 500), ev(1.6, .up, x: 800)])
        #expect(a.drags == [TimeSpan(begin: 1, end: 1.6)])
        #expect(a.clicks.isEmpty)
    }

    @Test func downWithoutUpIsAClick() {
        #expect(activity([ev(1, .down)]).clicks.count == 1)
    }

    @Test func threeKeysWithinGapFormTypingBurst() {
        #expect(activity([ev(1.0, .key), ev(1.4, .key), ev(1.9, .key)]).typing
                == [TimeSpan(begin: 1.0, end: 1.9)])
        #expect(activity([ev(1.0, .key), ev(1.4, .key)]).typing.isEmpty)
        // A pause longer than the gap starts a new burst.
        #expect(activity([ev(1.0, .key), ev(1.4, .key), ev(3.0, .key)]).typing.isEmpty)
    }

    @Test func shortcutKeysAreNotTyping() {
        let keys = (0..<5).map { ev(1 + Double($0) * 0.2, .key, mods: ["cmd"]) }
        #expect(activity(keys).typing.isEmpty)
    }

    @Test func keyPositionIsNotBoundsChecked() {
        let keys = (0..<4).map { ev(1 + Double($0) * 0.2, .key, x: 9000, y: 9000) }
        #expect(activity(keys).typing.count == 1)
    }

    @Test func scrollEventsGroupByGap() {
        let a = activity([1.0, 1.1, 1.2, 3.0, 3.1].map { ev($0, .scroll) })
        #expect(a.scrolls == [TimeSpan(begin: 1.0, end: 1.2), TimeSpan(begin: 3.0, end: 3.1)])
    }

    @Test func scrollOnlyActivityIsEmpty() {
        let a = activity([1.0, 1.1, 1.2].map { ev($0, .scroll) })
        #expect(a.isEmpty)
        #expect(!a.scrolls.isEmpty)
    }

    @Test func trimmedDropsEventsPastTheEnd() {
        let a = activity([ev(1, .down), ev(1.05, .up), ev(50, .down), ev(50.05, .up)])
        #expect(a.trimmed(to: 10).clicks.count == 1)
    }
}

@Suite struct AutoZoomSuggesterTests {
    private let source = CGSize(width: 1920, height: 1080)
    // preRoll 0.675, joinGap 2.875, minLength 1.95.
    private let config = AutoZoomSuggestConfig(rampIn: 0.475, rampOut: 0.475)
    private let eps = 1e-9

    private func click(_ t: Double, _ p: CGPoint = CGPoint(x: 960, y: 540)) -> ClickSample {
        ClickSample(t: t, p: p)
    }

    private func suggest(_ activity: ZoomActivity, span: ClosedRange<Double> = 0...60,
                         cuts: [Range<Double>] = [],
                         cursor: [CursorSample] = []) -> [ZoomBlock] {
        AutoZoomSuggester.suggest(activity: activity, cursorSamples: cursor, span: span,
                                  sourceSize: source, cuts: cuts, config: config)
    }

    private func covered(_ blocks: [ZoomBlock], _ t: Double) -> Bool {
        blocks.contains { $0.begin <= t && t <= $0.end }
    }

    @Test func configDerivedValues() {
        #expect(abs(config.preRoll - 0.675) < eps)
        #expect(abs(config.joinGap - 2.875) < eps)
        #expect(abs(config.minLength - 1.95) < eps)
    }

    @Test func noActivityGivesNoBlocks() {
        #expect(suggest(ZoomActivity()).isEmpty)
        // Scrolling alone is not a reason to zoom.
        #expect(suggest(ZoomActivity(scrolls: [TimeSpan(begin: 5, end: 8)])).isEmpty)
    }

    @Test func singleClickGivesMinLengthBlockLandingBeforeClick() {
        let blocks = suggest(ZoomActivity(clicks: [click(10)]))
        #expect(blocks.count == 1)
        #expect(abs(blocks[0].begin - (10 - 0.675)) < eps)
        #expect(blocks[0].end - blocks[0].begin >= 1.95 - eps)
        #expect(blocks[0].begin + config.rampIn <= 10)
    }

    @Test func clicksWithinJoinGapShareOneBlock() {
        #expect(suggest(ZoomActivity(clicks: [click(10), click(12.5)])).count == 1)
    }

    @Test func clicksBeyondJoinGapLeaveMinWideBetween() {
        let blocks = suggest(ZoomActivity(clicks: [click(10), click(13.5)]))
        #expect(blocks.count == 2)
        #expect(blocks[1].begin - blocks[0].end >= 1.0 - eps)
    }

    @Test func minLengthExtensionNeverClosesTheGap() {
        // 2.9 s apart: just over joinGap, but extending the first run to its
        // minimum length would leave only 0.95 s un-zoomed.
        let blocks = suggest(ZoomActivity(clicks: [click(10), click(12.9)]))
        #expect(blocks.count == 1)
        #expect(covered(blocks, 10) && covered(blocks, 12.9))
    }

    @Test func activityStartingJustBeforeTheSpanStillCounts() {
        // A drag that begins 0.1 s before the block and runs through it.
        let a = ZoomActivity(drags: [TimeSpan(begin: 19.9, end: 23)])
        let blocks = suggest(a, span: 20...26)
        #expect(blocks.count == 1)
        #expect(blocks[0].begin >= 20 && blocks[0].end <= 26)
    }

    @Test func longScrollSplitsEvenWhenClicksAreClose() {
        let a = ZoomActivity(clicks: [click(10), click(12)],
                             scrolls: [TimeSpan(begin: 10.6, end: 11.4)])
        let blocks = suggest(a)
        #expect(blocks.count == 2)
        for b in blocks { #expect(b.end <= 10.6 + eps || b.begin >= 11.4 - eps) }
        #expect(covered(blocks, 10) && covered(blocks, 12))
    }

    @Test func shortScrollDoesNotSplit() {
        let a = ZoomActivity(clicks: [click(10), click(12)],
                             scrolls: [TimeSpan(begin: 10.6, end: 10.9)])
        #expect(suggest(a).count == 1)
    }

    @Test func typingBurstBecomesManualBlockOnPrecedingClick() {
        let a = ZoomActivity(clicks: [click(10)], typing: [TimeSpan(begin: 10.5, end: 13)])
        let blocks = suggest(a)
        #expect(blocks.count == 3)
        let typed = blocks.first { $0.begin <= 11.5 && 11.5 <= $0.end }
        #expect(typed?.mode == .manual)
        #expect(typed?.focusX == 0.5 && typed?.focusY == 0.5)
        // The pieces tile one run: they touch.
        for i in 1..<blocks.count { #expect(abs(blocks[i].begin - blocks[i - 1].end) < eps) }
        #expect(blocks.filter { $0.mode == .manual }.count == 1)
    }

    @Test func typingWithoutRecentClickHoldsOnCursor() {
        let cursor = [CursorSample(t: 0, p: CGPoint(x: 480, y: 270), cursor: "ibeam"),
                      CursorSample(t: 60, p: CGPoint(x: 480, y: 270), cursor: "ibeam")]
        let a = ZoomActivity(typing: [TimeSpan(begin: 20, end: 23)])
        let typed = suggest(a, cursor: cursor).first { $0.mode == .manual }
        #expect(typed?.focusX == 0.25 && typed?.focusY == 0.25)
    }

    @Test func shortTypingBurstStaysFollow() {
        let a = ZoomActivity(clicks: [click(10)], typing: [TimeSpan(begin: 10.5, end: 11.2)])
        let blocks = suggest(a)
        #expect(blocks.count == 1)
        #expect(blocks[0].mode == nil)
    }

    @Test func noKeysStillClustersClicks() {
        // Recording without Input Monitoring: pointer activity alone still works.
        let a = ZoomActivity(clicks: [click(5), click(6), click(20)])
        let blocks = suggest(a)
        #expect(blocks.count == 2)
        #expect(covered(blocks, 5) && covered(blocks, 6) && covered(blocks, 20))
    }

    @Test func eventsInsideCutsAreIgnored() {
        #expect(suggest(ZoomActivity(clicks: [click(10)]), cuts: [9..<11]).isEmpty)
    }

    @Test func clicksAdjacentAcrossACutShareOneRun() {
        // 1.8 s apart for the viewer once 11.5…40 is cut out.
        let blocks = suggest(ZoomActivity(clicks: [click(10), click(40.3)]), cuts: [11.5..<40])
        #expect(blocks.count == 1)
        #expect(covered(blocks, 10) && covered(blocks, 40.3))
    }

    @Test func outputSortedNonOverlappingInsideSpan() {
        var seed: UInt64 = 42
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        let clicks = (0..<40).map { _ in click(rnd() * 60) }.sorted { $0.t < $1.t }
        let blocks = suggest(ZoomActivity(clicks: clicks), span: 5...50)
        #expect(!blocks.isEmpty)
        for b in blocks {
            #expect(b.begin >= 5 - eps && b.end <= 50 + eps && b.end > b.begin)
        }
        for i in 1..<blocks.count { #expect(blocks[i].begin >= blocks[i - 1].end - eps) }
    }

    @Test func spanLimitsActivityAndResults() {
        let blocks = suggest(ZoomActivity(clicks: [click(10), click(30)]), span: 28...33)
        #expect(blocks.count == 1)
        #expect(blocks[0].begin >= 28 && blocks[0].end <= 33)
        #expect(covered(blocks, 30))
    }

    @Test func spanTooShortForMinLengthGivesNothing() {
        #expect(suggest(ZoomActivity(clicks: [click(10)]), span: 9.5...10.5).isEmpty)
    }

    @Test func generatedFollowBlocksLeaveOptionalsNil() {
        let b = suggest(ZoomActivity(clicks: [click(10)]))[0]
        #expect(b.scale == nil && b.sensitivity == nil && b.overflow == nil)
        #expect(b.mode == nil && b.focusX == nil && b.focusY == nil)
    }

    // MARK: - Applying a result

    private let a = ZoomBlock(begin: 0, end: 2, scale: 3)
    private let b = ZoomBlock(begin: 5, end: 9)
    private let c = ZoomBlock(begin: 12, end: 14, sensitivity: 0.2)

    @Test func allScopeSpansWholeRecording() {
        #expect(AutoZoomSuggester.span(for: .all, existing: [], duration: 42) == 0...42)
    }

    @Test func blockScopeSpansThatBlock() {
        #expect(AutoZoomSuggester.span(for: .block(b.id), existing: [a, b, c], duration: 42)
                == 5...9)
    }

    @Test func blockScopeWithUnknownIDIsNoOp() {
        // A stale selection must never turn into "replace all".
        #expect(AutoZoomSuggester.span(for: .block(UUID()), existing: [a, b, c], duration: 42)
                == nil)
        #expect(AutoZoomSuggester.resolve(existing: [a, b, c],
                                          generated: [ZoomBlock(begin: 6, end: 8)],
                                          scope: .block(UUID())) == nil)
    }

    @Test func mergeAllReplacesEverything() {
        let x = ZoomBlock(begin: 20, end: 23)
        #expect(AutoZoomSuggester.merge(existing: [a, b, c], generated: [x], scope: .all) == [x])
    }

    @Test func mergeBlockReplacesOnlyThatBlock() {
        let x = ZoomBlock(begin: 6, end: 8)
        #expect(AutoZoomSuggester.merge(existing: [a, b, c], generated: [x], scope: .block(b.id))
                == [a, x, c])
    }

    @Test func nothingFoundLeavesBlocksUntouched() {
        #expect(AutoZoomSuggester.resolve(existing: [a, b, c], generated: [], scope: .all) == nil)
        #expect(AutoZoomSuggester.resolve(existing: [a, b, c], generated: [],
                                          scope: .block(b.id)) == nil)
    }
}
