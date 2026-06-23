import Testing
import Foundation
@testable import CaptureStudio

@Suite struct SubtitleTimelineTests {
    private func cue(_ begin: Double, _ end: Double, _ text: String = "") -> SubtitleCue {
        SubtitleCue(begin: begin, end: end, text: text)
    }

    @Test func activeIsHalfOpen() {
        let c = [cue(2, 4)]
        #expect(SubtitleTimeline.active(at: 1.99, cues: c).isEmpty)
        #expect(SubtitleTimeline.active(at: 2, cues: c).count == 1)
        #expect(SubtitleTimeline.active(at: 3.99, cues: c).count == 1)
        #expect(SubtitleTimeline.active(at: 4, cues: c).isEmpty)
    }

    @Test func effectiveOffsetZeroMatchesOldClamp() {
        let c = [cue(1, 5, "keep"), cue(8, 12, "clamp"), cue(20, 22, "drop")]
        let out = SubtitleTimeline.effective(c, offset: 0, duration: 10)
        #expect(out.count == 2)
        #expect(out[0].text == "keep" && out[0].end == 5)
        #expect(out[1].text == "clamp" && out[1].end == 10)   // clamped to duration
    }

    @Test func effectiveDropsCueStartingAtDuration() {
        #expect(SubtitleTimeline.effective([cue(10, 11)], offset: 0, duration: 10).isEmpty)
    }

    @Test func effectivePositiveOffsetShiftsLater() {
        let out = SubtitleTimeline.effective([cue(1, 2)], offset: 3, duration: 10)
        #expect(out.count == 1 && out[0].begin == 4 && out[0].end == 5)
    }

    @Test func effectiveNegativeOffsetShiftsEarlier() {
        let out = SubtitleTimeline.effective([cue(5, 6)], offset: -3, duration: 10)
        #expect(out.count == 1 && out[0].begin == 2 && out[0].end == 3)
    }

    @Test func effectiveDropsCueShiftedPastEnd() {
        #expect(SubtitleTimeline.effective([cue(8, 9)], offset: 5, duration: 10).isEmpty)
    }

    @Test func effectiveDropsCueShiftedBeforeZero() {
        #expect(SubtitleTimeline.effective([cue(1, 2)], offset: -5, duration: 10).isEmpty)
    }

    @Test func effectiveClampsBeginAtZero() {
        let out = SubtitleTimeline.effective([cue(1, 4)], offset: -2, duration: 10)
        #expect(out.count == 1 && out[0].begin == 0 && out[0].end == 2)
    }

    @Test func effectiveClampsEndAtDuration() {
        let out = SubtitleTimeline.effective([cue(7, 11)], offset: 1, duration: 10)
        #expect(out.count == 1 && out[0].begin == 8 && out[0].end == 10)
    }

    @Test func subRowsSingleRowWhenNoOverlap() {
        let rows = SubtitleTimeline.subRows([cue(0, 1), cue(1, 2), cue(2, 3)])
        #expect(rows.count == 1 && rows[0].count == 3)
    }

    @Test func subRowsSecondRowOnOverlap() {
        let rows = SubtitleTimeline.subRows([cue(0, 3), cue(1, 4)])
        #expect(rows.count == 2)
    }
}
