import Foundation

/// One piece of the master timeline produced by splitting. Segments partition the
/// whole timeline `[0, duration]` contiguously (`segment[i].end == segment[i+1].start`,
/// first `start == 0`, last `end == duration`). `hidden` marks a segment cut from
/// the output — non-destructively:
/// nothing is removed from the masters or the blocks, the cut is just stored and
/// applied at play/export time and can be restored (`hidden = false`) or reset.
struct TimelineSegment: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var hidden: Bool = false
}

/// Pure math for the split-&-cut master timeline. Segments are the complement of
/// the zoom/camera lanes: they tile the whole timeline with no gaps or overlap, so
/// the helpers here keep that invariant. Splitting divides the segment under the
/// playhead; hiding/restoring flips a flag; the merged hidden runs (`cutRanges`)
/// drive playback-skip and export. No AVFoundation, no UI — all unit-tested.
enum TimelineSegments {
    /// Smallest piece a split may leave on either side; a split closer than this to
    /// a boundary is refused (mirrors `ZoomTimeline.splitMinWidth`). Shared with the
    /// UI so the Split control can disable itself instead of silently no-opping.
    static let splitMinWidth = 0.05

    /// The default single visible segment spanning the whole timeline.
    static func full(duration: Double) -> [TimelineSegment] {
        [TimelineSegment(start: 0, end: max(0, duration))]
    }

    /// Clamp a stored segment list onto the current `duration`: sort, clip bounds to
    /// `[0, duration]`, drop empty pieces, and fill any gap / trailing remainder with
    /// a visible segment so the result always tiles `[0, duration]`. An empty or
    /// fully-degenerate list collapses to a single visible segment. Called on load
    /// (the duration may differ from when the cuts were saved).
    static func normalized(_ segments: [TimelineSegment], duration: Double) -> [TimelineSegment] {
        let dur = max(0, duration)
        guard dur > 0 else { return full(duration: 0) }
        let clipped = segments
            .map { TimelineSegment(id: $0.id, start: min(max(0, $0.start), dur),
                                   end: min(max(0, $0.end), dur), hidden: $0.hidden) }
            .filter { $0.end - $0.start > 1e-9 }
            .sorted { $0.start < $1.start }
        guard !clipped.isEmpty else { return full(duration: dur) }

        var out: [TimelineSegment] = []
        var cursor = 0.0
        for var seg in clipped {
            // Fill any gap before this segment (overlaps are trimmed to `cursor`).
            if seg.start > cursor + 1e-9 {
                out.append(TimelineSegment(start: cursor, end: seg.start))
            }
            seg.start = max(seg.start, cursor)
            if seg.end - seg.start > 1e-9 {
                out.append(seg)
                cursor = seg.end
            }
        }
        if dur - cursor > 1e-9 { out.append(TimelineSegment(start: cursor, end: dur)) }
        return out.isEmpty ? full(duration: dur) : out
    }

    /// True when a split at `t` would land strictly inside a segment with at least
    /// `minWidth` on each side (drives the Split control's enabled state).
    static func canSplit(_ segments: [TimelineSegment], at t: Double,
                         minWidth: Double = splitMinWidth) -> Bool {
        segments.contains { $0.start < t && t < $0.end
            && t - $0.start >= minWidth && $0.end - t >= minWidth }
    }

    /// Split the segment spanning `t` into two touching segments at `t`. The left
    /// half keeps the original id (and hidden flag); the right half gets a new id
    /// (returned so the caller can select it) and inherits the hidden flag. No-op
    /// (nil id) when no segment strictly spans `t` or either piece would be narrower
    /// than `minWidth`.
    static func split(_ segments: [TimelineSegment], at t: Double,
                      minWidth: Double = splitMinWidth) -> (segments: [TimelineSegment], id: UUID?) {
        let sorted = segments.sorted { $0.start < $1.start }
        guard let i = sorted.firstIndex(where: { $0.start < t && t < $0.end }),
              t - sorted[i].start >= minWidth,
              sorted[i].end - t >= minWidth else { return (sorted, nil) }
        var left = sorted[i]; left.end = t
        var right = sorted[i]; right.id = UUID(); right.start = t
        var out = sorted
        out[i] = left
        out.insert(right, at: i + 1)
        return (out, right.id)
    }

    /// Number of visible (non-hidden) segments.
    static func visibleCount(_ segments: [TimelineSegment]) -> Int {
        segments.reduce(0) { $0 + ($1.hidden ? 0 : 1) }
    }

    /// Set a segment's hidden flag. Refuses to hide the last visible segment (there
    /// must always be something to play/export); returns the list unchanged then.
    static func setHidden(_ segments: [TimelineSegment], id: UUID, _ hidden: Bool)
        -> [TimelineSegment] {
        guard segments.contains(where: { $0.id == id }) else { return segments }
        if hidden && visibleCount(segments.filter { $0.id != id }) == 0 { return segments }
        return segments.map { $0.id == id ? TimelineSegment(id: $0.id, start: $0.start,
                                                            end: $0.end, hidden: hidden) : $0 }
    }

    /// The hidden runs merged into `[begin, end)` ranges (adjacent hidden segments
    /// coalesce). These are the ranges playback skips and export removes.
    static func cutRanges(_ segments: [TimelineSegment]) -> [Range<Double>] {
        let sorted = segments.sorted { $0.start < $1.start }
        var out: [Range<Double>] = []
        for seg in sorted where seg.hidden {
            if let last = out.last, abs(last.upperBound - seg.start) < 1e-9 {
                out[out.count - 1] = last.lowerBound ..< seg.end
            } else {
                out.append(seg.start ..< seg.end)
            }
        }
        return out
    }

