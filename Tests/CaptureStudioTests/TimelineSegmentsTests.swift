import Testing
import Foundation
@testable import CaptureStudio

@Suite struct TimelineSegmentsTests {
    private func seg(_ start: Double, _ end: Double, hidden: Bool = false) -> TimelineSegment {
        TimelineSegment(start: start, end: end, hidden: hidden)
    }

    // MARK: - full / normalized

    @Test func fullIsOneVisibleSegment() {
        let s = TimelineSegments.full(duration: 10)
        #expect(s.count == 1)
        #expect(s[0].start == 0)
        #expect(s[0].end == 10)
        #expect(!s[0].hidden)
    }

    @Test func normalizedFillsGapsAndTilesTimeline() {
        // A stored list with a gap [3,6] and a trailing remainder → filled visible.
        let s = TimelineSegments.normalized([seg(0, 3), seg(6, 8, hidden: true)], duration: 10)
        #expect(s.first!.start == 0)
        #expect(s.last!.end == 10)
        // Contiguous, no overlap.
        for i in 1..<s.count { #expect(abs(s[i].start - s[i - 1].end) < 1e-9) }
        // The hidden piece survives.
        #expect(s.contains { $0.hidden && abs($0.start - 6) < 1e-9 && abs($0.end - 8) < 1e-9 })
    }

    @Test func normalizedClampsToDurationAndDropsEmpty() {
        let s = TimelineSegments.normalized([seg(0, 5), seg(5, 5), seg(5, 20)], duration: 10)
        #expect(s.last!.end == 10)
        #expect(s.allSatisfy { $0.end - $0.start > 1e-9 })
    }

    @Test func normalizedEmptyCollapsesToFull() {
        let s = TimelineSegments.normalized([], duration: 10)
        #expect(s.count == 1)
        #expect(s[0].start == 0 && s[0].end == 10 && !s[0].hidden)
    }

    // MARK: - split

    @Test func splitDividesSegmentAtPlayhead() {
        let (out, id) = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 4)
        #expect(out.count == 2)
        #expect(id != nil)
        #expect(out[0].start == 0 && out[0].end == 4)
        #expect(out[1].start == 4 && out[1].end == 10)
        #expect(out[1].id == id)           // right half is the new id
    }

    // MARK: hidden-run invariant

