import SwiftUI

/// Invisible tap targets over every shape visible at the playhead, so a click on
/// a shape selects it — the same selection a timeline-block tap makes. Targets
/// are rendered in array (z) order, so for overlapping shapes the topmost is
/// frontmost and wins the tap (SwiftUI hit-tests front-to-back). Sits above the
/// navigation layer (a shape tap selects rather than deselects) and below the
/// selected block's `ShapeCanvasOverlay` (that block keeps its move/resize).
struct ShapeSelectHitLayer: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        GeometryReader { geo in
            if model.renderSize.width > 0 {
                let videoRect = CropMath.aspectFitRect(model.renderSize, in: geo.size)
                let viewScale = videoRect.width / model.renderSize.width
                ForEach(activeBlocks) { block in
                    let frame = boxFrame(block, videoRect: videoRect, viewScale: viewScale)
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .onTapGesture { model.selectShapeBlock(block.id) }
                }
            }
        }
    }

    /// Shapes visible at the playhead, in array (z) order (later = on top).
    private var activeBlocks: [ShapeBlock] {
        ShapeTimeline.active(at: model.currentTime, blocks: model.shapeBlocks)
    }

    private func boxFrame(_ block: ShapeBlock, videoRect: CGRect, viewScale: CGFloat) -> CGRect {
        // Shapes ride the screen's auto zoom (see `ShapeCanvasOverlay`).
        let zoom = model.canvasZoomAtPlayhead
        let w = max(CGFloat(block.width) * videoRect.width * zoom.scale, 16)
        let h = max(CGFloat(block.height) * videoRect.height * zoom.scale, 16)
        let centre = zoom.map(CGPoint(x: block.centerX, y: block.centerY))
        let cx = videoRect.minX + centre.x * videoRect.width
        let cy = videoRect.minY + centre.y * videoRect.height
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
}
