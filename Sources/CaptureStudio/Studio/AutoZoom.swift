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

/// Tunables for the auto-zoom pre-pass. Defaults are v1 values; `defaultScale`
/// is overridden per project from `autoZoomDefaultScale`.
struct AutoZoomConfig {
    var defaultScale: Double = 2.0
    /// Anticipation: focus targets the cursor position this many seconds ahead.
    var lead: Double = 0.4
    /// Zoom-in / zoom-out ramp duration (each end of a block).
    var ramp: Double = 0.4
    /// Cursor speed (source px/sec) below which the cursor is "still": the pan
    /// target freezes (hold zoom, freeze pan).
    var idleSpeed: Double = 40
    /// Exponential focus-smoothing time constant (seconds).
    var smoothing: Double = 0.12
    /// Keyframe sampling step (seconds).
    var step: Double = 1.0 / 60.0
}

/// Pure pre-pass: turn zoom blocks + cursor samples into a smoothed
/// `[ZoomKeyframe]` track, then sample it statelessly per frame. Building once
/// (at composition build) and interpolating at render time keeps the render
/// deterministic under out-of-order frame requests (preview scrubbing). No
/// AVFoundation / AppKit deps so it's unit-testable.
enum AutoZoomTrack {
    static func build(blocks: [ZoomBlock], cursorSamples: [CursorSample],
                      sourceSize: CGSize,
                      config: AutoZoomConfig = AutoZoomConfig()) -> [ZoomKeyframe] {
        guard !blocks.isEmpty else { return [] }
        let center = CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)
        let alpha = 1 - exp(-config.step / max(config.smoothing, 1e-4))
        var out: [ZoomKeyframe] = []

        for block in blocks.sorted(by: { $0.begin < $1.begin }) {
            let span = block.end - block.begin
            guard span > 0 else { continue }
            let target = max(1, block.scale ?? config.defaultScale)
            let ramp = min(config.ramp, span / 2)

            // Seed the smoothed focus on the cursor at the block start.
            var focus = cursorPoint(at: block.begin, in: cursorSamples) ?? center
            var lastTarget = focus

            var t = block.begin
            while t < block.end - 1e-9 {
                // Scale ramp (smoothstep in, hold, smoothstep out).
                let scale = scaleAt(t, begin: block.begin, end: block.end,
                                    ramp: ramp, target: target)
                // Anticipated, idle-gated target.
                let aheadT = min(t + config.lead, block.end)
                let raw = cursorPoint(at: aheadT, in: cursorSamples) ?? center
                let speed = cursorSpeed(at: aheadT, in: cursorSamples, dt: config.step)
                let desired = speed < config.idleSpeed ? lastTarget : raw
                lastTarget = desired
                // Exponential smoothing toward the target, clamped to source.
                focus.x += (desired.x - focus.x) * alpha
                focus.y += (desired.y - focus.y) * alpha
                focus.x = min(max(focus.x, 0), sourceSize.width)
                focus.y = min(max(focus.y, 0), sourceSize.height)

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

    /// Cursor position at `t` (source px), linearly interpolated; nil if empty.
    private static func cursorPoint(at t: Double, in samples: [CursorSample]) -> CGPoint? {
        CursorOverlay.position(at: t, in: samples)?.p
    }

    /// Cursor speed (source px/sec) around `t` via a centered difference.
    private static func cursorSpeed(at t: Double, in samples: [CursorSample],
                                    dt: Double) -> Double {
        guard let a = cursorPoint(at: t - dt, in: samples),
              let b = cursorPoint(at: t + dt, in: samples) else { return 0 }
        let dx = b.x - a.x, dy = b.y - a.y
        return (dx * dx + dy * dy).squareRoot() / (2 * dt)
    }
}
