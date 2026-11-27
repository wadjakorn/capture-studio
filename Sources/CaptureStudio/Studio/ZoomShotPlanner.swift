import Foundation
import CoreGraphics

/// Follow knobs derived from a block's 0…1 sensitivity (low = calm, high = snappy).
struct FollowTuning: Equatable {
    /// Fraction of the view half-extent the cursor may roam before the camera moves.
    var safeFrac: Double
    /// Preferred travel speed, in view-widths per second.
    var vPref: Double
    /// How long (seconds) an excursion outside the safe zone is ignored.
    var flickGrace: Double
}

/// One held framing: the camera sits on `center` until the next shot's move.
struct PlannedShot: Equatable {
    /// Unclamped centre. Safe-zone / hard-margin tests use this, so a cursor
    /// parked beyond the reach does not keep re-triggering moves the picture
    /// cannot make. Carried between touching follow blocks.
    var aim: CGPoint
    /// `aim` clamped into the reach — what the camera shows.
    var center: CGPoint
    /// When the cursor left the previous shot (== `tArrive` for the first shot
    /// of a block and for shots entered at a cut).
    var tExit: Double
    /// When this shot's framing starts being measured (the cursor has landed).
    var tArrive: Double
    /// Entered at a picture discontinuity: the camera cuts, it does not glide.
    var isCut: Bool
}

/// One eased camera move. The focus path is `origin + Σ delta · progress`.
struct ZoomMove: Equatable {
    /// Centre time of the move.
    var t: Double
    /// Duration; 0 = an instantaneous step at `t`.
    var d: Double
    var dx: Double
    var dy: Double
    /// Dipped scale ÷ held scale, in (0, 1]; 1 = no dip.
    var dipRatio: Double = 1
}

/// Pure offline camera planning for auto-zoom follow blocks: split a cursor path
/// into held shots (look-ahead, so the camera can anticipate), and describe the
/// moves between them in closed form (a spring-like S-curve that starts and
/// stops with zero velocity and acceleration, so moves overlap by simple
/// addition). No
/// AVFoundation / AppKit deps — unit-tested in isolation.
enum ZoomShotPlanner {
    /// The cursor must stay inside the view shrunk by this factor while holding.
    static let hardMargin = 0.92
    /// Cursor speed (view-widths/s) below which it counts as having landed.
    static let vRest = 0.3
    /// Longest the planner waits for the cursor to land after it leaves a shot.
    static let maxTransit = 0.8
    /// Shortest / longest move. Screen-recording cameras read best when a move
    /// takes roughly 0.3–0.6 s; only a hop across most of the screen is longer.
    static let dMin = 0.3
    static let dMax = 0.9
    /// Peak on-screen speed (view-widths/s) a duration-capped move may reach
    /// before the zoom dips to slow it down.
    static let vMax = 3.5
    /// The camera may start moving at most this long before the cursor leaves
    /// the shot. More than a hint of anticipation reads as the frame wandering
    /// off on its own.
    static let maxLead = 0.15
    /// Time warp of the move curve (`ease`): < 1 puts the peak speed early and
    /// stretches the landing, like a damped spring. Must stay above 2/3 so the
    /// move still starts with zero acceleration.
    static let easeWarp = 0.75
    /// Peak of `ease`'s slope — the peak speed of a unit move of unit duration.
    static let easePeak: Double = {
        var peak = 0.0
        let n = 2000
        for i in 0..<n {
            let a = Double(i) / Double(n) - 0.5, b = Double(i + 1) / Double(n) - 0.5
            peak = max(peak, (ease(b) - ease(a)) * Double(n))
        }
        return peak
    }()
    /// A dip never takes the scale below this (scale 1 would un-recentre the frame).
    static let dipFloor = 1.1
    /// A shot leaning toward content keeps the pointer path inside this fraction
    /// of the safe zone, so ordinary jitter does not push it straight back out.
    static let leanZone = 0.6
    /// A lean smaller than this fraction of the view is not worth making.
    static let minLean = 0.05
    /// Pixel tolerance on safe-zone tests, so a cursor sitting exactly on the
    /// settle box edge does not immediately re-exit.
    private static let edgeTolerance = 0.5

    static func followTuning(_ sensitivity: Double) -> FollowTuning {
        let c = min(max(sensitivity, 0), 1)
        return FollowTuning(safeFrac: 0.85 - 0.30 * c,
                            vPref: 1.2 + 1.2 * c,
                            flickGrace: 0.50 - 0.40 * c)
    }

