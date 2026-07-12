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
/// - **Short blocks stay resizable.** For a block too narrow to host two
///   full-width targets, the body is split down the middle — the left half
///   grabs begin, the right half grabs end — so both edges remain reachable
///   down to a couple of points instead of collapsing into one another.
///
/// Coordinates are local to the block body (x = 0 at begin, x = `bodyWidth` at
/// end). The regions are half-open in intent (`[lowerBound, upperBound)`); at a
/// split they touch at the midpoint but never overlap.
struct EdgeHitRegions: Equatable {
    /// Local-x span of the begin (left) edge hit target.
    let begin: ClosedRange<CGFloat>
    /// Local-x span of the end (right) edge hit target.
    let end: ClosedRange<CGFloat>

    /// - Parameters:
    ///   - bodyWidth: rendered block width in points (negatives treated as 0).
    ///   - handleWidth: desired hit-target width per edge (e.g. 16).
    init(bodyWidth: CGFloat, handleWidth: CGFloat) {
        let w = max(0, bodyWidth)
        // Never let the two targets overlap: cap each at half the body.
        let hw = min(max(0, handleWidth), w / 2)
        begin = 0...hw
        end = (w - hw)...w
    }

    var beginWidth: CGFloat { begin.upperBound - begin.lowerBound }
    var endWidth: CGFloat { end.upperBound - end.lowerBound }

    /// Center x for positioning a target rectangle via SwiftUI `.position(x:)`.
    var beginMidX: CGFloat { (begin.lowerBound + begin.upperBound) / 2 }
    var endMidX: CGFloat { (end.lowerBound + end.upperBound) / 2 }
}
