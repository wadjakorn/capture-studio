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

    @Test func splitPreservesHiddenFlag() {
        let (out, _) = TimelineSegments.split([seg(0, 10, hidden: true)], at: 4)
        #expect(out.allSatisfy { $0.hidden })
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
}
