import Foundation

/// Pure trim/rebase math for committing a "set in / set out" window onto an
/// `EditState`. Trimming is destructive on the edit model: the timeline is cut
/// to `[in, out]`, every lane is rebased so the clip starts at the in-point, any
/// block fully outside the window is dropped, and a block straddling a boundary
/// is clamped to it. The masters themselves are never mutated — `committedTrim
/// Start/End` records the absolute source window so `StudioModel` re-derives the
/// trimmed composition. No AVFoundation, no UI — all unit-tested.
enum TrimTimeline {
    /// Commit the window `[trimIn, trimOut]` (timeline-relative, within the
    /// current `duration`) onto `edit`, returning the rebased edit. Compounds
    /// with any prior committed trim (the new absolute window is offset by the
    /// existing `committedTrimStart`). Live markers reset to the full new window.
    static func apply(_ edit: EditState, in trimIn: Double, out trimOut: Double,
                      duration: Double) -> EditState {
        let lo = min(max(0, trimIn), duration)
        let hi = min(max(lo, trimOut), duration)
        var e = edit
        e.cameraBlocks = edit.cameraBlocks.compactMap { rebase($0, lo: lo, hi: hi) }
        e.layoutBlocks = edit.layoutBlocks.compactMap { rebase($0, lo: lo, hi: hi) }
        e.zoomBlocks   = edit.zoomBlocks.compactMap   { rebase($0, lo: lo, hi: hi) }
        e.textBlocks   = edit.textBlocks.compactMap   { rebase($0, lo: lo, hi: hi) }
        e.shapeBlocks  = edit.shapeBlocks.compactMap  { rebase($0, lo: lo, hi: hi) }
        if var track = edit.subtitles {
            // Cues are kept verbatim and clamped at consumption; shifting the
            // track offset re-aligns them to the new t = 0.
            track.offset -= lo
            e.subtitles = track
        }
        e.committedTrimStart = edit.committedTrimStart + lo
        e.committedTrimEnd = edit.committedTrimStart + hi
        e.trimIn = 0
        e.trimOut = nil
        return e
    }

    /// Maps a block's `[begin, end]` from the old timeline into the window
    /// `[lo, hi]` and shifts it to start at 0. Returns nil if the block lies
    /// entirely in the trimmed-out head/tail. A zero-width hard cut inside the
    /// window is preserved; a positive-width block that only touches a boundary
    /// is dropped.
    private static func span(begin: Double, end: Double,
                             lo: Double, hi: Double) -> (Double, Double)? {
        if end < lo || begin > hi { return nil }
        let b = max(lo, begin)
        let e = min(hi, end)
        if end > begin && e <= b { return nil }   // positive-width but no overlap
        return (b - lo, e - lo)
    }

    private static func rebase(_ blk: CameraBlock, lo: Double, hi: Double) -> CameraBlock? {
        guard let (b, e) = span(begin: blk.begin, end: blk.end, lo: lo, hi: hi) else { return nil }
        var n = blk; n.begin = b; n.end = e; return n
    }
    private static func rebase(_ blk: LayoutBlock, lo: Double, hi: Double) -> LayoutBlock? {
        guard let (b, e) = span(begin: blk.begin, end: blk.end, lo: lo, hi: hi) else { return nil }
        var n = blk; n.begin = b; n.end = e; return n
    }
    private static func rebase(_ blk: ZoomBlock, lo: Double, hi: Double) -> ZoomBlock? {
        guard let (b, e) = span(begin: blk.begin, end: blk.end, lo: lo, hi: hi) else { return nil }
        var n = blk; n.begin = b; n.end = e; return n
    }
    private static func rebase(_ blk: TextBlock, lo: Double, hi: Double) -> TextBlock? {
        guard let (b, e) = span(begin: blk.begin, end: blk.end, lo: lo, hi: hi) else { return nil }
        var n = blk; n.begin = b; n.end = e; return n
    }
    private static func rebase(_ blk: ShapeBlock, lo: Double, hi: Double) -> ShapeBlock? {
        guard let (b, e) = span(begin: blk.begin, end: blk.end, lo: lo, hi: hi) else { return nil }
        var n = blk; n.begin = b; n.end = e; return n
    }
}
