import Testing
import Foundation
@testable import CaptureStudio

@Suite struct ShapeTimelineTests {
    private func block(_ begin: Double, _ end: Double,
                       _ kind: ShapeKind = .rectangle) -> ShapeBlock {
        ShapeBlock(begin: begin, end: end, kind: kind)
    }

    // MARK: active

    @Test func activeIsHalfOpen() {
        let b = [block(2, 4)]
        #expect(ShapeTimeline.active(at: 1.99, blocks: b).isEmpty)   // before begin
        #expect(ShapeTimeline.active(at: 2, blocks: b).count == 1)    // at begin: shown
        #expect(ShapeTimeline.active(at: 3.99, blocks: b).count == 1) // inside
        #expect(ShapeTimeline.active(at: 4, blocks: b).isEmpty)       // at end: hidden
    }

    @Test func zeroWidthBlockNeverShows() {
        #expect(ShapeTimeline.active(at: 5, blocks: [block(5, 5)]).isEmpty)
    }

    @Test func returnsAllOverlappingInArrayOrder() {
        // Array order is z-order and must be preserved even when begins differ.
        let b = [block(1, 9, .rectangle), block(3, 5, .blur)]
        let active = ShapeTimeline.active(at: 4, blocks: b)
        #expect(active.map(\.kind) == [.rectangle, .blur])
    }

    // MARK: add (overlap allowed)

    @Test func addAppendsToTopAndAllowsOverlap() {
        let existing = [block(0, 10)]
        let (out, id) = ShapeTimeline.add(existing, atTime: 2, width: 3,
                                          duration: 20, template: ShapeBlock(begin: 0, end: 0))
        #expect(out.count == 2)
        #expect(out.last?.id == id)              // appended at end = top of z-order
        #expect(out.last?.begin == 2)
        #expect(out.last?.end == 5)
        #expect(out.last!.begin < existing[0].end) // overlaps, not pushed away
    }

    @Test func addClampsToDuration() {
        let (out, _) = ShapeTimeline.add([], atTime: 9, width: 5,
                                         duration: 10, template: ShapeBlock(begin: 0, end: 0))
        #expect(out[0].begin == 9)
        #expect(out[0].end == 10)                // 9 + 5 clamped to duration
    }

    @Test func addCopiesTemplateStyleAndResetsSpan() {
        var template = ShapeBlock(begin: 0, end: 0)
        template.kind = .blur
        template.blurStyle = .pixellate
        template.blurStrength = 0.09
        template.centerX = 0.3
        template.width = 0.4

        let (blocks, id) = ShapeTimeline.add([], atTime: 2, width: 3,
                                             duration: 10, template: template)
        let b = blocks.first { $0.id == id }!
        #expect(b.kind == .blur)
        #expect(b.blurStyle == .pixellate)
        #expect(b.blurStrength == 0.09)
        #expect(b.centerX == 0.3)
        #expect(b.width == 0.4)
        #expect(b.begin == 2)
        #expect(b.end == 5)
        #expect(b.id != template.id)
    }

    // MARK: move (no neighbor clamp)

    @Test func moveBeginClampsToOwnEndAndZero() {
        let b = [block(2, 6)]
        #expect(ShapeTimeline.moveBegin(b, id: b[0].id, toTime: -3, duration: 20)[0].begin == 0)
        #expect(ShapeTimeline.moveBegin(b, id: b[0].id, toTime: 9, duration: 20)[0].begin == 6)
    }

    @Test func moveEndClampsToOwnBeginAndDuration() {
        let b = [block(2, 6)]
        #expect(ShapeTimeline.moveEnd(b, id: b[0].id, toTime: 1, duration: 20)[0].end == 2)
        #expect(ShapeTimeline.moveEnd(b, id: b[0].id, toTime: 99, duration: 20)[0].end == 20)
    }

    @Test func moveBeginIgnoresNeighbors() {
        let b = [block(0, 5), block(4, 8)]
        let out = ShapeTimeline.moveBegin(b, id: b[1].id, toTime: 1, duration: 20)
        #expect(out[1].begin == 1)               // crossed into block a's span, allowed
    }

    @Test func moveBlockKeepsWidthAndClampsToClip() {
        let b = [block(2, 5)]                     // width 3
        let out = ShapeTimeline.moveBlock(b, id: b[0].id, toBegin: 100, duration: 10)
        #expect(out[0].begin == 7)               // 10 - 3
        #expect(out[0].end == 10)
    }

    @Test func removeDropsTheBlock() {
        let b = [block(0, 1, .rectangle), block(2, 3, .ellipse)]
        let out = ShapeTimeline.remove(b, id: b[0].id)
        #expect(out.map(\.kind) == [.ellipse])
    }

    // MARK: z-order

    @Test func bringForwardAndSendBackwardSwapNeighbors() {
        let b = [block(0, 1, .rectangle), block(0, 1, .ellipse), block(0, 1, .blur)]
        #expect(ShapeTimeline.bringForward(b, id: b[0].id).map(\.kind) == [.ellipse, .rectangle, .blur])
        #expect(ShapeTimeline.sendBackward(b, id: b[2].id).map(\.kind) == [.rectangle, .blur, .ellipse])
        // No-ops at the ends.
        #expect(ShapeTimeline.bringForward(b, id: b[2].id).map(\.kind) == [.rectangle, .ellipse, .blur])
        #expect(ShapeTimeline.sendBackward(b, id: b[0].id).map(\.kind) == [.rectangle, .ellipse, .blur])
    }

