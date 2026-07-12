import SwiftUI

/// The grip for a timeline block's begin/end edge. Its *hit area equals the
/// visible grip capsule* — the lane attaches the resize gesture to this view,
/// and an explicit view-level `contentShape` (`gripRect`) constrains hit-testing
/// to exactly the pill you see, so the rest of the block stays free for the
/// drag-to-move gesture and two staggered neighbours never overlap in hit-test.
/// The stem is decoration.
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
    // taste — grip size vs. stem gap trade off against each other. Static so
    // they stay out of the synthesized memberwise initializer.
    private static let gripFraction: CGFloat = 0.42   // staggered grip height
    private static let gripOffset: CGFloat = 0.32     // staggered grip centre offset
    private static let stemWidth: CGFloat = 1.5

    var body: some View {
        ZStack {
            switch placement {
            case .full:
                capsule(capsuleHeight)
            case .top:
                stem(up: true)
                capsule(capsuleHeight * Self.gripFraction).offset(y: -capsuleHeight * Self.gripOffset)
            case .bottom:
                stem(up: false)
                capsule(capsuleHeight * Self.gripFraction).offset(y: capsuleHeight * Self.gripOffset)
            }
        }
        .frame(width: max(width, Self.stemWidth), height: contentHeight)
        // Authoritative hit region for this whole view (and any gesture the lane
        // attaches): exactly the visible grip capsule, at its staggered offset.
        // This overrides the child views' shapes so the parent frame's full
        // height never becomes a hit target.
        .contentShape(GripCapsule(rect: gripRect))
    }

    /// The grip capsule's rect within the view's own bounds (origin top-left,
    /// size `width × contentHeight`).
    private var gripRect: CGRect {
        let cx = max(width, Self.stemWidth) / 2
        let cy = contentHeight / 2
        switch placement {
        case .full:
            return CGRect(x: cx - width / 2, y: cy - capsuleHeight / 2,
                          width: width, height: capsuleHeight)
        case .top:
            let h = capsuleHeight * Self.gripFraction
            let gy = cy - capsuleHeight * Self.gripOffset
            return CGRect(x: cx - width / 2, y: gy - h / 2, width: width, height: h)
        case .bottom:
            let h = capsuleHeight * Self.gripFraction
            let gy = cy + capsuleHeight * Self.gripOffset
            return CGRect(x: cx - width / 2, y: gy - h / 2, width: width, height: h)
        }
    }

    private func capsule(_ h: CGFloat) -> some View {
        Capsule()
            .fill(color)
            .frame(width: width, height: h)
            .overlay(Capsule().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
    }

    /// Thin line from the block's vertical centre out to the grip's inner edge,
    /// so two neighbouring stems meet in the middle. Decoration only.
    private func stem(up: Bool) -> some View {
        let innerEdge = capsuleHeight * (Self.gripOffset - Self.gripFraction / 2)
        let dir: CGFloat = up ? -1 : 1
        return Rectangle()
            .fill(color)
            .frame(width: Self.stemWidth, height: max(0, innerEdge))
            .offset(y: dir * innerEdge / 2)
    }
}

/// A capsule occupying an explicit sub-rect of the layout bounds — used as the
/// hit-test `contentShape` so the grip's touch target matches its drawn pill
/// exactly, regardless of the surrounding frame height.
private struct GripCapsule: Shape {
    let rect: CGRect
    func path(in _: CGRect) -> Path {
        Capsule().path(in: rect)
    }
}