    /// Clamp `p` into `reach`, read as explicit min (`origin`) / max
    /// (`origin + size`) per axis. An inverted axis (max < min: the view is larger
    /// than the content there) collapses to its midpoint — no panning on it.
    static func clamp(_ p: CGPoint, toReach reach: CGRect) -> CGPoint {
        func axis(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            hi < lo ? (lo + hi) / 2 : min(max(v, lo), hi)
        }
        return CGPoint(x: axis(p.x, reach.origin.x, reach.origin.x + reach.size.width),
                       y: axis(p.y, reach.origin.y, reach.origin.y + reach.size.height))
    }

    // MARK: - Shots

    /// Split the cursor path over `[begin, end)` into held shots.
    ///
    /// - `cursor`: pointer position (source px) at a time. The caller clamps it
    ///   and makes it piecewise across `breaks`.
    /// - `start`: the AIM carried in from a preceding follow block, or nil to
    ///   settle on the cursor at `begin`.
    /// - `half`: view half-extent at the block's held scale.
    /// - `reach`: allowed range for `center` (see `clamp(_:toReach:)`).
    /// - `breaks`: picture discontinuities; one inside `(begin, end)` ends the
    ///   current shot and starts a fresh one flagged `isCut`.
    /// - `lean`: the content (source px) a shot settling at the given time
    ///   should try to include, or nil. The pointer still decides: the frame
    ///   only leans toward it (see `leanedAim`). nil = pointer-only framing.
    ///
    /// Every scan index only moves forward, so the pass is linear in samples.
    static func shots(cursor: (Double) -> CGPoint, begin: Double, end: Double,
                      start: CGPoint?, half: CGSize, tuning: FollowTuning,
                      reach: CGRect, breaks: [Double], step: Double,
                      lean: ((Double) -> CGRect?)? = nil) -> [PlannedShot] {
        guard end > begin, step > 0 else { return [] }
        let cuts = breaks.filter { $0 > begin + 1e-9 && $0 < end - 1e-9 }.sorted()
        var out: [PlannedShot] = []
        var segBegin = begin
        for (i, limit) in (cuts + [end]).enumerated() {
            planSegment(cursor: cursor, begin: segBegin, end: limit,
                        start: i == 0 ? start : nil, isCut: i > 0,
                        half: half, tuning: tuning, reach: reach, step: step, lean: lean,
                        into: &out)
            segBegin = limit
        }
        return out
    }

    /// The aim for a shot whose pointer path covers `box`, leaning toward
    /// `target` (already limited to where the view centre can go): as close to
    /// it as possible while the whole `box` stays within `leanZone` of the safe
    /// zone (`safeW` × `safeH` half-extent). An axis where the box is too large
    /// for that, or a lean under `minLean` of the view, keeps the box centre.
    static func leanedAim(box: CGRect, toward target: CGPoint, safeW: Double, safeH: Double,
                          half: CGSize) -> CGPoint {
        func axis(_ lo: CGFloat, _ hi: CGFloat, _ goal: CGFloat, _ safe: Double) -> CGFloat {
            let mid = (lo + hi) / 2
            let zone = CGFloat(safe * leanZone)
            let minAim = hi - zone, maxAim = lo + zone
            guard minAim <= maxAim else { return mid }
            return min(max(goal, minAim), maxAim)
        }
        let centre = CGPoint(x: box.midX, y: box.midY)
        let aim = CGPoint(x: axis(box.minX, box.maxX, target.x, safeW),
                          y: axis(box.minY, box.maxY, target.y, safeH))
        let moved = max(abs(Double(aim.x - centre.x)) / max(Double(half.width) * 2, 1e-6),
                        abs(Double(aim.y - centre.y)) / max(Double(half.height) * 2, 1e-6))
        return moved >= minLean ? aim : centre
    }

