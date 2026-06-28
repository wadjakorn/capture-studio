import Testing
import Foundation
@testable import CaptureStudio

@Suite struct TrimTimelineTests {
    private func cam(_ b: Double, _ e: Double) -> CameraBlock {
        CameraBlock(begin: b, end: e, centerX: 0.5, centerY: 0.5, scale: 0.3)
    }
    private func zoom(_ b: Double, _ e: Double) -> ZoomBlock { ZoomBlock(begin: b, end: e) }
    private func layout(_ b: Double, _ e: Double) -> LayoutBlock { LayoutBlock(begin: b, end: e) }
    private func text(_ b: Double, _ e: Double) -> TextBlock { TextBlock(begin: b, end: e, text: "x") }

    // MARK: committed window

    @Test func freshEditHasNoCommittedTrim() {
        let e = EditState()
        #expect(e.committedTrimStart == 0)
        #expect(e.committedTrimEnd == nil)
    }

    @Test func applySetsCommittedWindowAbsolute() {
        let r = TrimTimeline.apply(EditState(), in: 2, out: 8, duration: 10)
        #expect(r.committedTrimStart == 2)
        #expect(r.committedTrimEnd == 8)
    }

    @Test func compoundingTrimsAccumulate() {
        var e = EditState()
        e = TrimTimeline.apply(e, in: 2, out: 8, duration: 10)   // window [2,8], len 6
        e = TrimTimeline.apply(e, in: 1, out: 5, duration: 6)    // within len 6
        #expect(e.committedTrimStart == 3)                       // 2 + 1
        #expect(e.committedTrimEnd == 7)                         // 2 + 5
    }

    @Test func markersResetAfterApply() {
        var e = EditState(trimIn: 2, trimOut: 8)
        e = TrimTimeline.apply(e, in: 2, out: 8, duration: 10)
        #expect(e.trimIn == 0)
        #expect(e.trimOut == nil)
    }

    // MARK: block rebasing

    @Test func blockInsideWindowShiftsLeft() {
        let r = TrimTimeline.apply(EditState(cameraBlocks: [cam(3, 5)]), in: 2, out: 8, duration: 10)
        #expect(r.cameraBlocks.count == 1)
        #expect(r.cameraBlocks[0].begin == 1)
        #expect(r.cameraBlocks[0].end == 3)
    }

    @Test func blockBeforeHeadDropped() {
        let r = TrimTimeline.apply(EditState(cameraBlocks: [cam(0, 1.5)]), in: 2, out: 8, duration: 10)
        #expect(r.cameraBlocks.isEmpty)
    }

    @Test func blockAfterTailDropped() {
        let r = TrimTimeline.apply(EditState(zoomBlocks: [zoom(8.5, 9.5)]), in: 2, out: 8, duration: 10)
        #expect(r.zoomBlocks.isEmpty)
    }

    @Test func blockStraddlingHeadClampedToZero() {
        let r = TrimTimeline.apply(EditState(layoutBlocks: [layout(1, 4)]), in: 2, out: 8, duration: 10)
        #expect(r.layoutBlocks.count == 1)
        #expect(r.layoutBlocks[0].begin == 0)   // 1 clamped to 2, then -2
        #expect(r.layoutBlocks[0].end == 2)     // 4 - 2
    }

    @Test func blockStraddlingTailClampedToLen() {
        let r = TrimTimeline.apply(EditState(textBlocks: [text(6, 9)]), in: 2, out: 8, duration: 10)
        #expect(r.textBlocks.count == 1)
        #expect(r.textBlocks[0].begin == 4)     // 6 - 2
        #expect(r.textBlocks[0].end == 6)       // 9 clamped to 8, then -2 (len 6)
    }

    @Test func blockFullyInsideHeadDropped() {
        // [0,2] sits entirely in the trimmed-out head [0,2)
        let r = TrimTimeline.apply(EditState(cameraBlocks: [cam(0, 2)]), in: 2, out: 8, duration: 10)
        #expect(r.cameraBlocks.isEmpty)
    }

    @Test func zeroWidthHardCutInsideKept() {
        let r = TrimTimeline.apply(EditState(cameraBlocks: [cam(5, 5)]), in: 2, out: 8, duration: 10)
        #expect(r.cameraBlocks.count == 1)
        #expect(r.cameraBlocks[0].begin == 3)
        #expect(r.cameraBlocks[0].end == 3)
    }

    @Test func subtitleOffsetShiftsByHead() {
        let track = SubtitleTrack(srtFilename: "a.srt",
                                  cues: [SubtitleCue(begin: 3, end: 4, text: "hi")], offset: 0)
        let r = TrimTimeline.apply(EditState(subtitles: track), in: 2, out: 8, duration: 10)
        #expect(r.subtitles?.offset == -2)
    }

    @Test func noOpWhenFullRange() {
        let e = EditState(cameraBlocks: [cam(3, 5)], zoomBlocks: [zoom(1, 2)])
        let r = TrimTimeline.apply(e, in: 0, out: 10, duration: 10)
        #expect(r.committedTrimStart == 0)
        #expect(r.cameraBlocks[0].begin == 3)
        #expect(r.zoomBlocks[0].begin == 1)
    }

    @Test func outOfRangeMarkersClampToDuration() {
        // out beyond duration clamps; in below 0 clamps
        let r = TrimTimeline.apply(EditState(cameraBlocks: [cam(3, 5)]), in: -1, out: 99, duration: 10)
        #expect(r.committedTrimStart == 0)
        #expect(r.committedTrimEnd == 10)
        #expect(r.cameraBlocks[0].begin == 3)
    }
}