    /// The first hidden range that contains `t` (playhead), if any — used to skip it
    /// during playback by seeking to its `upperBound`.
    static func hiddenRange(containing t: Double, in segments: [TimelineSegment]) -> Range<Double>? {
        cutRanges(segments).first { $0.lowerBound <= t && t < $0.upperBound }
    }

    /// Hide `[range.lowerBound, range.upperBound)`: split at each bound that lies
    /// strictly inside a segment (a bound within `minWidth` of an existing
    /// boundary snaps to that boundary instead of splitting), then mark every
    /// segment fully inside the (snapped) range hidden. Returns the input
    /// unchanged when the range is empty after snapping or when no visible
    /// segment would remain.
    static func cut(_ segments: [TimelineSegment], range: Range<Double>,
                    minWidth: Double = splitMinWidth) -> [TimelineSegment] {
        /// Snap `b` to a nearby boundary, else split there (when allowed).
        func apply(_ b: Double, _ segs: [TimelineSegment]) -> (Double, [TimelineSegment]) {
            let bounds = segs.flatMap { [$0.start, $0.end] }
            if let x = bounds.first(where: { abs($0 - b) < minWidth }) { return (x, segs) }
            return (b, split(segs, at: b, minWidth: minWidth).segments)
        }
        let (lo, afterLo) = apply(range.lowerBound, segments.sorted { $0.start < $1.start })
        let (hi, afterHi) = apply(range.upperBound, afterLo)
        guard hi - lo > 1e-9 else { return segments }
        let out = afterHi.map { seg -> TimelineSegment in
            guard seg.start >= lo - 1e-9, seg.end <= hi + 1e-9 else { return seg }
            return TimelineSegment(id: seg.id, start: seg.start, end: seg.end, hidden: true)
        }
        return visibleCount(out) == 0 ? segments : out
    }

    /// First and last visible instants: `(start, end)` with `start` = end of a
    /// leading hidden run (else 0), `end` = start of a trailing hidden run
    /// (else `duration`).
    static func visibleBounds(_ segments: [TimelineSegment], duration: Double)
        -> (start: Double, end: Double) {
        let sorted = segments.sorted { $0.start < $1.start }
        guard let first = sorted.firstIndex(where: { !$0.hidden }),
              let last = sorted.lastIndex(where: { !$0.hidden }) else { return (0, duration) }
        return (first == 0 ? 0 : sorted[first].start,
                last == sorted.count - 1 ? duration : sorted[last].end)
    }
}

/// A cut-type transport action whose effect can be previewed on the timeline
/// while its button is hovered.
enum CutAction: Equatable { case cutSegment, restoreSegment, trimStart, trimEnd, clearAll }

/// What a hovered `CutAction` would do: the ranges it would hide (`.cut`) or
/// reveal (`.restore`), plus any split it would have to create first.
struct CutPreview: Equatable {
    enum Kind { case cut, restore }
    var ranges: [Range<Double>]
    var kind: Kind
    /// A split that the action would create (not yet a boundary) — drawn as a marker.
    var pendingSplitAt: Double?
}

extension TimelineSegments {
    /// Preview of `action` applied at playhead `t`. nil when the action would
    /// change nothing (mirrors the button's disabled state). An empty `segments`
    /// list is the implicit single full segment.
    static func preview(for action: CutAction, segments: [TimelineSegment],
                        at t: Double, duration: Double) -> CutPreview? {
        // Materialise once: `full(duration:)` mints a fresh id per call, so every
        // "did it change?" comparison below must be against this same instance.
        let s = (segments.isEmpty ? full(duration: duration) : segments)
            .sorted { $0.start < $1.start }
        let dur = max(0, duration)
        let t = min(max(t, 0), dur)
        let bounds = s.flatMap { [$0.start, $0.end] }
        /// Mirrors `cut`'s snapping: a bound within `splitMinWidth` of an existing
        /// boundary lands on it instead of splitting.
        func snapped(_ b: Double) -> (value: Double, isBoundary: Bool) {
            if let x = bounds.first(where: { abs($0 - b) < splitMinWidth }) { return (x, true) }
            return (b, false)
        }
        let under = s.first { $0.start <= t && t < $0.end }

        switch action {
        case .cutSegment:
            guard let seg = under, !seg.hidden,
                  setHidden(s, id: seg.id, true) != s else { return nil }
            return CutPreview(ranges: [seg.start ..< seg.end], kind: .cut)
        case .restoreSegment:
            guard let seg = under, seg.hidden,
                  setHidden(s, id: seg.id, false) != s else { return nil }
            return CutPreview(ranges: [seg.start ..< seg.end], kind: .restore)
        case .trimStart:
            guard cutRanges(cut(s, range: 0 ..< t)) != cutRanges(s) else { return nil }
            let hi = snapped(t)
            return CutPreview(ranges: [snapped(0).value ..< hi.value], kind: .cut,
                              pendingSplitAt: hi.isBoundary ? nil : t)
        case .trimEnd:
            guard cutRanges(cut(s, range: t ..< dur)) != cutRanges(s) else { return nil }
            let lo = snapped(t)
            return CutPreview(ranges: [lo.value ..< snapped(dur).value], kind: .cut,
                              pendingSplitAt: lo.isBoundary ? nil : t)
        case .clearAll:
            let ranges = cutRanges(s)
            return ranges.isEmpty ? nil : CutPreview(ranges: ranges, kind: .restore)
        }
    }
}
