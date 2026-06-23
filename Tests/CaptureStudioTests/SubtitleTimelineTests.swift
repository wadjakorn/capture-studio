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

    @Test func clampedDropsPastDurationAndClampsEnd() {
        let c = [cue(1, 5, "keep"), cue(8, 12, "clamp"), cue(20, 22, "drop")]
        let out = SubtitleTimeline.clamped(c, duration: 10)
        #expect(out.count == 2)
        #expect(out[0].text == "keep" && out[0].end == 5)
        #expect(out[1].text == "clamp" && out[1].end == 10)   // clamped to duration
    }

    @Test func clampedDropsCueStartingAtDuration() {
        #expect(SubtitleTimeline.clamped([cue(10, 11)], duration: 10).isEmpty)
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
