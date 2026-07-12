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

    // MARK: - Split (start/stop point mid-zoom)

    @Test func splitProducesTwoTouchingBlocks() {
        let aId = UUID()
        let a = ZoomBlock(id: aId, begin: 0, end: 4, scale: 2)
        let (out, newID) = ZoomTimeline.split([a], atTime: 2.5)
        #expect(out.count == 2)
        #expect(newID != nil)
        let left = out.first { $0.id == aId }!
        let right = out.first { $0.id == newID }!
        #expect(left.begin == 0)
        #expect(left.end == 2.5)
        #expect(right.begin == 2.5)     // touching → continuous run
        #expect(right.end == 4)
    }

    @Test func splitKeepsSettingsOnBothHalves() {
        let a = ZoomBlock(begin: 0, end: 4, scale: 3, sensitivity: 0.2,
                          overflow: true, mode: .manual, focusX: 0.6, focusY: 0.4)
        let (out, newID) = ZoomTimeline.split([a], atTime: 2)
        for b in out {
            #expect(b.scale == 3)
            #expect(b.sensitivity == 0.2)
            #expect(b.overflow == true)
            #expect(b.mode == .manual)
            #expect(b.focusX == 0.6)
            #expect(b.focusY == 0.4)
        }
        #expect(out.contains { $0.id == newID })
    }

    @Test func splitOutsideAnyBlockIsNoOp() {
        let blocks = [block(0, 2), block(3, 5)]
        let (out, newID) = ZoomTimeline.split(blocks, atTime: 2.5)   // in the gap
        #expect(newID == nil)
        #expect(out.count == 2)
    }

    @Test func splitTooCloseToEdgeIsNoOp() {
        let (out, newID) = ZoomTimeline.split([block(0, 4)], atTime: 0.01)
        #expect(newID == nil)
        #expect(out.count == 1)
    }
}
