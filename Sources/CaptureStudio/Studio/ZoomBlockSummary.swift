import Foundation
import CoreGraphics

/// What a zoom block's picture is doing over one stretch of it.
struct ZoomPhase: Equatable {
    enum Kind: Equatable {
        /// On the window the pointer is working in.
        case window
        /// Zoomed out to hold the window and the pointer.
        case both
        /// Going with the pointer (no window to stay with there).
        case pointer
        /// Staying on the window while the pointer is somewhere else.
        case holdWindow
        /// A fixed spot placed by hand.
        case spot
    }
    var begin: Double
    var end: Double
    var kind: Kind
    var scale: Double
}

/// A plain account of what one zoom block does — what the picture stays with,
/// when, and at what zoom — worked out by the same code that renders it, so
/// the editor can show "what is this block following?". Pure — unit-tested.
struct ZoomBlockStory: Equatable {
    var phases: [ZoomPhase] = []
    /// Times of clicks whose opened content (a menu, a popover, a tooltip)
    /// the picture leans toward during the block.
    var leans: [Double] = []
}

enum ZoomBlockSummary {
    /// Shortest stretch worth a line of its own (seconds).
    static let shortest = 0.5

    /// The story of `block` (one of `blocks`). Everything is given on the
    /// master timeline; with `cuts` it is worked out on the cut timeline — the
    /// one that plays — and reported back in master time.
    static func story(of block: ZoomBlock, in blocks: [ZoomBlock], cursor: [CursorSample],
                      sourceSize: CGSize, config: AutoZoomConfig,
                      cuts: [Range<Double>] = []) -> ZoomBlockStory {
        let level = max(1, block.scale ?? config.defaultScale)
        guard (block.mode ?? .follow) == .follow else {
            return ZoomBlockStory(phases: [ZoomPhase(begin: block.begin, end: block.end,
                                                     kind: .spot, scale: level)])
        }
        // Onto the timeline that plays.
        var cfg = config
        var blocks = blocks
        var cursor = cursor
        var span = (begin: block.begin, end: block.end)
        if !cuts.isEmpty {
            blocks = blocks.compactMap { b in
                TimelineCut.span(begin: b.begin, end: b.end, cuts: cuts).map {
                    var c = b
                    c.begin = $0.begin
                    c.end = $0.end
                    return c
                }
            }
            cursor = cursor.compactMap { s in
                TimelineCut.point(s.t, cuts: cuts).map { var c = s; c.t = $0; return c }
            }
            cfg.windows = WindowHints.collapsed(config.windows, cuts: cuts)
            cfg.reveals = config.reveals.compactMap { r in
                TimelineCut.point(r.t, cuts: cuts).map { var c = r; c.t = $0; return c }
            }
            cfg.discontinuities = AutoZoomTrack.collapsedCutTimes(cuts)
            guard let s = TimelineCut.span(begin: block.begin, end: block.end, cuts: cuts) else {
                return ZoomBlockStory()          // wholly cut away: nothing plays
            }
            span = s
        }
        func master(_ t: Double) -> Double { cuts.isEmpty ? t : TimelineCut.unmap(t, cuts: cuts) }

        let x = ZoomAutoScaler.expand(blocks: blocks, cursor: cursor, sourceSize: sourceSize,
                                      config: cfg)
        var phases: [ZoomPhase] = []
        for p in x.phases where p.end > span.begin + 1e-9 && p.begin < span.end - 1e-9 {
            let piece = ZoomPhase(begin: max(p.begin, span.begin), end: min(p.end, span.end),
                                  kind: p.kind, scale: p.scale)
            if let last = phases.last, last.kind == piece.kind, last.scale == piece.scale,
               abs(last.end - piece.begin) < 1e-6 {
                phases[phases.count - 1].end = piece.end
            } else {
                phases.append(piece)
            }
        }
        // A stretch too short to read as one (a window caught for a moment at
        // the block's edge) is left out of the account.
        let readable = phases.filter { $0.end - $0.begin >= shortest }
        if !readable.isEmpty { phases = readable }
        if phases.isEmpty {
            // Not framed by content: the pointer, at the block's own level.
            phases = [ZoomPhase(begin: span.begin, end: span.end, kind: .pointer, scale: level)]
        }
        // What the picture can lean toward: clicks whose opened content fits
        // the view at the zoom of that moment, outside stretches fixed by a
        // window alone.
        let view = cfg.viewSize ?? sourceSize
        let leans = cfg.reveals.filter { r in
            guard r.t >= span.begin - cfg.revealLag, r.t < span.end,
                  !x.windowOnly.contains(where: { $0.begin <= r.t && r.t < $0.end }) else {
                return false
            }
            let scale = (phases.last { $0.begin <= r.t } ?? phases[0]).scale
            return Double(r.rect.width) <= Double(view.width) / scale
                && Double(r.rect.height) <= Double(view.height) / scale
        }.map { master($0.t) }.sorted()
        return ZoomBlockStory(
            phases: phases.map {
                ZoomPhase(begin: master($0.begin), end: master($0.end), kind: $0.kind,
                          scale: $0.scale)
            },
            leans: leans)
    }
}
