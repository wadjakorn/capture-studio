import Testing
@testable import CaptureStudio

@Suite struct TimelineEdgeShareTests {

    // MARK: - isShared

    @Test func detectsCoincidentEdge() {
        // A block beginning at 2.0 shares with a neighbour ending at 2.0.
        #expect(TimelineEdgeShare.isShared(2.0, with: [0.0, 2.0, 5.0]))
    }

    @Test func nonCoincidentEdgeIsNotShared() {
        #expect(!TimelineEdgeShare.isShared(2.0, with: [0.0, 1.9, 5.0]))
    }

    @Test func toleratesFloatingPointJitterWithinEpsilon() {
        #expect(TimelineEdgeShare.isShared(2.0, with: [2.0 + 5e-7]))
        #expect(!TimelineEdgeShare.isShared(2.0, with: [2.0 + 1e-3]))
    }

    @Test func emptyNeighboursNeverShare() {
        #expect(!TimelineEdgeShare.isShared(2.0, with: []))
    }

    // MARK: - placement

    @Test func sharedBeginGoesToBottomEndToTop() {
        #expect(TimelineEdgeShare.placement(isBegin: true, shared: true) == .bottom)
        #expect(TimelineEdgeShare.placement(isBegin: false, shared: true) == .top)
    }

    @Test func unsharedEdgesStayFull() {
        #expect(TimelineEdgeShare.placement(isBegin: true, shared: false) == .full)
        #expect(TimelineEdgeShare.placement(isBegin: false, shared: false) == .full)
    }

    // MARK: - Adjacency scenario

    // Two blocks A[0,2] and B[2,4] meeting at t=2: A's end is shared (→ top),
    // B's begin is shared (→ bottom); their outer edges stay full.
    @Test func adjacentBlocksStaggerOnlyAtTheSharedBoundary() {
        let aEnd = 2.0, bBegin = 2.0
        let aBegin = 0.0, bEnd = 4.0
        let ends = [aEnd, bEnd]      // sibling ends
        let begins = [aBegin, bBegin] // sibling begins

        // A: begin 0 not shared (no sibling ends at 0), end 2 shared (B begins at 2).
        #expect(!TimelineEdgeShare.isShared(aBegin, with: [bEnd]))
        #expect(TimelineEdgeShare.isShared(aEnd, with: [bBegin]))
        // B: begin 2 shared (A ends at 2), end 4 not shared.
        #expect(TimelineEdgeShare.isShared(bBegin, with: [aEnd]))
        #expect(!TimelineEdgeShare.isShared(bEnd, with: [aBegin]))

        _ = (ends, begins)  // documents the sibling projections used per lane
    }
}
