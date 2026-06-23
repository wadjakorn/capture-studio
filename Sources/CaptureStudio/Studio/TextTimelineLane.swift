import SwiftUI

/// The text/caption track: a strip under the camera lane showing caption blocks
/// on the same time axis. Unlike the camera lane, blocks MAY overlap in time, so
/// the lane dynamically packs them into sub-rows (greedy, via
/// `TextTimeline.subRows`) and grows only as overlaps appear — one row when
/// nothing overlaps, capped with internal scroll past `maxVisibleRows`. Each
/// block shows its (truncated) text, drags to retime, has edge handles to
/// resize (overlap allowed — no neighbor clamp), taps to select, and
/// double-clicks to open the canvas editor.
struct TextTimelineLane: View {
    @ObservedObject var model: StudioModel

    private let rowHeight: CGFloat = 22
    private let rowSpacing: CGFloat = 3
    private let handleWidth: CGFloat = 7
    private let maxVisibleRows = 3
    private let laneSpace = "textLane"

    @State private var dragMoved = false
    @State private var dragStartBegin: Double = 0

    /// Greedy sub-row packing; row index → y-offset.
    private var rows: [[TextBlock]] { TextTimeline.subRows(model.textBlocks) }

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
                            blockView(block, width: width)
                                .offset(y: CGFloat(rowIndex) * (rowHeight + rowSpacing))
                        }
                    }

                    // Playhead spans all sub-rows.
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2, height: contentHeight)
                        .offset(x: fraction(model.currentTime) * width - 1)
                        .allowsHitTesting(false)
                }
                .frame(height: contentHeight)
                .coordinateSpace(name: laneSpace)
                .contentShape(Rectangle())
                // Empty-track scrub (blocks/handles consume their own hits first).
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(laneSpace))
                        .onChanged { value in
                            model.seek(to: time(atX: value.location.x, width: width))
                        }
                )
            }
            .frame(height: visibleHeight)
        }
        .frame(height: visibleHeight)
    }

    @ViewBuilder
    private func blockView(_ block: TextBlock, width: CGFloat) -> some View {
        let x0 = fraction(block.begin) * width
        let x1 = fraction(block.end) * width
        let selected = model.selectedTextBlockID == block.id
        let accent = Color.accentColor
        let bodyW = max(2, x1 - x0)

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

            Text(label(block))
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
                .padding(.horizontal, 5)
                .frame(width: bodyW, height: rowHeight - 2, alignment: .leading)
                .allowsHitTesting(false)

            edgeHandle(accent).position(x: 0, y: (rowHeight - 2) / 2)
                .highPriorityGesture(edgeGesture(block, width: width, isBegin: true))
            edgeHandle(accent).position(x: bodyW, y: (rowHeight - 2) / 2)
                .highPriorityGesture(edgeGesture(block, width: width, isBegin: false))
        }
        .frame(width: bodyW, height: rowHeight, alignment: .leading)
        .offset(x: x0)
    }

    private func label(_ block: TextBlock) -> String {
        block.text.isEmpty ? "Text" : block.text
    }

    private func edgeHandle(_ color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: handleWidth, height: rowHeight - 8)
            .overlay(Capsule().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
            .frame(width: 16, height: rowHeight)      // larger hit area
            .contentShape(Rectangle())
    }

    // MARK: - Gestures

    /// Drag the whole block (keeps width); tap selects. Overlap allowed.
    private func bodyGesture(_ block: TextBlock, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(laneSpace))
            .onChanged { value in
                if !dragMoved, abs(value.translation.width) > 2 {
                    dragMoved = true
                    dragStartBegin = block.begin
                    model.selectTextBlock(block.id)
                }
                if dragMoved, width > 0 {
                    let dt = Double(value.translation.width / width) * model.duration
                    model.moveTextBlock(block.id, toBegin: dragStartBegin + dt)
                }
            }
            .onEnded { _ in
                // Tap (no drag) only selects; editing happens in the tool group.
                if dragMoved { model.commitTextEdit() } else { model.selectTextBlock(block.id) }
                dragMoved = false
            }
    }

    /// Drag one edge to retime begin/end (clamped to the clip only — overlap OK).
    private func edgeGesture(_ block: TextBlock, width: CGFloat, isBegin: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(laneSpace))
            .onChanged { value in
                if abs(value.translation.width) > 2 { dragMoved = true }
                if dragMoved {
                    model.selectTextBlock(block.id)
                    let t = time(atX: value.location.x, width: width)
                    if isBegin { model.moveTextBlockBegin(block.id, toTime: t) }
                    else { model.moveTextBlockEnd(block.id, toTime: t) }
                }
            }
            .onEnded { _ in
                if dragMoved { model.commitTextEdit() } else { model.selectTextBlock(block.id) }
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
