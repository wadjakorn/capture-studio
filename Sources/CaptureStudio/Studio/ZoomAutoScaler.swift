import Foundation
import CoreGraphics

/// Turns follow blocks that frame by content — a zoom range (`ZoomBlock.auto`)
/// and/or a `ZoomShow` other than the bare pointer — into touching pieces with
/// one scale each, chosen to fit what is on screen (the window the block works
/// in, what clicks opened) inside the block's range, and works out where the
/// camera is held to a window. The track
/// builder then renders the pieces like any touching blocks: one continuous
/// zoom whose scale eases from piece to piece. Pure — unit-tested.
enum ZoomAutoScaler {
    /// A piece shorter than this does not get a scale of its own.
    static let minPiece = 1.5
    /// A piece zoomed in further than both its neighbours must last this long.
    static let minPeak = 3.0
    /// Neighbouring scales closer than this ratio are one scale.
    static let sameRatio = 1.15
    /// With `ZoomShow.auto`, a trip outside the window up to this long (that
    /// comes back) shows both; a longer one follows the pointer.
    static let briefTrip = 4.0
    /// "Window and pointer": a trip outside at least this long zooms out for
    /// both however short it is otherwise; a flick does not.
    static let minKeptTrip = 0.5
    /// How long the frame makes room for what a click opened.
    static let revealHold = 2.5

    struct Expansion: Equatable {
        /// The blocks with every auto block replaced by its pieces.
        var blocks: [ZoomBlock]
        /// The window spans the camera is held to (changed only inside trips
        /// outside the window and gaps in the data).
        var windows: [WindowSpan]
        /// Piece boundaries where the scale changes: eased, not snapped.
        var softSeams: [Double]
        /// Spans in which the pointer is treated as staying inside the rect
        /// ("stay on the window").
        var pointerHolds: [WindowSpan]
        /// Stretches where the frame is fixed by a window alone — a block that
        /// shows "the window", or a trip held on window and pointer: it does
        /// not lean toward what a click opened there (a menu, a Dock tooltip).
        var windowOnly: [TimeSpan] = []
        /// What the picture stays with over each stretch of the expanded
        /// blocks, with the scale it takes there (for the editor's summary).
        var phases: [ZoomPhase] = []
    }

    /// `config` carries the windows, reveals, view and content geometry, all
    /// on the same timeline as `blocks` and `cursor`.
    static func expand(blocks: [ZoomBlock], cursor: [CursorSample], sourceSize: CGSize,
                       config: AutoZoomConfig) -> Expansion {
        var out = Expansion(blocks: [], windows: config.windows, softSeams: [], pointerHolds: [])
        let sorted = blocks.filter { $0.end - $0.begin > 0 }.sorted { $0.begin < $1.begin }
        guard sorted.contains(where: { expands($0) }) else {
            out.blocks = blocks
            return out
        }
        // Touching auto blocks with the same settings are planned as one, so
        // splitting a block changes nothing by itself.
        var i = 0
        while i < sorted.count {
            let b = sorted[i]
            guard expands(b) else { out.blocks.append(b); i += 1; continue }
            var j = i
            while j + 1 < sorted.count, expands(sorted[j + 1]),
                  abs(sorted[j + 1].begin - sorted[j].end) < 1e-6,
                  sorted[j + 1].auto == b.auto, sorted[j + 1].scale == b.scale,
                  sorted[j + 1].overflow == b.overflow,
                  sorted[j + 1].effectiveShow == b.effectiveShow { j += 1 }
            expandGroup(Array(sorted[i...j]), cursor: cursor, sourceSize: sourceSize,
                        config: config, into: &out)
            i = j + 1
        }
        out.softSeams.sort()
        return out
    }

    /// Whether `b` is framed by content: a follow block with a zoom range, or
    /// one that shows more than the bare pointer. Anything else renders
    /// exactly as it is.
    static func expands(_ b: ZoomBlock) -> Bool {
        (b.mode ?? .follow) == .follow && (b.auto != nil || b.effectiveShow != .pointer)
    }

