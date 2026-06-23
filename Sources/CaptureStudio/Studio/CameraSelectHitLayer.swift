import SwiftUI

/// Invisible tap target over the camera PiP, shown only while the camera is
/// editable at the playhead but not yet selected. A tap selects the camera —
/// revealing the full `CameraPipOverlay` (move/resize handles) — mirroring how
/// `TextSelectHitLayer` selects a caption. Sits above the navigation layer (a
/// camera tap selects rather than deselects) and is hidden once selected, so the
/// overlay's own gestures take over.
struct CameraSelectHitLayer: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        GeometryReader { geo in
            if let pip = model.cameraPipRect, model.renderSize.width > 0 {
                let videoRect = CropMath.aspectFitRect(model.renderSize, in: geo.size)
                let viewScale = videoRect.width / model.renderSize.width
                let frame = CGRect(
                    x: videoRect.minX + pip.minX * viewScale,
                    y: videoRect.minY + pip.minY * viewScale,
                    width: pip.width * viewScale,
                    height: pip.height * viewScale
                )
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .onTapGesture { model.selectCamera() }
            }
        }
    }
}
