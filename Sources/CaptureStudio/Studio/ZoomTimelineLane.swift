import SwiftUI

/// The auto-zoom track: a strip under the main scrubber showing zoom blocks.
/// Each block spans its `[begin, end)` with draggable edge handles; the body
/// drags to reposition (keeping width); the empty track scrubs. Tapping selects
/// a block. Mirrors `CameraTimelineLane` (non-overlapping, single row).
struct ZoomTimelineLane: View {
    @ObservedObject var model: StudioModel

    private let laneHeight: CGFloat = 26
    private let handleWidth: CGFloat = 7
    private let laneSpace = "zoomLane"

    @State private var dragMoved = false
    @State private var dragStartBegin: Double = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)

                ForEach(model.zoomBlocks) { block in
                    blockView(block, width: width)
                }

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
            )
        }
        .frame(height: laneHeight)
    }

    @ViewBuilder
    private func blockView(_ block: ZoomBlock, width: CGFloat) -> some View {
        let x0 = fraction(block.begin) * width
        let x1 = fraction(block.end) * width
        let selected = model.selectedZoomBlockID == block.id
        let accent = Color.orange     // distinct from camera (accent) + text lanes
        let bodyW = max(2, x1 - x0)

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(accent.opacity(selected ? 0.5 : 0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(selected ? accent : .clear, lineWidth: 1.5)
                )
                .frame(width: bodyW, height: laneHeight - 2)
                .contentShape(Rectangle())
                .gesture(bodyGesture(block, width: width))

            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: bodyW, height: laneHeight - 2)
                .allowsHitTesting(false)

            edgeHandle(accent).position(x: 0, y: laneHeight / 2)
                .highPriorityGesture(edgeGesture(block, width: width, isBegin: true))
            edgeHandle(accent).position(x: bodyW, y: laneHeight / 2)
                .highPriorityGesture(edgeGesture(block, width: width, isBegin: false))
        }
        .frame(width: bodyW, height: laneHeight, alignment: .leading)
        .offset(x: x0)
    }

    private func edgeHandle(_ color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: handleWidth, height: laneHeight - 6)
            .overlay(Capsule().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
            .frame(width: 16, height: laneHeight)
            .contentShape(Rectangle())
    }

    private func bodyGesture(_ block: ZoomBlock, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(laneSpace))
            .onChanged { value in
                if !dragMoved, abs(value.translation.width) > 2 {
                    dragMoved = true
                    dragStartBegin = block.begin
                    model.selectedZoomBlockID = block.id
                }
                if dragMoved, width > 0 {
                    let dt = Double(value.translation.width / width) * model.duration
                    model.moveZoomBlock(block.id, toBegin: dragStartBegin + dt)
                }
            }
            .onEnded { _ in
                if dragMoved { model.commitZoomEdit() } else { model.selectZoomBlock(block.id) }
                dragMoved = false
            }
    }

    private func edgeGesture(_ block: ZoomBlock, width: CGFloat, isBegin: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(laneSpace))
            .onChanged { value in
                if abs(value.translation.width) > 2 { dragMoved = true }
                if dragMoved {
                    model.selectedZoomBlockID = block.id
                    let t = time(atX: value.location.x, width: width)
                    if isBegin { model.moveZoomBlockBegin(block.id, toTime: t) }
                    else { model.moveZoomBlockEnd(block.id, toTime: t) }
                }
            }
            .onEnded { _ in
                if dragMoved { model.commitZoomEdit() } else { model.selectZoomBlock(block.id) }
                dragMoved = false
            }
    }

    private func fraction(_ seconds: Double) -> CGFloat {
        guard model.duration > 0 else { return 0 }
        return CGFloat(min(max(0, seconds / model.duration), 1))
    }

    private func time(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(0, x / width), 1)) * model.duration
    }
}
