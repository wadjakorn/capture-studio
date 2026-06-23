import Foundation
import CoreGraphics

/// One resolved auto-zoom state at an instant: magnification (`scale`, ≥1) and
/// the focus point in screen-source pixels (top-left origin) the zoom centers on.
struct ZoomKeyframe: Equatable {
    var t: Double
    var scale: Double
    var focusX: Double
    var focusY: Double
}

/// Tunables for the auto-zoom pre-pass. `defaultScale` / `defaultSensitivity`
/// are overridden per project from UserDefaults (see `StudioModel.autoZoomConfig`).
struct AutoZoomConfig {
    var defaultScale: Double = 2.0
    /// Zoom-in / zoom-out ramp duration (each end of a block).
    var ramp: Double = 0.4
    /// How aggressively the pan follows the cursor, 0…1. Low = calm (large
    /// ignore-zone, long settle delay, slow pan); high = snappy (no ignore-zone,
    /// no delay, fast pan). Resolved to deadzone/dwell/smoothing via `tuning`.
    /// Overridden per block by `ZoomBlock.sensitivity`.
    var defaultSensitivity: Double = 0.5
    /// Keyframe sampling step (seconds).
    var step: Double = 1.0 / 60.0
    /// How still the cursor must stay (fraction of source width) to count as
    /// "resting at the same spot" for the dwell timer.
    var restRadiusFrac: Double = 0.012
}

/// Pure pre-pass: turn zoom blocks + cursor samples into a smoothed
/// `[ZoomKeyframe]` track, then sample it statelessly per frame. Building once
/// (at composition build) and interpolating at render time keeps the render
/// deterministic under out-of-order frame requests (preview scrubbing). No
/// AVFoundation / AppKit deps so it's unit-testable.
///
/// Follow model (settle-based): the canvas does NOT chase the moving cursor.
/// When the cursor comes to rest at a new spot, holds it for the `dwell` time,
/// and that spot is beyond the `deadzone` from where the canvas is currently
/// looking, the focus gently pans toward it. Quick flicks, jitters, and
/// pass-throughs never accumulate dwell, so they are ignored.
enum AutoZoomTrack {
    static func build(blocks: [ZoomBlock], cursorSamples: [CursorSample],
                      sourceSize: CGSize,
                      config: AutoZoomConfig = AutoZoomConfig()) -> [ZoomKeyframe] {
        guard !blocks.isEmpty else { return [] }
        let center = CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)
        let restRadius = config.restRadiusFrac * sourceSize.width
        var out: [ZoomKeyframe] = []

        for block in blocks.sorted(by: { $0.begin < $1.begin }) {
            let span = block.end - block.begin
            guard span > 0 else { continue }
            let target = max(1, block.scale ?? config.defaultScale)
            let ramp = min(config.ramp, span / 2)
            // Per-block sensitivity → ignore-zone + settle delay + pan gentleness.
            let (deadzoneFrac, dwell, smoothTime) = tuning(block.sensitivity ?? config.defaultSensitivity)
            let deadzonePx = deadzoneFrac * sourceSize.width

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
                // Track how long the cursor has rested near the same spot.
                let pos = cursorPoint(at: t, in: cursorSamples) ?? center
                if hypot(pos.x - restPos.x, pos.y - restPos.y) <= restRadius {
                    restElapsed += config.step
                } else {
                    restPos = pos
                    restElapsed = 0
                }
                // Pan toward the rest spot only once it has settled long enough
                // AND is beyond the ignore-zone from the current focus.
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
                                        focusX: focus.x, focusY: focus.y))
                t += config.step
            }
            // Exact end keyframe (scale back to 1) for a clean handoff to the gap.
            out.append(ZoomKeyframe(t: block.end, scale: 1,
                                    focusX: focus.x, focusY: focus.y))
        }
        return out
    }

    /// Interpolate the track at `t`. Outside the track (gaps / ends) → no zoom.
    static func sample(at t: Double, track: [ZoomKeyframe]) -> (scale: CGFloat, focus: CGPoint) {
        guard let first = track.first, let last = track.last else { return (1, .zero) }
        if t <= first.t || t >= last.t { return (1, .zero) }

        var lo = 0, hi = track.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if track[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        let a = track[lo]
        let b = track[min(lo + 1, track.count - 1)]
        let span = b.t - a.t
        guard span > 0 else {
            return (CGFloat(a.scale), CGPoint(x: a.focusX, y: a.focusY))
        }
        let f = (t - a.t) / span
        let scale = a.scale + (b.scale - a.scale) * f
        let fx = a.focusX + (b.focusX - a.focusX) * f
        let fy = a.focusY + (b.focusY - a.focusY) * f
        return (CGFloat(scale), CGPoint(x: fx, y: fy))
    }

    // MARK: - Helpers

    /// Map a 0…1 sensitivity to the follow knobs. Low sensitivity = large
    /// ignore-zone (fraction of source width), long settle delay, and a long
    /// `smoothing` (slow, gentle pan); high = no ignore-zone, no delay, short
    /// `smoothing` (fast pan). `smoothing` is the critically-damped easing's
    /// approximate time-to-target in seconds (see `smoothDamp`).
    static func tuning(_ s: Double) -> (deadzone: Double, dwell: Double, smoothing: Double) {
        let c = min(max(s, 0), 1)
        return (deadzone: 0.10 * (1 - c),
                dwell: 0.6 * (1 - c),
                smoothing: 0.30 - 0.25 * c)
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
