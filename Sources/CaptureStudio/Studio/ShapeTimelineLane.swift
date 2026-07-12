import SwiftUI

/// The shape overlay track: a strip under the text lane showing shape blocks on
/// the same time axis. Like the text lane (and unlike the camera lane), blocks
/// MAY overlap in time, so the lane dynamically packs them into sub-rows (greedy,
/// via `ShapeTimeline.subRows`) and grows only as overlaps appear. Each block
/// shows its kind, drags to retime, has edge handles to resize (overlap allowed
/// — no neighbor clamp), taps to select.
struct ShapeTimelineLane: View {
    @ObservedObject var model: StudioModel

    private let rowHeight: CGFloat = 22
    private let rowSpacing: CGFloat = 3
    private let handleWidth: CGFloat = 7
    private let edgeHitWidth: CGFloat = 16
    private let edgeProximity: CGFloat = 30   // stagger grips within this px gap
    private let maxVisibleRows = 3
    private let laneSpace = "shapeLane"

    @State private var dragMoved = false
    @State private var dragStartBegin: Double = 0

    private var rows: [[ShapeBlock]] { ShapeTimeline.subRows(model.shapeBlocks) }

    private var contentHeight: CGFloat {
        let n = max(1, rows.count)
        return CGFloat(n) * rowHeight + CGFloat(max(0, n - 1)) * rowSpacing
    }

    private var visibleHeight: CGFloat {
        let n = min(max(1, rows.count), maxVisibleRows)
        return CGFloat(n) * rowHeight + CGFloat(max(0, n - 1)) * rowSpacing
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ScrollView(.vertical, showsIndicators: rows.count > maxVisibleRows) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .frame(height: contentHeight)

                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, blocks in
                        ForEach(blocks) { block in
                            blockView(block, rowMates: blocks, width: width)
                                .offset(y: CGFloat(rowIndex) * (rowHeight + rowSpacing))
                        }
                    }

                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2, height: contentHeight)
                        .offset(x: fraction(model.currentTime) * width - 1)
                        .allowsHitTesting(false)
                }
                .frame(height: contentHeight)
                .coordinateSpace(name: laneSpace)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(laneSpace))
                        .onChanged { value in
                            model.seek(to: time(atX: value.location.x, width: width))
                        }
                        .onEnded { value in
                            if abs(value.translation.width) < 3
                                && abs(value.translation.height) < 3 {
                                model.deselectAll()
                            }
                        }
                )
            }
            .frame(height: visibleHeight)
        }
        .frame(height: visibleHeight)
    }

    @ViewBuilder
    private func blockView(_ block: ShapeBlock, rowMates: [ShapeBlock], width: CGFloat) -> some View {
        let x0 = fraction(block.begin) * width
        let x1 = fraction(block.end) * width
        let selected = model.selectedShapeBlockID == block.id
        let accent = Color.accentColor
        let bodyW = max(2, x1 - x0)
        let hits = EdgeHitRegions(bodyWidth: bodyW, handleWidth: edgeHitWidth)
        // Only same-row neighbours share a visible edge (overlaps pack onto
        // other rows), so detect coincident edges within this sub-row.
        let siblings = rowMates.filter { $0.id != block.id }
        let beginShared = TimelineEdgeShare.isShared(
            Double(x0), with: siblings.map { Double(fraction($0.end) * width) }, tolerance: Double(edgeProximity))
        let endShared = TimelineEdgeShare.isShared(
            Double(x1), with: siblings.map { Double(fraction($0.begin) * width) }, tolerance: Double(edgeProximity))

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(accent.opacity(selected ? 0.5 : 0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(selected ? accent : .clear, lineWidth: 1.5)
                )
                .frame(width: bodyW, height: rowHeight - 2)
                .contentShape(Rectangle())
                .gesture(bodyGesture(block, width: width))

            Label(block.kind.displayName, systemImage: symbol(block.kind))
                .labelStyle(.titleAndIcon)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
                .padding(.horizontal, 5)
                .frame(width: bodyW, height: rowHeight - 2, alignment: .leading)
                .allowsHitTesting(false)

            // Visible grips sit on the edges (staggered top/bottom at a shared
            // boundary so neighbours read apart); the invisible hit targets
            // below carry the drag gestures, biased into the block interior.
            TimelineEdgeHandle(color: accent,
                               placement: TimelineEdgeShare.placement(isBegin: true, shared: beginShared),
                               contentHeight: rowHeight - 2, capsuleHeight: rowHeight - 8, width: handleWidth)
                .position(x: 0, y: (rowHeight - 2) / 2).allowsHitTesting(false)
            TimelineEdgeHandle(color: accent,
                               placement: TimelineEdgeShare.placement(isBegin: false, shared: endShared),
                               contentHeight: rowHeight - 2, capsuleHeight: rowHeight - 8, width: handleWidth)
                .position(x: bodyW, y: (rowHeight - 2) / 2).allowsHitTesting(false)

            edgeHitTarget(width: hits.beginWidth).position(x: hits.beginMidX, y: (rowHeight - 2) / 2)
                .highPriorityGesture(edgeGesture(block, width: width, isBegin: true))
            edgeHitTarget(width: hits.endWidth).position(x: hits.endMidX, y: (rowHeight - 2) / 2)
                .highPriorityGesture(edgeGesture(block, width: width, isBegin: false))
        }
        .frame(width: bodyW, height: rowHeight, alignment: .leading)
        .offset(x: x0)
    }

    private func symbol(_ kind: ShapeKind) -> String {
        switch kind {
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .blur: return "drop.halffull"
        }
    }

    private func edgeHitTarget(width: CGFloat) -> some View {
        Color.clear
            .frame(width: width, height: rowHeight)
            .contentShape(Rectangle())
    }

    // MARK: - Gestures

    private func bodyGesture(_ block: ShapeBlock, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(laneSpace))
            .onChanged { value in
                if !dragMoved, abs(value.translation.width) > 2 {
                    dragMoved = true
                    dragStartBegin = block.begin
                    model.selectShapeBlock(block.id)
                }
                if dragMoved, width > 0 {
                    let dt = Double(value.translation.width / width) * model.duration
                    model.moveShapeBlock(block.id, toBegin: dragStartBegin + dt)
                }
            }
            .onEnded { _ in
                if dragMoved { model.commitShapeEdit() } else { model.selectShapeBlock(block.id) }
                dragMoved = false
            }
    }

    private func edgeGesture(_ block: ShapeBlock, width: CGFloat, isBegin: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(laneSpace))
            .onChanged { value in
                if abs(value.translation.width) > 2 { dragMoved = true }
                if dragMoved {
                    model.selectShapeBlock(block.id)
                    let t = time(atX: value.location.x, width: width)
                    if isBegin { model.moveShapeBlockBegin(block.id, toTime: t) }
                    else { model.moveShapeBlockEnd(block.id, toTime: t) }
                }
            }
            .onEnded { _ in
                if dragMoved { model.commitShapeEdit() } else { model.selectShapeBlock(block.id) }
                dragMoved = false
            }
    }

    // MARK: - Geometry

    private func fraction(_ seconds: Double) -> CGFloat {
        guard model.duration > 0 else { return 0 }
        return CGFloat(min(max(0, seconds / model.duration), 1))
    }

    private func time(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(0, x / width), 1)) * model.duration
    }
}
