import Foundation
import CoreGraphics

/// One resolved auto-zoom state at an instant: magnification (`scale`, ≥1) and
/// the focus point in screen-source pixels (top-left origin) the zoom centers on.
/// `weight` is the normalized zoom progress (0 at a block's edges where scale==1,
/// 1 at the fully-held target scale); the renderer uses it to blend the focus
/// toward the framing-window centre so the cursor ends up centred in the output.
struct ZoomKeyframe: Equatable {
    var t: Double
    var scale: Double
    var focusX: Double
    var focusY: Double
    var weight: Double = 0
    /// The owning block's overflow flag — whether the pan may leave the framing
    /// window and reveal the background. Carried per keyframe so the renderer can
    /// read it without the block list; not interpolated (stepwise per block).
    var overflow: Bool = false
}

/// Tunables for the auto-zoom pre-pass. The defaults come from UserDefaults and
/// the project's own follow settings (see `StudioModel.autoZoomConfig`).
struct AutoZoomConfig {
    var defaultScale: Double = 2.0
    /// How readily the frame moves to follow the cursor, 0…1. Drives the safe
    /// zone, travel speed and flick tolerance via `ZoomShotPlanner.followTuning`:
    /// low = holds longer and glides, high = follows closely. Overridden per block
    /// by `ZoomBlock.sensitivity`.
    var defaultSensitivity: Double = 0.5
    /// Overflow for blocks without their own setting (see `ZoomBlock.overflow`).
    var defaultOverflow: Bool = false
    /// Keyframe sampling step (seconds).
    var step: Double = 1.0 / 60.0
    /// How much source (px) fits in the framing region at scale 1. nil = the full
    /// source. Smaller with a framing window; larger than the content on one axis
    /// in a letterboxed fit (that axis then never pans).
    var viewSize: CGSize? = nil
    /// The part of the source the picture can show (the reframe crop). nil = the
    /// full source. In contained mode the view never leaves it.
    var contentRect: CGRect? = nil
    /// Times on the track's timeline where the picture cuts (collapsed cut
    /// points). The camera cuts with it instead of gliding across footage that
    /// was never adjacent.
    var discontinuities: [Double] = []
    /// What clicks opened (see `ContentHints.reveals`), on the track's timeline.
    /// A follow shot that settles around one leans toward it. Empty = frame by
    /// the pointer alone.
    var reveals: [Reveal] = []
    /// A reveal counts for a shot settling within this long before / after its
    /// click.
    var revealLead = 2.0
    var revealLag = 0.5
}

/// Pure pre-pass: turn zoom blocks + cursor samples into a `[ZoomKeyframe]`
/// track, then sample it statelessly per frame. Building once (at composition
/// build) and interpolating at render time keeps the render deterministic under
/// out-of-order frame requests (preview scrubbing). No AVFoundation / AppKit
/// deps so it's unit-testable.
///
/// Follow model (shots): the camera holds a framing while the cursor stays in
/// its safe zone, and makes one eased move to a new framing when the cursor
/// leaves — placed where the cursor lands, and started early because the whole
/// path is known up front. Long hops dip the zoom so the screen never sweeps by
/// too fast. See `ZoomShotPlanner`.
enum AutoZoomTrack {
    static func build(blocks: [ZoomBlock], cursorSamples: [CursorSample],
                      sourceSize: CGSize,
                      config: AutoZoomConfig = AutoZoomConfig()) -> [ZoomKeyframe] {
        guard !blocks.isEmpty else { return [] }
        let sorted = blocks.filter { $0.end - $0.begin > 0 }
            .sorted { $0.begin < $1.begin }
        guard !sorted.isEmpty else { return [] }

        // Group touching blocks (prev.end == next.begin) into continuous "runs".
        // The zoom ramps in only at a run's start and out only at its end; inside a
        // run the scale is held (never returns to 1×) and the focus path is
        // continuous across block boundaries — so switching follow↔manual mid-run
        // is seamless. A gap between blocks starts a new run and re-zooms from 1×.
        var runs: [[ZoomBlock]] = []
        for b in sorted {
            if let prev = runs.last?.last, abs(b.begin - prev.end) < 1e-6 {
                runs[runs.count - 1].append(b)
            } else {
                runs.append([b])
            }
        }

        var out: [ZoomKeyframe] = []
        for run in runs {
            appendRun(run, into: &out, cursorSamples: cursorSamples,
                      sourceSize: sourceSize, config: config)
        }
        return out
    }

