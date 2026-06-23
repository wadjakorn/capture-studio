import SwiftUI

/// Invisible tap targets over every caption visible at the playhead, so a click
/// on a box selects it — the same selection a timeline-block tap makes. Targets
/// are rendered in array (z) order, so for overlapping boxes the topmost is
/// frontmost and wins the tap (SwiftUI hit-tests front-to-back). Sits above the
/// navigation layer (a box tap selects rather than deselects) and below the
/// selected block's `TextCanvasOverlay` (that block keeps its move/resize).
struct TextSelectHitLayer: View {
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
                        .onTapGesture { model.selectTextBlock(block.id) }
                }
            }
        }
    }

    /// Captions visible at the playhead, in array (z) order (later = on top).
    private var activeBlocks: [TextBlock] {
        TextTimeline.active(at: model.currentTime, blocks: model.textBlocks)
    }

    private func boxFrame(_ block: TextBlock, videoRect: CGRect, viewScale: CGFloat) -> CGRect {
        let measured = TextImageRenderer.size(block, canvas: model.renderSize)
        let w = max(measured.width * viewScale, 24)
        let h = max(measured.height * viewScale, 16)
        let cx = videoRect.minX + CGFloat(block.centerX) * model.renderSize.width * viewScale
        let cy = videoRect.minY + CGFloat(block.centerY) * model.renderSize.height * viewScale
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
}
