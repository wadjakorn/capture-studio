import SwiftUI

/// Interactive handles for the camera PiP, drawn over the player. The PiP
/// itself is burned into preview frames by the video composition; this view
/// just maps view-space drags back into normalized render-space settings.
///
/// Gestures: a plain drag moves the PiP, ⌥-drag pans the camera feed crop
/// (when zoomed in), and the bottom-right handle resizes it.
struct CameraPipOverlay: View {
    @ObservedObject var model: StudioModel

    @State private var dragStartCenter: CGPoint?
    @State private var resizeStartScale: Double?
    @State private var feedStartCenter: CGPoint?
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
                let canPan = model.cameraZoom > 1.0

                // Plain drag moves the PiP; ⌥-drag pans the feed crop (only
                // when zoomed in). The modifier-gated pan takes priority so the
                // two never compete for the same drag.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: pipView.width, height: pipView.height)
                    .position(x: pipView.midX, y: pipView.midY)
                    .highPriorityGesture(feedPanGesture(pipView: pipView).modifiers(.option),
                                         including: canPan ? .all : .subviews)
                    .gesture(moveGesture(viewScale: viewScale))

                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(hovering || dragStartCenter != nil
                                  || resizeStartScale != nil || feedStartCenter != nil
                                  ? Color.accentColor : Color.white.opacity(0.35),
                                  lineWidth: 2)
                    .frame(width: pipView.width, height: pipView.height)
                    .position(x: pipView.midX, y: pipView.midY)
                    .onHover { hovering = $0 }
                    .allowsHitTesting(false)

                // Resize handle, bottom-right corner.
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 12, height: 12)
                    .position(x: pipView.maxX, y: pipView.maxY)
                    .gesture(resizeGesture(viewScale: viewScale, pipView: pipView))
            }
        }
        .allowsHitTesting(model.showsCameraOverlay)
    }

    private func moveGesture(viewScale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartCenter == nil {
                    let s = model.editingCameraSample
                    dragStartCenter = CGPoint(x: s.centerX, y: s.centerY)
                }
                guard let start = dragStartCenter else { return }
                let dx = Double(value.translation.width / viewScale) / model.renderSize.width
                let dy = Double(value.translation.height / viewScale) / model.renderSize.height
                model.dragCameraCenter(x: start.x + dx, y: start.y + dy)
            }
            .onEnded { _ in
                dragStartCenter = nil
                model.commitCameraEdit()
            }
    }

    private func resizeGesture(viewScale: CGFloat, pipView: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if resizeStartScale == nil { resizeStartScale = model.editingCameraSample.scale }
                guard let start = resizeStartScale else { return }
                let dw = Double(value.translation.width / viewScale) / model.renderSize.width
                // Dragging the corner outward grows width; center stays put.
                model.dragCameraScale(start + dw * 2)
            }
            .onEnded { _ in
                resizeStartScale = nil
                model.commitCameraEdit()
            }
    }

    /// Pans the camera feed crop; content follows the cursor. Maps view px →
    /// feed px via the crop-to-PiP scale, then normalizes by the feed size.
    private func feedPanGesture(pipView: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if feedStartCenter == nil {
                    feedStartCenter = CGPoint(x: model.cameraFeedX, y: model.cameraFeedY)
                }
                guard let start = feedStartCenter,
                      let crop = model.cameraCropRectInFeed,
                      let feed = model.cameraNaturalSize,
                      pipView.width > 0, feed.width > 0 else { return }
                let feedPxPerViewX = crop.width / pipView.width
                let feedPxPerViewY = crop.height / pipView.height
                let dx = Double(value.translation.width * feedPxPerViewX) / feed.width
                let dy = Double(value.translation.height * feedPxPerViewY) / feed.height
                model.setCameraFeedCenter(x: start.x - dx, y: start.y - dy)
            }
            .onEnded { _ in
                feedStartCenter = nil
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
