import SwiftUI

/// Drag-to-pan for the reframe crop. The preview is WYSIWYG — the player
/// already shows the cropped canvas — so dragging the video pans the crop
/// underneath it (content follows the cursor). Sits below CameraPipOverlay
/// in the ZStack so PiP drags win hit-testing.
struct CropPanOverlay: View {
    @ObservedObject var model: StudioModel

    @State private var dragStartCenter: CGPoint?

    var body: some View {
        GeometryReader { geo in
            if model.cropActive, model.renderSize.width > 0,
               let crop = model.cropRectInSource, crop.width > 0 {
                let videoRect = CropMath.aspectFitRect(model.renderSize, in: geo.size)
                let viewScale = videoRect.width / model.renderSize.width
                // View px → canvas px → source px.
                let viewToSource = crop.width / model.renderSize.width / viewScale

                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: videoRect.width, height: videoRect.height)
                    .position(x: videoRect.midX, y: videoRect.midY)
                    .gesture(panGesture(viewToSource: viewToSource))
            }
        }
        .allowsHitTesting(model.cropActive)
    }

    private func panGesture(viewToSource: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartCenter == nil {
                    dragStartCenter = CGPoint(x: model.cropCenterX, y: model.cropCenterY)
                }
                guard let start = dragStartCenter, model.sourceSize.width > 0 else { return }
                // Content follows the cursor: crop center moves opposite the drag.
                let dx = Double(value.translation.width * viewToSource) / model.sourceSize.width
                let dy = Double(value.translation.height * viewToSource) / model.sourceSize.height
                model.setCropCenter(x: start.x - dx, y: start.y - dy)
            }
            .onEnded { _ in
                dragStartCenter = nil
                model.commitCropEdit()
            }
    }
}
