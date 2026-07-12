import SwiftUI

/// The grip for a timeline block's begin/end edge. Its *hit area equals the
/// visible capsule* — the lane attaches the resize gesture to this view, so
/// only the pill you see grabs the edge; the rest of the block stays free for
/// the drag-to-move gesture. The stem is decoration (`allowsHitTesting(false)`).
///
/// - `.full`: one capsule centred on the edge — the normal, isolated case.
/// - `.top` / `.bottom`: a shorter grip pushed into the top (end) or bottom
///   (begin) half, with a thin stem back to the vertical centre. When two
///   adjacent blocks share a boundary, one renders `.top` and the other
///   `.bottom`, so the two coincident lines read as separate handles instead of
///   one ambiguous bar — and their hit areas, following the grips, don't overlap.
struct TimelineEdgeHandle: View {
    let color: Color
    let placement: EdgeHandlePlacement
    /// Height of the frame the grip is centred within (= 2 × the edge's centre y).
    let contentHeight: CGFloat
    /// Capsule height in the `.full` (non-staggered) case.
    let capsuleHeight: CGFloat
    var width: CGFloat = 7

    // Staggered-look tunables (fractions of `capsuleHeight`). Adjust here to
    // taste — grip size vs. stem gap trade off against each other.
    private let gripFraction: CGFloat = 0.42   // staggered grip height
    private let gripOffset: CGFloat = 0.32     // staggered grip centre offset
    private let stemWidth: CGFloat = 1.5

    var body: some View {
        ZStack {
            switch placement {
            case .full:
                capsule(capsuleHeight)
            case .top:
                stem(up: true)
                capsule(capsuleHeight * gripFraction).offset(y: -capsuleHeight * gripOffset)
            case .bottom:
                stem(up: false)
                capsule(capsuleHeight * gripFraction).offset(y: capsuleHeight * gripOffset)
            }
        }
        .frame(width: max(width, stemWidth), height: contentHeight)
    }

    private func capsule(_ h: CGFloat) -> some View {
        Capsule()
            .fill(color)
            .frame(width: width, height: h)
            .overlay(Capsule().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
            .contentShape(Capsule())   // hit area == the visible pill
    }

    /// Thin line from the block's vertical centre out to the grip's inner edge,
    /// so two neighbouring stems meet in the middle. Decoration only.
    private func stem(up: Bool) -> some View {
        let innerEdge = capsuleHeight * (gripOffset - gripFraction / 2)
        let dir: CGFloat = up ? -1 : 1
        return Rectangle()
            .fill(color)
            .frame(width: stemWidth, height: max(0, innerEdge))
            .offset(y: dir * innerEdge / 2)
            .allowsHitTesting(false)
    }
}