    /// What a block asks for, with one zoom level read as the range `s…s`.
    private struct Settings {
        var min: Double
        var max: Double
        var fitReveals: Bool
        var show: ZoomShow
    }

    /// A stretch of time at one scale.
    private struct Piece {
        var begin: Double
        var end: Double
        var scale: Double
        /// Asked for by the user ("window and pointer"): not dropped for being short.
        var keep = false
        var length: Double { end - begin }
    }

    private enum Trip { case both, pointer, window }

    private static func expandGroup(_ group: [ZoomBlock], cursor: [CursorSample],
                                    sourceSize: CGSize, config: AutoZoomConfig,
                                    into out: inout Expansion) {
        guard let first = group.first, let last = group.last else { return }
        let show = first.effectiveShow
        let level = Swift.max(1, first.scale ?? config.defaultScale)
        let auto = first.auto.map {
            Settings(min: $0.min, max: $0.max, fitReveals: $0.fitReveals, show: show)
        } ?? Settings(min: level, max: level, fitReveals: false, show: show)
        let g0 = first.begin, g1 = last.end
        let full = CGRect(origin: .zero, size: sourceSize)
        let content = (config.contentRect ?? full).standardized
        let view = config.viewSize ?? sourceSize
        // With nothing to fit: the block's own level, kept inside its range.
        let base = Swift.min(Swift.max(level, auto.min), auto.max)
        // Holding a window means the picture stops at its edge, whatever the
        // block's edge setting says.
        let holdsWindow = show == .window || show == .both
        if show == .window { out.windowOnly.append(TimeSpan(begin: g0, end: g1)) }
        let contained = holdsWindow || !(first.overflow ?? config.defaultOverflow)
        let room = 1 - 2 * ZoomShotPlanner.boundMargin

        func rawFit(_ subject: CGRect?) -> Double? {
            guard let s = subject, s.width > 0, s.height > 0, view.width > 0, view.height > 0
            else { return nil }
            return room * Swift.min(Double(view.width / s.width), Double(view.height / s.height))
        }
        /// The scale at which `subject` and the camera's margin fill the frame,
        /// kept inside the block's range: a subject too large for the least
        /// zoom gets the least zoom — as much of it as the user allows.
        func fit(_ subject: CGRect?) -> Double? {
            rawFit(subject).map {
                Swift.max(Swift.min(($0 * 20 + 1e-9).rounded(.down) / 20, auto.max), auto.min)
            }
        }
        /// Whether the frame can hold `subject` somewhere in the range — nearly
        /// edge to edge counts (`holdFill`): the margin is a nicety, not a
        /// reason to give up on it.
        func fits(_ subject: CGRect?) -> Bool {
            (rawFit(subject) ?? 0) / room * ZoomShotPlanner.holdFill >= auto.min - 1e-9
        }
        func clip(_ r: CGRect) -> CGRect? {
            let c = r.intersection(content)
            return c.isNull || c.width <= 0 || c.height <= 0 ? nil : c
        }
        func pointerBox(_ a: Double, _ b: Double) -> CGRect? {
            var box: CGRect?
            // First sample at or after `a` (samples are in time order).
            var lo = 0, hi = cursor.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if cursor[mid].t < a - 1e-9 { lo = mid + 1 } else { hi = mid }
            }
            for s in cursor[lo...].prefix(while: { $0.t <= b + 1e-9 }) {
                let p = CGRect(x: Swift.min(Swift.max(s.p.x, content.minX), content.maxX),
                               y: Swift.min(Swift.max(s.p.y, content.minY), content.maxY),
                               width: 0, height: 0)
                box = box.map { $0.union(p) } ?? p
            }
            return box
        }

        // --- The window under the pointer, over the group -------------------------
        struct Seg { var begin: Double; var end: Double; var id: Int; var rect: CGRect? }
        var segs: [Seg] = []
        var t = g0
        for w in config.windows where w.end > g0 + 1e-9 && w.begin < g1 - 1e-9 {
            let a = Swift.max(w.begin, g0), b = Swift.min(w.end, g1)
            if a > t + 1e-9 { segs.append(Seg(begin: t, end: a, id: 0, rect: nil)) }
            if b > a + 1e-9 { segs.append(Seg(begin: a, end: b, id: w.id, rect: clip(w.rect))) }
            t = Swift.max(t, b)
        }
        if g1 > t + 1e-9 { segs.append(Seg(begin: t, end: g1, id: 0, rect: nil)) }

