# Auto Zoom/Pan — Design

Date: 2026-06-23
Status: Approved (pending implementation plan)

## Goal

Add an automatic zoom/pan feature to the Studio editor. The user marks time
ranges ("zoom blocks") on a dedicated timeline lane; inside those ranges the
canvas automatically zooms in and pans to follow the mouse cursor and its
actions, with smooth animation. Outside those ranges the canvas is untouched.

This mirrors the auto-zoom behavior of Screen Studio, built on Capture Studio's
existing host-clock-synced cursor event data.

## Requirements (from user)

- Zoom/pan blocks live on a **separate timeline lane**, distinct from the main
  (screen) and text lanes.
- Adding a zoom block reveals the zoom/pan lane. The lane is **hidden by default
  when there are no zoom blocks**.
- The user chooses **where** in the timeline auto zoom/pan applies. Time ranges
  with no zoom block get **no** auto zoom/pan.
- Inside a zoom block, auto zoom/pan **follows the cursor position and mouse
  actions**, with smooth animation.
- **Idle behavior:** when the cursor is still, the canvas **holds its current
  zoom and freezes the pan** (does not drift). It re-pans when the cursor moves
  again. (Screen Studio style.)
- **Anticipation:** the pan begins moving toward where the cursor *will* move or
  click slightly *before* it gets there, using smooth animation.

## Key decisions

- **Zoom level:** per-block `scale`, editable in the inspector. Each block
  defaults to a global config value; the per-block value overrides it.
- **Lookahead:** anticipate by ~0.4s (default, tunable later), for both moves
  and clicks. Feasible because the recording is already captured — future cursor
  positions are known.
- **Idle:** hold zoom + freeze pan.
- **Zoom blocks are non-overlapping** (like `CameraBlock`).
- **Auto-zoom scales the screen + cursor + click rings only.** The camera PiP
  and text overlays do **not** zoom (they composite after, at fixed canvas
  positions) — matches Screen Studio.

## Architecture

### The core problem and its solution

The compositor (`CameraCompositor`) may render frames **out of order** — preview
scrubbing and seeking request arbitrary composition times. Therefore per-frame
smoothing that depends on "the previous frame's state" is unsafe (a spring
integrator would produce different results depending on seek history).

**Solution:** compute a **smoothed zoom track once** when the composition is
built, store it alongside the existing cursor samples, and have the renderer
**interpolate it statelessly** per frame. This is the exact pattern already used
for `cursorSamples` (`CursorOverlay.position(at:)`): deterministic, seek-safe,
cheap per frame.

### Components

**1. Data model — `ZoomBlock`** (`Sources/CaptureStudio/Studio/EditState.swift`)

```
struct ZoomBlock: Codable, Identifiable, Equatable {
    var id: UUID
    var begin: Double        // seconds, screen-track timeline
    var end: Double          // [begin, end); non-overlapping
    var scale: Double?       // nil = use global default; else per-block override
}
```

- Mirrors `CameraBlock` (`EditState.swift:99`). Added to `EditState.zoomBlocks`.
- `StudioModel.zoomBlocks: [ZoomBlock]` (published, private set), persisted via
  `saveEdit()` / decoded in `load()`.
- `StudioModel.selectedZoomBlockID: UUID?`.

**2. Block math — `ZoomTimeline`** (new `Sources/CaptureStudio/Studio/ZoomTimeline.swift`)

Enum of pure functions, mirroring `CameraTimeline`: `add`, `moveBlock`,
`moveBlockBegin`, `moveBlockEnd`, `remove`, with non-overlapping clamping
(adjacent blocks cannot cross). No `sample()` here — sampling is the pre-pass's
job (see below).

**3. Timeline lane UI — `ZoomTimelineLane`** (new `Sources/CaptureStudio/Studio/ZoomTimelineLane.swift`)

- Mirrors `CameraTimelineLane` (single-row, non-overlapping): time↔x mapping,
  drag-to-move, edge-resize handles, tap-to-select, empty-track scrub.
- Inserted in `StudioWindow` lane stack (near `StudioWindow.swift:116`), shown
  when `!model.zoomBlocks.isEmpty`. Icon: `magnifyingglass`.
- "Add zoom" button (mirrors "Add move"): `model.addZoomBlock()` samples the
  playhead, inserts a default-width block, auto-selects it.
- Inspector panel for the selected zoom block: a **scale slider** that shows the
  effective value and writes a per-block override (reset = fall back to global).

**4. Pre-pass — `AutoZoomTrack`** (new `Sources/CaptureStudio/Studio/AutoZoomTrack.swift`)

```
struct ZoomKeyframe { var t: Double; var scale: Double; var focusX: Double; var focusY: Double }  // focus in source px

enum AutoZoomTrack {
    static func build(blocks: [ZoomBlock],
                      cursorSamples: [CursorSample],
                      sourceSize: CGSize,
                      config: AutoZoomConfig) -> [ZoomKeyframe]
}
```

Build algorithm:

