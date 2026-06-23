import Testing
import Foundation
@testable import CaptureStudio

@Suite struct ZoomTimelineTests {
    private func block(_ begin: Double, _ end: Double, scale: Double? = nil) -> ZoomBlock {
        ZoomBlock(begin: begin, end: end, scale: scale)
    }

    @Test func addClampsIntoClip() {
        let (blocks, id) = ZoomTimeline.add([], atTime: 5, width: 2, duration: 10)
        let b = blocks.first { $0.id == id }!
        #expect(b.begin == 5)
        #expect(b.end == 7)
    }

    @Test func addPastDurationClampsEnd() {
        let (blocks, id) = ZoomTimeline.add([], atTime: 9.5, width: 2, duration: 10)
        let b = blocks.first { $0.id == id }!
        #expect(b.begin == 9.5)
        #expect(b.end == 10)
    }

    @Test func addCannotOverlapNextBlock() {
        let existing = [block(6, 8)]
        let (blocks, id) = ZoomTimeline.add(existing, atTime: 5, width: 5, duration: 10)
        let b = blocks.first { $0.id == id }!
        #expect(b.begin == 5)
        #expect(b.end == 6)   // clamped to the next block's begin
    }

    @Test func moveBeginCannotCrossPreviousEnd() {
        let a = block(0, 2)
        let bId = UUID()
        let b = ZoomBlock(id: bId, begin: 3, end: 5)
        let out = ZoomTimeline.moveBegin([a, b], id: bId, toTime: 1, duration: 10)
        let moved = out.first { $0.id == bId }!
        #expect(moved.begin == 2)   // clamped to a.end
    }

    @Test func moveEndCannotCrossNextBegin() {
        let aId = UUID()
        let a = ZoomBlock(id: aId, begin: 0, end: 2)
        let b = block(3, 5)
        let out = ZoomTimeline.moveEnd([a, b], id: aId, toTime: 4, duration: 10)
        let moved = out.first { $0.id == aId }!
        #expect(moved.end == 3)     // clamped to b.begin
    }

    @Test func moveBlockKeepsWidthAndStaysInsideNeighbors() {
        let a = block(0, 2)
        let cId = UUID()
        let c = ZoomBlock(id: cId, begin: 3, end: 4)   // width 1
        let out = ZoomTimeline.moveBlock([a, c], id: cId, toBegin: 0.5, duration: 10)
        let moved = out.first { $0.id == cId }!
        #expect(moved.begin == 2)       // clamped to a.end
        #expect(moved.end == 3)         // width preserved
    }

    @Test func removeDropsBlock() {
        let aId = UUID()
        let a = ZoomBlock(id: aId, begin: 0, end: 2)
        let out = ZoomTimeline.remove([a, block(3, 5)], id: aId)
        #expect(out.count == 1)
        #expect(!out.contains { $0.id == aId })
    }
}
