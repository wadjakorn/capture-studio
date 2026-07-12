import CoreGraphics

/// Pure geometry for a timeline block's begin/end edge *hit regions* — the
/// invisible drag targets, not the visible edge capsules.
///
/// The visible capsule sits on the edge, but its hit target is biased **into
/// the block's own interior** instead of straddling the edge. Two consequences:
///
/// - **Adjacent blocks stay separable.** When block A's end meets block B's
///   begin at the same x, A's end target lives inside A (left of the boundary)
///   and B's begin target lives inside B (right of the boundary), so the two
///   16pt targets no longer overlap and each edge stays grabbable.
/// - **Short blocks stay movable.** Each edge target is capped at a *fraction*
///   of the body (`edgeFraction`), so a short block always keeps a central band
///   free for the body drag-to-move gesture instead of the two edges swallowing
///   the whole block. Edges shrink with the block; the body is never fully
///   consumed.
///
/// Coordinates are local to the block body (x = 0 at begin, x = `bodyWidth` at
/// end). The regions are half-open in intent (`[lowerBound, upperBound)`) and
/// never overlap (`edgeFraction` is clamped to ≤ 0.5).
struct EdgeHitRegions: Equatable {
    /// Local-x span of the begin (left) edge hit target.
    let begin: ClosedRange<CGFloat>
    /// Local-x span of the end (right) edge hit target.
    let end: ClosedRange<CGFloat>

    /// - Parameters:
    ///   - bodyWidth: rendered block width in points (negatives treated as 0).
    ///   - handleWidth: max hit-target width per edge on a wide block (e.g. 16).
    ///   - edgeFraction: share of the body each edge may take on a narrow block,
    ///     clamped to `0...0.5`. The default 0.3 leaves ~40% of a short block as
    ///     a central move zone.
    init(bodyWidth: CGFloat, handleWidth: CGFloat, edgeFraction: CGFloat = 0.3) {
        let w = max(0, bodyWidth)
        let frac = min(0.5, max(0, edgeFraction))
        // Cap each edge at the smaller of the fixed handle width and the
        // fractional share, so a short block keeps a central move band.
        let hw = min(max(0, handleWidth), w * frac)
        begin = 0...hw
        end = (w - hw)...w
    }

    var beginWidth: CGFloat { begin.upperBound - begin.lowerBound }
    var endWidth: CGFloat { end.upperBound - end.lowerBound }

    /// Center x for positioning a target rectangle via SwiftUI `.position(x:)`.
    var beginMidX: CGFloat { (begin.lowerBound + begin.upperBound) / 2 }
    var endMidX: CGFloat { (end.lowerBound + end.upperBound) / 2 }
}