        // Home: the window the pointer is over for the longest (first on a tie).
        var totals: [Int: Double] = [:]
        var order: [Int] = []
        for s in segs where s.rect != nil {
            if totals[s.id] == nil { order.append(s.id) }
            totals[s.id, default: 0] += s.end - s.begin
        }
        let home = order.max { (totals[$0] ?? 0) < (totals[$1] ?? 0) - 1e-9 }

        // A gap during which the pointer never leaves the home window is home.
        if let home {
            let near = CGFloat(ZoomShotPlanner.boundMargin)
            for k in segs.indices where segs[k].rect == nil {
                let before = segs[..<k].last { $0.id == home && $0.rect != nil }?.rect
                let after = segs[(k + 1)...].first { $0.id == home && $0.rect != nil }?.rect
                guard let rect = before ?? after,
                      let box = pointerBox(segs[k].begin, segs[k].end),
                      rect.insetBy(dx: -near * view.width, dy: -near * view.height).contains(box)
                else { continue }
                segs[k].id = home
                segs[k].rect = rect
            }
        }

        // --- Pieces: one scale per stretch -----------------------------------------
        var pieces: [Piece] = []
        /// Window spans replacing the recorded ones inside the group.
        var held: [WindowSpan] = []
        /// "Show both" trips: valid only while the piece scale still fits them.
        var both: [(span: WindowSpan, fit: Double)] = []
        func add(_ a: Double, _ b: Double, _ subject: CGRect?) {
            guard b > a + 1e-9 else { return }
            pieces.append(Piece(begin: a, end: b, scale: fit(subject) ?? base))
        }

        /// What the picture stays with, per stretch (scales are filled in last).
        var marks: [(begin: Double, end: Double, kind: ZoomPhase.Kind)] = []
        var k = 0
        while k < segs.count {
            let s = segs[k]
            let isHome = home != nil && s.id == home && s.rect != nil
            if isHome || home == nil {
                add(s.begin, s.end, s.rect)
                marks.append((s.begin, s.end, contained && s.rect != nil ? .window : .pointer))
                if let rect = s.rect {
                    held.append(WindowSpan(begin: s.begin, end: s.end, rect: rect, id: s.id))
                }
                k += 1
                continue
            }
            // A trip away from the home window: every segment until it is back.
            var e = k
            while e + 1 < segs.count, !(segs[e + 1].id == home && segs[e + 1].rect != nil) { e += 1 }
            let tripBegin = s.begin, tripEnd = segs[e].end
            let homeBefore = segs[..<k].last { $0.id == home && $0.rect != nil }?.rect
            let comesBack = e + 1 < segs.count
            let homeRect = homeBefore ?? (comesBack ? segs[e + 1].rect : nil)

            var trip: Trip
            switch auto.show {
            case .pointer: trip = .pointer
            case .both: trip = .both
            case .window: trip = .window
            case .auto:
                trip = homeBefore != nil && comesBack && tripEnd - tripBegin <= briefTrip
                    ? .both : .pointer
            }
            // Without a contained frame the camera is not held to anything.
            if !contained || homeRect == nil { trip = .pointer }
            var union: CGRect?
            var wideTrip = false
            if trip == .both, let homeRect {
                union = pointerBox(tripBegin, tripEnd).map { homeRect.union($0) } ?? homeRect
                // Both cannot be shown: go with the pointer, as wide as allowed.
                if !fits(union) { trip = .pointer; wideTrip = true }
            }

            switch trip {
            case .both:
                guard let union, let f = fit(union) else { break }
                pieces.append(Piece(begin: tripBegin, end: tripEnd, scale: f,
                                    keep: auto.show == .both
                                        && tripEnd - tripBegin >= minKeptTrip))
                both.append((WindowSpan(begin: tripBegin, end: tripEnd, rect: union,
                                        id: home ?? 0), f))
            case .window:
                guard let homeRect else { break }
                add(tripBegin, tripEnd, homeRect)
                marks.append((tripBegin, tripEnd, .holdWindow))
                let span = WindowSpan(begin: tripBegin, end: tripEnd, rect: homeRect, id: home ?? 0)
                held.append(span)
                out.pointerHolds.append(span)
            case .pointer:
                for x in segs[k...e] {
                    if wideTrip {
                        pieces.append(Piece(begin: x.begin, end: x.end, scale: auto.min))
                        marks.append((x.begin, x.end, .pointer))
                    } else {
                        add(x.begin, x.end, x.rect)
                        marks.append((x.begin, x.end,
                                      contained && x.rect != nil ? .window : .pointer))
                    }
                    if let rect = x.rect {
                        held.append(WindowSpan(begin: x.begin, end: x.end, rect: rect, id: x.id))
                    }
                }
            }
            k = e + 1
        }

