import SwiftUI

/// On-canvas affordance for the subtitle track: a draggable selection box around
/// the cue active at the playhead. Dragging repositions the *shared* subtitle
/// style, so every cue moves together. The subtitle text itself is burned into
/// preview frames by the compositor; this view only draws the box. Shown while
/// the subtitle track is selected and a cue is on screen.
///
/// A SwiftUI layer ON TOP of the `NSViewRepresentable` player (SwiftUI
/// `VideoPlayer` SIGABRTs on Command-Line-Tools builds), never a player feature.
struct SubtitleCanvasOverlay: View {
    @ObservedObject var model: StudioModel

    @State private var dragStart: CGPoint?
    @State private var resizeStartWidth: Double?
    private let space = "subtitleCanvas"

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Tap empty canvas to deselect.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.deselectAll() }

                if let cue = activeCue, let style = model.subtitles?.style,
                   model.renderSize.width > 0 {
                    let block = style.asTextBlock(id: cue.id, begin: cue.begin,
                                                  end: cue.end, text: cue.text)
                    let videoRect = aspectFitRect(model.renderSize, in: geo.size)
                    let viewScale = videoRect.width / model.renderSize.width
                    let cx = videoRect.minX + CGFloat(style.centerX) * model.renderSize.width * viewScale
                    let cy = videoRect.minY + CGFloat(style.centerY) * model.renderSize.height * viewScale
                    let measured = TextImageRenderer.size(block, canvas: model.renderSize)
                    // Subtitles always auto-wrap, so the box shows the wrap frame
                    // (boxWidth) — its side edges are the draggable wrap width.
                    let frameW = CGFloat(style.boxWidth) * model.renderSize.width * viewScale
                    let boxW = max(frameW, 44)
                    let boxH = max(measured.height * viewScale, 26)

                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .contentShape(Rectangle())
                        .frame(width: boxW, height: boxH)
                        .overlay {
                            resizeHandle(viewScale: viewScale, leading: true)
                                .position(x: 0, y: boxH / 2)
                            resizeHandle(viewScale: viewScale, leading: false)
                                .position(x: boxW, y: boxH / 2)
                        }
                        .gesture(moveGesture(viewScale: viewScale))
                        .help("Drag to move all subtitles · drag a side handle to resize the wrap width")
                        .position(x: cx, y: cy)
                }
            }
            .coordinateSpace(name: space)
        }
    }

    /// The cue under the playhead (so the box aligns with what's on screen).
    private var activeCue: SubtitleCue? {
        model.effectiveSubtitleCues.first {
            $0.begin <= model.currentTime && model.currentTime < $0.end
        }
    }

    private func moveGesture(viewScale: CGFloat) -> some Gesture {
        // Measure in the container's fixed space, NOT the box's local space — the
        // box moves during the drag, which would corrupt the translation.
        DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
            .onChanged { value in
                guard model.renderSize.width > 0, let style = model.subtitles?.style else { return }
                if dragStart == nil {
                    dragStart = CGPoint(x: style.centerX, y: style.centerY)
                    model.beginDraggingSubtitle()
                }
                guard let start = dragStart else { return }
                let dx = Double(value.translation.width / viewScale) / model.renderSize.width
                let dy = Double(value.translation.height / viewScale) / model.renderSize.height
                model.dragSubtitlePosition(x: start.x + dx, y: start.y + dy)
            }
            .onEnded { _ in
                dragStart = nil
                model.endDraggingSubtitle()
            }
    }

    /// A small side handle that resizes the shared wrap width symmetrically about
    /// the subtitle center (so every cue re-wraps to the new width).
    private func resizeHandle(viewScale: CGFloat, leading: Bool) -> some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 6, height: 22)
            .overlay(Capsule().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
            .frame(width: 18, height: 30)            // larger hit area
            .contentShape(Rectangle())
            .highPriorityGesture(resizeGesture(viewScale: viewScale, leading: leading))
    }

    private func resizeGesture(viewScale: CGFloat, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
            .onChanged { value in
                guard model.renderSize.width > 0,
                      let style = model.subtitles?.style else { return }
                if resizeStartWidth == nil { resizeStartWidth = style.boxWidth }
                guard let start = resizeStartWidth else { return }
                // Center-anchored: leading drag-left and trailing drag-right both
                // widen; the factor of 2 keeps the box centered.
                let deltaFrac = Double(value.translation.width / viewScale) / model.renderSize.width
                let signed = leading ? -deltaFrac : deltaFrac
                model.setSubtitleBoxWidth(start + 2 * signed)
            }
            .onEnded { _ in
                resizeStartWidth = nil
                model.commitSubtitleEdit()
            }
    }

    private func aspectFitRect(_ content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}