    @Test func splitRefusedInsideHiddenSegment() {
        let s = TimelineSegments.cut(TimelineSegments.full(duration: 10), range: 0..<4)
        #expect(!TimelineSegments.canSplit(s, at: 2))
        #expect(TimelineSegments.split(s, at: 2).id == nil)
        #expect(TimelineSegments.canSplit(s, at: 6))
    }
    @Test func coalescedHiddenMergesRunsKeepingFirstId() {
        let a = seg(0, 2, hidden: true), b = seg(2, 5, hidden: true), c = seg(5, 7), d = seg(7, 9, hidden: true), e = seg(9, 10, hidden: true)
        let out = TimelineSegments.coalescedHidden([a, b, c, d, e])
        #expect(out.map(\.start) == [0, 5, 7]); #expect(out.map(\.end) == [5, 7, 10])
        #expect(out.map(\.hidden) == [true, false, true])
        #expect(out[0].id == a.id && out[2].id == d.id && out[1] == c)
    }
    @Test func coalescedHiddenIsIdentityWhenNothingAdjacent() {
        let s = [seg(0, 2, hidden: true), seg(2, 5), seg(5, 10, hidden: true)]
        #expect(TimelineSegments.coalescedHidden(s) == s)
        #expect(TimelineSegments.coalescedHidden(TimelineSegments.coalescedHidden(s)) == s)
    }
    @Test func normalizedCoalescesAdjacentHidden() {
        let s = [seg(0, 2, hidden: true), seg(2, 4, hidden: true), seg(4, 10)]
        let n = TimelineSegments.normalized(s, duration: 10)
        #expect(n.count == 2); #expect(n[0].hidden && n[0].end == 4)
    }
    @Test func cutAdjacentToHiddenRunMergesIntoIt() {
        var s = TimelineSegments.cut(TimelineSegments.full(duration: 10), range: 0..<2)
        s = TimelineSegments.cut(s, range: 2..<5)
        #expect(s.count == 2); #expect(s[0].hidden && s[0].start == 0 && s[0].end == 5)
    }
    @Test func setHiddenMergesWithNeighbours() {
        var s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 3).segments
        s = TimelineSegments.split(s, at: 6).segments
        s = TimelineSegments.setHidden(s, id: s[0].id, true)
        s = TimelineSegments.setHidden(s, id: s[1].id, true)
        #expect(s.count == 2); #expect(s[0].hidden && s[0].end == 6); #expect(!s[1].hidden)
    }
    @Test func cutOverSplitsCollapsesThemIntoOneHiddenSegment() {
        var s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 2).segments
        s = TimelineSegments.split(s, at: 4).segments
        let t = TimelineSegments.cut(s, range: 0..<6)
        #expect(t.count == 2); #expect(t[0].hidden && t[0].end == 6); #expect(t[1].start == 6)
    }

    @Test func multipleSplitsSupported() {
        var s = TimelineSegments.full(duration: 12)
        s = TimelineSegments.split(s, at: 4).segments
        s = TimelineSegments.split(s, at: 8).segments
        #expect(s.count == 3)
        #expect(s.map(\.start) == [0, 4, 8])
        #expect(s.map(\.end) == [4, 8, 12])
    }

    @Test func splitRefusedTooCloseToEdge() {
        let (out, id) = TimelineSegments.split(TimelineSegments.full(duration: 10),
                                               at: 0.01, minWidth: 0.05)
        #expect(id == nil)
        #expect(out.count == 1)
    }

    @Test func canSplitMatchesSplit() {
        let s = TimelineSegments.full(duration: 10)
        #expect(TimelineSegments.canSplit(s, at: 5))
        #expect(!TimelineSegments.canSplit(s, at: 0.001))
        #expect(!TimelineSegments.canSplit(s, at: 10))   // on the boundary, not inside
    }

    // MARK: - hide / restore

    @Test func setHiddenTogglesFlag() {
        let s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 5).segments
        let id = s[1].id
        let hidden = TimelineSegments.setHidden(s, id: id, true)
        #expect(hidden.first { $0.id == id }!.hidden)
        let restored = TimelineSegments.setHidden(hidden, id: id, false)
        #expect(!restored.first { $0.id == id }!.hidden)
    }

    @Test func cannotHideLastVisibleSegment() {
        let s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 5).segments
        let hiddenOne = TimelineSegments.setHidden(s, id: s[0].id, true)
        #expect(TimelineSegments.visibleCount(hiddenOne) == 1)
        // Hiding the remaining visible segment is refused.
        let attempt = TimelineSegments.setHidden(hiddenOne, id: s[1].id, true)
        #expect(attempt == hiddenOne)
        #expect(TimelineSegments.visibleCount(attempt) == 1)
    }

    // MARK: - cut ranges

    @Test func cutRangesMergeAdjacentHidden() {
        var s = TimelineSegments.full(duration: 12)
        s = TimelineSegments.split(s, at: 4).segments
        s = TimelineSegments.split(s, at: 8).segments   // [0,4] [4,8] [8,12]
        s = TimelineSegments.setHidden(s, id: s.sorted { $0.start < $1.start }[0].id, true)
        let sorted = s.sorted { $0.start < $1.start }
        s = TimelineSegments.setHidden(s, id: sorted[1].id, true)  // hide [0,4] and [4,8]
        let ranges = TimelineSegments.cutRanges(s)
        #expect(ranges.count == 1)                       // merged into one [0,8)
        #expect(ranges[0].lowerBound == 0 && ranges[0].upperBound == 8)
    }

    @Test func hiddenRangeContainingPlayhead() {
        let s = [seg(0, 4), seg(4, 8, hidden: true), seg(8, 12)]
        #expect(TimelineSegments.hiddenRange(containing: 6, in: s)?.upperBound == 8)
        #expect(TimelineSegments.hiddenRange(containing: 2, in: s) == nil)
        #expect(TimelineSegments.hiddenRange(containing: 8, in: s) == nil)  // upperBound is exclusive
    }

    // MARK: cut(range:) / visibleBounds

    @Test func cutHeadProducesHiddenLeadingSegment() {
        let s = TimelineSegments.cut(TimelineSegments.full(duration: 10), range: 0..<3)
        #expect(s.count == 2); #expect(s[0].hidden && s[0].end == 3); #expect(!s[1].hidden)
    }
    @Test func cutTailProducesHiddenTrailingSegment() {
        let s = TimelineSegments.cut(TimelineSegments.full(duration: 10), range: 7..<10)
        #expect(s.count == 2); #expect(!s[0].hidden); #expect(s[1].hidden && s[1].start == 7)
    }
    @Test func cutMiddleSplitsTwice() {
        let s = TimelineSegments.cut(TimelineSegments.full(duration: 10), range: 2..<5)
        #expect(s.map(\.hidden) == [false, true, false]); #expect(s[1].start == 2 && s[1].end == 5)
    }
    @Test func cutSnapsToNearbyBoundary() {
        var s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 4).segments
        s = TimelineSegments.cut(s, range: 0..<4.02)             // within splitMinWidth of 4
        #expect(s.count == 2); #expect(s[0].hidden && s[0].end == 4)
    }
    @Test func cutRefusesToHideEverything() {
        let full = TimelineSegments.full(duration: 10)
        #expect(TimelineSegments.cut(full, range: 0..<10) == full)
    }
    @Test func cutEmptyRangeIsNoOp() {
        let full = TimelineSegments.full(duration: 10)
        #expect(TimelineSegments.cut(full, range: 3..<3.01) == full)
    }
    @Test func cutPreservesExistingHiddenInsideRange() {
        var s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 2).segments
        s = TimelineSegments.setHidden(s, id: s[0].id, true)     // [0,2) hidden
        s = TimelineSegments.cut(s, range: 0..<5)
        #expect(TimelineSegments.cutRanges(s) == [0..<5])
    }
    @Test func visibleBoundsSkipLeadingAndTrailingCuts() {
        var s = TimelineSegments.cut(TimelineSegments.full(duration: 10), range: 0..<2)
        s = TimelineSegments.cut(s, range: 8..<10)
        let b = TimelineSegments.visibleBounds(s, duration: 10)
        #expect(b.start == 2 && b.end == 8)
        let e = TimelineSegments.visibleBounds([], duration: 10)
        #expect(e.start == 0 && e.end == 10)
    }

    @Test func previewTrimStartIsHeadRangeWithPendingSplit() {
        let p = TimelineSegments.preview(for: .trimStart, segments: TimelineSegments.full(duration: 10),
                                         at: 3, duration: 10)
        #expect(p == CutPreview(ranges: [0..<3], kind: .cut, pendingSplitAt: 3))
    }
    @Test func previewTrimStartOnExistingBoundaryHasNoPendingSplit() {
        let s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 3).segments
        let p = TimelineSegments.preview(for: .trimStart, segments: s, at: 3, duration: 10)
        #expect(p == CutPreview(ranges: [0..<3], kind: .cut, pendingSplitAt: nil))
    }
    @Test func previewCutSegmentIsSegmentUnderPlayhead() {
        let s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 4).segments
        let p = TimelineSegments.preview(for: .cutSegment, segments: s, at: 5, duration: 10)
        #expect(p == CutPreview(ranges: [4..<10], kind: .cut, pendingSplitAt: nil))
    }
    @Test func previewRestoreOnlyForHiddenSegment() {
        var s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 4).segments
        #expect(TimelineSegments.preview(for: .restoreSegment, segments: s, at: 5, duration: 10) == nil)
        s = TimelineSegments.setHidden(s, id: s[1].id, true)
        let p = TimelineSegments.preview(for: .restoreSegment, segments: s, at: 5, duration: 10)
        #expect(p == CutPreview(ranges: [4..<10], kind: .restore, pendingSplitAt: nil))
    }
    @Test func previewClearAllListsEveryHiddenRun() {
        var s = TimelineSegments.cut(TimelineSegments.full(duration: 10), range: 0..<2)
        s = TimelineSegments.cut(s, range: 6..<8)
        let p = TimelineSegments.preview(for: .clearAll, segments: s, at: 5, duration: 10)
        #expect(p == CutPreview(ranges: [0..<2, 6..<8], kind: .restore, pendingSplitAt: nil))
        let none = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 4).segments
        #expect(TimelineSegments.preview(for: .clearAll, segments: none, at: 5, duration: 10) == nil)
    }
    @Test func previewIsNilWhenActionWouldNotChangeAnything() {
        let full = TimelineSegments.full(duration: 10)
        #expect(TimelineSegments.preview(for: .trimStart, segments: full, at: 0, duration: 10) == nil)
        #expect(TimelineSegments.preview(for: .trimEnd, segments: full, at: 10, duration: 10) == nil)
        // Empty (uncut) list materialises once — fresh-UUID trap must not yield a false preview.
        #expect(TimelineSegments.preview(for: .trimStart, segments: [], at: 0, duration: 10) == nil)
        #expect(TimelineSegments.preview(for: .cutSegment, segments: [], at: 5, duration: 10) == nil)
    }

    @Test func joinMergesVisibleNeighboursKeepingLeftId() {
        let s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 4).segments
        let j = TimelineSegments.join(s, atBoundaryOf: s[1].id)
        #expect(j.count == 1); #expect(j[0].id == s[0].id); #expect(j[0].start == 0 && j[0].end == 10 && !j[0].hidden)
    }
    @Test func joinRefusedForMixedFlagsFirstSegmentAndUnknownId() {
        let s = TimelineSegments.cut(TimelineSegments.full(duration: 10), range: 0..<4)   // [0,4)h [4,10)
        #expect(TimelineSegments.join(s, atBoundaryOf: s[1].id) == s)
        #expect(TimelineSegments.join(s, atBoundaryOf: s[0].id) == s)
        #expect(TimelineSegments.join(s, atBoundaryOf: UUID()) == s)
    }
    @Test func previewRemoveSplitIsMergeMarker() {
        let s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 4).segments
        let p = TimelineSegments.preview(for: .removeSplit(rightID: s[1].id), segments: s, at: 0, duration: 10)
        #expect(p == CutPreview(ranges: [], kind: .merge, removingSplitAt: 4))
        let mixed = TimelineSegments.cut(s, range: 0..<4)
        #expect(TimelineSegments.preview(for: .removeSplit(rightID: mixed[1].id), segments: mixed, at: 0, duration: 10) == nil)
    }
    @Test func previewHideSegmentIDNilForLastVisible() {
        let s = TimelineSegments.cut(TimelineSegments.full(duration: 10), range: 0..<4)
        #expect(TimelineSegments.preview(for: .hideSegmentID(s[1].id), segments: s, at: 0, duration: 10) == nil)
        #expect(TimelineSegments.preview(for: .restoreSegmentID(s[0].id), segments: s, at: 9, duration: 10)
                == CutPreview(ranges: [0..<4], kind: .restore))
        let two = TimelineSegments.split(s, at: 7).segments
        #expect(TimelineSegments.preview(for: .hideSegmentID(two[1].id), segments: two, at: 0, duration: 10)
                == CutPreview(ranges: [4..<7], kind: .cut))
    }
}