    private static func planSegment(cursor: (Double) -> CGPoint, begin: Double, end: Double,
                                    start: CGPoint?, isCut: Bool, half: CGSize,
                                    tuning: FollowTuning, reach: CGRect, step: Double,
                                    lean: ((Double) -> CGRect?)?,
                                    into out: inout [PlannedShot]) {
        let n = max(1, Int(((end - begin) / step - 1e-9).rounded(.up)))
        func time(_ k: Int) -> Double { begin + Double(k) * step }
        let viewW = max(Double(half.width) * 2, 1e-6)
        let viewH = max(Double(half.height) * 2, 1e-6)
        let safeW = Double(half.width) * tuning.safeFrac
        let safeH = Double(half.height) * tuning.safeFrac
        let hardW = Double(half.width) * hardMargin
        let hardH = Double(half.height) * hardMargin

        func inside(_ p: CGPoint, _ aim: CGPoint, _ w: Double, _ h: Double) -> Bool {
            abs(Double(p.x - aim.x)) <= w + edgeTolerance
                && abs(Double(p.y - aim.y)) <= h + edgeTolerance
        }
        // Centre of the cursor path's bounding box from step `k0`, grown for as
        // long as the box still fits one safe zone.
        func settle(_ k0: Int) -> CGPoint {
            let p0 = cursor(time(k0))
            var minX = Double(p0.x), maxX = minX, minY = Double(p0.y), maxY = minY
            var k = k0 + 1
            while k < n {
                let p = cursor(time(k))
                let nMinX = min(minX, Double(p.x)), nMaxX = max(maxX, Double(p.x))
                let nMinY = min(minY, Double(p.y)), nMaxY = max(maxY, Double(p.y))
                if nMaxX - nMinX > 2 * safeW || nMaxY - nMinY > 2 * safeH { break }
                minX = nMinX; maxX = nMaxX; minY = nMinY; maxY = nMaxY
                k += 1
            }
            let box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            guard let content = lean?(time(k0)) else {
                return CGPoint(x: box.midX, y: box.midY)
            }
            // Lean toward where the view could actually centre on the content.
            let goal = clamp(CGPoint(x: content.midX, y: content.midY), toReach: reach)
            return leanedAim(box: box, toward: goal, safeW: safeW, safeH: safeH, half: half)
        }
        // Step-to-step cursor speed in view-widths per second.
        func speed(_ k: Int) -> Double {
            let a = cursor(time(k > 0 ? k - 1 : k)), b = cursor(time(k > 0 ? k : k + 1))
            return hypot(Double(b.x - a.x) / viewW, Double(b.y - a.y) / viewH) / step
        }

        var aim = start ?? settle(0)
        var center = clamp(aim, toReach: reach)
        out.append(PlannedShot(aim: aim, center: center, tExit: begin, tArrive: begin,
                               isCut: isCut))
        let graceSteps = max(1, Int((tuning.flickGrace / step).rounded()))
        let transitSteps = max(1, Int((maxTransit / step).rounded()))

        var k = 0
        while k < n {
            if inside(cursor(time(k)), aim, safeW, safeH) { k += 1; continue }
            // Left the safe zone at k. A flick that comes back within the grace
            // period — without crossing the hard margin — is ignored.
            var returned: Int?
            var j = k
            while j < n && j <= k + graceSteps {
                let p = cursor(time(j))
                if !inside(p, aim, hardW, hardH) { break }
                if j > k && inside(p, aim, safeW, safeH) { returned = j; break }
                j += 1
            }
            if let r = returned { k = r + 1; continue }

            // A real exit. Skip the cursor's flight: frame where it lands.
            let exitK = k
            var arriveK = exitK
            let lastK = min(n - 1, exitK + transitSteps)
            while arriveK < lastK && speed(arriveK) >= vRest { arriveK += 1 }
            aim = settle(arriveK)
            let next = clamp(aim, toReach: reach)
            if hypot(Double(next.x - center.x), Double(next.y - center.y)) > 1e-6 {
                center = next
                out.append(PlannedShot(aim: aim, center: center, tExit: time(exitK),
                                       tArrive: time(arriveK), isCut: false))
            } else {
                // Same picture (e.g. pinned at the reach limit): keep the shot,
                // but adopt the new aim so the cursor stops re-exiting.
                out[out.count - 1].aim = aim
            }
            k = arriveK + 1
        }
    }

    // MARK: - Moves

    /// Minimum-jerk S-curve over `u ∈ [−½, ½]` → `[0, 1]`: zero velocity and
    /// acceleration at both ends.
    static func minJerk(_ u: Double) -> Double {
        if u <= -0.5 { return 0 }
        if u >= 0.5 { return 1 }
        let x = u + 0.5
        return x * x * x * (10 - 15 * x + 6 * x * x)
    }

