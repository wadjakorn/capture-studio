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
    private let space = "textCanvas"

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Tap empty canvas to deselect (present only while selected).
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.deselectText() }

                if let block = activeSelectedBlock, model.renderSize.width > 0 {
                    let videoRect = aspectFitRect(model.renderSize, in: geo.size)
                    let viewScale = videoRect.width / model.renderSize.width
                    let cx = videoRect.minX + CGFloat(block.centerX) * model.renderSize.width * viewScale
                    let cy = videoRect.minY + CGFloat(block.centerY) * model.renderSize.height * viewScale
                    let measured = TextImageRenderer.size(block, canvas: model.renderSize)
                    let boxW = max(measured.width * viewScale, 44)
                    let boxH = max(measured.height * viewScale, 26)

                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .contentShape(Rectangle())            // whole box is draggable
                        .frame(width: boxW, height: boxH)
                        .gesture(moveGesture(block: block, viewScale: viewScale))
                        .onTapGesture(count: 2) { model.beginEditingText(block.id) }
                        // Consume single taps so a click on the box keeps the
                        // selection instead of falling through to the catcher.
                        .onTapGesture { model.selectTextBlock(block.id) }
                        .help("Drag to move · double-click to edit text")
                        .position(x: cx, y: cy)
                }
            }
            .coordinateSpace(name: space)   // stable frame for the move drag
            // Esc / Return deselect, but only when the text input is closed (it
            // owns those keys while open).
            .background {
                if model.editingTextBlockID == nil {
                    Button("") { model.deselectText() }
                        .keyboardShortcut(.cancelAction).opacity(0)
                    Button("") { model.deselectText() }
                        .keyboardShortcut(.return, modifiers: []).opacity(0)
                }
            }
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
