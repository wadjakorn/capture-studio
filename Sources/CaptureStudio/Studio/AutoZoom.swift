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

/// Tunables for the auto-zoom pre-pass. `defaultScale` / `defaultSensitivity`
/// are overridden per project from UserDefaults (see `StudioModel.autoZoomConfig`).
struct AutoZoomConfig {
    var defaultScale: Double = 2.0
    /// How the pan follows the cursor, 0…1. Drives a settle delay (ignore jiggle),
    /// an ignore-radius, and the ease speed via `tuning`: low = long delay + slow
    /// glide, high = ~no delay + near-live tracking. A rested cursor still ends
    /// centred at any level. Overridden per block by `ZoomBlock.sensitivity`.
    var defaultSensitivity: Double = 0.5
    /// How still the cursor must stay (fraction of source width) to count as
    /// "resting at the same spot" for the settle timer.
    var restRadiusFrac: Double = 0.012
    /// Keyframe sampling step (seconds).
    var step: Double = 1.0 / 60.0
}

/// Pure pre-pass: turn zoom blocks + cursor samples into a smoothed
/// `[ZoomKeyframe]` track, then sample it statelessly per frame. Building once
/// (at composition build) and interpolating at render time keeps the render
/// deterministic under out-of-order frame requests (preview scrubbing). No
/// AVFoundation / AppKit deps so it's unit-testable.
///
/// Follow model (settle + ease-to-centre): the canvas does not chase jiggle. A
/// new cursor spot must hold still for the `dwell` delay and sit beyond the
/// `deadzone` before the focus pans to it, then a critically-damped ease glides
/// there — so a rested cursor ends centred in the output while flicks/jitter are
/// ignored. Sensitivity sets all three (via `tuning`): low = long delay + wide
/// ignore-zone + slow glide, high = ~no delay + no ignore-zone + near-live track.
enum AutoZoomTrack {
    static func build(blocks: [ZoomBlock], cursorSamples: [CursorSample],
                      sourceSize: CGSize,
                      config: AutoZoomConfig = AutoZoomConfig()) -> [ZoomKeyframe] {
        guard !blocks.isEmpty else { return [] }
        let center = CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)
        let sorted = blocks.filter { $0.end - $0.begin > 0 }
            .sorted { $0.begin < $1.begin }
        guard !sorted.isEmpty else { return [] }