    /// The move curve over `u ∈ [−½, ½]` → `[0, 1]`: minimum-jerk on warped time,
    /// so it leaves quickly and settles gently (spring-like) while still starting
    /// and stopping with zero velocity and acceleration.
    static func ease(_ u: Double) -> Double {
        if u <= -0.5 { return 0 }
        if u >= 0.5 { return 1 }
        return minJerk(pow(u + 0.5, easeWarp) - 0.5)
    }

    /// Smooth 0 → 1 → 0 over `u ∈ [−½, ½]`, zero slope at the ends and the peak.
    static func bump(_ u: Double) -> Double {
        guard abs(u) < 0.5 else { return 0 }
        let s = sin(Double.pi * (u + 0.5))
        return s * s
    }

    /// Travel in view-widths, per axis (`half` is the view half-extent).
    static func dNorm(dx: Double, dy: Double, half: CGSize) -> Double {
        hypot(dx / max(Double(half.width) * 2, 1e-6), dy / max(Double(half.height) * 2, 1e-6))
    }

    static func duration(dNorm: Double, vPref: Double) -> Double {
        min(max(dNorm / max(vPref, 1e-6), dMin), dMax)
    }

    /// Dipped ÷ held scale for a move. Only a duration-capped move dips (an
    /// uncapped one is already within `vMax`; a move shortened by a seam or a
    /// cut must not pump the zoom), just enough to hold the peak on-screen speed
    /// at `vMax`, and never below `dipFloor`.
    static func dipRatio(hold: Double, dNorm: Double, d: Double) -> Double {
        guard d >= dMax - 1e-9, dNorm > 0, hold > 0 else { return 1 }
        let floor = min(1, dipFloor / hold)
        return min(max(vMax * d / (easePeak * dNorm), floor), 1)
    }

    /// Centre time for a follow move. Starts at the middle of the cursor's flight
    /// — but never more than `maxLead` before the cursor leaves — and is delayed,
    /// in `step` increments up to `tExit + d/2` (no anticipation at all), until
    /// the camera leaving early never pushes the cursor outside the hard margin
    /// before the cursor itself starts to leave. `from` is the previous shot's
    /// aim; `delta` the change of centre.
    static func moveTime(cursor: (Double) -> CGPoint, from: CGPoint, delta: CGVector,
                         d: Double, tExit: Double, tArrive: Double, half: CGSize,
                         step: Double) -> Double {
        let mid = (tExit + tArrive) / 2
        guard d > 0, step > 0 else { return mid }
        let latest = tExit + d / 2
        let hardW = Double(half.width) * hardMargin + edgeTolerance
        let hardH = Double(half.height) * hardMargin + edgeTolerance
        func keepsCursorInFrame(_ t: Double) -> Bool {
            var tau = tExit
            while tau > t - d / 2 {
                let s = ease((tau - t) / d)
                let p = cursor(tau)
                if abs(Double(p.x - from.x) - Double(delta.dx) * s) > hardW
                    || abs(Double(p.y - from.y) - Double(delta.dy) * s) > hardH { return false }
                tau -= step
            }
            return true
        }
        var t = max(mid, tExit - maxLead + d / 2)
        while t < latest {
            if keepsCursorInFrame(t) { return t }
            t += step
        }
        return latest
    }

    /// Progress of `move` at `t`, 0…1.
    static func progress(_ move: ZoomMove, at t: Double) -> Double {
        move.d > 0 ? ease((t - move.t) / move.d) : (t >= move.t ? 1 : 0)
    }

    /// The focus path: `origin` plus every move's contribution at `t`.
    static func focus(at t: Double, origin: CGPoint, moves: [ZoomMove]) -> CGPoint {
        var x = Double(origin.x), y = Double(origin.y)
        for m in moves {
            let s = progress(m, at: t)
            x += m.dx * s; y += m.dy * s
        }
        return CGPoint(x: x, y: y)
    }

    /// Scale multiplier from zoom dips at `t`: 1 outside any dipping move.
    static func dipFactor(at t: Double, moves: [ZoomMove]) -> Double {
        var f = 1.0
        for m in moves where m.d > 0 && m.dipRatio < 1 {
            f = min(f, 1 - (1 - m.dipRatio) * bump((t - m.t) / m.d))
        }
        return f
    }
}
