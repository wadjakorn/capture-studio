import Testing
import Foundation
@testable import CaptureStudio

@Suite struct TimelineCutTests {
    // One cut [4, 6) removed from a 10s timeline.
    private let cuts = [4.0 ..< 6.0]

    @Test func mapShiftsAfterCut() {
        #expect(TimelineCut.map(2, cuts: cuts) == 2)     // before the cut: unchanged
        #expect(TimelineCut.map(8, cuts: cuts) == 6)     // after: shifted left by 2
        #expect(TimelineCut.map(5, cuts: cuts) == 4)     // inside: maps to the cut start
    }

    @Test func remainingDurationDropsCutTime() {
        #expect(TimelineCut.remainingDuration(10, cuts: cuts) == 8)
        #expect(TimelineCut.remainingDuration(10, cuts: [4.0..<6.0, 8.0..<9.0]) == 7)
    }

    @Test func blockSpanningCutShrinks() {
        // [3, 7] spans the cut → [3, 5] (loses the 2s cut).
        let s = TimelineCut.span(begin: 3, end: 7, cuts: cuts)
        #expect(s != nil)
        #expect(s!.begin == 3)
        #expect(s!.end == 5)
    }

    @Test func blockStraddlingBoundaryClamps() {
        // [5, 8] starts inside the cut → begin clamps to the cut start (4), end 6.
        let s = TimelineCut.span(begin: 5, end: 8, cuts: cuts)
        #expect(s != nil)
        #expect(s!.begin == 4)
        #expect(s!.end == 6)
    }

    @Test func blockWhollyInsideCutIsDropped() {
        #expect(TimelineCut.span(begin: 4.5, end: 5.5, cuts: cuts) == nil)
    }

    @Test func zeroWidthMarkerOutsideCutSurvives() {
        let s = TimelineCut.span(begin: 8, end: 8, cuts: cuts)
        #expect(s != nil)
        #expect(s!.begin == 6 && s!.end == 6)
    }

    @Test func pointInsideCutDropped() {
        #expect(TimelineCut.point(5, cuts: cuts) == nil)
        #expect(TimelineCut.point(2, cuts: cuts) == 2)
        #expect(TimelineCut.point(8, cuts: cuts) == 6)
    }

    @Test func unmapInvertsMap() {
        // Collapsed → timeline. A collapsed time on a cut resolves to the cut end.
        #expect(TimelineCut.unmap(2, cuts: cuts) == 2)     // before the cut: unchanged
        #expect(TimelineCut.unmap(6, cuts: cuts) == 8)     // after: shifted right by 2
        #expect(TimelineCut.unmap(4, cuts: cuts) == 6)     // on the cut → cut end
        // Round-trips for visible times.
        for t in [0.0, 1.5, 4.0, 7.9, 10.0] where !TimelineCut.isCut(t, cuts: cuts) {
            #expect(abs(TimelineCut.unmap(TimelineCut.map(t, cuts: cuts), cuts: cuts) - t) < 1e-9)
        }
    }

    @Test func unmapWithTwoCuts() {
        let two = [4.0 ..< 6.0, 8.0 ..< 9.0]
        // collapsed: [0,4] visible, then [6,8] (collapsed 4..6), then [9,end] (collapsed 6..).
        #expect(TimelineCut.unmap(3, cuts: two) == 3)
        #expect(TimelineCut.unmap(5, cuts: two) == 7)      // in the 2nd visible run
        #expect(TimelineCut.unmap(6, cuts: two) == 9)      // past both cuts
    }

    @Test func noCutsIsIdentity() {
        #expect(TimelineCut.map(5, cuts: []) == 5)
        #expect(TimelineCut.span(begin: 2, end: 7, cuts: [])?.end == 7)
        #expect(TimelineCut.remainingDuration(10, cuts: []) == 10)
    }
}