        // Group touching blocks (prev.end == next.begin) into continuous "runs".
        // The zoom ramps in only at a run's start and out only at its end; inside a
        // run the scale is held (never returns to 1×) and the smoothed focus is
        // carried across block boundaries — so switching follow↔manual mid-run is
        // seamless. A gap between blocks starts a new run and re-zooms from 1×.
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
                      sourceSize: sourceSize, center: center, config: config)
        }
        return out
    }

    /// Emit keyframes for one run of touching blocks. Scale follows a run-wide
    /// envelope (ramp in at the run start, hold, ramp out at the run end) times a
    /// per-instant target blended across internal boundaries; the focus state
    /// (position, velocity, settle timer) is carried across every block boundary so
    /// there is no jump when the mode changes mid-run.
    private static func appendRun(_ run: [ZoomBlock], into out: inout [ZoomKeyframe],
                                  cursorSamples: [CursorSample], sourceSize: CGSize,
                                  center: CGPoint, config: AutoZoomConfig) {
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

        let restRadius = config.restRadiusFrac * sourceSize.width
        // Seed the smoothed focus: on the manual target if the run opens manual,
        // else on the cursor at the run start.
        var focus = aimAtStart(of: first, cursorSamples: cursorSamples,
                               sourceSize: sourceSize, center: center)
        var restPos = focus
        var restElapsed = 0.0
        var velX = 0.0, velY = 0.0

        var t = runStart, bi = 0
        while t < runEnd - 1e-9 {
            while bi < run.count - 1 && t >= run[bi].end - 1e-9 { bi += 1 }
            let block = run[bi]
            let mode = block.mode ?? .follow
            let (deadzoneFrac, dwell, smoothTime) = tuning(block.sensitivity ?? config.defaultSensitivity)
            let deadzonePx = deadzoneFrac * sourceSize.width
            let overflow = block.overflow ?? false

            // Scale = run envelope × blended target. weight (recenter blend) tracks
            // the envelope: full inside the run, easing to 0 only at the run edges.
            let env = envelope(t, runStart: runStart, runEnd: runEnd, rIn: rIn, rOut: rOut)
            let target = blendedTarget(t, run: run, config: config)
            let scale = 1 + (target - 1) * env
            // Recenter blend tracks the zoom envelope, but stays 0 when there is no
            // magnification (target ≤ 1) so an un-zoomed block never recenters.
            let weight = target > 1 ? env : 0

            // Aim: manual holds the fixed target (ignores the cursor); follow tracks
            // the settled cursor spot. Either way the same critically-damped ease
            // moves the focus, so a follow→manual seam eases with no teleport.
            let aim: CGPoint
            if mode == .manual {
                aim = manualTarget(block, sourceSize: sourceSize) ?? focus
                // Reset the settle tracker so a following block starts fresh.
                restPos = aim; restElapsed = 0
            } else {
                let pos = cursorPoint(at: t, in: cursorSamples) ?? center
                if hypot(pos.x - restPos.x, pos.y - restPos.y) <= restRadius {
                    restElapsed += config.step
                } else {
                    restPos = pos; restElapsed = 0
                }
                let settled = restElapsed >= dwell
                let beyond = hypot(restPos.x - focus.x, restPos.y - focus.y) > deadzonePx
                aim = (settled && beyond) ? restPos : focus
            }
            focus.x = smoothDamp(focus.x, aim.x, &velX, smoothTime: smoothTime, dt: config.step)
            focus.y = smoothDamp(focus.y, aim.y, &velY, smoothTime: smoothTime, dt: config.step)
            if focus.x < 0 { focus.x = 0; velX = 0 }
            else if focus.x > sourceSize.width { focus.x = sourceSize.width; velX = 0 }
            if focus.y < 0 { focus.y = 0; velY = 0 }
            else if focus.y > sourceSize.height { focus.y = sourceSize.height; velY = 0 }

            out.append(ZoomKeyframe(t: t, scale: scale, focusX: focus.x, focusY: focus.y,
                                    weight: weight, overflow: overflow))
            t += config.step
        }
        // Exact end keyframe (scale back to 1) for a clean handoff to the gap.
        out.append(ZoomKeyframe(t: runEnd, scale: 1, focusX: focus.x, focusY: focus.y,
                                weight: 0, overflow: last.overflow ?? false))
    }

    /// The focus a run should seed on: the manual target if the first block opens
    /// manual (so a standalone manual block holds a constant frame from the start),
    /// else the cursor position at the run start.
    private static func aimAtStart(of block: ZoomBlock, cursorSamples: [CursorSample],
                                   sourceSize: CGSize, center: CGPoint) -> CGPoint {
        if (block.mode ?? .follow) == .manual,
           let target = manualTarget(block, sourceSize: sourceSize) {
            return target
        }
        return cursorPoint(at: block.begin, in: cursorSamples) ?? center
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
        let blend = 0.3
        func tgt(_ b: ZoomBlock) -> Double { max(1, b.scale ?? config.defaultScale) }
        var i = 0
        while i < run.count - 1 && t >= run[i].end - 1e-9 { i += 1 }
        let cur = tgt(run[i])
        if i > 0 {
            let bT = run[i].begin
            if t < bT + blend / 2 {
                let f = min(max((t - (bT - blend / 2)) / blend, 0), 1)
                return tgt(run[i - 1]) + (cur - tgt(run[i - 1])) * f
            }
        }
        if i < run.count - 1 {
            let bT = run[i].end
            if t > bT - blend / 2 {
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

    /// Map a 0…1 sensitivity to the follow knobs. Calibrated so 50% ≈ the old
    /// snappiest-calm feel and 0% is markedly slower with a long jiggle delay:
    ///  - `deadzone` (ignore-radius, fraction of source width): 0.08 → 0.
    ///  - `dwell` (settle delay, s): 0.80 → 0, quadratic so it stays long into the
    ///    low half (0% → 0.80, 50% → 0.20, 100% → 0).
    ///  - `smoothing` (`smoothTime`, s): 0.60 → 0.03 (50% → 0.315 ≈ old 0%).
    static func tuning(_ s: Double) -> (deadzone: Double, dwell: Double, smoothing: Double) {
        let c = min(max(s, 0), 1)
        let inv = 1 - c
        return (deadzone: 0.08 * inv,
                dwell: 0.80 * inv * inv,
                smoothing: 0.60 - 0.57 * c)
    }

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

    /// Critically-damped smoothing toward `target` (Game Programming Gems /
    /// Unity `SmoothDamp`). Carries `velocity` across calls so the value eases
    /// into motion and eases out of it with no overshoot. `smoothTime` is the
    /// approximate time to reach the target.
    private static func smoothDamp(_ current: Double, _ target: Double,
                                   _ velocity: inout Double,
                                   smoothTime: Double, dt: Double) -> Double {
        let st = max(smoothTime, 1e-4)
        let omega = 2 / st
        let x = omega * dt
        let exp = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
        let change = current - target
        let temp = (velocity + omega * change) * dt
        velocity = (velocity - omega * temp) * exp
        return target + (change + temp) * exp
    }

    /// Cursor position at `t` (source px), linearly interpolated; nil if empty.
    private static func cursorPoint(at t: Double, in samples: [CursorSample]) -> CGPoint? {
        CursorOverlay.position(at: t, in: samples)?.p
    }
}
