# Camera timeline blocks

**Date:** 2026-06-19
**Scope:** Studio camera overlay only. Adds a time dimension to camera
position / size / visibility via draggable **transition blocks** on a dedicated
camera lane. Camera *style* (shape, border, shadow, zoom, aspect, rotation)
stays global. Screen zoom/crop and captions are out of scope — but the lane
scaffold and block UI are built to host them later.

> **Revision (same day):** the first cut used point breakpoints + a single
> global transition duration. Replaced — before any commit — with the **block
> model** below: each transition is an explicit `[begin, end]` span with its own
> duration. This makes the animation's end visible, gives per-move durations,
> and (via non-overlap) removes a discontinuity the point model had.

## Problem

Camera placement in Studio is a single static state (`EditState.cameraCenterX/Y`,
`cameraScale`, `cameraVisible`). It can't change over the recording, and there's
no separate camera track. Goal: let the user add / remove / move / resize
**blocks** on a camera lane to reposition, resize, and show/hide the camera over
time, with each block carrying its own transition ramp.

## Model: transition blocks

- A **block** is one transition span `[begin, end]`. Left edge = where the
  move/fade begins; right edge = where it settles. Both edges drag.
- During `[begin, end]`: the camera eases from the **previous block's settled
  placement** (or the static **home** placement, for the first block) into this
  block's placement, ease-in-out.
- After `end` until the next block's `begin`: **hold** this block's placement.
- `begin == end` is a hard cut.
- Camera is a single instance, so blocks **never overlap**: `end ≥ begin` within
  a block, and `begin(next) ≥ end(prev)`. The lane clamps drags to enforce this.

Consequences:
- The animation's **end** is explicit (the right edge) — not inferable before.
- Each block has its own duration (`end − begin`); no global transition knob.
- Non-overlap means a transition is **never interrupted**, so the "from" state
  is always a settled value → no discontinuity / pop.

## Approaches considered (render pipeline)

1. **Extend the custom Core Image compositor** — evaluate blocks per frame at
   `request.compositionTime`, interpolate the PiP rect + opacity, reusing the
   per-frame cursor/click infrastructure. **Chosen.** One path for preview +
   export; exact ease-in-out.
2. **Native layer-instruction ramps** — linear only (no ease-in-out), awkward
   with the cursor compositor, N instructions. Rejected.
3. **Pre-bake camera frames.** Slow, redundant. Rejected.

## Design

### A. Data model — `ProjectBundle/EditState.swift`

```swift
struct CameraBlock: Codable, Equatable, Identifiable {
    var id: UUID
    var begin: Double     // sec on the screen-track timeline; ramp start
    var end: Double        // ramp end (settle); end >= begin; begin == end = cut
    var visible: Bool
    var centerX: Double    // normalized 0–1 render space, same units as cameraCenterX
    var centerY: Double
    var scale: Double      // PiP width / screen width, same units as cameraScale
}

// in EditState:
var cameraBlocks: [CameraBlock] = []   // EMPTY = today's static path, byte-identical
```

Additive, `decodeIfPresent`, `schemaVersion` unchanged → legacy bundles load as
empty (static camera, identical to today). The static `cameraCenterX/Y`,
`cameraScale`, `cameraVisible` remain and double as the **home** placement.

### B. Evaluator (pure, unit-tested) — `Studio/CameraTimeline.swift`

```swift
struct CameraSample { var centerX, centerY, scale, opacity: Double }
func sample(at t: Double, blocks: [CameraBlock], home: CameraSample) -> CameraSample
```

- empty blocks → `home`.
- `t` before the first block → `home`.
- active block `k` = last with `begin ≤ t`. `from` = `S(k-1)` (or `home` for
  `k = 0`).
  - `t < end_k` → ease `from → S_k` over `[begin_k, end_k]`, ease-in-out.
  - `t ≥ end_k` → hold `S_k` (the exact target — settle returns the literal
    target, avoiding float drift at `f = 1`).
- visibility rides the same ease as opacity 0↔1 → show/hide is a crossfade;
  opacity 0 ⇒ the compositor skips the camera.

Plus pure list ops with the non-overlap clamps: `clampBegin`, `clampEnd`,
`moveBegin`, `moveEnd`, `moveBlock` (shift keeping width), `add` (places at the
playhead, pushes past any block it lands in, clamps to the next block /
duration), `remove`.

### C. Render wiring — `StudioModel` + `CameraCompositor`

- `needsCompositor` gains `cameraHasTimeline` (`!cameraBlocks.isEmpty`).
- `buildCompositorComposition` passes `CameraTimelineSpec { blocks, home }` plus
  the existing feed geometry + canvas into the instruction — no pre-baked PiP.
- `StudioCompositor.startVideoCompositionRequest` evaluates `sample(at:)`, builds
  the per-frame PiP rect + opacity. Decorations (mask/border/shadow) are built
  from fractions against the per-frame PiP size and cached by size (a held block
  hits the cache; only a scale-animating ramp rebuilds). Cursor/click unchanged.
- Preview (`AVPlayer`) and `Exporter` share the one composition → WYSIWYG export.

### D. Camera lane + alignment — `Studio/CameraTimelineLane.swift`, `StudioWindow.swift`

- **Shared lane scaffold:** every lane is a fixed-width leading **icon gutter**
  + track. The main scrubber (`display` icon) and the camera lane (`video.fill`)
  both use it, so their time axes start at the same x and the playheads line up
  vertically. Future caption/text lanes drop into the same scaffold.
- **Blocks** render as rectangles spanning `[begin, end]` with draggable edge
  handles (left = begin, right = end) and a draggable body (moves the whole
  block, keeping width). Zero-width blocks render as a single cut diamond. Hidden
  blocks are dimmed with an `eye.slash`. Selected block is accent-outlined.
- Edge / body drags route to `moveBlockBegin/End/Block` (clamped, non-
  overlapping); the empty track scrubs. Tapping a block selects it and parks the
  playhead at `end` (settled) so the PiP overlay is WYSIWYG.
- **Editing targets:** a selected block → the PiP overlay edits that block's
  placement. No selection + playhead before the first block → the overlay edits
  the **home** placement (the static fields). Toolbar: add block at playhead,
  delete selected, show/hide selected.

### E. Invariants preserved (do not regress)

- `EditState` additive, `decodeIfPresent`, `schemaVersion` unchanged.
- Cursor-not-baked, host-clock sync, region-relative `DisplayInfo`, own-app
  windows excluded, preview/record split — untouched. `DisplayInfo` schema
  unchanged.

## Testing

swift-testing, pure helpers only (UI + compositor glue not unit-tested, per
convention):

- `sample(at:)`: empty→home · before-first→home · ramp start→from · mid-ramp
  interpolation · settle→exact target · hold after end · second block eases from
  the first's target (no pop) · hide crossfade · zero-width cut · unsorted input.
- list ops: `clampBegin`/`clampEnd` bounds, `moveBegin`/`moveEnd`/`moveBlock`,
  `add` (playhead placement, push-past, duration clamp), `remove`.
- `EditState` codec round-trip incl. legacy decode (missing key → empty).

## Generalization (next features)

- The lane scaffold (icon gutter + track) and the block UI (rectangle + edge
  handles) are reused by future display-zoom and caption/text lanes.
- Non-overlap + single-instance is **camera-only**. Caption/text lanes will
  allow stacked/overlapping blocks; the clamp logic is per-lane, not global.

## Out of scope (future)

- Per-block easing-curve choice.
- Per-block camera *style* overrides.
- Horizontal timeline zoom (needed to separate blocks that are very close in
  time at the current fixed lane width).
- Display-zoom and caption lanes.
