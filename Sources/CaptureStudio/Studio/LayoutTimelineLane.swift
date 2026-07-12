import SwiftUI

/// The layout track: a strip under the main scrubber showing the frame-layout
/// blocks. Each block spans its `[begin, end)` with draggable edge handles
/// (retime begin/end) and a draggable body (reposition, keeping width). Tapping
/// a block selects it (parks the playhead inside its span) so the toolbar's
/// layout picker edits that block. Empty track scrubs / deselects. Blocks are
/// colored + SF-symboled by their layout. Mirrors `CameraTimelineLane`.
struct LayoutTimelineLane: View {
    @ObservedObject var model: StudioModel

    private let laneHeight: CGFloat = 26
    private let handleWidth: CGFloat = 7
    private let edgeHitWidth: CGFloat = 16
    private let laneSpace = "layoutLane"

    @State private var dragMoved = false
    @State private var dragStartBegin: Double = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)

                ForEach(model.layoutBlocks) { block in
                    blockView(block, width: width)
                }

                // Playhead.
                Rectangle()
                    .fill(.primary)
                    .frame(width: 2, height: laneHeight)
                    .offset(x: fraction(model.currentTime) * width - 1)
                    .allowsHitTesting(false)
            }
            .frame(height: laneHeight)
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
        .frame(height: laneHeight)
    }

    @ViewBuilder
    private func blockView(_ block: LayoutBlock, width: CGFloat) -> some View {
        let x0 = fraction(block.begin) * width
        let x1 = fraction(block.end) * width
        let selected = model.selectedLayoutBlockID == block.id
        let tint = color(for: block.layout)
        let bodyW = max(x1 - x0, 2)
        let hits = EdgeHitRegions(bodyWidth: bodyW, handleWidth: edgeHitWidth)
        let siblings = model.layoutBlocks.filter { $0.id != block.id }
        let beginShared = TimelineEdgeShare.isShared(block.begin, with: siblings.map(\.end))
        let endShared = TimelineEdgeShare.isShared(block.end, with: siblings.map(\.begin))

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(tint.opacity(selected ? 0.6 : 0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(selected ? tint : .clear, lineWidth: 1.5)
                )
                .frame(width: bodyW, height: laneHeight - 2)
                .contentShape(Rectangle())
                .gesture(bodyGesture(block, width: width))

            if bodyW > 16 {
                Image(systemName: block.layout.symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(.primary)
                    .frame(width: bodyW, height: laneHeight - 2)
                    .allowsHitTesting(false)
            }

            // Visible grips sit on the edges (staggered top/bottom at a shared
            // boundary so neighbours read apart); the invisible hit targets
            // below carry the drag gestures, biased into the block interior.
            TimelineEdgeHandle(color: tint,
                               placement: TimelineEdgeShare.placement(isBegin: true, shared: beginShared),
                               contentHeight: laneHeight, capsuleHeight: laneHeight - 6, width: handleWidth)
                .position(x: 0, y: laneHeight / 2).allowsHitTesting(false)
            TimelineEdgeHandle(color: tint,
                               placement: TimelineEdgeShare.placement(isBegin: false, shared: endShared),
                               contentHeight: laneHeight, capsuleHeight: laneHeight - 6, width: handleWidth)
                .position(x: bodyW, y: laneHeight / 2).allowsHitTesting(false)

            edgeHitTarget(width: hits.beginWidth).position(x: hits.beginMidX, y: laneHeight / 2)
                .highPriorityGesture(edgeGesture(block, width: width, isBegin: true))
            edgeHitTarget(width: hits.endWidth).position(x: hits.endMidX, y: laneHeight / 2)
                .highPriorityGesture(edgeGesture(block, width: width, isBegin: false))
        }
        .frame(width: bodyW, height: laneHeight, alignment: .leading)
        .offset(x: x0)
    }

    /// A distinct hue per layout so the track reads at a glance.
    private func color(for layout: CameraLayout) -> Color {
        switch layout {
        case .mainAndFloat: return .accentColor
        case .mainOnly: return .gray
        case .floatCamera: return .teal
        case .cameraStatic: return .purple
        }
    }

    private func edgeHitTarget(width: CGFloat) -> some View {
        Color.clear
            .frame(width: width, height: laneHeight)
            .contentShape(Rectangle())
    }

    // MARK: - Gestures

    private func bodyGesture(_ block: LayoutBlock, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(laneSpace))
            .onChanged { value in
                if !dragMoved, abs(value.translation.width) > 2 {
                    dragMoved = true
                    dragStartBegin = block.begin
                    model.selectedLayoutBlockID = block.id
                }
                if dragMoved, width > 0 {
                    let dt = Double(value.translation.width / width) * model.duration
                    model.moveLayoutBlock(block.id, toBegin: dragStartBegin + dt)
                }
            }
            .onEnded { _ in
                if dragMoved { model.commitLayoutEdit() } else { model.selectLayoutBlock(block.id) }
                dragMoved = false
            }
    }

    private func edgeGesture(_ block: LayoutBlock, width: CGFloat, isBegin: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(laneSpace))
            .onChanged { value in
                if abs(value.translation.width) > 2 { dragMoved = true }
                if dragMoved {
                    model.selectedLayoutBlockID = block.id
                    let t = time(atX: value.location.x, width: width)
                    if isBegin { model.moveLayoutBlockBegin(block.id, toTime: t) }
                    else { model.moveLayoutBlockEnd(block.id, toTime: t) }
                }
            }
            .onEnded { _ in
                if dragMoved { model.commitLayoutEdit() } else { model.selectLayoutBlock(block.id) }
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
