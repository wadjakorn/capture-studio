import Foundation

/// Resolved camera placement at a single instant: position + scale in the same
/// normalized units as the static `EditState.camera*` fields, plus an opacity
/// (1 = fully shown, 0 = hidden) so show/hide reads as a crossfade.
struct CameraSample: Equatable {
    var centerX: Double
    var centerY: Double
    var scale: Double
    var opacity: Double
}

/// Pure block math: evaluate the camera state at a time, and the add / move /
/// remove operations the lane UI drives. Blocks are transition spans — the
/// camera eases from the previous block's settled placement (or `home` for the
/// first block) into a block over `[begin, end]`, then holds. Non-overlap is
/// enforced by the clamps here, which guarantees a transition is never
/// interrupted (no discontinuity). No AVFoundation, no UI — all unit-tested.
enum CameraTimeline {
    /// Ease-in-out (smoothstep): flat slope at both ends, 0→0, 1→1.
    static func ease(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// Camera state at `t`. Empty blocks → `home` (the static placement).
    static func sample(at t: Double, blocks: [CameraBlock], home: CameraSample) -> CameraSample {
        guard !blocks.isEmpty else { return home }
        let sorted = blocks.sorted { $0.begin < $1.begin }
        // Before the first block: hold home.
        guard let k = sorted.lastIndex(where: { $0.begin <= t }) else { return home }
        let block = sorted[k]
        let target = state(block)
        if t < block.end {
            // Inside the ramp: ease the previous settled placement → this target.
            let from = k == 0 ? home : state(sorted[k - 1])
            let span = block.end - block.begin
            let f = span > 0 ? ease((t - block.begin) / span) : 1
            return CameraSample(
                centerX: lerp(from.centerX, target.centerX, f),
                centerY: lerp(from.centerY, target.centerY, f),
                scale: lerp(from.scale, target.scale, f),
                opacity: lerp(from.opacity, target.opacity, f)
            )
        }
        return target   // settled — hold until the next block
    }

    // MARK: - Edge clamps (non-overlap)

    /// A block's begin can't cross its own end, the previous block's end, or 0.
    static func clampBegin(_ blocks: [CameraBlock], id: UUID, toTime: Double,
                           duration: Double) -> Double {
        let sorted = sortedByBegin(blocks)
        guard let i = sorted.firstIndex(where: { $0.id == id }) else { return toTime }
        let lower = i > 0 ? sorted[i - 1].end : 0
        let upper = sorted[i].end
        return min(max(toTime, lower), upper)
    }

    /// A block's end can't cross its own begin, the next block's begin, or the
    /// clip duration.
    static func clampEnd(_ blocks: [CameraBlock], id: UUID, toTime: Double,
                         duration: Double) -> Double {
        let sorted = sortedByBegin(blocks)
        guard let i = sorted.firstIndex(where: { $0.id == id }) else { return toTime }
        let lower = sorted[i].begin
        let upper = i + 1 < sorted.count ? sorted[i + 1].begin : duration
        return min(max(toTime, lower), upper)
    }

    // MARK: - Operations

    static func moveBegin(_ blocks: [CameraBlock], id: UUID, toTime: Double,
                          duration: Double) -> [CameraBlock] {
        let t = clampBegin(blocks, id: id, toTime: toTime, duration: duration)
        return sortedByBegin(blocks.map { $0.id == id ? with($0, begin: t) : $0 })
    }

    static func moveEnd(_ blocks: [CameraBlock], id: UUID, toTime: Double,
                        duration: Double) -> [CameraBlock] {
        let t = clampEnd(blocks, id: id, toTime: toTime, duration: duration)
        return sortedByBegin(blocks.map { $0.id == id ? with($0, end: t) : $0 })
    }

    /// Shift a whole block (keeping its width) to a new begin, clamped so it
    /// stays inside its neighbors.
    static func moveBlock(_ blocks: [CameraBlock], id: UUID, toBegin: Double,
                          duration: Double) -> [CameraBlock] {
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

    static func remove(_ blocks: [CameraBlock], id: UUID) -> [CameraBlock] {
        blocks.filter { $0.id != id }
    }

    /// Insert a block at `atTime`, `width` wide, taking `placement` as its
    /// target. Pushed past any block it lands inside and clamped to the next
    /// block / duration, so the result never overlaps.
    static func add(_ blocks: [CameraBlock], atTime: Double, width: Double,
                    duration: Double, placement: CameraSample)
        -> (blocks: [CameraBlock], id: UUID) {
        let lowerBound = blocks.filter { $0.begin <= atTime }.map(\.end).max() ?? 0
        let begin = min(max(atTime, lowerBound, 0), max(0, duration))
        let nextBegin = blocks.filter { $0.begin > begin }.map(\.begin).min() ?? duration
        let end = min(begin + max(0, width), nextBegin, duration)
        let block = CameraBlock(begin: begin, end: max(begin, end),
                                visible: placement.opacity > 0.5,
                                centerX: placement.centerX, centerY: placement.centerY,
                                scale: placement.scale)
        return (sortedByBegin(blocks + [block]), block.id)
    }

    // MARK: - Helpers

    private static func state(_ b: CameraBlock) -> CameraSample {
        CameraSample(centerX: b.centerX, centerY: b.centerY,
                     scale: b.scale, opacity: b.visible ? 1 : 0)
    }

    private static func lerp(_ a: Double, _ b: Double, _ f: Double) -> Double {
        a + (b - a) * f
    }

    private static func sortedByBegin(_ blocks: [CameraBlock]) -> [CameraBlock] {
        blocks.sorted { $0.begin < $1.begin }
    }

    private static func with(_ b: CameraBlock, begin: Double? = nil,
                             end: Double? = nil) -> CameraBlock {
        var c = b
        if let begin { c.begin = begin }
        if let end { c.end = end }
        return c
    }
}