        // --- Make room for what a click opened (only ever by zooming out) ----------
        // ("The window" means the window: it makes room for nothing else.)
        if auto.fitReveals && show != .window {
            let subjects: [(begin: Double, end: Double, rect: CGRect?)] =
                both.map { ($0.span.begin, $0.span.end, Optional($0.span.rect)) }
                + held.map { ($0.begin, $0.end, Optional($0.rect)) }
            var lowered = pieces
            for r in config.reveals.sorted(by: { $0.t < $1.t })
            where r.t >= g0 - 1e-9 && r.t < g1 - 1e-9 {
                guard let opened = clip(r.rect.union(CGRect(origin: r.click, size: .zero)))
                else { continue }
                let around = subjects.first { $0.begin <= r.t && r.t < $0.end }
                    .flatMap { $0.rect }
                // Something that cannot fit anyway is left to the camera's lean.
                let subject = around.map { $0.union(opened) } ?? opened
                guard fits(subject), let need = fit(subject) else { continue }
                let a = Swift.max(r.t, g0), b = Swift.min(r.t + revealHold, g1)
                lowered = lower(lowered, from: a, to: b, toScale: need)
            }
            pieces = lowered
        }

        pieces = calm(pieces)

        // A "show both" trip only holds the frame on both while they still fit.
        for trip in both {
            let scale = pieces.first { $0.begin <= trip.span.begin + 1e-9
                                       && $0.end > trip.span.begin + 1e-9 }?.scale ?? base
            let holds = scale <= trip.fit + 1e-9
            if holds {
                held.append(trip.span)
                // Held on both: a lean would only pull one of them out of frame.
                out.windowOnly.append(TimeSpan(begin: trip.span.begin, end: trip.span.end))
            }
            marks.append((trip.span.begin, trip.span.end, holds ? .both : .pointer))
        }
        for m in marks.sorted(by: { $0.begin < $1.begin }) {
            for p in pieces where p.end > m.begin + 1e-9 && p.begin < m.end - 1e-9 {
                out.phases.append(ZoomPhase(begin: Swift.max(p.begin, m.begin),
                                            end: Swift.min(p.end, m.end), kind: m.kind,
                                            scale: p.scale))
            }
        }
        held.sort { $0.begin < $1.begin }
        out.windows = out.windows.flatMap { w -> [WindowSpan] in
            // Recorded spans give way to the group's own inside it.
            var parts: [WindowSpan] = []
            if w.begin < g0 - 1e-9 {
                parts.append(WindowSpan(begin: w.begin, end: Swift.min(w.end, g0), rect: w.rect,
                                        id: w.id))
            }
            if w.end > g1 + 1e-9 {
                parts.append(WindowSpan(begin: Swift.max(w.begin, g1), end: w.end, rect: w.rect,
                                        id: w.id))
            }
            return parts
        }
        out.windows = (out.windows + held).sorted { $0.begin < $1.begin }

