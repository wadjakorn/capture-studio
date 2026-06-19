import Testing
import Foundation
@testable import CaptureStudio

@Suite struct CameraTimelineTests {
    private let home = CameraSample(centerX: 0.85, centerY: 0.82, scale: 0.24, opacity: 1)

    private func block(_ begin: Double, _ end: Double, visible: Bool = true,
                       cx: Double = 0.5, cy: Double = 0.5, scale: Double = 0.3) -> CameraBlock {
        CameraBlock(begin: begin, end: end, visible: visible, centerX: cx, centerY: cy, scale: scale)
    }

    // MARK: ease

    @Test func easeEndpointsAndMidpoint() {
        #expect(CameraTimeline.ease(0) == 0)
        #expect(CameraTimeline.ease(1) == 1)
        #expect(abs(CameraTimeline.ease(0.5) - 0.5) < 1e-9)
    }

    // MARK: sample

    @Test func emptyBlocksReturnHome() {
        #expect(CameraTimeline.sample(at: 5, blocks: [], home: home) == home)
    }

    @Test func beforeFirstBlockHoldsHome() {
        let blocks = [block(2, 4, cx: 0.2, cy: 0.2, scale: 0.2)]
        #expect(CameraTimeline.sample(at: 0, blocks: blocks, home: home) == home)
    }

    @Test func blockStartEqualsFromState() {
        // At begin the eased fraction is 0 → the "from" state (home for block 0).
        let blocks = [block(2, 6, cx: 0.2, cy: 0.2, scale: 0.2)]
        #expect(CameraTimeline.sample(at: 2, blocks: blocks, home: home) == home)
    }

    @Test func midBlockInterpolatesHalfway() {
        // begin 10, end 14 → t=12 is fraction 0.5 → ease 0.5 → midpoint home→target.
        let blocks = [block(10, 14, cx: 0.2, cy: 0.4, scale: 0.4)]
        let s = CameraTimeline.sample(at: 12, blocks: blocks, home: home)
        #expect(abs(s.centerX - (home.centerX + 0.2) / 2) < 1e-9)
        #expect(abs(s.centerY - (home.centerY + 0.4) / 2) < 1e-9)
        #expect(abs(s.scale - (home.scale + 0.4) / 2) < 1e-9)
    }

    @Test func blockEndEqualsTarget() {
        let blocks = [block(10, 14, cx: 0.2, cy: 0.4, scale: 0.4)]
        let s = CameraTimeline.sample(at: 14, blocks: blocks, home: home)
        #expect(s == CameraSample(centerX: 0.2, centerY: 0.4, scale: 0.4, opacity: 1))
    }

    @Test func holdsTargetAfterEnd() {
        let blocks = [block(10, 14, cx: 0.2, cy: 0.4, scale: 0.4)]
        let s = CameraTimeline.sample(at: 30, blocks: blocks, home: home)
        #expect(s == CameraSample(centerX: 0.2, centerY: 0.4, scale: 0.4, opacity: 1))
    }

