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
}
