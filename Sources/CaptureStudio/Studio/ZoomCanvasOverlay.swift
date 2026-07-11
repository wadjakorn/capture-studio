import SwiftUI

/// On-canvas control for a selected MANUAL zoom block: a reticle marking the held
/// frame — which the recenter parks at the framing-window centre — that drags to
/// reposition the manual target. Present only while a manual block is active at the
/// playhead; follow blocks track the cursor and have no target to place.
///
/// A SwiftUI layer ON TOP of the player, mirroring `TextCanvasOverlay`. The model's
/// `renderSize` is `sourceSize` scaled uniformly, so a translation normalized by
/// `renderSize` equals the source-normalized `focusX`/`focusY` the zoom stores.
struct ZoomCanvasOverlay: View {
    @ObservedObject var model: StudioModel

    @State private var dragStart: CGPoint?
    private let space = "zoomCanvas"

    var body: some View {
        GeometryReader { geo in
            if let block = activeManualBlock, model.renderSize.width > 0 {
                let videoRect = aspectFitRect(model.renderSize, in: geo.size)
                let viewScale = videoRect.width / model.renderSize.width
                reticle
                    .frame(width: 42, height: 42)
                    .position(x: videoRect.midX, y: videoRect.midY)
                    .gesture(dragGesture(block: block, viewScale: viewScale))
                    .help("Drag to reposition the held frame")
            }
        }
        .coordinateSpace(name: space)
    }

    /// The selected block, but only while it is manual and the playhead is inside
    /// its span (so the reticle lines up with what's on screen).
    private var activeManualBlock: ZoomBlock? {
        guard let b = model.selectedZoomBlock, (b.mode ?? .follow) == .manual,
              b.begin <= model.currentTime, model.currentTime < b.end else { return nil }
        return b
    }

    private var reticle: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.15))
            Circle().strokeBorder(Color.teal, lineWidth: 2)
            Rectangle().fill(Color.teal).frame(width: 2, height: 16)
            Rectangle().fill(Color.teal).frame(width: 16, height: 2)
        }
        .shadow(radius: 1)
        .contentShape(Circle())
    }

    private func dragGesture(block: ZoomBlock, viewScale: CGFloat) -> some Gesture {
        // Measure in the container's fixed space (the reticle stays centred, so its
        // local space can't be used). The view is magnified by the zoom, so a
        // screen delta maps to a smaller source delta (÷ scale).
        DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
            .onChanged { value in
                guard model.renderSize.width > 0, model.renderSize.height > 0,
                      viewScale > 0 else { return }
                if dragStart == nil {
                    dragStart = CGPoint(x: block.focusX ?? 0.5, y: block.focusY ?? 0.5)
                }
                guard let start = dragStart else { return }
                let scale = max(1, model.selectedZoomScale)
                let dx = Double(value.translation.width / viewScale) / Double(model.renderSize.width) / scale
                let dy = Double(value.translation.height / viewScale) / Double(model.renderSize.height) / scale
                model.setZoomTarget(x: Double(start.x) + dx, y: Double(start.y) + dy)
            }
            .onEnded { _ in
                dragStart = nil
                model.commitZoomEdit()
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
