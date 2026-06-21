import SwiftUI

/// Studio-only TikTok/Reels safe-area guide for the "9:16 with template"
/// aspect. Draws a dashed canvas border, a top tabs bar, and a horizontally
/// flipped "L" (⅃) — the right action column joined to a thick bottom caption /
/// nav base — marking where the platform's own chrome covers content, so the
/// user keeps captions / camera clear of it.
///
/// Purely visual: `allowsHitTesting(false)`, never part of the composition or
/// export. A SwiftUI layer ON TOP of the player, like `TextCanvasOverlay`.
struct ReelsSafeAreaOverlay: View {
    @ObservedObject var model: StudioModel

    // Proportions of the 9:16 content rect (TikTok-ish; tune freely).
    private let topBarH: CGFloat = 0.095   // Following / For You / search
    private let colWidth: CGFloat = 0.16   // right action column width
    private let colTop: CGFloat = 0.36     // column top (avatar level)
    private let baseTop: CGFloat = 0.745   // thick base top (caption / nav)

    var body: some View {
        GeometryReader { geo in
            if model.cropAspect == .nineBySixteenTemplate,
               model.templateGuideVisible,
               model.renderSize.width > 0 {
                let rect = CropMath.aspectFitRect(model.renderSize, in: geo.size)
                ZStack(alignment: .topLeading) {
                    zone(rect, x: 0, y: 0, w: 1, h: topBarH)   // top tabs bar
                    flippedL(rect)                             // right column + thick base (⅃)

                    // Canvas border — the reels frame boundary (studio-only).
                    Rectangle()
                        .strokeBorder(Color.accentColor,
                                      style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// Right action column joined to a thick bottom base — one connected
    /// flipped-L (⅃) silhouette, drawn as a single path so the fill has no
    /// double-opacity seam where column and base meet.
    private func flippedL(_ rect: CGRect) -> some View {
        let colLeft = 1 - colWidth
        let pts: [(CGFloat, CGFloat)] = [
            (colLeft, colTop),   // top-left of column
            (1, colTop),         // top-right of column
            (1, 1),              // bottom-right
            (0, 1),              // bottom-left of base
            (0, baseTop),        // top-left of base
            (colLeft, baseTop),  // inner corner (base top meets column left)
        ]
        let path = Path { p in
            for (i, f) in pts.enumerated() {
                let pt = CGPoint(x: rect.minX + f.0 * rect.width,
                                 y: rect.minY + f.1 * rect.height)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
        }
        return path.fill(Color.accentColor.opacity(0.18))
            .overlay(path.stroke(Color.accentColor.opacity(0.5), lineWidth: 1))
    }

    /// One translucent safe-zone box, placed by normalized fractions of `rect`.
    private func zone(_ rect: CGRect, x: CGFloat, y: CGFloat,
                      w: CGFloat, h: CGFloat) -> some View {
        let frame = CGRect(x: rect.minX + x * rect.width,
                           y: rect.minY + y * rect.height,
                           width: w * rect.width, height: h * rect.height)
        return RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }
}
