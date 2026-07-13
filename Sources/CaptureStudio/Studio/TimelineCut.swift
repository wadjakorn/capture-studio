import Foundation

/// Pure math for collapsing hidden ("cut") ranges out of the timeline for export.
/// The visible timeline is the full clip with the `cuts` removed and everything
/// after each cut shifted left. The whole mapping is one monotonic function
/// `map(t) = t - hiddenBefore(t)`:
///  - a point inside a cut maps to the cut's (collapsed) start;
///  - a block spanning a cut shrinks by the cut's width (it continues across the
///    removed region);
///  - a block straddling a cut boundary clamps to that boundary;
///  - a block wholly inside a cut collapses to zero width → dropped.
/// `cuts` are `[begin, end)` in timeline seconds (use `TimelineSegments.cutRanges`);
/// they are assumed non-overlapping and sorted. No AVFoundation — unit-tested.
enum TimelineCut {
    /// Total hidden time strictly before `t`.
    static func hiddenBefore(_ t: Double, cuts: [Range<Double>]) -> Double {
        cuts.reduce(0) { $0 + max(0, min(t, $1.upperBound) - $1.lowerBound) }
    }

    /// Map a timeline time onto the collapsed (cuts-removed) timeline.
    static func map(_ t: Double, cuts: [Range<Double>]) -> Double {
        t - hiddenBefore(t, cuts: cuts)
    }

    /// Collapsed duration of a `duration`-long timeline with `cuts` removed.
    static func remainingDuration(_ duration: Double, cuts: [Range<Double>]) -> Double {
        map(duration, cuts: cuts)
    }

    /// Whether `t` falls inside a cut (removed) region.
    static func isCut(_ t: Double, cuts: [Range<Double>]) -> Bool {
        cuts.contains { $0.lowerBound <= t && t < $0.upperBound }
    }

    /// Collapse a block's `[begin, end]` onto the visible timeline. Returns nil when
    /// the block is wholly inside a cut (positive width that collapses to zero) —
    /// the caller drops it. A genuine zero-width marker (begin == end) not inside a
    /// cut is preserved.
    static func span(begin: Double, end: Double, cuts: [Range<Double>]) -> (begin: Double, end: Double)? {
        let b = map(begin, cuts: cuts)
        let e = map(end, cuts: cuts)
        if end > begin && e - b < 1e-9 { return nil }   // fully inside a cut
        return (b, e)
    }

    /// Collapse an instantaneous sample time (cursor/click). Returns nil when the
    /// sample sits inside a cut (it's removed).
    static func point(_ t: Double, cuts: [Range<Double>]) -> Double? {
        isCut(t, cuts: cuts) ? nil : map(t, cuts: cuts)
    }
}
