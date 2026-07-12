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

    // MARK: - Short block (edges capped to a fraction, central move band kept)

    @Test func narrowBlockCapsEdgesToFractionAndKeepsCentre() {
        let h = EdgeHitRegions(bodyWidth: 20, handleWidth: 16)   // default 0.3
        // 0.3 * 20 = 6 per edge, leaving a 8pt central move band.
        #expect(h.begin == 0...6)
        #expect(h.end == 14...20)
        #expect(h.beginWidth == 6)
        #expect(h.endWidth == 6)
        #expect(h.end.lowerBound - h.begin.upperBound == 8)   // body stays grabbable
    }

    @Test func shortBlocksAlwaysReserveACentralMoveBand() {
        // Across a range of short widths the two edges never meet: a middle
        // strip is always left for the body drag-to-move gesture.
        for w in stride(from: CGFloat(2), through: 60, by: 3) {
            let h = EdgeHitRegions(bodyWidth: w, handleWidth: 16)
            #expect(h.begin.upperBound < h.end.lowerBound)     // strict gap
            let centre = h.end.lowerBound - h.begin.upperBound
            #expect(centre >= w * 0.4 - 0.0001)                // ~40% stays body
        }
    }

    @Test func tinyBlockStillLeavesAGap() {
        let h = EdgeHitRegions(bodyWidth: 4, handleWidth: 16)
        #expect(abs(h.beginWidth - 1.2) < 0.0001)
        #expect(abs(h.endWidth - 1.2) < 0.0001)
        #expect(h.begin.upperBound < h.end.lowerBound)   // never swallow the body
    }

    @Test func edgeFractionClampsToHalfSoTargetsNeverOverlap() {
        let h = EdgeHitRegions(bodyWidth: 20, handleWidth: 16, edgeFraction: 0.9)
        // 0.9 clamps to 0.5 → each edge caps at half; they touch, never overlap.
        #expect(h.begin.upperBound <= h.end.lowerBound)
        #expect(h.begin == 0...10)
        #expect(h.end == 10...20)
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
