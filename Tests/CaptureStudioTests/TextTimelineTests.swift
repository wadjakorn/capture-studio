import Testing
import Foundation
@testable import CaptureStudio

@Suite struct TextTimelineTests {
    private func block(_ begin: Double, _ end: Double, _ text: String = "") -> TextBlock {
        TextBlock(begin: begin, end: end, text: text)
    }

    // MARK: active

    @Test func activeIsHalfOpen() {
        let b = [block(2, 4)]
        #expect(TextTimeline.active(at: 1.99, blocks: b).isEmpty)   // before begin
        #expect(TextTimeline.active(at: 2, blocks: b).count == 1)    // at begin: shown
        #expect(TextTimeline.active(at: 3.99, blocks: b).count == 1) // inside
        #expect(TextTimeline.active(at: 4, blocks: b).isEmpty)       // at end: hidden
    }

    @Test func zeroWidthBlockNeverShows() {
        #expect(TextTimeline.active(at: 5, blocks: [block(5, 5)]).isEmpty)
    }

    @Test func returnsAllOverlappingInArrayOrder() {
        // Array order is z-order and must be preserved even when begins differ.
        let b = [block(1, 9, "back"), block(3, 5, "front")]
        let active = TextTimeline.active(at: 4, blocks: b)
        #expect(active.map(\.text) == ["back", "front"])
    }

    // MARK: add (overlap allowed)

    @Test func addAppendsToTopAndAllowsOverlap() {
        let existing = [block(0, 10, "a")]
        let (out, id) = TextTimeline.add(existing, atTime: 2, width: 3,
                                         duration: 20, template: TextBlock(begin: 0, end: 0))
        #expect(out.count == 2)
        #expect(out.last?.id == id)              // appended at end = top of z-order
        #expect(out.last?.begin == 2)
        #expect(out.last?.end == 5)
        // Overlaps the existing block — not pushed away.
        #expect(out.last!.begin < existing[0].end)
    }

    @Test func addClampsToDuration() {
        let (out, _) = TextTimeline.add([], atTime: 9, width: 5,
                                        duration: 10, template: TextBlock(begin: 0, end: 0))
        #expect(out[0].begin == 9)
        #expect(out[0].end == 10)                // 9 + 5 clamped to duration
    }

    // MARK: move (no neighbor clamp)

    @Test func moveBeginClampsToOwnEndAndZero() {
        let b = [block(2, 6)]
        #expect(TextTimeline.moveBegin(b, id: b[0].id, toTime: -3, duration: 20)[0].begin == 0)
        #expect(TextTimeline.moveBegin(b, id: b[0].id, toTime: 9, duration: 20)[0].begin == 6)
    }

    @Test func moveEndClampsToOwnBeginAndDuration() {
        let b = [block(2, 6)]
        #expect(TextTimeline.moveEnd(b, id: b[0].id, toTime: 1, duration: 20)[0].end == 2)
        #expect(TextTimeline.moveEnd(b, id: b[0].id, toTime: 99, duration: 20)[0].end == 20)
    }

    @Test func moveBeginIgnoresNeighbors() {
        // Two overlapping blocks; moving one's begin past the other is allowed.
        let b = [block(0, 5, "a"), block(4, 8, "b")]
        let out = TextTimeline.moveBegin(b, id: b[1].id, toTime: 1, duration: 20)
        #expect(out[1].begin == 1)               // crossed into block a's span, allowed
    }

    @Test func moveBlockKeepsWidthAndClampsToClip() {
        let b = [block(2, 5)]                     // width 3
        let out = TextTimeline.moveBlock(b, id: b[0].id, toBegin: 100, duration: 10)
        #expect(out[0].begin == 7)               // 10 - 3
        #expect(out[0].end == 10)
    }

    @Test func removeDropsTheBlock() {
        let b = [block(0, 1, "a"), block(2, 3, "b")]
        let out = TextTimeline.remove(b, id: b[0].id)
        #expect(out.map(\.text) == ["b"])
    }

    // MARK: z-order

    @Test func bringForwardAndSendBackwardSwapNeighbors() {
        let b = [block(0, 1, "a"), block(0, 1, "b"), block(0, 1, "c")]
        #expect(TextTimeline.bringForward(b, id: b[0].id).map(\.text) == ["b", "a", "c"])
        #expect(TextTimeline.sendBackward(b, id: b[2].id).map(\.text) == ["a", "c", "b"])
        // No-ops at the ends.
        #expect(TextTimeline.bringForward(b, id: b[2].id).map(\.text) == ["a", "b", "c"])
        #expect(TextTimeline.sendBackward(b, id: b[0].id).map(\.text) == ["a", "b", "c"])
    }

    @Test func moveToFrontAndBack() {
        let b = [block(0, 1, "a"), block(0, 1, "b"), block(0, 1, "c")]
        #expect(TextTimeline.moveToFront(b, id: b[0].id).map(\.text) == ["b", "c", "a"])
        #expect(TextTimeline.moveToBack(b, id: b[2].id).map(\.text) == ["c", "a", "b"])
    }

    // MARK: subRows (greedy packing)

    @Test func sequentialBlocksPackIntoOneRow() {
        let b = [block(0, 2), block(2, 4), block(4, 6)]   // touching, not overlapping
        #expect(TextTimeline.subRows(b).count == 1)
    }

    @Test func mutuallyOverlappingBlocksNeedNRows() {
        let b = [block(0, 9), block(1, 9), block(2, 9)]
        #expect(TextTimeline.subRows(b).count == 3)
    }

    @Test func mixedOverlapUsesMinimalRows() {
        // a:[0,5] b:[1,3] c:[6,8] — a&b overlap → 2 rows; c reuses a row after a.
        let b = [block(0, 5, "a"), block(1, 3, "b"), block(6, 8, "c")]
        let rows = TextTimeline.subRows(b)
        #expect(rows.count == 2)
    }

    // MARK: persistence / forward-compat

    @Test func textBlockRoundTrips() throws {
        let original = TextBlock(begin: 1, end: 4, text: "hi", centerX: 0.3,
                                 fontWeight: .bold, source: .systemAudio)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TextBlock.self, from: data)
        #expect(decoded == original)
    }

    @Test func editStateWithoutTextBlocksDecodesEmpty() throws {
        // A bundle written before text blocks existed has no `textBlocks` key.
        let json = Data(#"{"schemaVersion":1,"trimIn":0}"#.utf8)
        let edit = try JSONDecoder().decode(EditState.self, from: json)
        #expect(edit.textBlocks.isEmpty)
    }

    @Test func textBlockUnknownEnumDecodesToDefault() throws {
        let json = Data(#"{"id":"00000000-0000-0000-0000-000000000000","begin":0,"end":1,"source":"future"}"#.utf8)
        let block = try JSONDecoder().decode(TextBlock.self, from: json)
        #expect(block.source == .manual)        // unknown raw string → default
    }
}
