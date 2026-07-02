import SwiftUI

/// On-canvas affordance for the selected shape block: a selection box sized to
/// the shape's normalized geometry that drags to reposition and has four corner
/// handles to resize (center-anchored). The shape itself (fill / stroke / blur)
/// is burned into preview frames by the compositor; this view only draws the
/// editing box, mirroring `TextCanvasOverlay`.
///
/// A SwiftUI layer ON TOP of the `NSViewRepresentable` player (SwiftUI
/// `VideoPlayer` SIGABRTs on Command-Line-Tools builds), never a player feature.
struct ShapeCanvasOverlay: View {
    @ObservedObject var model: StudioModel

    @State private var dragStart: CGPoint?
    @State private var resizeStart: CGSize?
    private let space = "shapeCanvas"

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Tap empty canvas to deselect (present only while selected).
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.deselectAll() }

                if let block = activeSelectedBlock, model.renderSize.width > 0 {
                    let videoRect = CropMath.aspectFitRect(model.renderSize, in: geo.size)
                    let viewScale = videoRect.width / model.renderSize.width
                    let cx = videoRect.minX + CGFloat(block.centerX) * model.renderSize.width * viewScale
                    let cy = videoRect.minY + CGFloat(block.centerY) * model.renderSize.height * viewScale
                    let boxW = max(CGFloat(block.width) * model.renderSize.width * viewScale, 20)
                    let boxH = max(CGFloat(block.height) * model.renderSize.height * viewScale, 20)

                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .contentShape(Rectangle())            // whole box is draggable
                        .frame(width: boxW, height: boxH)
                        .overlay {
                            cornerHandle(block, viewScale, signX: -1, signY: -1).position(x: 0, y: 0)
                            cornerHandle(block, viewScale, signX: 1, signY: -1).position(x: boxW, y: 0)
                            cornerHandle(block, viewScale, signX: -1, signY: 1).position(x: 0, y: boxH)
                            cornerHandle(block, viewScale, signX: 1, signY: 1).position(x: boxW, y: boxH)
                        }
                        .gesture(moveGesture(block: block, viewScale: viewScale))
                        .onTapGesture { model.selectShapeBlock(block.id) }
                        .help("Drag to move · drag a corner to resize")
                        .position(x: cx, y: cy)
                }
            }
            .coordinateSpace(name: space)   // stable frame for the move drag
        }
    }

    /// The selected block, but only while the playhead is within its span (so the
    /// box lines up with what's actually on screen).
    private var activeSelectedBlock: ShapeBlock? {
        guard let b = model.selectedShapeBlock,
              b.begin <= model.currentTime, model.currentTime < b.end else { return nil }
        return b
    }

    private func moveGesture(block: ShapeBlock, viewScale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
            .onChanged { value in
                guard model.renderSize.width > 0 else { return }
                if dragStart == nil {
                    dragStart = CGPoint(x: block.centerX, y: block.centerY)
                    model.beginDraggingShape(block.id)
                }
                guard let start = dragStart else { return }
                let dx = Double(value.translation.width / viewScale) / model.renderSize.width
                let dy = Double(value.translation.height / viewScale) / model.renderSize.height
                model.dragShapePosition(x: start.x + dx, y: start.y + dy, for: block.id)
            }
            .onEnded { _ in
                dragStart = nil
                model.endDraggingShape()
            }
    }

    /// A corner handle that resizes the box symmetrically about its center. `sign`
    /// flips the drag direction so every corner grows the box when dragged
    /// outward.
    private func cornerHandle(_ block: ShapeBlock, _ viewScale: CGFloat,
                              signX: Double, signY: Double) -> some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
            .frame(width: 22, height: 22)            // larger hit area
            .contentShape(Rectangle())
            .highPriorityGesture(resizeGesture(block: block, viewScale: viewScale,
                                               signX: signX, signY: signY))
    }

    private func resizeGesture(block: ShapeBlock, viewScale: CGFloat,
                               signX: Double, signY: Double) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
            .onChanged { value in
                guard model.renderSize.width > 0 else { return }
                if resizeStart == nil {
                    resizeStart = CGSize(width: block.width, height: block.height)
                    model.beginDraggingShape(block.id)
                }
                guard let start = resizeStart else { return }
                // Center-anchored: the factor of 2 keeps the box centered while a
                // corner drags outward.
                let dxFrac = Double(value.translation.width / viewScale) / model.renderSize.width
                let dyFrac = Double(value.translation.height / viewScale) / model.renderSize.height
                model.dragShapeSize(width: start.width + 2 * signX * dxFrac,
                                    height: start.height + 2 * signY * dyFrac,
                                    for: block.id)
            }
            .onEnded { _ in
                resizeStart = nil
                model.endDraggingShape()
            }
    }
}
