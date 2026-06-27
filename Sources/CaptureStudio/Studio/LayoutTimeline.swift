import Foundation

/// Pure block math for the **layout timeline**: which `CameraLayout` is in
/// effect at a time, plus the add / move / resize / remove operations the lane
/// UI drives. Blocks are non-overlapping spans (a single layout at a time), so
/// the clamps here guarantee no overlap. Unlike `CameraTimeline`, a layout is
/// held flat across its span (categorical — never interpolated). Time not
/// covered by any block is a gap (renders blank). Mirrors `ZoomTimeline`'s edge
/// logic. No AVFoundation, no UI — all unit-tested.
enum LayoutTimeline {
    /// Smallest block width the lane will create / keep, in seconds. Used both
    /// for the default insert width and to decide whether a gap can hold a new
    /// block (so the "add" button can disable when the timeline is full).
    static let minBlockWidth = 0.1

    /// The layout covering `t`, or nil when `t` falls in a gap (or there are no
    /// blocks). Spans are `[begin, end)`; the caller supplies the fallback
    /// (home layout for an empty timeline, blank for a real gap).
    static func sample(at t: Double, blocks: [LayoutBlock]) -> CameraLayout? {
        blocks.first { $0.begin <= t && t < $0.end }?.layout
    }

    // MARK: - Gap / capacity

    /// Free `[begin, end)` gaps between blocks across `[0, duration]`, each at
    /// least `minWidth` wide. Used to gate insertion and pick the insert point.
    static func gaps(_ blocks: [LayoutBlock], duration: Double,
                     minWidth: Double = minBlockWidth) -> [(begin: Double, end: Double)] {
        guard duration > 0 else { return [] }
        let sorted = sortedByBegin(blocks)
        var result: [(Double, Double)] = []
        var cursor = 0.0
        for b in sorted {
            if b.begin - cursor >= minWidth { result.append((cursor, b.begin)) }
            cursor = max(cursor, b.end)
        }
        if duration - cursor >= minWidth { result.append((cursor, duration)) }
        return result
    }

    /// Whether a new block (≥ `minWidth`) would fit anywhere — the "add" button
    /// is enabled iff this is true.
    static func hasSpace(_ blocks: [LayoutBlock], duration: Double,
                         minWidth: Double = minBlockWidth) -> Bool {
        !gaps(blocks, duration: duration, minWidth: minWidth).isEmpty
    }

    /// The begin time for a new block near `atTime`: the start of the gap that
    /// contains `atTime`, else the start of the first gap at/after it, else the
    /// first gap of any. nil when the timeline is full.
    static func insertBegin(_ blocks: [LayoutBlock], atTime: Double, duration: Double,
                            minWidth: Double = minBlockWidth) -> Double? {
        let gs = gaps(blocks, duration: duration, minWidth: minWidth)
        guard !gs.isEmpty else { return nil }
        // Playhead sits in a free gap: start the block at the playhead, but keep
        // it back far enough that a min-width block still fits before the gap end.
        if let here = gs.first(where: { $0.begin <= atTime && atTime < $0.end }) {
            return min(max(atTime, here.begin), here.end - minWidth)
        }
        if let after = gs.first(where: { $0.begin >= atTime }) { return after.begin }
        return gs.first?.begin
    }

    // MARK: - Edge clamps (non-overlap)

    static func clampBegin(_ blocks: [LayoutBlock], id: UUID, toTime: Double,
                           duration: Double) -> Double {
        let sorted = sortedByBegin(blocks)
        guard let i = sorted.firstIndex(where: { $0.id == id }) else { return toTime }
        let lower = i > 0 ? sorted[i - 1].end : 0
        let upper = sorted[i].end
        return min(max(toTime, lower), upper)
    }

    static func clampEnd(_ blocks: [LayoutBlock], id: UUID, toTime: Double,
                         duration: Double) -> Double {
        let sorted = sortedByBegin(blocks)
        guard let i = sorted.firstIndex(where: { $0.id == id }) else { return toTime }
        let lower = sorted[i].begin
        let upper = i + 1 < sorted.count ? sorted[i + 1].begin : duration
        return min(max(toTime, lower), upper)
    }

    // MARK: - Operations

    static func moveBegin(_ blocks: [LayoutBlock], id: UUID, toTime: Double,
                          duration: Double) -> [LayoutBlock] {
        let t = clampBegin(blocks, id: id, toTime: toTime, duration: duration)
        return sortedByBegin(blocks.map { $0.id == id ? with($0, begin: t) : $0 })
    }

    static func moveEnd(_ blocks: [LayoutBlock], id: UUID, toTime: Double,
                        duration: Double) -> [LayoutBlock] {
        let t = clampEnd(blocks, id: id, toTime: toTime, duration: duration)
        return sortedByBegin(blocks.map { $0.id == id ? with($0, end: t) : $0 })
    }

    static func moveBlock(_ blocks: [LayoutBlock], id: UUID, toBegin: Double,
                          duration: Double) -> [LayoutBlock] {
        let sorted = sortedByBegin(blocks)
        guard let i = sorted.firstIndex(where: { $0.id == id }) else { return sorted }
        let width = sorted[i].end - sorted[i].begin
        let lower = i > 0 ? sorted[i - 1].end : 0
        let upperBegin = (i + 1 < sorted.count ? sorted[i + 1].begin : duration) - width
        let begin = min(max(toBegin, lower), max(lower, upperBegin))
        return sortedByBegin(sorted.map {
            $0.id == id ? with($0, begin: begin, end: begin + width) : $0
        })
    }

    static func remove(_ blocks: [LayoutBlock], id: UUID) -> [LayoutBlock] {
        blocks.filter { $0.id != id }
    }

    /// Insert a `width`-wide `layout` block near `atTime`, snapped into the gap
    /// that holds (or follows) `atTime` and clamped to the gap's far edge so the
    /// result never overlaps. Returns nil (no insert) when the timeline is full.
    static func add(_ blocks: [LayoutBlock], atTime: Double, width: Double,
                    duration: Double, layout: CameraLayout)
        -> (blocks: [LayoutBlock], id: UUID)? {
        guard let begin = insertBegin(blocks, atTime: atTime, duration: duration) else {
            return nil
        }
        let nextBegin = sortedByBegin(blocks).first { $0.begin > begin }?.begin ?? duration
        let end = min(begin + max(minBlockWidth, width), nextBegin, duration)
        let block = LayoutBlock(begin: begin, end: max(begin, end), layout: layout)
        return (sortedByBegin(blocks + [block]), block.id)
    }

    // MARK: - Helpers

    private static func sortedByBegin(_ blocks: [LayoutBlock]) -> [LayoutBlock] {
        blocks.sorted { $0.begin < $1.begin }
    }

    private static func with(_ b: LayoutBlock, begin: Double? = nil,
                             end: Double? = nil) -> LayoutBlock {
        var c = b
        if let begin { c.begin = begin }
        if let end { c.end = end }
        return c
    }
}
