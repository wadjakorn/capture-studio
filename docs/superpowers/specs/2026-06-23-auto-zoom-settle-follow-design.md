# Auto Zoom/Pan — Settle-Based Follow (v3)

Date: 2026-06-23
Status: Approved (pending implementation plan)
Revises: [2026-06-23-auto-zoom-pan-design.md](2026-06-23-auto-zoom-pan-design.md),
[2026-06-23-auto-zoom-sensitivity-design.md](2026-06-23-auto-zoom-sensitivity-design.md)

## Goal

Even at minimum sensitivity, the pan still chased small mouse moves. Root cause:
the gate was **speed-based**, so a small-but-fast flick (e.g. 10 px over 1/60 s ≈
600 px/s) passed the deadzone and the 0.4 s anticipation jumped the pan toward it.

Replace the follow model with a calmer **settle-then-pan** behavior: the canvas
does not chase the moving cursor; when the cursor parks at a new spot and stays
there briefly, the canvas gently pans toward it.

## Behavior (inside a zoom block)

- Cursor moving / roaming → canvas **holds** (no chase).
- Cursor comes to **rest** at a new spot, stays for a **dwell** time, and that
  spot is **beyond the deadzone** from where the canvas is currently looking →
  canvas **gently pans** toward it.
- Quick flicks, jitters, and pass-throughs never accumulate dwell → ignored.
- Cursor still → already at rest, no distance to cover → canvas holds (the
  original "freeze when still" requirement, preserved for free).

## Decisions (locked)

- **Anticipation (lead) removed.** Settle-then-pan is reactive, the opposite of
  anticipating where the cursor will go. The `lead` config field and the
  look-ahead sampling are removed.
- **Speed gate removed.** Replaced by a positional **deadzone** + **dwell**.
- One **sensitivity** slider still drives everything (per-block override + global
  default, unchanged from v2). `restRadius` is a constant, not on the slider.

## Model

`AutoZoomTrack.tuning(_ s:)` now returns `(deadzone, dwell, smoothing)` with `s`
clamped to `[0,1]`:

```
deadzone(s) = 0.10 * (1 - s)     // fraction of source width; s=0 → 0.10, s=1 → 0
dwell(s)    = 0.6  * (1 - s)     // seconds of rest before panning; s=0 → 0.6, s=1 → 0
smoothing(s)= 0.30 - 0.25 * s    // pan gentleness (exp time constant); s=0 → 0.30, s=1 → 0.05
```

`AutoZoomConfig`:
- Remove `lead` and `idleSpeed` (idleSpeed was already folded into sensitivity in
  v2; `lead` is removed now).
- Keep `defaultScale`, `ramp`, `defaultSensitivity = 0.5`, `step`.
- Add `restRadiusFrac: Double = 0.012` — how still the cursor must be (within this
  fraction of source width) to count as "resting at the same spot."

## Algorithm (`AutoZoomTrack.build`, stateful forward pass, per block)

Per block, seed `focus = cursorPoint(at: block.begin) ?? center`; track a
candidate rest point and how long the cursor has held it:

```
let (deadzoneFrac, dwell, smoothing) = tuning(block.sensitivity ?? config.defaultSensitivity)
let deadzonePx  = deadzoneFrac * sourceSize.width
let restRadius  = config.restRadiusFrac * sourceSize.width
let alpha       = 1 - exp(-config.step / max(smoothing, 1e-4))

var focus       = cursorPoint(at: block.begin) ?? center
var restPos     = focus
var restElapsed = 0.0

for each step t in [block.begin, block.end):
    let pos = cursorPoint(at: t) ?? center          // ACTUAL position, no lead
    if hypot(pos - restPos) <= restRadius {
        restElapsed += config.step                   // still holding this spot
    } else {
        restPos = pos                                // moved → new candidate, reset timer
        restElapsed = 0
    }
    let settled = restElapsed >= dwell
    let beyond  = hypot(restPos - focus) > deadzonePx
    let target  = (settled && beyond) ? restPos : focus    // else hold
    focus += (target - focus) * alpha                // gentle ease
    clamp focus to [0, sourceSize]
    emit ZoomKeyframe(t, scaleAt(t, …), focus)        // scale ramp unchanged
// end keyframe at scale 1 (unchanged)
```

Scale ramping (`scaleAt`, smoothstep in/out, `ramp = min(config.ramp, span/2)`),
the per-frame scale, the end-of-block scale=1 keyframe, and the stateless
`sample(at:track:)` are all unchanged.

At `s = 1`: deadzone 0 + dwell 0 → target tracks the cursor immediately with
light smoothing (snappy, like before). At `s = 0`: ignore moves within 10% of
width unless the cursor rests there for 0.6 s, then pan slowly.

## Untouched

- `StudioModel` sensitivity ops and the "Follow" slider (already feed
  `sensitivity` → `tuning`).
- The compositor (`magnify`, track sampling) — only the focus values in the
  pre-built track change.
- Persistence (`ZoomBlock.sensitivity`), `ZoomTimeline`.

## Testing

Unit tests (swift-testing), rewritten for the settle model:

- `tuning`: endpoints (`s=0` → (0.10, 0.6, 0.30); `s=1` → (0, 0, 0.05)),
  monotonic decreasing in all three, clamps out-of-range `s`.
- A small-fast flick (large speed, small displacement, no dwell) does NOT move
  the focus at low sensitivity (the reported bug).
- A cursor that moves to a new spot and RESTS there past the dwell DOES pan
  toward it (focus moves) — and does so only after the dwell, not immediately, at
  low sensitivity.
- At `s = 1` (dwell 0, deadzone 0) the focus tracks a moved cursor without
  requiring rest.
- A large move while `s` is low that the cursor passes through (never rests) does
  not pan.
- Empty cursor samples → centered focus; focus clamped to source bounds (carried
  over).

The compositor/model/UI wiring is unchanged and already covered; verify the feel
by building and running.

## Open items

- `restRadiusFrac` (0.012) and the `deadzone`/`dwell` maxima (0.10 / 0.6 s) are
  first-pass values; fine-tune against real recordings via the slider.
- Click-anticipation (zoom toward an imminent click) is intentionally not in this
  model; could return later as a separate, opt-in behavior.
