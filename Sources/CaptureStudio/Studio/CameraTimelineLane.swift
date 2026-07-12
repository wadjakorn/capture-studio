import SwiftUI

/// The camera track: a strip under the main scrubber showing transition blocks.
/// Each block is a rectangle spanning its `[begin, end]` with draggable edge
/// handles — left = where the move/fade begins, right = where it settles. The
/// block body drags to reposition (keeping width); the empty track scrubs.
/// Tapping a block selects it (parks the playhead at its settled state so the
/// PiP overlay edits that block's target). Built as a reusable lane so future
/// tracks (display zoom, captions) can stack on the same time axis.
struct CameraTimelineLane: View {
    @ObservedObject var model: StudioModel

    private let laneHeight: CGFloat = 26
    private let handleWidth: CGFloat = 7
    private let edgeProximity: CGFloat = 14   // stagger grips within this px gap
    private let cutSize: CGFloat = 12
    private let laneSpace = "cameraLane"

    @State private var dragMoved = false
    @State private var dragStartBegin: Double = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)

                ForEach(model.cameraBlocks) { block in
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
            // Empty-track scrub (blocks/handles consume their own hits first);
            // a pure tap (no scrub) on empty track also deselects.
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
    private func blockView(_ block: CameraBlock, width: CGFloat) -> some View {
        let x0 = fraction(block.begin) * width
        let x1 = fraction(block.end) * width
        let selected = model.selectedBlockID == block.id
        let accent = Color.accentColor

        if x1 - x0 < 1.5 {
            // Zero-width = hard cut: a single diamond, draggable to reposition.
            Diamond()
                .fill(selected ? accent : Color.white)
                .overlay(Diamond().stroke(Color.black.opacity(0.35), lineWidth: 0.5))
                .frame(width: cutSize, height: cutSize)
                .frame(width: 22, height: laneHeight)
                .contentShape(Rectangle())
                .position(x: x0, y: laneHeight / 2)
                .highPriorityGesture(bodyGesture(block, width: width))
        } else {
            let bodyW = x1 - x0
            let siblings = model.cameraBlocks.filter { $0.id != block.id }
            let beginShared = TimelineEdgeShare.isShared(
                Double(x0), with: siblings.map { Double(fraction($0.end) * width) }, tolerance: Double(edgeProximity))
            let endShared = TimelineEdgeShare.isShared(
                Double(x1), with: siblings.map { Double(fraction($0.begin) * width) }, tolerance: Double(edgeProximity))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill((block.layout.showsCamera ? accent : Color.secondary)
                        .opacity(selected ? 0.5 : 0.3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(selected ? accent : .clear, lineWidth: 1.5)
                    )
                    .frame(width: bodyW, height: laneHeight - 2)
                    .contentShape(Rectangle())
                    .gesture(bodyGesture(block, width: width))

                // The block's layout, as an SF Symbol, when there's room.
                if bodyW > 16 {
                    Image(systemName: block.layout.symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(block.layout.showsCamera ? .primary : .secondary)
                        .frame(width: bodyW, height: laneHeight - 2)
                        .allowsHitTesting(false)
                }

                // Edge grips carry the resize gesture directly — the hit area is
                // just the visible capsule, so the rest of the block stays free
                // for drag-to-move. Grips stagger top/bottom at a shared boundary
                // so neighbours read apart and their hit areas don't overlap.
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
    }

    // MARK: - Gestures

    /// Drag the whole block (keeps width); tap selects.
    private func bodyGesture(_ block: CameraBlock, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(laneSpace))
            .onChanged { value in
                if !dragMoved, abs(value.translation.width) > 2 {
                    dragMoved = true
                    dragStartBegin = block.begin
                    model.selectedBlockID = block.id
                }
                if dragMoved, width > 0 {
                    let dt = Double(value.translation.width / width) * model.duration
                    model.moveBlock(block.id, toBegin: dragStartBegin + dt)
                }
            }
            .onEnded { _ in
                if dragMoved { model.commitBlockEdit() } else { model.selectBlock(block.id) }
                dragMoved = false
            }
    }

    /// Drag one edge to retime the begin/end (clamped, non-overlapping).
    private func edgeGesture(_ block: CameraBlock, width: CGFloat, isBegin: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(laneSpace))
            .onChanged { value in
                if abs(value.translation.width) > 2 { dragMoved = true }
                if dragMoved {
                    model.selectedBlockID = block.id
                    let t = time(atX: value.location.x, width: width)
                    if isBegin { model.moveBlockBegin(block.id, toTime: t) }
                    else { model.moveBlockEnd(block.id, toTime: t) }
                }
            }
            .onEnded { _ in
                if dragMoved { model.commitBlockEdit() } else { model.selectBlock(block.id) }
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

/// A simple 4-point diamond marker.
private struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.closeSubpath()
        return p
    }
}