- Default state everywhere: `scale = 1`, focus = source center (no transform).
- For each block, emit keyframes at a fine step (60 Hz):
  - **Scale ramp:** smoothstep `1 → S` over `rampIn` (~0.4s) at entry,
    `S → 1` over `rampOut` at exit. Ramps clamped to ≤ ½ the block length so
    short blocks still fully ramp.
  - **Anticipated target:** raw focus target at time `t` = cursor position at
    `t + lead` (via interpolation of `cursorSamples`), clamped to block end.
  - **Idle gate:** estimate cursor speed near `t`; if below `idleSpeed`
    threshold, do **not** advance the target (hold last focus) → "freeze pan
    while still".
  - **Smoothing:** a single forward pass applies exponential / critically-damped
    smoothing to the focus target → smoothed focus. (Stateful here is fine: it
    is a one-shot build-time pass, not per-render-frame.)
- Keyframes from adjacent blocks never overlap (blocks are non-overlapping); the
  gaps carry the implicit `scale = 1` default.

`AutoZoomConfig`: `{ defaultScale, lead, rampIn, rampOut, idleSpeed,
smoothing }` — sourced from settings with sensible defaults.

**5. Render integration** (`Sources/CaptureStudio/Studio/CameraCompositor.swift`)

- The built `[ZoomKeyframe]` track is carried in the composition instruction /
  overlay payload (next to cursor + click samples), produced in
  `StudioModel.buildCompositorComposition()`.
- Per frame in `startRequest()` (already has `now =
  request.compositionTime.seconds`): interpolate the track at `now` →
  `(scale, focusSource)`. Map focus to canvas via the existing
  `sourceToCanvas`.
- Fold magnification into the screen source→canvas transform around the focus:
  `canvasP' = focusCanvas + (canvasP - focusCanvas) * scale`.
  - Applied to the screen image draw transform **and** to `sourceToCanvas` used
    by the cursor + click overlays, so they zoom together.
  - The camera PiP and text overlays use their own placement and are composited
    afterward → unaffected.
- Composes on top of whatever base placement is active (fit/letterbox, cover, or
  reframe crop), so it works in original **and** reframe modes.

### Data flow

```
events.jsonl ──load──> cursorSamples (source px)
                               │
zoomBlocks + config ───────────┤
                               ▼
                AutoZoomTrack.build()  →  [ZoomKeyframe]   (composition build time)
                               │
                               ▼
        CameraCompositor.startRequest(now)  → interpolate → (scale, focus)
                               │
                               ▼
        fold into screen source→canvas transform (screen + cursor + clicks)
```

Rebuild the track whenever inputs change: zoom blocks added/moved/resized/
removed, a block's scale changed, global config changed, or cursor samples
(re)loaded.

## Untouched / non-goals

- **`canvasZoom` / `canvasPanX` / `canvasPanY`** (`StudioModel.swift:184`) —
  ephemeral preview-inspection zoom, view-only, not exported. Stays independent.
- **`cropZoom` / `cropCenterX/Y`** — reframe-mode base framing. Stays
  independent; auto-zoom composes on top of it.
- No automatic *creation* of zoom blocks (no auto-detection of "interesting"
  moments) in v1 — the user places blocks manually.
- Camera PiP and text do not zoom in v1.

## Edge cases

- **Overlapping blocks:** prevented by non-overlapping clamp on add/move/resize.
- **Block shorter than ramps:** clamp `rampIn`/`rampOut` to ≤ ½ block length.
- **No cursor samples within a block:** focus = source center; static zoom only.
- **Cursor near source edges:** clamp focus so the magnified screen never
  reveals area outside the source (no empty margins from over-panning).
- **Scale = 1 block:** effectively a no-op; allowed but harmless.
- **Seeking / out-of-order frames:** handled by the stateless interpolation of
  the pre-built track.

## Testing

Unit tests (swift-testing, pure helpers — consistent with the existing suite):

- `ZoomTimeline` block ops: add clamps into range; move/resize cannot overlap
  neighbors; remove; ordering preserved.
- `AutoZoomTrack.build`:
  - scale ramps reach `S` and return to `1`; ramps clamped for short blocks;
  - outside blocks `scale == 1`;
  - per-block scale overrides global default; `nil` uses global;
  - idle gate freezes focus when cursor speed below threshold;
  - anticipation: focus leads the cursor by ~`lead`;
  - focus clamped to source bounds;
  - empty cursor samples → centered static zoom.
- Persistence: `EditState` round-trips `zoomBlocks` through encode/decode.

Capture/UI/compositor glue is not unit-tested (matches project convention);
verified by building and running the app.

## Open items (defaults chosen, tunable later)

- Exact default values: `defaultScale ≈ 2.0`, `lead ≈ 0.4s`, `rampIn/Out ≈
  0.4s`, `idleSpeed` and `smoothing` constants — finalize during implementation
  against real recordings.
- Whether to expose `lead` / smoothing in settings UI now or later (lean: global
  config value now, per-block later).
