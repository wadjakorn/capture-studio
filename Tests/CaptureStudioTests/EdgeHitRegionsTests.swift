import Testing
import CoreGraphics
@testable import CaptureStudio

@Suite struct EdgeHitRegionsTests {

    // MARK: - Wide block (room for two full-width targets)

    @Test func wideBlockBiasesEachTargetIntoTheInterior() {
        let h = EdgeHitRegions(bodyWidth: 100, handleWidth: 16)
        // Begin target hugs the left interior, end target the right interior.
        #expect(h.begin == 0...16)
        #expect(h.end == 84...100)
        #expect(h.beginWidth == 16)
        #expect(h.endWidth == 16)
        #expect(h.beginMidX == 8)
        #expect(h.endMidX == 92)
    }

    @Test func wideBlockLeavesBodyGapBetweenTargets() {
        let h = EdgeHitRegions(bodyWidth: 100, handleWidth: 16)
        // Middle stays free so the block body remains grabbable to reposition.
        #expect(h.begin.upperBound < h.end.lowerBound)
        #expect(h.end.lowerBound - h.begin.upperBound == 68)
    }

    // MARK: - Adjacent blocks: no cross-boundary overlap

    // At a shared A.end / B.begin boundary the two targets live in different
    // blocks. Modelled locally: every target stays strictly on its own half, so
    // neither reaches across the edge into the neighbour.
    @Test func targetsNeverCrossTheBlockMidline() {
        for w in stride(from: CGFloat(1), through: 200, by: 7) {
            let h = EdgeHitRegions(bodyWidth: w, handleWidth: 16)
            #expect(h.begin.upperBound <= w / 2 + 0.0001)
            #expect(h.end.lowerBound >= w / 2 - 0.0001)
            #expect(h.begin.upperBound <= h.end.lowerBound)   // never overlap
        }
    }

    // MARK: - Short block (body split down the middle)

    @Test func narrowBlockSplitsBodyInHalf() {
        let h = EdgeHitRegions(bodyWidth: 20, handleWidth: 16)
        // 20 < 2*16, so each target caps at half the body and they meet at 10.
        #expect(h.begin == 0...10)
        #expect(h.end == 10...20)
        #expect(h.beginWidth == 10)
        #expect(h.endWidth == 10)
    }

    @Test func exactlyTwiceHandleWidthTouchesWithoutGapOrOverlap() {
        let h = EdgeHitRegions(bodyWidth: 32, handleWidth: 16)
        #expect(h.begin == 0...16)
        #expect(h.end == 16...32)
        #expect(h.begin.upperBound == h.end.lowerBound)   // touch, no gap
    }

    @Test func tinyBlockKeepsBothEdgesReachable() {
        let h = EdgeHitRegions(bodyWidth: 4, handleWidth: 16)
        #expect(h.beginWidth == 2)
        #expect(h.endWidth == 2)
        #expect(h.begin.upperBound == h.end.lowerBound)   // no overlap
    }

    // MARK: - Degenerate inputs

    @Test func zeroWidthBlockYieldsEmptyTargetsAtOrigin() {
        let h = EdgeHitRegions(bodyWidth: 0, handleWidth: 16)
        #expect(h.begin == 0...0)
        #expect(h.end == 0...0)
        #expect(h.beginWidth == 0)
        #expect(h.endWidth == 0)
    }

    @Test func negativeWidthClampsToZero() {
        let h = EdgeHitRegions(bodyWidth: -50, handleWidth: 16)
        #expect(h.begin == 0...0)
        #expect(h.end == 0...0)
    }

    @Test func zeroHandleWidthYieldsEmptyTargetsAtEdges() {
        let h = EdgeHitRegions(bodyWidth: 100, handleWidth: 0)
        #expect(h.begin == 0...0)
        #expect(h.end == 100...100)
        #expect(h.beginWidth == 0)
        #expect(h.endWidth == 0)
    }
}
