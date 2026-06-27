import Testing
import Foundation
@testable import CaptureStudio

@Suite struct LayoutTimelineTests {
    private func block(_ begin: Double, _ end: Double,
                       _ layout: CameraLayout = .mainAndFloat) -> LayoutBlock {
        LayoutBlock(begin: begin, end: end, layout: layout)
    }

    // MARK: - Sampling

    @Test func sampleReturnsCoveringBlockLayout() {
        let blocks = [block(0, 2, .mainOnly), block(4, 6, .cameraStatic)]
        #expect(LayoutTimeline.sample(at: 1, blocks: blocks) == .mainOnly)
        #expect(LayoutTimeline.sample(at: 5, blocks: blocks) == .cameraStatic)
    }

    @Test func sampleInGapReturnsNil() {
        let blocks = [block(0, 2, .mainOnly), block(4, 6, .cameraStatic)]
        #expect(LayoutTimeline.sample(at: 3, blocks: blocks) == nil)   // gap → blank
    }

    @Test func sampleEmptyReturnsNil() {
        #expect(LayoutTimeline.sample(at: 1, blocks: []) == nil)
    }

    @Test func sampleSpanIsHalfOpen() {
        let blocks = [block(0, 2, .mainOnly)]
        #expect(LayoutTimeline.sample(at: 0, blocks: blocks) == .mainOnly)   // begin inclusive
        #expect(LayoutTimeline.sample(at: 2, blocks: blocks) == nil)         // end exclusive
    }

    // MARK: - Capacity / gaps

    @Test func hasSpaceWhenEmpty() {
        #expect(LayoutTimeline.hasSpace([], duration: 10))
    }

    @Test func noSpaceWhenFull() {
        let blocks = [block(0, 10)]
        #expect(!LayoutTimeline.hasSpace(blocks, duration: 10))
    }

    @Test func hasSpaceWithInteriorGap() {
        let blocks = [block(0, 3), block(7, 10)]
        #expect(LayoutTimeline.hasSpace(blocks, duration: 10))   // [3,7) is free
    }

    @Test func gapSmallerThanMinDoesNotCount() {
        // Two blocks leaving only a 0.05 s gap (< 0.1 min) → no space.
        let blocks = [block(0, 4.97), block(5.02, 10)]
        #expect(!LayoutTimeline.hasSpace(blocks, duration: 10, minWidth: 0.1))
    }

    @Test func insertBeginHonorsPlayheadInsideGap() {
        // Playhead at 5 lies in the free gap [3,7) → block starts at 5, not the
        // gap's begin.
        let blocks = [block(0, 3), block(7, 10)]
        #expect(LayoutTimeline.insertBegin(blocks, atTime: 5, duration: 10) == 5)
    }

    @Test func insertBeginFallsForwardToNextGap() {
        // Playhead sits inside a block; the next free gap starts at its end.
        let blocks = [block(0, 3), block(7, 10)]
        #expect(LayoutTimeline.insertBegin(blocks, atTime: 1, duration: 10) == 3)
    }

    @Test func insertBeginNilWhenFull() {
        #expect(LayoutTimeline.insertBegin([block(0, 10)], atTime: 5, duration: 10) == nil)
    }

    // MARK: - Add

    @Test func addInsertsAtPlayheadGap() {
        let added = LayoutTimeline.add([], atTime: 4, width: 2, duration: 10,
                                       layout: .floatCamera)
        let b = added!.blocks.first { $0.id == added!.id }!
        #expect(b.begin == 4)
        #expect(b.end == 6)
        #expect(b.layout == .floatCamera)
    }

    @Test func addClampsToNextBlock() {
        let existing = [block(6, 8)]
        let added = LayoutTimeline.add(existing, atTime: 5, width: 5, duration: 10,
                                       layout: .mainOnly)
        let b = added!.blocks.first { $0.id == added!.id }!
        #expect(b.begin == 5)
        #expect(b.end == 6)   // clamped to next block's begin — no overlap
    }

    @Test func addReturnsNilWhenFull() {
        let added = LayoutTimeline.add([block(0, 10)], atTime: 5, width: 2,
                                       duration: 10, layout: .mainOnly)
        #expect(added == nil)
    }

    @Test func addNeverOverlaps() {
        var blocks: [LayoutBlock] = []
        for t in stride(from: 0.0, to: 9.0, by: 1.0) {
            if let added = LayoutTimeline.add(blocks, atTime: t, width: 0.5,
                                              duration: 10, layout: .mainOnly) {
                blocks = added.blocks
            }
        }
        let sorted = blocks.sorted { $0.begin < $1.begin }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            #expect(a.end <= b.begin)   // strictly non-overlapping
        }
    }

    // MARK: - Edge clamps

    @Test func moveBeginCannotCrossPreviousEnd() {
        let a = block(0, 2)
        let bId = UUID()
        let b = LayoutBlock(id: bId, begin: 3, end: 5, layout: .mainOnly)
        let out = LayoutTimeline.moveBegin([a, b], id: bId, toTime: 1, duration: 10)
        #expect(out.first { $0.id == bId }!.begin == 2)
    }

    @Test func moveEndCannotCrossNextBegin() {
        let aId = UUID()
        let a = LayoutBlock(id: aId, begin: 0, end: 2, layout: .mainOnly)
        let b = block(4, 6)
        let out = LayoutTimeline.moveEnd([a, b], id: aId, toTime: 5, duration: 10)
        #expect(out.first { $0.id == aId }!.end == 4)
    }

    @Test func moveBlockKeepsWidthAndStaysInBounds() {
        let id = UUID()
        let blocks = [block(0, 2), LayoutBlock(id: id, begin: 3, end: 5, layout: .mainOnly)]
        let out = LayoutTimeline.moveBlock(blocks, id: id, toBegin: 0, duration: 10)
        let moved = out.first { $0.id == id }!
        #expect(moved.begin == 2)          // clamped to previous block's end
        #expect(moved.end - moved.begin == 2)
    }
}
