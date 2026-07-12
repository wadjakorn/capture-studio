import Foundation

/// Vertical placement of a block's edge handle grip.
///
/// A handle stays `.full` (a single capsule centred on the edge) unless its edge
/// is *crowded* — close to an adjacent block's opposite edge. When crowded the
/// left block's end grip rides the `.top` half and the right block's begin grip
/// the `.bottom` half, so the two otherwise-overlapping lines read as distinct.
enum EdgeHandlePlacement: Equatable { case full, top, bottom }

/// Pure logic for deciding when a timeline block edge is crowded by a neighbour
/// and how its grip should be placed. Kept lane-agnostic so every timeline lane
/// (camera, text, shape, layout, zoom) can reuse and unit-test it.
///
/// Proximity is measured in the SAME units the caller passes — lanes pass
/// screen-space x (points) with a pixel `tolerance`, so blocks that merely sit
/// *near* each other (not only ones that share an exact time boundary) stagger.
enum TimelineEdgeShare {
    /// True when `edge` is within `tolerance` of any of `neighbourEdges`.
    /// Pass a begin against sibling *ends*, or an end against sibling *begins*.
    static func isShared(_ edge: Double, with neighbourEdges: [Double],
                         tolerance: Double = 1e-6) -> Bool {
        neighbourEdges.contains { abs($0 - edge) <= tolerance }
    }

    /// Grip placement for one edge: begin → bottom, end → top when shared;
    /// otherwise full-height.
    static func placement(isBegin: Bool, shared: Bool) -> EdgeHandlePlacement {
        guard shared else { return .full }
        return isBegin ? .bottom : .top
    }
}
