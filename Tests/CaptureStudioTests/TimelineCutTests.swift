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

    @Test func noCutsIsIdentity() {
        #expect(TimelineCut.map(5, cuts: []) == 5)
        #expect(TimelineCut.span(begin: 2, end: 7, cuts: [])?.end == 7)
        #expect(TimelineCut.remainingDuration(10, cuts: []) == 10)
    }
}
