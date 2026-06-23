import Foundation

/// Pure block math for the text/caption track: which blocks are visible at a
/// time, the add / move / remove operations the lane UI drives, z-order
/// reordering, and greedy sub-row packing for the lane layout. No AVFoundation,
/// no UI — all unit-tested.
///
/// This is the multi-instance, overlap-allowed counterpart to `CameraTimeline`:
///   - `active(at:)` returns ALL blocks live at `t` (camera returns one).
///   - moves/adds have NO non-overlap clamp (camera enforces non-overlap).
///   - block storage order is the z-order (later = on top); operations preserve
///     it, and only the explicit reorder ops change it. Nothing here sorts the
///     stored array — `subRows` sorts a local copy for display only.
enum TextTimeline {
    /// Every block live at `t`, in array (z) order. Span is half-open
    /// `[begin, end)`, so `begin == end` never shows.
    static func active(at t: Double, blocks: [TextBlock]) -> [TextBlock] {
        blocks.filter { $0.begin <= t && t < $0.end }
    }

    // MARK: - Operations (overlap allowed; only clamp to the clip + begin<=end)

    /// Append a block `[atTime, atTime + width]` clamped to `[0, duration]`.
    /// Appended at the end of the array = top of the z-order. No neighbor clamp:
    /// the new block may overlap existing ones.
    static func add(_ blocks: [TextBlock], atTime: Double, width: Double,
                    duration: Double, template: TextBlock)
        -> (blocks: [TextBlock], id: UUID) {
        let begin = clamp(atTime, 0, max(0, duration))
        let end = min(begin + max(0, width), max(begin, duration))
        var block = template
        block.id = UUID()
        block.begin = begin
        block.end = max(begin, end)
        return (blocks + [block], block.id)
    }

    /// Move a block's begin; clamped only to `[0, its own end]`.
    static func moveBegin(_ blocks: [TextBlock], id: UUID, toTime: Double,
                          duration: Double) -> [TextBlock] {
        blocks.map { b in
            guard b.id == id else { return b }
            var c = b
            c.begin = clamp(toTime, 0, b.end)
            return c
        }
    }

    /// Move a block's end; clamped only to `[its own begin, duration]`.
    static func moveEnd(_ blocks: [TextBlock], id: UUID, toTime: Double,
                        duration: Double) -> [TextBlock] {
        blocks.map { b in
            guard b.id == id else { return b }
            var c = b
            c.end = clamp(toTime, b.begin, max(b.begin, duration))
            return c
        }
    }

    /// Shift a whole block (keeping width) to a new begin, clamped to the clip.
    /// No neighbor clamp — the block may slide across others.
    static func moveBlock(_ blocks: [TextBlock], id: UUID, toBegin: Double,
                          duration: Double) -> [TextBlock] {
        blocks.map { b in
            guard b.id == id else { return b }
            let width = b.end - b.begin
            let begin = clamp(toBegin, 0, max(0, duration - width))
            var c = b
            c.begin = begin
            c.end = begin + width
            return c
        }
    }

    static func remove(_ blocks: [TextBlock], id: UUID) -> [TextBlock] {
        blocks.filter { $0.id != id }
    }

    // MARK: - Z-order (array index moves)

    /// Move the block one step toward the top (higher index draws later = above).
    static func bringForward(_ blocks: [TextBlock], id: UUID) -> [TextBlock] {
        guard let i = blocks.firstIndex(where: { $0.id == id }), i < blocks.count - 1
        else { return blocks }
        var b = blocks
        b.swapAt(i, i + 1)
        return b
    }

    /// Move the block one step toward the bottom.
    static func sendBackward(_ blocks: [TextBlock], id: UUID) -> [TextBlock] {
        guard let i = blocks.firstIndex(where: { $0.id == id }), i > 0 else { return blocks }
        var b = blocks
        b.swapAt(i, i - 1)
        return b
    }

    static func moveToFront(_ blocks: [TextBlock], id: UUID) -> [TextBlock] {
        guard let i = blocks.firstIndex(where: { $0.id == id }) else { return blocks }
        var b = blocks
        let block = b.remove(at: i)
        b.append(block)
        return b
    }

    static func moveToBack(_ blocks: [TextBlock], id: UUID) -> [TextBlock] {
        guard let i = blocks.firstIndex(where: { $0.id == id }) else { return blocks }
        var b = blocks
        let block = b.remove(at: i)
        b.insert(block, at: 0)
        return b
    }

    // MARK: - Lane layout

    /// Greedy interval packing for the timeline lane: blocks sorted by `begin`,
    /// each placed in the first sub-row whose last block ends at or before this
    /// block's begin (touching is allowed). Returns the sub-row buckets; the
    /// count is the peak overlap depth. Display-only — does not affect storage
    /// or z-order. Zero-width blocks still occupy a slot at their instant.
    static func subRows(_ blocks: [TextBlock]) -> [[TextBlock]] {
        let sorted = blocks.sorted { $0.begin < $1.begin }
        var rows: [[TextBlock]] = []
        for block in sorted {
            if let i = rows.firstIndex(where: { ($0.last?.end ?? -.infinity) <= block.begin }) {
                rows[i].append(block)
            } else {
                rows.append([block])
            }
        }
        return rows
    }

    // MARK: - Helpers

    /// Frame-aligned time for the first visible frame of a caption with the given
    /// begin time. Aligns the time to the nearest frame boundary (rounded up) so
    /// the caption appears at the seeked frame instead of one frame late.
    static func firstVisibleTime(begin: Double, fps: Int) -> Double {
        let frameRate = Double(fps)
        return ceil(begin * frameRate) / frameRate
    }

    private static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(x, lo), max(lo, hi))
    }
}
