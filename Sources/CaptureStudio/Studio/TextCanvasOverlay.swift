import SwiftUI

/// On-canvas affordance for the selected text/caption block: a transparent
/// selection box, sized to the baked text (via the shared `TextImageRenderer`),
/// that drags to reposition. Text content is NOT edited here — that happens in
/// the timeline-anchored input popover. The text itself is always burned into
/// preview frames by the compositor; this view only draws the box.
///
/// A SwiftUI layer ON TOP of the `NSViewRepresentable` player (SwiftUI
/// `VideoPlayer` SIGABRTs on Command-Line-Tools builds), never a player feature.
struct TextCanvasOverlay: View {
    @ObservedObject var model: StudioModel

    @State private var dragStart: CGPoint?
    @State private var resizeStartWidth: Double?
    private let space = "textCanvas"

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Tap empty canvas to deselect (present only while selected).
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.deselectAll() }

                if let block = activeSelectedBlock, model.renderSize.width > 0 {
                    let videoRect = aspectFitRect(model.renderSize, in: geo.size)
                    let viewScale = videoRect.width / model.renderSize.width
                    let cx = videoRect.minX + CGFloat(block.centerX) * model.renderSize.width * viewScale
                    let cy = videoRect.minY + CGFloat(block.centerY) * model.renderSize.height * viewScale
                    let measured = TextImageRenderer.size(block, canvas: model.renderSize)
                    // While auto-wrapping, the box shows the wrap frame (boxWidth)
                    // so its edges are the draggable wrap width; otherwise it hugs
                    // the measured single-line text.
                    let frameW = block.autoWrap
                        ? CGFloat(block.boxWidth) * model.renderSize.width * viewScale
                        : measured.width * viewScale
                    let boxW = max(frameW, 44)
                    let boxH = max(measured.height * viewScale, 26)

                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .contentShape(Rectangle())            // whole box is draggable
                        .frame(width: boxW, height: boxH)
                        .overlay {
                            if block.autoWrap {
                                resizeHandle(block: block, viewScale: viewScale, leading: true)
                                    .position(x: 0, y: boxH / 2)
                                resizeHandle(block: block, viewScale: viewScale, leading: false)
                                    .position(x: boxW, y: boxH / 2)
                            }
                        }
                        .gesture(moveGesture(block: block, viewScale: viewScale))
                        // Consume single taps so a click on the box keeps the
                        // selection instead of falling through to the catcher.
                        .onTapGesture { model.selectTextBlock(block.id) }
                        .help("Drag to move · drag a side handle to resize the wrap width")
                        .position(x: cx, y: cy)
                }
            }
            .coordinateSpace(name: space)   // stable frame for the move drag
        }
    }

    /// The selected block, but only while the playhead is within its span (so
    /// the box lines up with what's actually on screen).
    private var activeSelectedBlock: TextBlock? {
        guard let b = model.selectedTextBlock,
              b.begin <= model.currentTime, model.currentTime < b.end else { return nil }
        return b
    }

    private func moveGesture(block: TextBlock, viewScale: CGFloat) -> some Gesture {
        // Measure in the container's fixed coordinate space, NOT the box's local
        // space — the box moves during the drag, which would corrupt translation.
        DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
            .onChanged { value in
                guard model.renderSize.width > 0 else { return }
                if dragStart == nil {
                    dragStart = CGPoint(x: block.centerX, y: block.centerY)
                    model.beginDraggingText(block.id)
                }
                guard let start = dragStart else { return }
                let dx = Double(value.translation.width / viewScale) / model.renderSize.width
                let dy = Double(value.translation.height / viewScale) / model.renderSize.height
                model.dragTextPosition(x: start.x + dx, y: start.y + dy, for: block.id)
            }
            .onEnded { _ in
                dragStart = nil
                model.endDraggingText()
            }
    }

    /// A small side handle that resizes the wrap width symmetrically about the
    /// block center.
    private func resizeHandle(block: TextBlock, viewScale: CGFloat, leading: Bool) -> some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 6, height: 22)
            .overlay(Capsule().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
            .frame(width: 18, height: 30)            // larger hit area
            .contentShape(Rectangle())
            .highPriorityGesture(resizeGesture(block: block, viewScale: viewScale, leading: leading))
    }

    private func resizeGesture(block: TextBlock, viewScale: CGFloat, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
            .onChanged { value in
                guard model.renderSize.width > 0 else { return }
                if resizeStartWidth == nil { resizeStartWidth = block.boxWidth }
                guard let start = resizeStartWidth else { return }
                // Center-anchored: a leading drag-left and a trailing drag-right
                // both widen; the factor of 2 keeps the box centered.
                let deltaFrac = Double(value.translation.width / viewScale) / model.renderSize.width
                let signed = leading ? -deltaFrac : deltaFrac
                model.setTextBoxWidth(start + 2 * signed)
            }
            .onEnded { _ in
                resizeStartWidth = nil
                model.commitTextEdit()
            }
    }

    /// Aspect-fit rect of the video inside the available view size.
    private func aspectFitRect(_ content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}
