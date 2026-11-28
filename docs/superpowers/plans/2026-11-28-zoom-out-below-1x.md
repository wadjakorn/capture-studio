# Zoom out below 1× (down to 0.5×) — plan

## Intent (user, 2026-11-28)

A zoom block may pull back past "no zoom": from 1.0× down to 0.5×. The picture
then gets smaller and the background shows around it — that is accepted
("we already have Overflow inside frame; black edges are fine when zoomed far
out"). It applies to the fixed Zoom slider and to the auto range (Least / Most
zoom).

Builds on the uncommitted work in the tree (3a window frames, dynamic zoom).

## What a scale below 1 means

The same mapping as today, `out(p) = target + scale · (p − focus)`, with
`scale < 1`: the placed video shrinks. Where it no longer covers the framing
region the existing background fill (black, blur or photo) shows — the
compositor already composites the video over that fill in every layout that
shows the main video.

- **Contained** (Overflow off): `recenterTarget`'s cover clamp already has the
  case "scaled content too small to cover the region → centre it". The shrunken
  video sits centred in the region. In cover layouts the source outside the
  reframe crop slides into view first (the full source is kept live), then the
  background.
- **Overflow on**: no clamp — the pointer stays centred and the shrunken video
  moves around it.

## What assumes `scale ≥ 1` today (all found by search)

