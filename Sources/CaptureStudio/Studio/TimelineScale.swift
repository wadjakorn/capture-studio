import CoreGraphics
import Foundation

/// Pure time↔pixel math for the zoomable editor timeline. The timeline maps the
/// whole clip `[0, duration]` onto a content width; at `zoom == 1` that width is
/// the viewport (the classic fit-to-window behavior), and higher zoom widens the
/// content so it scrolls horizontally. Every lane multiplies `seconds` by the
/// same `pixelsPerSecond`, so they stay aligned at any zoom. No SwiftUI — unit-
/// tested.
enum TimelineScale {
    /// Fit-to-window (can't zoom out past the whole clip).
    static let minZoom = 1.0
    /// Upper bound so a very long clip can't blow the content width past what the
    /// scroll view / geometry handles sanely.
    static let maxZoom = 60.0

    static func clampZoom(_ zoom: Double) -> Double {
        min(max(zoom, minZoom), maxZoom)
    }

    /// Slider position (0…1) for a zoom, on a log scale so low zoom levels (the
    /// common ones) get most of the travel. Inverse of `zoomForSlider`.
    static func zoomSliderPosition(_ zoom: Double) -> Double {
        log(clampZoom(zoom) / minZoom) / log(maxZoom / minZoom)
    }

    /// Zoom for a slider position (0…1), log-mapped. Inverse of `zoomSliderPosition`.
    static func zoomForSlider(_ t: Double) -> Double {
        clampZoom(minZoom * pow(maxZoom / minZoom, min(max(t, 0), 1)))
    }

    /// Content width for the whole timeline at `zoom` (1 = exactly the viewport).
    static func contentWidth(viewport: CGFloat, zoom: Double) -> CGFloat {
        guard viewport > 0 else { return 0 }
        return viewport * CGFloat(clampZoom(zoom))
    }

    /// Pixels per second at a given content width.
    static func pixelsPerSecond(contentWidth: CGFloat, duration: Double) -> CGFloat {
        guard duration > 0 else { return 0 }
        return contentWidth / CGFloat(duration)
    }

    /// The horizontal scroll offset (content x of the left viewport edge) that
    /// keeps `time` sitting under viewport position `viewportX`, clamped to the
    /// valid range `[0, contentWidth - viewport]`. Used to anchor a zoom at the
    /// pointer and to keep the playhead in view.
    static func scrollX(keepingTime time: Double, atViewportX viewportX: CGFloat,
                        viewport: CGFloat, contentWidth: CGFloat, duration: Double) -> CGFloat {
        let pps = pixelsPerSecond(contentWidth: contentWidth, duration: duration)
        let raw = CGFloat(time) * pps - viewportX
        let maxScroll = max(0, contentWidth - viewport)
        return min(max(0, raw), maxScroll)
    }

    /// The scroll offset needed to bring `time` into view within `[0, viewport]`,
    /// given the current offset — nil when it's already visible (with `margin`
    /// padding). Keeps the playhead on screen while playing without recentering on
    /// every tick.
    static func scrollToReveal(time: Double, currentScrollX: CGFloat, viewport: CGFloat,
                               contentWidth: CGFloat, duration: Double,
                               margin: CGFloat = 24) -> CGFloat? {
        let pps = pixelsPerSecond(contentWidth: contentWidth, duration: duration)
        let x = CGFloat(time) * pps
        let maxScroll = max(0, contentWidth - viewport)
        if x < currentScrollX + margin {
            return min(max(0, x - margin), maxScroll)
        }
        if x > currentScrollX + viewport - margin {
            return min(max(0, x - viewport + margin), maxScroll)
        }
        return nil
    }
}

/// Shared vertical metrics for the stacked timeline lanes, so the fixed icon
/// gutter and each lane's own body compute identical row heights (no drift when
/// the dynamic text/shape/subtitle lanes grow with overlapping blocks).
enum TimelineLaneMetrics {
    static let scrubberHeight: CGFloat = 18
    static let blockLaneHeight: CGFloat = 26
    static let rowHeight: CGFloat = 22
    static let rowSpacing: CGFloat = 3
    static let maxVisibleRows = 3

    /// Visible height of a dynamic (overlap-packing) lane for `rowCount` sub-rows,
    /// capped at `maxVisibleRows` (the rest scrolls vertically inside the lane).
    static func packedHeight(rowCount: Int) -> CGFloat {
        let n = min(max(1, rowCount), maxVisibleRows)
        return CGFloat(n) * rowHeight + CGFloat(max(0, n - 1)) * rowSpacing
    }
}
