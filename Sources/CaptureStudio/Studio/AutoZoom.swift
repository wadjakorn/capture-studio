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
        var out: [ZoomKeyframe] = []

        for block in blocks.sorted(by: { $0.begin < $1.begin }) {
            let span = block.end - block.begin
            guard span > 0 else { continue }
            let target = max(1, block.scale ?? config.defaultScale)
            let sensitivity = block.sensitivity ?? config.defaultSensitivity
            // Per-block sensitivity drives BOTH the zoom-in/out ramp (how fast the
            // block eases into and out of the zoom, with the recenter pan riding
            // that ramp) and the cursor-follow ease speed. Low = slow & gentle,
            // high = snappy. Ramp is capped at half the span so it always
            // completes.
            let ramp = min(rampFor(sensitivity), span / 2)
            // Per-block sensitivity → settle delay + ignore-zone + ease speed.
            let (deadzoneFrac, dwell, smoothTime) = tuning(sensitivity)
            let deadzonePx = deadzoneFrac * sourceSize.width
            let restRadius = config.restRadiusFrac * sourceSize.width
            let overflow = block.overflow ?? false

            // Seed the smoothed focus on the cursor at the block start.
            var focus = cursorPoint(at: block.begin, in: cursorSamples) ?? center
            var restPos = focus
            var restElapsed = 0.0
            // Pan velocity (px/s) carried by the critically-damped easing, so the
            // pan accelerates and decelerates smoothly instead of starting at full
            // speed. Resets per block (each block starts at rest).
            var velX = 0.0, velY = 0.0

            var t = block.begin
            while t < block.end - 1e-9 {
                // Scale ramp (smoothstep in, hold, smoothstep out).
                let scale = scaleAt(t, begin: block.begin, end: block.end,
                                    ramp: ramp, target: target)
                // Recenter blend: 0 while un-zoomed, 1 at full hold. Ties the
                // focus→frame-centre pan to the same ramp as the scale, so the
                // pan eases in and out together with the zoom.
                let weight = target > 1 ? (scale - 1) / (target - 1) : 0
                // Track how long the cursor has rested near the same spot.
                let pos = cursorPoint(at: t, in: cursorSamples) ?? center
                if hypot(pos.x - restPos.x, pos.y - restPos.y) <= restRadius {
                    restElapsed += config.step
                } else {
                    restPos = pos
                    restElapsed = 0
                }
                // Pan toward the rest spot only once it has settled past the delay
                // AND is beyond the ignore-zone; otherwise hold (ignore jiggle).
                let settled = restElapsed >= dwell
                let beyond = hypot(restPos.x - focus.x, restPos.y - focus.y) > deadzonePx
                let aim = (settled && beyond) ? restPos : focus
                // Critically-damped ease: smooth acceleration into the pan and
                // smooth deceleration out of it, with no overshoot.
                focus.x = smoothDamp(focus.x, aim.x, &velX, smoothTime: smoothTime, dt: config.step)
                focus.y = smoothDamp(focus.y, aim.y, &velY, smoothTime: smoothTime, dt: config.step)
                if focus.x < 0 { focus.x = 0; velX = 0 }
                else if focus.x > sourceSize.width { focus.x = sourceSize.width; velX = 0 }
                if focus.y < 0 { focus.y = 0; velY = 0 }
                else if focus.y > sourceSize.height { focus.y = sourceSize.height; velY = 0 }

                out.append(ZoomKeyframe(t: t, scale: scale,
                                        focusX: focus.x, focusY: focus.y,
                                        weight: weight, overflow: overflow))
                t += config.step
            }
            // Exact end keyframe (scale back to 1) for a clean handoff to the gap.
            out.append(ZoomKeyframe(t: block.end, scale: 1,
                                    focusX: focus.x, focusY: focus.y,
                                    weight: 0, overflow: overflow))
        }
        return out
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

    private static func scaleAt(_ t: Double, begin: Double, end: Double,
                                ramp: Double, target: Double) -> Double {
        guard ramp > 1e-9 else { return target }
        if t < begin + ramp {
            return 1 + (target - 1) * smoothstep((t - begin) / ramp)
        }
        if t > end - ramp {
            return 1 + (target - 1) * smoothstep((end - t) / ramp)
        }
        return target
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