    @Test func secondBlockEasesFromFirstTargetNoPop() {
        // Non-overlapping blocks: block 2 starts from block 1's settled target.
        let b1 = block(0, 2, cx: 0.2, cy: 0.2, scale: 0.2)
        let b2 = block(10, 12, cx: 0.8, cy: 0.8, scale: 0.4)
        let blocks = [b1, b2]
        // Held at b1's target between the blocks.
        #expect(CameraTimeline.sample(at: 5, blocks: blocks, home: home)
                == CameraSample(centerX: 0.2, centerY: 0.2, scale: 0.2, opacity: 1))
        // Entering b2 at begin → still b1's target (continuous, no pop).
        #expect(CameraTimeline.sample(at: 10, blocks: blocks, home: home)
                == CameraSample(centerX: 0.2, centerY: 0.2, scale: 0.2, opacity: 1))
        // Midway through b2 → halfway between the two targets.
        let mid = CameraTimeline.sample(at: 11, blocks: blocks, home: home)
        #expect(abs(mid.centerX - 0.5) < 1e-9)
        #expect(abs(mid.scale - 0.3) < 1e-9)
    }

    @Test func hideBlockCrossfadesOpacityDown() {
        let blocks = [block(10, 14, visible: false)]
        let mid = CameraTimeline.sample(at: 12, blocks: blocks, home: home)
        #expect(abs(mid.opacity - 0.5) < 1e-9)
        let after = CameraTimeline.sample(at: 20, blocks: blocks, home: home)
        #expect(after.opacity == 0)
    }

    @Test func zeroWidthBlockIsAHardCut() {
        let b1 = block(0, 2, cx: 0.2, cy: 0.2, scale: 0.2)
        let cut = block(10, 10, cx: 0.8, cy: 0.8, scale: 0.4)
        let blocks = [b1, cut]
        #expect(CameraTimeline.sample(at: 9.999, blocks: blocks, home: home).centerX == 0.2)
        #expect(CameraTimeline.sample(at: 10, blocks: blocks, home: home).centerX == 0.8)
    }

    @Test func unsortedInputSamplesSameAsSorted() {
        let b1 = block(0, 2, cx: 0.2, cy: 0.2, scale: 0.2)
        let b2 = block(10, 12, cx: 0.8, cy: 0.8, scale: 0.4)
        let a = CameraTimeline.sample(at: 11, blocks: [b1, b2], home: home)
        let b = CameraTimeline.sample(at: 11, blocks: [b2, b1], home: home)
        #expect(a == b)
    }

    // MARK: clamp / edge moves (non-overlap)

    private var trio: [CameraBlock] {
        [block(0, 2), block(5, 7), block(10, 12)]
    }

    @Test func clampBeginStaysWithinPrevEndAndOwnEnd() {
        let b = trio
        #expect(CameraTimeline.clampBegin(b, id: b[1].id, toTime: 1, duration: 30) == 2)   // prev end
        #expect(CameraTimeline.clampBegin(b, id: b[1].id, toTime: 9, duration: 30) == 7)   // own end
        #expect(CameraTimeline.clampBegin(b, id: b[1].id, toTime: 6, duration: 30) == 6)
    }

    @Test func clampEndStaysWithinOwnBeginAndNextBegin() {
        let b = trio
        #expect(CameraTimeline.clampEnd(b, id: b[1].id, toTime: 1, duration: 30) == 5)     // own begin
        #expect(CameraTimeline.clampEnd(b, id: b[1].id, toTime: 11, duration: 30) == 10)   // next begin
        #expect(CameraTimeline.clampEnd(b, id: b[2].id, toTime: 99, duration: 30) == 30)   // duration
    }

    @Test func moveBeginAndEndApplyClamp() {
        let b = trio
        let m1 = CameraTimeline.moveBegin(b, id: b[1].id, toTime: 1, duration: 30)
        #expect(m1.first(where: { $0.id == b[1].id })?.begin == 2)
        let m2 = CameraTimeline.moveEnd(b, id: b[1].id, toTime: 11, duration: 30)
        #expect(m2.first(where: { $0.id == b[1].id })?.end == 10)
    }

    @Test func moveBlockShiftsKeepingWidthWithinNeighbors() {
        let b = trio
        let moved = CameraTimeline.moveBlock(b, id: b[1].id, toBegin: 9, duration: 30)
        let mb = moved.first(where: { $0.id == b[1].id })!
        #expect(mb.begin == 8)   // width 2, next begin 10 → max begin 8
        #expect(mb.end == 10)
    }

    @Test func removeDropsByID() {
        let b = trio
        let pruned = CameraTimeline.remove(b, id: b[1].id)
        #expect(pruned.map(\.begin) == [0, 10])
    }

    // MARK: add

    @Test func addPlacesBlockAtPlayheadWithWidth() {
        let placement = CameraSample(centerX: 0.5, centerY: 0.5, scale: 0.3, opacity: 1)
        let r = CameraTimeline.add([], atTime: 5, width: 2, duration: 30, placement: placement)
        #expect(r.blocks.count == 1)
        #expect(r.blocks[0].begin == 5)
        #expect(r.blocks[0].end == 7)
    }

    @Test func addPushesPastBlockItLandsInside() {
        let placement = CameraSample(centerX: 0.5, centerY: 0.5, scale: 0.3, opacity: 1)
        let first = CameraTimeline.add([], atTime: 5, width: 2, duration: 30, placement: placement)
        let second = CameraTimeline.add(first.blocks, atTime: 6, width: 2, duration: 30, placement: placement)
        #expect(second.blocks.map(\.begin) == [5, 7])
        #expect(second.blocks[1].end == 9)
    }

    @Test func addClampsToDuration() {
        let placement = CameraSample(centerX: 0.5, centerY: 0.5, scale: 0.3, opacity: 1)
        let r = CameraTimeline.add([], atTime: 29, width: 2, duration: 30, placement: placement)
        #expect(r.blocks[0].begin == 29)
        #expect(r.blocks[0].end == 30)
    }
}