    /// Per-block framing geometry in source pixels.
    private struct BlockGeometry {
        /// Held magnification.
        var hold: Double
        /// View half-extent at the held scale.
        var half: CGSize
        /// Where the view centre may go (min/max per axis; may be inverted).
        var reach: CGRect
        /// Where cursor samples are clamped before planning.
        var cursorBounds: CGRect
        var tuning: FollowTuning
    }

    /// A move plus what its dip is computed from.
    private struct PlannedMove {
        var move: ZoomMove
        var dNorm: Double
        var hold: Double
    }

    /// Emit keyframes for one run of touching blocks. Scale follows a run-wide
    /// envelope (ramp in at the run start, hold, ramp out at the run end) times a
    /// per-instant target blended across internal boundaries, times any zoom dip.
    /// The focus is a sequence of centres (follow shots, manual targets) joined by
    /// eased moves; every change of centre has a move, so the path always ends
    /// exactly on the current centre.
    private static func appendRun(_ run: [ZoomBlock], into out: inout [ZoomKeyframe],
                                  cursorSamples: [CursorSample], sourceSize: CGSize,
                                  config: AutoZoomConfig) {
        guard let first = run.first, let last = run.last else { return }
        let runStart = first.begin, runEnd = last.end
        let runSpan = runEnd - runStart
        guard runSpan > 0 else { return }

        // Run-edge ramps: in from the first block's sensitivity, out from the last's.
        // Scale both down together if they'd overlap so each still completes.
        var rIn = rampFor(first.sensitivity ?? config.defaultSensitivity)
        var rOut = rampFor(last.sensitivity ?? config.defaultSensitivity)
        if rIn + rOut > runSpan {
            let k = runSpan / (rIn + rOut)
            rIn *= k; rOut *= k
        }

        let full = CGRect(origin: .zero, size: sourceSize)
        let content = (config.contentRect ?? full).standardized
        let view = config.viewSize ?? sourceSize
        let contentCentre = CGPoint(x: content.midX, y: content.midY)
        let breaks = config.discontinuities
            .filter { $0 > runStart + 1e-9 && $0 < runEnd - 1e-9 }.sorted()

        func geometry(_ b: ZoomBlock) -> BlockGeometry {
            let hold = max(1, b.scale ?? config.defaultScale)
            let half = CGSize(width: view.width / (2 * hold), height: view.height / (2 * hold))
            let overflow = b.overflow ?? config.defaultOverflow
            // Contained: the view stays inside the content (mirrors the
            // compositor's cover clamp). Built from explicit min/max so an axis
            // where the view is larger than the content stays inverted and the
            // planner collapses it to the midpoint.
            let reach = overflow ? full
                : CGRect(x: content.minX + half.width, y: content.minY + half.height,
                         width: content.width - 2 * half.width,
                         height: content.height - 2 * half.height)
            return BlockGeometry(hold: hold, half: half, reach: reach,
                                 cursorBounds: overflow ? full : content,
                                 tuning: ZoomShotPlanner.followTuning(
                                    b.sensitivity ?? config.defaultSensitivity))
        }
        func cursor(_ g: BlockGeometry) -> (Double) -> CGPoint {
            { t in
                let p = cursorPoint(at: t, in: cursorSamples, breaks: breaks) ?? contentCentre
                return CGPoint(x: min(max(p.x, g.cursorBounds.minX), g.cursorBounds.maxX),
                               y: min(max(p.y, g.cursorBounds.minY), g.cursorBounds.maxY))
            }
        }
        // Reveals in this run, by click time.
        let reveals = config.reveals
            .filter { $0.t >= runStart - config.revealLag && $0.t <= runEnd }
            .sorted { $0.t < $1.t }
        // The revealed content a shot settling at `t` should lean toward: the
        // reveals of the clicks around it that fit the view, united for as long
        // as the union still fits.
        func leanTarget(at t: Double, geo: BlockGeometry) -> CGRect? {
            var union: CGRect?
            for r in reveals where r.t >= t - config.revealLag && r.t <= t + config.revealLead {
                // No pairing across a picture cut.
                if breaks.contains(where: { ($0 > t && $0 <= r.t) || ($0 > r.t && $0 <= t) }) {
                    continue
                }
                let rect = r.rect.intersection(geo.cursorBounds)
                guard !rect.isNull, rect.width > 0, rect.height > 0 else { continue }
                let next = union.map { $0.union(rect) } ?? rect
                guard next.width <= geo.half.width * 2, next.height <= geo.half.height * 2
                else { continue }
                union = next
            }
            return union
        }
        func differs(_ a: CGPoint, _ b: CGPoint) -> Bool {
            hypot(Double(a.x - b.x), Double(a.y - b.y)) > 1e-6
        }

        // --- Centres and the moves between them --------------------------------
        var planned: [PlannedMove] = []
        var origin = contentCentre
        var current = contentCentre
        var haveOrigin = false
        var lastAim: CGPoint?
        var prevMode: ZoomMode?
        var prevGeo: BlockGeometry?
        // Manual block index → index of the move entering / leaving it.
        var entering: [Int: Int] = [:], leaving: [Int: Int] = [:]

        func append(to target: CGPoint, geo: BlockGeometry, d: Double? = nil,
                    time: (Double) -> Double) -> Int {
            let dx = Double(target.x - current.x), dy = Double(target.y - current.y)
            let dn = ZoomShotPlanner.dNorm(dx: dx, dy: dy, half: geo.half)
            let dur = d ?? ZoomShotPlanner.duration(dNorm: dn, vPref: geo.tuning.vPref)
            planned.append(PlannedMove(move: ZoomMove(t: time(dur), d: dur, dx: dx, dy: dy),
                                       dNorm: dn, hold: geo.hold))
            current = target
            return planned.count - 1
        }

        // A follow move must stay inside its contiguous stretch of follow blocks:
        // a neighbouring manual block holds its own target.
        func isManual(_ i: Int) -> Bool { (run[i].mode ?? .follow) == .manual }
        func followBounds(_ i: Int) -> (lo: Double, hi: Double) {
            var a = i, b = i
            while a > 0 && !isManual(a - 1) { a -= 1 }
            while b < run.count - 1 && !isManual(b + 1) { b += 1 }
            return (a > 0 ? run[a].begin : -.infinity,
                    b < run.count - 1 ? run[b].end : .infinity)
        }
        func confine(_ idx: Int, to bounds: (lo: Double, hi: Double)) {
            let m = planned[idx].move
            guard m.d > 0 else { return }
            let lo = max(m.t - m.d / 2, bounds.lo), hi = min(m.t + m.d / 2, bounds.hi)
            guard lo > m.t - m.d / 2 || hi < m.t + m.d / 2 else { return }
            planned[idx].move.d = max(0, hi - lo)
            planned[idx].move.t = hi > lo ? (lo + hi) / 2 : min(max(m.t, bounds.lo), bounds.hi)
        }

        for (i, block) in run.enumerated() {
            let geo = geometry(block)
            let mode = block.mode ?? .follow
            let span = block.end - block.begin
            // The picture cuts exactly at this block's start (two blocks either
            // side of a removed range collapse to touch): the camera cuts too.
            let cutAtBegin = i > 0 && config.discontinuities.contains {
                abs($0 - block.begin) < 1e-6
            }
            if mode == .manual {
                // A manual block with no stored target holds the incoming centre.
                let raw = manualTarget(block, sourceSize: sourceSize)
                    ?? (haveOrigin ? current : cursor(geo)(runStart))
                let target = ZoomShotPlanner.clamp(raw, toReach: geo.reach)
                if !haveOrigin {
                    origin = target; current = target; haveOrigin = true
                } else if differs(target, current) {
                    if cutAtBegin {
                        _ = append(to: target, geo: geo, d: 0) { _ in block.begin }
                    } else if prevMode == .manual {
                        // Manual → manual: centred on the boundary, inside both.
                        let dn = ZoomShotPlanner.dNorm(dx: Double(target.x - current.x),
                                                       dy: Double(target.y - current.y),
                                                       half: geo.half)
                        let prevSpan = run[i - 1].end - run[i - 1].begin
                        let d = min(ZoomShotPlanner.duration(dNorm: dn, vPref: geo.tuning.vPref),
                                    prevSpan, span)
                        _ = append(to: target, geo: geo, d: d) { _ in block.begin }
                    } else {
                        // Follow → manual: the move sits wholly inside the manual block.
                        entering[i] = append(to: target, geo: geo) { block.begin + $0 / 2 }
                    }
                }
                lastAim = nil
            } else {
                let cur = cursor(geo)
                let shots = ZoomShotPlanner.shots(
                    cursor: cur, begin: block.begin, end: block.end,
                    start: prevMode == .follow && !cutAtBegin ? lastAim : nil, half: geo.half,
                    tuning: geo.tuning, reach: geo.reach, breaks: breaks, step: config.step,
                    lean: reveals.isEmpty ? nil : { leanTarget(at: $0, geo: geo) })
                if let firstShot = shots.first {
                    if !haveOrigin {
                        origin = firstShot.center; current = origin; haveOrigin = true
                    } else if differs(firstShot.center, current) {
                        if cutAtBegin {
                            _ = append(to: firstShot.center, geo: geo, d: 0) { _ in block.begin }
                        } else if prevMode == .manual, let pg = prevGeo {
                            // Manual → follow: the move ends at the boundary.
                            leaving[i - 1] = append(to: firstShot.center, geo: pg) {
                                block.begin - $0 / 2
                            }
                        } else {
                            // Follow → follow with a different reach.
                            _ = append(to: firstShot.center, geo: geo) { _ in block.begin }
                        }
                    }
                    var fromAim = firstShot.aim
                    for s in shots.dropFirst() {
                        defer { fromAim = s.aim }
                        guard differs(s.center, current) else { continue }
                        if s.isCut {
                            _ = append(to: s.center, geo: geo, d: 0) { _ in s.tExit }
                            continue
                        }
                        let delta = CGVector(dx: s.center.x - current.x,
                                             dy: s.center.y - current.y)
                        let from = fromAim
                        let idx = append(to: s.center, geo: geo) { d in
                            ZoomShotPlanner.moveTime(
                                cursor: cur, from: from, delta: delta, d: d, tExit: s.tExit,
                                tArrive: s.tArrive, half: geo.half, step: config.step)
                        }
                        confine(idx, to: followBounds(i))
                    }
                    lastAim = shots.last?.aim
                }
            }
            prevMode = mode
            prevGeo = geo
        }

        // A manual block too short for its two seam moves: shorten both to fit.
        for (i, block) in run.enumerated() {
            let ids = [entering[i], leaving[i]].compactMap { $0 }
            let total = ids.reduce(0) { $0 + planned[$1].move.d }
            let span = block.end - block.begin
            guard total > span, total > 0 else { continue }
            let k = span / total
            if let e = entering[i] {
                planned[e].move.d *= k
                planned[e].move.t = block.begin + planned[e].move.d / 2
            }
            if let l = leaving[i] {
                planned[l].move.d *= k
                planned[l].move.t = block.end - planned[l].move.d / 2
            }
        }
        // No move may span a picture cut: stop it at the cut, or fold it into the
        // cut when too little of it is left to read as a move.
        for i in planned.indices where planned[i].move.d > 0 {
            for tau in breaks {
                let m = planned[i].move
                guard tau > m.t - m.d / 2 + 1e-9, tau < m.t + m.d / 2 - 1e-9 else { continue }
                let d = 2 * abs(tau - m.t)
                if d < ZoomShotPlanner.dMin {
                    planned[i].move.d = 0; planned[i].move.t = tau
                    break
                }
                planned[i].move.d = d
            }
        }
        for i in planned.indices {
            planned[i].move.dipRatio = ZoomShotPlanner.dipRatio(
                hold: planned[i].hold, dNorm: planned[i].dNorm, d: planned[i].move.d)
        }

        // --- Keyframes -----------------------------------------------------------
        // Moves sorted by start; finished ones fold into a running base so each
        // keyframe only evaluates moves in progress (linear in keyframes).
        func startTime(_ m: ZoomMove) -> Double { m.t - m.d / 2 }
        let moves: [ZoomMove] = planned.map { $0.move }
            .sorted { (a: ZoomMove, b: ZoomMove) -> Bool in startTime(a) < startTime(b) }
        var next = 0
        var active: [ZoomMove] = []
        var baseX = Double(origin.x), baseY = Double(origin.y)
        var focus = origin
        var emitted = 0

        var t = runStart, bi = 0
        while t < runEnd - 1e-9 {
            while bi < run.count - 1 && t >= run[bi].end - 1e-9 { bi += 1 }
            let overflow = run[bi].overflow ?? config.defaultOverflow

            // Scale = run envelope × blended target. weight (recenter blend) tracks
            // the envelope: full inside the run, easing to 0 only at the run edges,
            // and stays 0 when there is no magnification (target ≤ 1) so an
            // un-zoomed block never recenters.
            let env = envelope(t, runStart: runStart, runEnd: runEnd, rIn: rIn, rOut: rOut)
            let target = blendedTarget(t, run: run, config: config)
            let weight = target > 1 ? env : 0

            while next < moves.count && startTime(moves[next]) <= t {
                active.append(moves[next]); next += 1
            }
            var fx = baseX, fy = baseY, dip = 1.0
            var cutAt: Double?
            var ai = 0
            while ai < active.count {
                let m = active[ai]
                if m.d > 0 ? t >= m.t + m.d / 2 : t >= m.t {
                    if m.d <= 0 { cutAt = max(cutAt ?? m.t, m.t) }
                    baseX += m.dx; baseY += m.dy; fx += m.dx; fy += m.dy
                    active.remove(at: ai)
                    continue
                }
                let s = ZoomShotPlanner.progress(m, at: t)
                fx += m.dx * s; fy += m.dy * s
                if m.dipRatio < 1 {
                    dip = min(dip, 1 - (1 - m.dipRatio) * ZoomShotPlanner.bump((t - m.t) / m.d))
                }
                ai += 1
            }
            focus = CGPoint(x: min(max(fx, 0), Double(sourceSize.width)),
                            y: min(max(fy, 0), Double(sourceSize.height)))
            // Dip the held target, never the enveloped product: the dipped scale
            // stays above 1 (scale 1 with a non-zero weight would un-recentre the
            // frame) even across a seam into a lower-scale block or inside a ramp.
            let dipped = max(min(target, ZoomShotPlanner.dipFloor), target * dip)
            let scale = 1 + (dipped - 1) * env

            // A camera cut between two keyframes: pin both sides of it so the
            // sampler does not blend the two framings for a frame.
            if let tau = cutAt, emitted > 0, let prev = out.last {
                if tau - 1e-6 > prev.t {
                    var pre = prev
                    pre.t = tau - 1e-6
                    out.append(pre)
                }
                if t - tau > 1e-6 {
                    out.append(ZoomKeyframe(t: tau, scale: scale, focusX: focus.x,
                                            focusY: focus.y, weight: weight,
                                            overflow: overflow))
                }
            }
            out.append(ZoomKeyframe(t: t, scale: scale, focusX: focus.x, focusY: focus.y,
                                    weight: weight, overflow: overflow))
            emitted += 1
            t += config.step
        }
        // Exact end keyframe (scale back to 1) for a clean handoff to the gap.
        out.append(ZoomKeyframe(t: runEnd, scale: 1, focusX: focus.x, focusY: focus.y,
                                weight: 0, overflow: last.overflow ?? config.defaultOverflow))
    }

