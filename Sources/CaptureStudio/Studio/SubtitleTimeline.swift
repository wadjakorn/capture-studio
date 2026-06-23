import Foundation

/// Pure cue math for the subtitle track: which cues are visible at a time, lane
/// sub-row packing, and clamping/dropping cues against the clip duration. No
/// AVFoundation, no UI — all unit-tested. Cues are read-only (SRT-driven), so
/// unlike `TextTimeline` there are no move/add/remove operations.
enum SubtitleTimeline {
    /// Every cue live at `t`. Span is half-open `[begin, end)`.
    static func active(at t: Double, cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.filter { $0.begin <= t && t < $0.end }
    }

    /// Drop cues that start at or after `duration`; clamp each remaining end to
    /// `duration`. Preserves order.
    static func clamped(_ cues: [SubtitleCue], duration: Double) -> [SubtitleCue] {
        cues.compactMap { cue in
            guard cue.begin < duration else { return nil }
            var c = cue
            c.end = min(cue.end, duration)
            return c
        }
    }

    /// Greedy interval packing for the lane: cues sorted by `begin`, each placed
    /// in the first sub-row whose last cue ends at or before this cue's begin.
    /// Display-only.
    static func subRows(_ cues: [SubtitleCue]) -> [[SubtitleCue]] {
        let sorted = cues.sorted { $0.begin < $1.begin }
        var rows: [[SubtitleCue]] = []
        for cue in sorted {
            if let i = rows.firstIndex(where: { ($0.last?.end ?? -.infinity) <= cue.begin }) {
                rows[i].append(cue)
            } else {
                rows.append([cue])
            }
        }
        return rows
    }
}