        // --- Emit: pieces cut at the original block boundaries ---------------------
        for (bi, block) in group.enumerated() {
            var firstOfBlock = true
            for p in pieces where p.end > block.begin + 1e-9 && p.begin < block.end - 1e-9 {
                var piece = block
                piece.id = firstOfBlock ? block.id : UUID()
                piece.begin = Swift.max(p.begin, block.begin)
                piece.end = Swift.min(p.end, block.end)
                piece.scale = p.scale
                piece.auto = nil
                piece.show = .pointer
                if holdsWindow { piece.overflow = false }
                guard piece.end - piece.begin > 1e-9 else { continue }
                if !firstOfBlock || bi > 0, let prev = out.blocks.last,
                   abs(prev.end - piece.begin) < 1e-6, prev.scale != piece.scale {
                    out.softSeams.append(piece.begin)
                }
                out.blocks.append(piece)
                firstOfBlock = false
            }
        }
    }

    /// `pieces` with the scale over `[a, b)` no higher than `toScale`.
    private static func lower(_ pieces: [Piece], from a: Double, to b: Double,
                              toScale: Double) -> [Piece] {
        guard b > a + 1e-9 else { return pieces }
        var out: [Piece] = []
        for p in pieces {
            guard p.end > a + 1e-9, p.begin < b - 1e-9, p.scale > toScale + 1e-9 else {
                out.append(p)
                continue
            }
            let lo = Swift.max(p.begin, a), hi = Swift.min(p.end, b)
            if lo > p.begin + 1e-9 {
                out.append(Piece(begin: p.begin, end: lo, scale: p.scale, keep: p.keep))
            }
            out.append(Piece(begin: lo, end: hi, scale: toScale, keep: p.keep))
            if p.end > hi + 1e-9 {
                out.append(Piece(begin: hi, end: p.end, scale: p.scale, keep: p.keep))
            }
        }
        return out
    }

    /// The scale each stretch of `block` takes, for callers that need the scale
    /// at one moment (e.g. turning an auto block into a manual one).
    static func scale(at t: Double, in expansion: Expansion) -> Double? {
        expansion.blocks.first { $0.begin <= t && t < $0.end }?.scale
    }

    /// Fewer, calmer changes: a piece too short for a scale of its own takes
    /// its predecessor's; a brief zoom-in between two wider framings is not
    /// made; scales too close to tell apart become one (the lower).
    private static func calm(_ input: [Piece]) -> [Piece] {
        func joined(_ ps: [Piece], lowest: Bool) -> [Piece] {
            var out: [Piece] = []
            // Highest scale merged into the last piece: the whole merged run
            // must stay within the ratio, so a slow drift is not one scale.
            var high = 0.0
            for p in ps {
                if let last = out.last,
                   Swift.max(high, p.scale) / Swift.min(last.scale, p.scale)
                    < (lowest ? sameRatio : 1 + 1e-9) {
                    out[out.count - 1].end = p.end
                    out[out.count - 1].scale = Swift.min(last.scale, p.scale)
                    out[out.count - 1].keep = last.keep || p.keep
                    high = Swift.max(high, p.scale)
                } else {
                    out.append(p)
                    high = p.scale
                }
            }
            return out
        }
        var ps = joined(input, lowest: false)
        // Short pieces.
        var changed = true
        while changed {
            changed = false
            for i in ps.indices
            where ps[i].length < minPiece - 1e-9 && ps.count > 1 && !ps[i].keep {
                ps[i].scale = i > 0 ? ps[i - 1].scale : ps[i + 1].scale
                ps = joined(ps, lowest: false)
                changed = true
                break
            }
        }
        // Brief zoom-ins.
        changed = true
        while changed {
            changed = false
            for i in ps.indices where ps[i].length < minPeak - 1e-9 && ps.count > 1 {
                // Only between two wider framings: at the block's edge the
                // zoom ramps in or out there anyway.
                guard i > 0, i + 1 < ps.count, ps[i - 1].scale < ps[i].scale,
                      ps[i + 1].scale < ps[i].scale else { continue }
                ps[i].scale = Swift.max(ps[i - 1].scale, ps[i + 1].scale)
                ps = joined(ps, lowest: false)
                changed = true
                break
            }
        }
        return joined(ps, lowest: true)
    }
}