    /// How much source (px) fits in `region` at scale 1 when `sourceRect` is drawn
    /// into the canvas rect `placedAt`: the region's size divided by the placement
    /// scale, per axis.
    static func viewSize(sourceRect: CGRect, placedAt: CGRect, region: CGRect) -> CGSize {
        guard placedAt.width > 0, placedAt.height > 0 else { return sourceRect.size }
        return CGSize(width: region.width * sourceRect.width / placedAt.width,
                      height: region.height * sourceRect.height / placedAt.height)
    }

    /// Where each cut lands on the collapsed (cuts-removed) timeline — the times
    /// the picture jumps. A cut at the very start produces no jump.
    static func collapsedCutTimes(_ cuts: [Range<Double>]) -> [Double] {
        var out: [Double] = []
        for cut in cuts.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let t = TimelineCut.map(cut.lowerBound, cuts: cuts)
            if t > 1e-9, out.last.map({ abs($0 - t) > 1e-9 }) ?? true { out.append(t) }
        }
        return out
    }

    /// A manual block's target focus in source pixels, or nil if it has no stored
    /// target (falls back to holding the current focus).
    private static func manualTarget(_ block: ZoomBlock, sourceSize: CGSize) -> CGPoint? {
        guard let fx = block.focusX, let fy = block.focusY else { return nil }
        return CGPoint(x: fx * sourceSize.width, y: fy * sourceSize.height)
    }

    /// Run envelope in [0, 1]: 0 at the run edges, smoothstep ramps in over `rIn`
    /// and out over `rOut`, held at 1 in between.
    private static func envelope(_ t: Double, runStart: Double, runEnd: Double,
                                 rIn: Double, rOut: Double) -> Double {
        var w = 1.0
        if rIn > 1e-9, t < runStart + rIn { w = min(w, smoothstep((t - runStart) / rIn)) }
        if rOut > 1e-9, t > runEnd - rOut { w = min(w, smoothstep((runEnd - t) / rOut)) }
        return max(0, w)
    }

    /// The zoom target at `t`: the current block's target, linearly blended with a
    /// neighbour across a short window centred on each internal boundary so blocks
    /// with different scales interpolate rather than stepping.
    private static func blendedTarget(_ t: Double, run: [ZoomBlock],
                                      config: AutoZoomConfig) -> Double {
        func tgt(_ b: ZoomBlock) -> Double { max(1, b.scale ?? config.defaultScale) }
        func span(_ b: ZoomBlock) -> Double { b.end - b.begin }
        var i = 0
        while i < run.count - 1 && t >= run[i].end - 1e-9 { i += 1 }
        let cur = tgt(run[i])
        let curSpan = span(run[i])
        // Blend window clamped to both adjacent spans so it never overruns a short
        // block (the two half-windows meet at the block midpoint at most, so each
        // boundary blends on both sides).
        if i > 0 {
            let blend = min(0.3, curSpan, span(run[i - 1]))
            let bT = run[i].begin
            if blend > 1e-9, t < bT + blend / 2 {
                let f = min(max((t - (bT - blend / 2)) / blend, 0), 1)
                return tgt(run[i - 1]) + (cur - tgt(run[i - 1])) * f
            }
        }
        if i < run.count - 1 {
            let blend = min(0.3, curSpan, span(run[i + 1]))
            let bT = run[i].end
            if blend > 1e-9, t > bT - blend / 2 {
                let f = min(max((t - (bT - blend / 2)) / blend, 0), 1)
                return cur + (tgt(run[i + 1]) - cur) * f
            }
        }
        return cur
    }

    /// Interpolate the track at `t`. Outside the track (gaps / ends) → no zoom.
    static func sample(at t: Double, track: [ZoomKeyframe])
        -> (scale: CGFloat, focus: CGPoint, weight: CGFloat, overflow: Bool) {
        guard let first = track.first, let last = track.last else { return (1, .zero, 0, false) }
        if t <= first.t || t >= last.t { return (1, .zero, 0, false) }

        var lo = 0, hi = track.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if track[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        let a = track[lo]
        let b = track[min(lo + 1, track.count - 1)]
        let span = b.t - a.t
        guard span > 0 else {
            return (CGFloat(a.scale), CGPoint(x: a.focusX, y: a.focusY), CGFloat(a.weight), a.overflow)
        }
        let f = (t - a.t) / span
        let scale = a.scale + (b.scale - a.scale) * f
        let fx = a.focusX + (b.focusX - a.focusX) * f
        let fy = a.focusY + (b.focusY - a.focusY) * f
        let w = a.weight + (b.weight - a.weight) * f
        return (CGFloat(scale), CGPoint(x: fx, y: fy), CGFloat(w), a.overflow)
    }

    // MARK: - Helpers

    /// Map a 0…1 sensitivity to the zoom-in/out ramp duration (seconds): low
    /// sensitivity = long, gentle ramp; high = short, snappy. The recenter pan
    /// rides this ramp (via the keyframe `weight`), so it eases in/out at the same
    /// pace. Default 0.5 → 0.475 s (≈ the previous fixed 0.4 s feel).
    static func rampFor(_ s: Double) -> Double {
        let c = min(max(s, 0), 1)
        return 0.80 - 0.65 * c
    }

    private static func smoothstep(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }

    /// Cursor position at `t` (source px), linearly interpolated; nil if empty.
    /// Never interpolates across a picture cut: when a break lies between the two
    /// bracketing samples, the earlier one is returned before it and the later
    /// one from it on (the footage either side was never adjacent).
    private static func cursorPoint(at t: Double, in samples: [CursorSample],
                                    breaks: [Double]) -> CGPoint? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if t <= first.t { return first.p }
        if t >= last.t { return last.p }
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if samples[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        let a = samples[lo], b = samples[min(lo + 1, samples.count - 1)]
        // First break after `a` (breaks are sorted): it splits this pair if it is
        // not after `b`.
        var bl = 0, bh = breaks.count
        while bl < bh {
            let mid = (bl + bh) / 2
            if breaks[mid] > a.t { bh = mid } else { bl = mid + 1 }
        }
        if bl < breaks.count, breaks[bl] <= b.t {
            return t < breaks[bl] ? a.p : b.p
        }
        let span = b.t - a.t
        guard span > 0 else { return a.p }
        let f = (t - a.t) / span
        return CGPoint(x: a.p.x + (b.p.x - a.p.x) * f, y: a.p.y + (b.p.y - a.p.y) * f)
    }
}
