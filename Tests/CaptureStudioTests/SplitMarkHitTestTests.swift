import Testing
import Foundation
@testable import CaptureStudio

struct SplitMarkHitTestTests {
    @Test func isolatedMarkGetsCappedHalfWidth() {
        let r = SplitMarkHitTest.rects(xs: [100], width: 400)
        #expect(r == [92...108])
    }
    @Test func hitRectsNeverOverlapAndCoverEveryMark() {
        let xs: [CGFloat] = [10, 14, 15, 60, 300]
        let r = SplitMarkHitTest.rects(xs: xs, width: 320)
        #expect(r.count == xs.count)
        for (i, x) in xs.enumerated() { #expect(r[i].contains(x)) }
        for i in 1..<r.count { #expect(r[i - 1].upperBound <= r[i].lowerBound) }
    }
    @Test func rectsClampToLaneEdges() {
        let r = SplitMarkHitTest.rects(xs: [2, 398], width: 400)
        #expect(r[0].lowerBound == 0); #expect(r[1].upperBound == 400)
    }
}
