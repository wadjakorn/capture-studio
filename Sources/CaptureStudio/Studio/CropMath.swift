import CoreGraphics

/// Pure geometry for the reframe crop. All inputs/outputs in source pixels
/// unless noted; centers are normalized 0–1 in source space.
enum CropMath {
    /// Largest crop of aspect `ratio` (w/h) that fits inside the source.
    static func maxFitSize(source: CGSize, ratio: CGFloat) -> CGSize {
        guard source.width > 0, source.height > 0, ratio > 0 else { return .zero }
        if source.width / source.height > ratio {
            return CGSize(width: source.height * ratio, height: source.height)
        }
        return CGSize(width: source.width, height: source.width / ratio)
    }

    /// Normalized center clamped so a crop of `cropSize` stays inside source.
    static func clampedCenter(source: CGSize, cropSize: CGSize,
                              centerX: CGFloat, centerY: CGFloat) -> CGPoint {
        guard source.width > 0, source.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let halfW = cropSize.width / 2 / source.width
        let halfH = cropSize.height / 2 / source.height
        return CGPoint(
            x: min(max(centerX, halfW), 1 - halfW),
            y: min(max(centerY, halfH), 1 - halfH)
        )
    }

    /// Crop rect in source pixels for the given aspect, zoom (fraction of
    /// max-fit, clamped 0.2…1.0), and normalized center (clamped inside).
    static func cropRect(source: CGSize, ratio: CGFloat, zoom: CGFloat,
                         centerX: CGFloat, centerY: CGFloat) -> CGRect {
        let maxFit = maxFitSize(source: source, ratio: ratio)
        guard maxFit.width > 0 else { return .zero }
        let z = min(max(zoom, 0.2), 1.0)
        let size = CGSize(width: maxFit.width * z, height: maxFit.height * z)
        let c = clampedCenter(source: source, cropSize: size,
                              centerX: centerX, centerY: centerY)
        return CGRect(
            x: c.x * source.width - size.width / 2,
            y: c.y * source.height - size.height / 2,
            width: size.width, height: size.height
        )
    }

    /// Drawn rect (top-left, canvas pixels) of the whole `source` contained in
    /// `canvas` for the fit/letterbox aspect, at `zoom` (0.2…1.0, where 1.0 =
    /// full fit / widest) and normalized `center`. `zoom` < 1 scales the fitted
    /// content up (zoom in). Both axes pan: an axis larger than the canvas pans
    /// within its overflow (clamped so no gap shows); a smaller axis pans within
    /// its slack (the letterbox bars redistribute) — `center` 0.5 keeps it
    /// centered. The origin is clamped so the content never leaves the canvas.
    static func fitPlacement(source: CGSize, canvas: CGSize, zoom: CGFloat,
                             centerX: CGFloat, centerY: CGFloat) -> CGRect {
        guard source.width > 0, source.height > 0,
              canvas.width > 0, canvas.height > 0 else { return .zero }
        let s0 = min(canvas.width / source.width, canvas.height / source.height)
        let z = min(max(zoom, 0.2), 1.0)
        let s = s0 / z
        let w = source.width * s, h = source.height * s
        let x = clampOrigin(canvas.width / 2 - centerX * w, canvas: canvas.width, drawn: w)
        let y = clampOrigin(canvas.height / 2 - centerY * h, canvas: canvas.height, drawn: h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Clamp a placement origin so the drawn extent stays within the canvas: a
    /// larger-than-canvas extent stays flush (overflow only); a smaller one
    /// stays inside (free slack for the letterbox bars).
    private static func clampOrigin(_ o: CGFloat, canvas: CGFloat, drawn: CGFloat) -> CGFloat {
        let a = min(0, canvas - drawn), b = max(0, canvas - drawn)
        return min(max(o, a), b)
    }

    /// Aspect-fit rect of `content` centered inside `container` (view space).
    static func aspectFitRect(_ content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        let scale = min(container.width / content.width,
                        container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }

    /// Aspect-fill (cover) rect of `content` centered inside `container`: scaled
    /// so it fully covers the container, overflow cropped. Mirror of
    /// `aspectFitRect`. Used for background fills (blur / photo) behind the video.
    static func aspectFillRect(_ content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        let scale = max(container.width / content.width,
                        container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }
}