    @Test func moveToFrontAndBack() {
        let b = [block(0, 1, .rectangle), block(0, 1, .ellipse), block(0, 1, .blur)]
        #expect(ShapeTimeline.moveToFront(b, id: b[0].id).map(\.kind) == [.ellipse, .blur, .rectangle])
        #expect(ShapeTimeline.moveToBack(b, id: b[2].id).map(\.kind) == [.blur, .rectangle, .ellipse])
    }

    // MARK: subRows (greedy packing)

    @Test func sequentialBlocksPackIntoOneRow() {
        let b = [block(0, 2), block(2, 4), block(4, 6)]   // touching, not overlapping
        #expect(ShapeTimeline.subRows(b).count == 1)
    }

    @Test func mutuallyOverlappingBlocksNeedNRows() {
        let b = [block(0, 9), block(1, 9), block(2, 9)]
        #expect(ShapeTimeline.subRows(b).count == 3)
    }

    // MARK: default factory

    @Test func makeDefaultClampsSpanToClip() {
        let b = ShapeBlock.makeDefault(at: 8, duration: 10, kind: .blur)
        #expect(b.begin == 8)
        #expect(b.end == 10)                     // 8 + 3 clamped to duration
        #expect(b.kind == .blur)
    }

    // MARK: persistence / forward-compat

    @Test func shapeBlockRoundTrips() throws {
        let original = ShapeBlock(begin: 1, end: 4, kind: .ellipse, centerX: 0.3,
                                  width: 0.5, height: 0.4, fillHex: "#112233",
                                  fillOpacity: 0.7, strokeHex: "#445566",
                                  strokeWidth: 0.02, cornerRadius: 0.1,
                                  blurStyle: .pixellate, blurStrength: 0.06)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ShapeBlock.self, from: data)
        #expect(decoded == original)
    }

    @Test func editStateWithoutShapeBlocksDecodesEmpty() throws {
        // A bundle written before shape blocks existed has no `shapeBlocks` key.
        let json = Data(#"{"schemaVersion":1,"trimIn":0}"#.utf8)
        let edit = try JSONDecoder().decode(EditState.self, from: json)
        #expect(edit.shapeBlocks.isEmpty)
    }

    @Test func shapeBlockUnknownKindDecodesToRectangle() throws {
        let json = Data(#"{"id":"00000000-0000-0000-0000-000000000000","begin":0,"end":1,"kind":"hexagon"}"#.utf8)
        let block = try JSONDecoder().decode(ShapeBlock.self, from: json)
        #expect(block.kind == .rectangle)        // unknown raw string → default
    }

    @Test func shapeBlockUnknownBlurStyleDecodesToGaussian() throws {
        let json = Data(#"{"id":"00000000-0000-0000-0000-000000000000","begin":0,"end":1,"blurStyle":"swirl"}"#.utf8)
        let block = try JSONDecoder().decode(ShapeBlock.self, from: json)
        #expect(block.blurStyle == .gaussian)
    }

    @Test func shapeBlockMissingNewFieldsDefault() throws {
        // Only the required span present — every style field falls back.
        let json = Data(#"{"id":"00000000-0000-0000-0000-000000000000","begin":0,"end":2}"#.utf8)
        let b = try JSONDecoder().decode(ShapeBlock.self, from: json)
        #expect(b.kind == .rectangle)
        #expect(b.centerX == 0.5)
        #expect(b.centerY == 0.5)
        #expect(b.width == 0.3)
        #expect(b.height == 0.2)
        #expect(b.fillOpacity == 0)
        #expect(b.strokeWidth == 0.008)
        #expect(b.cornerRadius == 0)
        #expect(b.blurStrength == 0.04)
    }

    @Test func editStateShapeBlocksRoundTrip() throws {
        var edit = EditState()
        edit.shapeBlocks = [
            ShapeBlock(begin: 0, end: 2, kind: .rectangle),
            ShapeBlock(begin: 1, end: 3, kind: .blur, blurStyle: .pixellate),
        ]
        let data = try JSONEncoder().encode(edit)
        let decoded = try JSONDecoder().decode(EditState.self, from: data)
        #expect(decoded.shapeBlocks == edit.shapeBlocks)
    }

    // MARK: trim rebase

    @Test func trimRebasesShapeBlocksAndDropsOutside() {
        var edit = EditState()
        edit.shapeBlocks = [
            ShapeBlock(begin: 0, end: 1, kind: .rectangle),   // before window → dropped
            ShapeBlock(begin: 3, end: 6, kind: .blur),        // inside → shifted to [1, 4]
        ]
        let out = TrimTimeline.apply(edit, in: 2, out: 8, duration: 10)
        #expect(out.shapeBlocks.count == 1)
        #expect(out.shapeBlocks[0].kind == .blur)
        #expect(out.shapeBlocks[0].begin == 1)
        #expect(out.shapeBlocks[0].end == 4)
    }
}
