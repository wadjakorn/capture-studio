import CoreGraphics
import CoreText
import Foundation

/// Renders a `TextBlock` to a bitmap via Core Text, and exposes the rendered
/// size separately so UI (the canvas selection box) can match the baked image
/// exactly. Core Text + CGContext only — no AppKit / SwiftUI — so it is safe on
/// the off-main compositor queue and on Command-Line-Tools builds.
enum TextImageRenderer {
    /// Full rendered image size in canvas pixels (text + padding + box), or
    /// `.zero` if the block has no visible content. Position-independent.
    static func size(_ block: TextBlock, canvas: CGSize) -> CGSize {
        measure(block, canvas: canvas)?.imageSize ?? .zero
    }

    /// Rendered block as a CGImage (origin top-left, premultiplied), or nil if
    /// it has no visible content.
    static func image(_ block: TextBlock, canvas: CGSize) -> CGImage? {
        guard let m = measure(block, canvas: canvas),
              let ctx = CGContext(data: nil, width: Int(m.imageSize.width),
                                  height: Int(m.imageSize.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        if block.boxEnabled {
            let boxRect = CGRect(x: m.pad, y: m.pad,
                                 width: m.imageSize.width - m.pad * 2,
                                 height: m.imageSize.height - m.pad * 2)
            let radius = min(m.boxPadY, m.fontSize * 0.2)
            ctx.setFillColor(cgColor(hex: block.boxHex,
                                     alpha: CGFloat(min(max(0, block.boxOpacity), 1))))
            ctx.addPath(CGPath(roundedRect: boxRect, cornerWidth: radius,
                               cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
        if block.shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -max(1, m.fontSize * 0.04)),
                          blur: max(1, m.fontSize * 0.08),
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))
        }

        let textRect = CGRect(x: m.pad + m.boxPadX, y: m.pad + m.boxPadY,
                              width: m.textW, height: m.textH)
        let frame = CTFramesetterCreateFrame(m.framesetter, m.full,
                                             CGPath(rect: textRect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
        return ctx.makeImage()
    }

    // MARK: - Measurement

    private struct Metrics {
        let fontSize: CGFloat
        let framesetter: CTFramesetter
        let full: CFRange
        let textW: CGFloat
        let textH: CGFloat
        let boxPadX: CGFloat
        let boxPadY: CGFloat
        let pad: CGFloat
        let imageSize: CGSize
    }

    private static func measure(_ block: TextBlock, canvas: CGSize) -> Metrics? {
        guard !block.text.isEmpty, canvas.width > 1, canvas.height > 1 else { return nil }
        let fontSize = max(1, CGFloat(block.fontSize) * canvas.height)
        let font = ctFont(name: block.fontName, size: fontSize, weight: block.fontWeight)

        var alignment: CTTextAlignment = {
            switch block.alignment {
            case .leading: return .left
            case .center: return .center
            case .trailing: return .right
            }
        }()
        let paragraph = withUnsafeMutablePointer(to: &alignment) { ptr -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(spec: .alignment,
                                                  valueSize: MemoryLayout<CTTextAlignment>.size,
                                                  value: ptr)
            return CTParagraphStyleCreate(&setting, 1)
        }

        var attrs: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): cgColor(hex: block.colorHex, alpha: 1),
            .init(kCTParagraphStyleAttributeName as String): paragraph,
        ]
        if block.strokeWidth > 0 {
            // Negative width = fill + stroke; magnitude is a percent of font size.
            attrs[.init(kCTStrokeWidthAttributeName as String)] = -Double(block.strokeWidth) * 100
            attrs[.init(kCTStrokeColorAttributeName as String)] = cgColor(hex: block.strokeHex, alpha: 1)
        }
        let attr = NSAttributedString(string: block.text, attributes: attrs)

        let maxWidth = canvas.width * 0.9
        let framesetter = CTFramesetterCreateWithAttributedString(attr as CFAttributedString)
        let full = CFRange(location: 0, length: attr.length)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, full, nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let textW = ceil(fit.width), textH = ceil(fit.height)
        guard textW > 0, textH > 0 else { return nil }

        let boxPadX = block.boxEnabled ? fontSize * 0.4 : 0
        let boxPadY = block.boxEnabled ? fontSize * 0.25 : 0
        let pad = ceil(max(block.shadow ? fontSize * 0.25 : 0,
                           CGFloat(block.strokeWidth) * fontSize)) + 2
        let imageSize = CGSize(width: (textW + boxPadX * 2 + pad * 2).rounded(),
                               height: (textH + boxPadY * 2 + pad * 2).rounded())
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        return Metrics(fontSize: fontSize, framesetter: framesetter, full: full,
                       textW: textW, textH: textH, boxPadX: boxPadX, boxPadY: boxPadY,
                       pad: pad, imageSize: imageSize)
    }

    /// CTFont for a family name + size + weight. Falls back to a system font if
    /// the family is unknown (CTFont never returns nil here).
    private static func ctFont(name: String, size: CGFloat, weight: TextWeight) -> CTFont {
        let w: CGFloat
        switch weight {
        case .regular: w = 0
        case .medium: w = 0.23
        case .semibold: w = 0.3
        case .bold: w = 0.4
        }
        let attrs: [CFString: Any] = [
            kCTFontFamilyNameAttribute: name,
            kCTFontTraitsAttribute: [kCTFontWeightTrait: w],
        ]
        let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        return CTFontCreateWithFontDescriptor(desc, size, nil)
    }

    /// Parses "#RRGGBB" (or "RRGGBB") with an explicit alpha; falls back to white.
    private static func cgColor(hex: String, alpha: CGFloat) -> CGColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            return CGColor(red: 1, green: 1, blue: 1, alpha: alpha)
        }
        return CGColor(red: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }
}
