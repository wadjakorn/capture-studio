import Foundation
import CoreGraphics

/// One cursor position sample in screen-source pixel space (top-left origin),
/// `t` seconds on the composition timeline (same zero as the screen track).
struct CursorSample: Equatable {
    var t: Double
    var p: CGPoint
    /// Cursor name from EventLine (arrow, pointingHand, …); used to pick glyph.
    var cursor: String
}

/// One mouse-down in screen-source pixel space (top-left), `t` on the timeline.
struct ClickSample: Equatable {
    var t: Double
    var p: CGPoint
}

/// Pure event→render mapping and time→position lookup. No AVFoundation /
/// AppKit deps so it's unit-testable in isolation.
enum CursorOverlay {
    /// Click-ring lifetime in seconds (expand + fade).
    static let ringDuration = 0.4

    /// Maps a global-screen-point coordinate (top-left origin, as stored in
    /// events.jsonl) into screen-source pixels using the captured display
    /// geometry. `sourceSize` is the screen video's natural pixel size.
    static func sourcePoint(x: Double, y: Double, display: DisplayInfo,
                            sourceSize: CGSize) -> CGPoint {
        guard display.pointWidth > 0, display.pointHeight > 0 else { return .zero }
        let fx = (x - display.originX) / display.pointWidth
        let fy = (y - display.originY) / display.pointHeight
        return CGPoint(x: fx * sourceSize.width, y: fy * sourceSize.height)
    }

    /// Extracts sorted cursor + click samples (in source pixels) from raw events.
    static func samples(from events: [EventLine], display: DisplayInfo,
                        sourceSize: CGSize) -> (cursor: [CursorSample], clicks: [ClickSample]) {
        var cursor: [CursorSample] = []
        var clicks: [ClickSample] = []
        for e in events {
            guard let x = e.x, let y = e.y else { continue }
            let p = sourcePoint(x: x, y: y, display: display, sourceSize: sourceSize)
            switch e.e {
            case .pos:
                cursor.append(CursorSample(t: e.t, p: p, cursor: e.cursor ?? "arrow"))
            case .down:
                clicks.append(ClickSample(t: e.t, p: p))
            default:
                break
            }
        }
        // Events are written in capture order (already ascending), but sort
        // defensively so the lookup's binary search is sound.
        cursor.sort { $0.t < $1.t }
        clicks.sort { $0.t < $1.t }
        return (cursor, clicks)
    }

    /// Cursor position (source pixels) at time `now`, linearly interpolated
    /// between the bracketing samples. Clamps to the ends; nil if empty.
    /// Returns the chosen cursor name (from the earlier sample of the pair).
    static func position(at now: Double, in samples: [CursorSample]) -> (p: CGPoint, cursor: String)? {
        guard let first = samples.first else { return nil }
        if now <= first.t { return (first.p, first.cursor) }
        guard let last = samples.last else { return nil }
        if now >= last.t { return (last.p, last.cursor) }

        // Binary search for the last index with t <= now.
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if samples[mid].t <= now { lo = mid } else { hi = mid - 1 }
        }
        let a = samples[lo]
        let b = samples[min(lo + 1, samples.count - 1)]
        let span = b.t - a.t
        guard span > 0 else { return (a.p, a.cursor) }
        let f = (now - a.t) / span
        let p = CGPoint(x: a.p.x + (b.p.x - a.p.x) * f,
                        y: a.p.y + (b.p.y - a.p.y) * f)
        return (p, a.cursor)
    }
}
