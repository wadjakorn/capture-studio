import CoreGraphics

/// Pure geometry for the main-video framing window: a single static rectangle,
/// normalized 0–1 in canvas space (center + size, top-left origin), that masks
/// the screen video. The video pans behind it (auto zoom); the window itself
/// never moves over time.
enum FrameMath {
    /// Smallest allowed side, as a fraction of the canvas.
    static let minSize: Double = 0.05

    /// Clamp a normalized frame so its size stays within [minSize, 1] and the
    /// whole rect stays inside the canvas (center pulled in as needed).
    static func clamped(centerX: Double, centerY: Double,
                        width: Double, height: Double)
        -> (centerX: Double, centerY: Double, width: Double, height: Double) {
        let w = min(max(width, minSize), 1)
        let h = min(max(height, minSize), 1)
        let cx = min(max(centerX, w / 2), 1 - w / 2)
        let cy = min(max(centerY, h / 2), 1 - h / 2)
        return (cx, cy, w, h)
    }

    /// Normalized frame → canvas pixel rect (top-left origin), clamped first so
    /// out-of-range persisted values can't produce a rect outside the canvas.
    static func rectInCanvas(_ canvas: CGSize, centerX: Double, centerY: Double,
                             width: Double, height: Double) -> CGRect {
        let f = clamped(centerX: centerX, centerY: centerY, width: width, height: height)
        let w = CGFloat(f.width) * canvas.width
        let h = CGFloat(f.height) * canvas.height
        return CGRect(x: CGFloat(f.centerX) * canvas.width - w / 2,
                      y: CGFloat(f.centerY) * canvas.height - h / 2,
                      width: w, height: h)
    }

    /// New normalized frame from a corner-handle drag: the dragged corner moves
    /// to `dragged` (normalized canvas coords) while the opposite corner stays
    /// at `anchor`. Result is clamped.
    static func resized(anchor: CGPoint, dragged: CGPoint)
        -> (centerX: Double, centerY: Double, width: Double, height: Double) {
        let minX = min(anchor.x, dragged.x), maxX = max(anchor.x, dragged.x)
        let minY = min(anchor.y, dragged.y), maxY = max(anchor.y, dragged.y)
        return clamped(centerX: Double(minX + maxX) / 2,
                       centerY: Double(minY + maxY) / 2,
                       width: Double(maxX - minX),
                       height: Double(maxY - minY))
    }
}
