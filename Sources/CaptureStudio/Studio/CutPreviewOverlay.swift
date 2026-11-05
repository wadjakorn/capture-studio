import SwiftUI

/// One view, two styles: `.lane` = tint + 1pt border per range + pending-split
/// marker on the master lane; `.dim` = faint wash across the whole lane stack.
/// Never intercepts hits.
struct CutPreviewOverlay: View {
    enum Style { case lane, dim }
    let preview: CutPreview?
    let duration: Double
    let width: CGFloat
    let style: Style

    var body: some View {
        if let preview, duration > 0 {
            content(preview)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private func content(_ preview: CutPreview) -> some View {
        let isCut = preview.kind == .cut
        switch style {
        case .lane:
            ZStack(alignment: .leading) {
                ForEach(Array(preview.ranges.enumerated()), id: \.offset) { _, r in
                    let x0 = px(r.lowerBound)
                    let w = max(0, px(r.upperBound) - x0)
                    Rectangle()
                        .fill((isCut ? Color.red : Color.green).opacity(isCut ? 0.28 : 0.25))
                        .overlay(
                            Rectangle().strokeBorder((isCut ? Color.red : Color.green).opacity(0.8), lineWidth: 1)
                        )
                        .frame(width: w, height: 10)
                        .offset(x: x0)
                }
                if let at = preview.pendingSplitAt {
                    Rectangle()
                        .stroke(Color.primary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .frame(width: 0)
                        .frame(maxHeight: .infinity)
                        .offset(x: px(at))
                }
            }
            .frame(width: width, alignment: .leading)
        case .dim:
            ZStack(alignment: .topLeading) {
                ForEach(Array(preview.ranges.enumerated()), id: \.offset) { _, r in
                    let x0 = px(r.lowerBound)
                    let w = max(0, px(r.upperBound) - x0)
                    Rectangle()
                        .fill(isCut ? Color.black.opacity(0.18) : Color.green.opacity(0.08))
                        .frame(width: w)
                        .frame(maxHeight: .infinity)
                        .offset(x: x0)
                }
            }
            .frame(width: width, alignment: .topLeading)
        }
    }

    private func px(_ t: Double) -> CGFloat {
        CGFloat(min(max(0, t / duration), 1)) * width
    }
}
