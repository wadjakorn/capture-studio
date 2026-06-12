import SwiftUI

/// Interactive handles for the camera PiP, drawn over the player. The PiP
/// itself is burned into preview frames by the video composition; this view
/// just maps view-space drags back into normalized render-space settings.
struct CameraPipOverlay: View {
    @ObservedObject var model: StudioModel

    @State private var dragStartCenter: CGPoint?
    @State private var resizeStartScale: Double?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            if let pip = model.cameraPipRect, model.renderSize.width > 0 {
                let videoRect = aspectFitRect(model.renderSize, in: geo.size)
                let viewScale = videoRect.width / model.renderSize.width
                let pipView = CGRect(
                    x: videoRect.minX + pip.minX * viewScale,
                    y: videoRect.minY + pip.minY * viewScale,
                    width: pip.width * viewScale,
                    height: pip.height * viewScale
                )

                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(hovering || dragStartCenter != nil || resizeStartScale != nil
                                  ? Color.accentColor : Color.white.opacity(0.35),
                                  lineWidth: 2)
                    .contentShape(Rectangle())
                    .frame(width: pipView.width, height: pipView.height)
                    .position(x: pipView.midX, y: pipView.midY)
                    .onHover { hovering = $0 }
                    .gesture(moveGesture(viewScale: viewScale))

                // Resize handle, bottom-right corner.
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 12, height: 12)
                    .position(x: pipView.maxX, y: pipView.maxY)
                    .gesture(resizeGesture(viewScale: viewScale, pipView: pipView))
            }
        }
        .allowsHitTesting(model.cameraVisible && model.hasCameraTrack)
    }

    private func moveGesture(viewScale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartCenter == nil {
                    dragStartCenter = CGPoint(x: model.cameraCenterX, y: model.cameraCenterY)
                }
                guard let start = dragStartCenter else { return }
                let dx = Double(value.translation.width / viewScale) / model.renderSize.width
                let dy = Double(value.translation.height / viewScale) / model.renderSize.height
                model.cameraCenterX = min(max(start.x + dx, 0), 1)
                model.cameraCenterY = min(max(start.y + dy, 0), 1)
                model.applyVideoComposition()
            }
            .onEnded { _ in
                dragStartCenter = nil
                model.commitCameraEdit()
            }
    }

    private func resizeGesture(viewScale: CGFloat, pipView: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if resizeStartScale == nil { resizeStartScale = model.cameraScale }
                guard let start = resizeStartScale else { return }
                let dw = Double(value.translation.width / viewScale) / model.renderSize.width
                // Dragging the corner outward grows width; center stays put.
                model.cameraScale = min(max(start + dw * 2, 0.08), 0.8)
                model.applyVideoComposition()
            }
            .onEnded { _ in
                resizeStartScale = nil
                model.commitCameraEdit()
            }
    }

    /// Aspect-fit rect of the video inside the available view size.
    private func aspectFitRect(_ content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }
}
