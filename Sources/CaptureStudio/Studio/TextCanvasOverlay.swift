import SwiftUI

/// WYSIWYG editing affordance for text/caption blocks, drawn over the player.
/// The text itself is burned into preview frames by the compositor; this view
/// maps view-space drags back into normalized render-space position, and shows
/// an inline editor for the block being edited. Only the selected block whose
/// span contains the playhead gets an affordance — others are just rendered.
///
/// This is a SwiftUI layer ON TOP of the `NSViewRepresentable` player (SwiftUI
/// `VideoPlayer` SIGABRTs on Command-Line-Tools builds), never a player feature.
struct TextCanvasOverlay: View {
    @ObservedObject var model: StudioModel

    @State private var dragStart: CGPoint?
    @FocusState private var editorFocused: Bool

    var body: some View {
        GeometryReader { geo in
            if let block = activeSelectedBlock, model.renderSize.width > 0 {
                let videoRect = aspectFitRect(model.renderSize, in: geo.size)
                let viewScale = videoRect.width / model.renderSize.width
                let cx = videoRect.minX + CGFloat(block.centerX) * model.renderSize.width * viewScale
                let cy = videoRect.minY + CGFloat(block.centerY) * model.renderSize.height * viewScale
                let isEditing = model.editingTextBlockID == block.id

                Group {
                    if isEditing {
                        TextField("Caption", text: Binding(
                            get: { model.selectedTextBlock?.text ?? "" },
                            set: { model.setText($0, for: block.id) }
                        ), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: max(140, videoRect.width * 0.5))
                        .focused($editorFocused)
                        .onAppear { editorFocused = true }
                        .onChange(of: editorFocused) {
                            if !editorFocused { model.endEditingText() }
                        }
                        .onExitCommand { model.endEditingText() }
                    } else {
                        Text(block.text.isEmpty ? "Text" : block.text)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.55)))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.accentColor, lineWidth: 1.5))
                            .foregroundStyle(.white)
                            .contentShape(Rectangle())
                            .gesture(moveGesture(viewScale: viewScale))
                            .onTapGesture(count: 2) { model.beginEditingText(block.id) }
                            .help("Drag to position · double-click to edit")
                    }
                }
                .position(x: cx, y: cy)
            }
        }
    }

    /// The selected block, but only while the playhead is within its span (so
    /// the affordance lines up with what's actually on screen).
    private var activeSelectedBlock: TextBlock? {
        guard let b = model.selectedTextBlock,
              b.begin <= model.currentTime, model.currentTime < b.end else { return nil }
        return b
    }

    private func moveGesture(viewScale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let block = model.selectedTextBlock, model.renderSize.width > 0 else { return }
                if dragStart == nil { dragStart = CGPoint(x: block.centerX, y: block.centerY) }
                guard let start = dragStart else { return }
                let dx = Double(value.translation.width / viewScale) / model.renderSize.width
                let dy = Double(value.translation.height / viewScale) / model.renderSize.height
                model.setTextPosition(x: start.x + dx, y: start.y + dy, for: block.id)
            }
            .onEnded { _ in
                dragStart = nil
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