| Where | Today | Change |
|---|---|---|
| `AutoZoom.swift` `geometry` / `blendedTarget.tgt` | `max(1, scale)` | `max(ZoomBlock.minScale, scale)` (0.5) |
| `ZoomAutoScaler.expandGroup` `base` | `max(1, …)` | same constant |
| `AutoZoom.swift` keyframes: `weight = target > 1 ? env : 0` | no recentre at ≤ 1× | `weight = env` unless every block of the run sits at exactly 1× (a run that is "no zoom" throughout keeps today's behaviour) |
| `CameraCompositor.magnify` | identity when `scale ≤ 1.0001` | identity only when `|scale − 1| ≤ 0.0001` **and** `target == focus`; otherwise apply the transform (a pure pan at exactly 1× must not be dropped, or the picture jumps when a blend crosses 1×) |
| `StudioCompositor.canvasZoom` (shapes, editor overlays) | identity when `scale ≤ 1.0001` | same rule as `magnify` |
| `StudioModel.setZoomScale` | clamp 1…6 | 0.5…6 |
| `StudioModel.seedManualFocus` | uses the sampled focus only when `scale > 1` | when `|scale − 1| > 0.0001` or weight > 0 |
| `ZoomCanvasOverlay` drag | `max(1, scale)` | `max(0.5, scale)` |
| `ZoomAutoScale.scaleLimits` | 1.1…6 | 0.5…6 |
| Inspector sliders | 1…6 / limits | 0.5…6 |

Unchanged and why it is safe:

- Run envelope `scale = 1 + (dipped − 1) · env`: linear in the target, fine
  below 1 (ramps 1 → 0.7 and back).
- Dip: `max(min(target, dipFloor), target · dip)` leaves a target ≤ 1.1 alone.
- Planner: `half = view / (2 · scale)` grows; where it exceeds the content the
  reach inverts and the centre collapses to the midpoint — the same thing the
  compositor's clamp does. No special case.
- `AutoZoomTrack.sample` outside a run returns scale 1, weight 0.
- The Settings default scale and the suggester's 1.5–3.0 range are untouched:
  nothing zooms out below 1× unless the user sets a block or a range that way.

## Auto range below 1×

`fit = (1 − 2·margin) · view / subject` keeps a 7% margin around the subject.
Below 1× that margin is pointless — the picture's own edge is the margin — and
would shrink the picture just to add a border. Rule:

```
raw = (1 − 2·margin) · min(view.w / subject.w, view.h / subject.h)
if raw < 1 { raw = min(1, min(view.w / subject.w, view.h / subject.h)) }
scale = clamp(floor05(raw), auto.min, auto.max)
```

So an auto block goes below 1× only when the subject is genuinely larger than
what the frame shows at 1× (a framing window narrower than the video; a
"show both" union wider than the frame), and only as far as needed.
`fits(subject)` uses the same `raw`.

Default range for generated blocks stays 1.5–3.0.

## Tasks

1. `ZoomBlock.minScale = 0.5` and the clamp sites; `ZoomAutoScale.scaleLimits`.
   Tests: a 0.6× block builds keyframes at 0.6 with weight 1; a run at exactly
   1× still has weight 0; decode clamps.
2. Compositor: `magnify` / `canvasZoom` rule. Tests on the pure parts:
   `recenterTarget` at 0.5× contained → content centred in the region;
   overflow → focus on the region centre; `canvasZoom` at 0.5× is not identity
   and maps the focus to the target; continuity of `recenterTarget` +
   `canvasZoom` as the scale sweeps 1.2 → 0.8 (no jump at 1.0), contained and
   overflow.
3. Scaler fit rule. Tests: a subject wider than the view with range 0.5–3 →
   `view / subject` floored; a subject that fits with margin only below 1 → 1.0
   exactly; range 1.5–3 unchanged.
4. UI ranges; `seedManualFocus`; `ZoomCanvasOverlay`.
5. `swift test` (Xcode + CLT); build; look at one frame: render a 0.5× block
   through the exporter or a compositor harness and check the picture is
   centred, half size, background around it, cursor and a shape in the right
   place.
6. Independent code review.

## Risks

- Scaling the video down in Core Image: edge pixels of the shrunken video
  against the background (a transparent fringe) — check in task 5.
- A blurred background uses the video itself; at 0.5× it becomes the dominant
  part of the frame. Accepted (user's choice of background).
- In cover layouts the planner believes only the reframe crop is reachable,
  while below 1× the compositor shows more of the source. The camera is then
  simply centred; no pointer guarantee is lost because more is visible, not
  less.

## Scrutiny outcome (2026-11-28)

Independent review against the code; verdict fix-then-ship. Accepted changes:

- **One identity rule, one place (blocker).** `CanvasZoom.isIdentity` was
  missing from the table: the renderer builds `CanvasZoom` directly for mask /
  blur shapes, and `map` returns its input when `scale ≤ 1.0001` — below 1×
  shapes would stay put while the picture shrinks. `isIdentity` becomes
  `|scale − 1| ≤ 1e-4 && target == focus`; `magnify` takes a `CanvasZoom`; the
  render path and `canvasZoom()` build it through one helper.
  `CanvasZoomTests` (asserts the old rule) and `ZoomRampContinuityTests` (a
  hand copy of the old gate) are rewritten; a sweep 1.2 → 0.8 through
  `CanvasZoom.map` is added, contained and overflow.
- **No dead zone at exactly 1×.** The "weight 0 at 1×" exception applies only
  to runs made solely of user blocks with a fixed scale of exactly 1; pieces of
  an auto block always recentre.
- **"No zoom" stays easy to pick.** The fixed slider and both range sliders
  snap to 1.0 within ±0.03.
- A manual block below 1× in contained mode cannot be aimed (the picture is
  centred): the reticle is hidden there.
- Stale comments (`dipFloor`, `scaleLimits`, `ZoomBlock.scale` "≥ 1") fixed;
  the clamp is tested at `geometry` / `tgt` (there is no decode clamp).
- Noted behaviour change: a 1× block touching a zoomed block now recentres
  with the run (overflow / framing window), which also removes an existing
  one-frame snap as a blend leaves 1.0.

**Open — needs the user:** in a cover layout (the reframe crop fills the
canvas, e.g. a 9:16 crop of a 16:9 recording) zooming out below 1× in contained
mode brings the cropped-away parts of the recording back into view before any
background shows. Either keep that ("zoom out shows more of the recording"), or
clip to the crop so the picture shrinks with background around it.

**Added 2026-11-28 (after the contained-ramp fix).** `recenterTarget` now
hard-clamps the eased target when the content covers the region *and
`scale ≥ 1`*; below 1× it falls back to the weight-eased rule. That switch is
discontinuous for 0 < weight < 1 (a jump of up to `(centre − focus)·w(1 − w)`),
unreachable today because the track never goes below 1×. This plan must make
it continuous (and test a sweep across 1× at fixed weight) before allowing
scales below 1.
