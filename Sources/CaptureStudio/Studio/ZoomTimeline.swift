import Foundation

/// Pure block math for the auto-zoom timeline: add / move / resize / remove
/// operations the lane UI drives. Blocks are non-overlapping spans (a single
/// zoom state at a time), so the clamps here guarantee no overlap. Mirrors
/// `CameraTimeline`'s edge logic. No AVFoundation, no UI — all unit-tested.
enum ZoomTimeline {
    // MARK: - Edge clamps (non-overlap)

    static func clampBegin(_ blocks: [ZoomBlock], id: UUID, toTime: Double,
                           duration: Double) -> Double {
        let sorted = sortedByBegin(blocks)
        guard let i = sorted.firstIndex(where: { $0.id == id }) else { return toTime }
        let lower = i > 0 ? sorted[i - 1].end : 0
        let upper = sorted[i].end
        return min(max(toTime, lower), upper)
    }

    static func clampEnd(_ blocks: [ZoomBlock], id: UUID, toTime: Double,
                         duration: Double) -> Double {
        let sorted = sortedByBegin(blocks)
        guard let i = sorted.firstIndex(where: { $0.id == id }) else { return toTime }
        let lower = sorted[i].begin
        let upper = i + 1 < sorted.count ? sorted[i + 1].begin : duration
        return min(max(toTime, lower), upper)
    }

    // MARK: - Operations

    static func moveBegin(_ blocks: [ZoomBlock], id: UUID, toTime: Double,
                          duration: Double) -> [ZoomBlock] {
        let t = clampBegin(blocks, id: id, toTime: toTime, duration: duration)
        return sortedByBegin(blocks.map { $0.id == id ? with($0, begin: t) : $0 })
    }

    static func moveEnd(_ blocks: [ZoomBlock], id: UUID, toTime: Double,
                        duration: Double) -> [ZoomBlock] {
        let t = clampEnd(blocks, id: id, toTime: toTime, duration: duration)
        return sortedByBegin(blocks.map { $0.id == id ? with($0, end: t) : $0 })
    }

    static func moveBlock(_ blocks: [ZoomBlock], id: UUID, toBegin: Double,
                          duration: Double) -> [ZoomBlock] {
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

    static func remove(_ blocks: [ZoomBlock], id: UUID) -> [ZoomBlock] {
        blocks.filter { $0.id != id }
    }

    /// Insert a `width`-wide block at `atTime`, clamped past any block it lands
    /// inside and against the next block / duration, so the result never overlaps.
    static func add(_ blocks: [ZoomBlock], atTime: Double, width: Double,
                    duration: Double) -> (blocks: [ZoomBlock], id: UUID) {
        let lowerBound = blocks.filter { $0.begin <= atTime }.map(\.end).max() ?? 0
        let begin = min(max(atTime, lowerBound, 0), max(0, duration))
        let nextBegin = blocks.filter { $0.begin > begin }.map(\.begin).min() ?? duration
        let end = min(begin + max(0, width), nextBegin, duration)
        let block = ZoomBlock(begin: begin, end: max(begin, end))
        return (sortedByBegin(blocks + [block]), block.id)
    }

    // MARK: - Helpers

    private static func sortedByBegin(_ blocks: [ZoomBlock]) -> [ZoomBlock] {
        blocks.sorted { $0.begin < $1.begin }
    }

    private static func with(_ b: ZoomBlock, begin: Double? = nil,
                             end: Double? = nil) -> ZoomBlock {
        var c = b
        if let begin { c.begin = begin }
        if let end { c.end = end }
        return c
    }
}
