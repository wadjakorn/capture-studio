import SwiftUI

/// Interactive transform handles for the framing window, drawn over the player.
/// The window itself (the main-video mask) is burned into preview frames by the
/// compositor; this view just maps view-space drags back into normalized
/// canvas-space settings. Shown only in frame edit mode.
///
/// Gestures: a drag on the body moves the window; each corner handle resizes it
/// with the opposite corner anchored. A SwiftUI layer ON TOP of the
/// `NSViewRepresentable` player, like `TextCanvasOverlay` / `CameraPipOverlay`.
struct FrameCanvasOverlay: View {
    @ObservedObject var model: StudioModel

    @State private var dragStartCenter: CGPoint?
    /// Captured at corner-drag start: the fixed anchor (opposite corner) and the
    /// dragged corner's starting position, both in normalized canvas coords.
    @State private var resizeAnchor: CGPoint?
    @State private var resizeStartDragged: CGPoint?

    /// The four draggable corners, named by which normalized-canvas point they
    /// occupy; the anchor is the diagonally opposite corner.
    private enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
        var unit: CGPoint {                 // this corner in 0–1 frame space
            switch self {
            case .topLeading: return CGPoint(x: 0, y: 0)
            case .topTrailing: return CGPoint(x: 1, y: 0)
            case .bottomLeading: return CGPoint(x: 0, y: 1)
            case .bottomTrailing: return CGPoint(x: 1, y: 1)
            }
        }
        var opposite: CGPoint { CGPoint(x: 1 - unit.x, y: 1 - unit.y) }
    }

    var body: some View {
        GeometryReader { geo in
            if model.frameEnabled, model.frameEditMode, model.renderSize.width > 0 {
                let videoRect = aspectFitRect(model.renderSize, in: geo.size)
                let viewScale = videoRect.width / model.renderSize.width
                // Frame rect in view coordinates.
                let w = CGFloat(model.frameWidth) * model.renderSize.width * viewScale
                let h = CGFloat(model.frameHeight) * model.renderSize.height * viewScale
                let cx = videoRect.minX + CGFloat(model.frameCenterX) * model.renderSize.width * viewScale
                let cy = videoRect.minY + CGFloat(model.frameCenterY) * model.renderSize.height * viewScale
                let box = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)

                // Body — drag to move the whole window.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
                    .gesture(moveGesture(viewScale: viewScale))

                Rectangle()
                    .strokeBorder(Color.accentColor,
                                  style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
                    .allowsHitTesting(false)

                // Corner resize handles.
                ForEach(Array(Corner.allCases.enumerated()), id: \.offset) { _, corner in
                    let px = box.minX + corner.unit.x * box.width
                    let py = box.minY + corner.unit.y * box.height
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 12, height: 12)
                        .position(x: px, y: py)
                        .gesture(resizeGesture(corner: corner, videoRect: videoRect,
                                               viewScale: viewScale))
                }
            }
        }
    }

    private func moveGesture(viewScale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard model.renderSize.width > 0 else { return }
                if dragStartCenter == nil {
                    dragStartCenter = CGPoint(x: model.frameCenterX, y: model.frameCenterY)
                }
                guard let start = dragStartCenter else { return }
                let dx = Double(value.translation.width / viewScale) / model.renderSize.width
                let dy = Double(value.translation.height / viewScale) / model.renderSize.height
                model.dragFrameCenter(x: start.x + dx, y: start.y + dy)
            }
            .onEnded { _ in
                dragStartCenter = nil
                model.commitFrameEdit()
            }
    }

    private func resizeGesture(corner: Corner, videoRect: CGRect,
                               viewScale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard model.renderSize.width > 0 else { return }
                // Capture the fixed anchor + dragged-corner start ONCE, so the
                // anchor can't drift as the frame mutates through the drag.
                if resizeAnchor == nil {
                    let halfW = model.frameWidth / 2, halfH = model.frameHeight / 2
                    resizeAnchor = CGPoint(
                        x: model.frameCenterX + (corner.opposite.x - 0.5) * 2 * halfW,
                        y: model.frameCenterY + (corner.opposite.y - 0.5) * 2 * halfH)
                    resizeStartDragged = CGPoint(
                        x: model.frameCenterX + (corner.unit.x - 0.5) * 2 * halfW,
                        y: model.frameCenterY + (corner.unit.y - 0.5) * 2 * halfH)
                }
                guard let anchor = resizeAnchor, let start = resizeStartDragged else { return }
                let dx = Double(value.translation.width / viewScale) / model.renderSize.width
                let dy = Double(value.translation.height / viewScale) / model.renderSize.height
                let dragged = CGPoint(x: start.x + dx, y: start.y + dy)
                model.dragFrameCorner(anchor: anchor, dragged: dragged)
            }
            .onEnded { _ in
                resizeAnchor = nil
                resizeStartDragged = nil
                model.commitFrameEdit()
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
