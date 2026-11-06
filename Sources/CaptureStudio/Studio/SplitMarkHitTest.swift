import CoreGraphics

/// Hit-target geometry for split marks on the timeline lane.
enum SplitMarkHitTest {
    /// x-ranges (points) for marks at `xs` (in points): each mark gets half the gap to its
    /// neighbours on either side, capped at `maxHalf` (8), clamped to [0, width]. Never overlapping.
    ///
    /// Precondition: `xs` is sorted ascending (the model keeps `segments` sorted, so mark xs are too).
    static func rects(xs: [CGFloat], width: CGFloat, maxHalf: CGFloat = 8) -> [ClosedRange<CGFloat>] {
        let last = xs.count - 1
        return xs.indices.map { i in
            let x = xs[i]
            let lo = max(x - maxHalf, i == 0 ? 0 : (xs[i - 1] + x) / 2)
            let hi = min(x + maxHalf, i == last ? width : (x + xs[i + 1]) / 2)
            return lo...max(lo, hi)
        }
    }
}
