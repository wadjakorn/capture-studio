import SwiftUI

/// The auto-zoom track: a strip under the main scrubber showing zoom blocks.
/// Each block spans its `[begin, end)` with draggable edge handles; the body
/// drags to reposition (keeping width); the empty track scrubs. Tapping selects
/// a block. Mirrors `CameraTimelineLane` (non-overlapping, single row).
struct ZoomTimelineLane: View {
    @ObservedObject var model: StudioModel

    private let laneHeight: CGFloat = 26
    private let handleWidth: CGFloat = 7
    private let edgeProximity: CGFloat = 14   // stagger grips within this px gap
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
    private func blockView(_ block: ZoomBlock, width: CGFloat) -> some View {
        let x0 = fraction(block.begin) * width
        let x1 = fraction(block.end) * width
        let selected = model.selectedZoomBlockID == block.id
        let manual = (block.mode ?? .follow) == .manual
        // Manual holds a fixed frame (teal); follow tracks the cursor (orange).
        let accent = manual ? Color.teal : Color.orange
        let icon = manual ? "pin.fill" : "plus.magnifyingglass"
        // A block that starts exactly where another ends is a continuous run: mark
        // the shared edge as a start/stop seam.
        let touchesPrev = model.zoomBlocks.contains { abs($0.end - block.begin) < 1e-6 }
        let bodyW = max(2, x1 - x0)
        let siblings = model.zoomBlocks.filter { $0.id != block.id }
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
                .frame(width: bodyW, height: laneHeight - 2)
                .contentShape(Rectangle())
                .gesture(bodyGesture(block, width: width))

            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: bodyW, height: laneHeight - 2)
                .allowsHitTesting(false)

            if touchesPrev {
                Rectangle()
                    .fill(.white)
                    .frame(width: 1.5, height: laneHeight - 6)
                    .position(x: 0.75, y: laneHeight / 2)
                    .allowsHitTesting(false)
            }

            // Edge grips carry the resize gesture directly — the hit area is
            // just the visible capsule, so the rest of the block stays free for
            // drag-to-move. Grips stagger top/bottom at a shared boundary so
            // neighbours read apart and their hit areas don't overlap.
            TimelineEdgeHandle(color: accent,
                               placement: TimelineEdgeShare.placement(isBegin: true, shared: beginShared),
                               contentHeight: laneHeight, capsuleHeight: laneHeight - 6, width: handleWidth)
                .position(x: 0, y: laneHeight / 2)
                .highPriorityGesture(edgeGesture(block, width: width, isBegin: true))
            TimelineEdgeHandle(color: accent,
                               placement: TimelineEdgeShare.placement(isBegin: false, shared: endShared),
                               contentHeight: laneHeight, capsuleHeight: laneHeight - 6, width: handleWidth)
                .position(x: bodyW, y: laneHeight / 2)
                .highPriorityGesture(edgeGesture(block, width: width, isBegin: false))
        }
        .frame(width: bodyW, height: laneHeight, alignment: .leading)
        .offset(x: x0)
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
