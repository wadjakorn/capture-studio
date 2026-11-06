import Testing
import Foundation
@testable import CaptureStudio

@Suite struct LegacyTrimMigrationTests {
    private func cam(_ b: Double, _ e: Double) -> CameraBlock {
        CameraBlock(begin: b, end: e, centerX: 0.5, centerY: 0.5, scale: 0.3)
    }
    private func ranges(_ e: EditState) -> [Range<Double>] {
        TimelineSegments.cutRanges(e.segments)
    }

    @Test func noLegacyTrimIsIdentity() {
        let e = EditState()
        #expect(LegacyTrimMigration.migrate(e, masterDuration: 10) == e)
    }

    @Test func committedWindowBecomesHeadAndTailCuts() {
        let e = EditState(committedTrimStart: 2, committedTrimEnd: 8)
        let r = LegacyTrimMigration.migrate(e, masterDuration: 10)
        #expect(ranges(r) == [0..<2, 8..<10])
    }

    @Test func blocksAreRebasedToMasterTime() {
        var e = EditState(committedTrimStart: 2, committedTrimEnd: 8)
        e.cameraBlocks = [cam(1, 3)]
        e.subtitles = SubtitleTrack(srtFilename: "a.srt", offset: 0)
        let r = LegacyTrimMigration.migrate(e, masterDuration: 10)
        #expect(r.cameraBlocks[0].begin == 3)
        #expect(r.cameraBlocks[0].end == 5)
        #expect(r.subtitles?.offset == 2)
    }

    @Test func existingSegmentsShiftWithTheWindow() {
        let segs = [TimelineSegment(start: 0, end: 3, hidden: true),
                    TimelineSegment(start: 3, end: 6)]
        let e = EditState(committedTrimStart: 2, committedTrimEnd: 8, segments: segs)
        let r = LegacyTrimMigration.migrate(e, masterDuration: 10)
        // Hidden 2..<5 merges with the head cut 0..<2.
        #expect(ranges(r) == [0..<5, 8..<10])
    }

    @Test func liveMarkersBecomeCuts() {
        let e = EditState(trimIn: 1.5, trimOut: 8.25)
        let r = LegacyTrimMigration.migrate(e, masterDuration: 10)
        #expect(ranges(r) == [0..<1.5, 8.25..<10])
    }

    @Test func migrationClampsWindowToMaster() {
        let e = EditState(committedTrimStart: 2, committedTrimEnd: 50)
        let r = LegacyTrimMigration.migrate(e, masterDuration: 10)
        #expect(ranges(r) == [0..<2])
        #expect(r.segments.allSatisfy { $0.end <= 10 })
    }

    @Test func invertedMarkersAreIgnored() {
        let e = EditState(trimIn: 8, trimOut: 2)
        let r = LegacyTrimMigration.migrate(e, masterDuration: 10)
        #expect(ranges(r).isEmpty)
    }

    @Test func legacyFieldsAreZeroedAfterMigration() {
        let e = EditState(trimIn: 1, trimOut: 9, committedTrimStart: 2, committedTrimEnd: 8)
        let r = LegacyTrimMigration.migrate(e, masterDuration: 10)
        #expect(r.committedTrimStart == 0)
        #expect(r.committedTrimEnd == nil)
        #expect(r.trimIn == 0)
        #expect(r.trimOut == nil)
    }
}
