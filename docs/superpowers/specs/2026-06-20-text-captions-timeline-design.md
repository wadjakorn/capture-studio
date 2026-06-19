# Text / captions timeline

**Date:** 2026-06-20
**Scope:** Studio editor only. Adds a second timeline track for on-screen
text/captions, modeled on the existing camera timeline. Recorder, capture, and
the `.capturestudio` on-disk schema version are unchanged (the new field is
additive). Auto-generated captions are a **follow-up task** — this design only
makes the model and renderer ready for them.

## Problem

Studio can place an animated camera PiP via the camera timeline, but has no way
to put **text** on the video. We want multiple independent text/caption
instances on their own timeline track, where:

- Each text is its own block with a `[begin, end]` span.
- Multiple texts can be visible **at the same instant** (blocks may overlap in
  time) — e.g. a persistent title plus a lower-third caption.
- Text can sit **anywhere** on the frame (free position), edited where it
  appears (WYSIWYG on the preview canvas).
- The next task will auto-generate captions from system audio and/or
  microphone; those captions must drop into the **same** model and renderer with
  no rework.

## Key divergence from the camera timeline

The camera is a **single** instance: `CameraTimeline.sample(at:)` returns one
resolved placement, and blocks are clamped to never overlap. Text is the
opposite:

- **Many active at once.** The text evaluator returns *all* blocks active at
  time `t`, not one.
- **Overlap allowed.** No non-overlap clamps. Two text blocks may cover the same
  time range.
- **Z-order by array order.** Render order = storage order; a later element
  draws on top. "Bring forward / send back" reorders the array. (The camera
  track has no z concept.)

Everything else — Codable block in `EditState`, a pure unit-tested math enum, a
reusable timeline lane view, a per-frame compositor spec — mirrors the camera
track. `CameraTimelineLane`'s own doc comment already anticipated this
("future tracks … captions … stack on the same time axis").

## Decisions (locked in brainstorming)

| Topic | Decision |
|-------|----------|
| Model shape | Flat list of free-floating blocks; renderer composites all active ones. **Not** stacked lanes (would overflow UI). |
| Timeline display of time-overlaps | **Dynamic auto-stack, capped.** Single row normally; split into mini sub-rows only when blocks actually overlap, capped (≈3) with internal scroll past the cap. |
| Position | Free x/y, normalized 0–1 (same units as camera `centerX/centerY`). |
| Z-order | Array order; later = on top. Reorder actions move within the array. |
| Text editing | **Inline on the preview canvas (WYSIWYG):** double-click the text where it sits to type; drag to set position. |
| Add block | Button → inserts an empty default block at the playhead. |
| Default duration | **3 s**. |
| Style controls | Style bar shown when a block is selected: font family, size, weight, color, background box on/off + color/opacity, alignment, **stroke/outline** + **shadow** (legibility over busy video). |
| Auto-captions forward-compat | `TextBlock.source` enum: `.manual` / `.systemAudio` / `.microphone`. One block = one caption line (`begin`/`end` + text). **No word-level timing** in the model. |

## Data model

New `TextBlock` (Codable, Identifiable) in `ProjectBundle/EditState.swift`,
alongside `CameraBlock`:

```
struct TextBlock {
    var id: UUID
    var begin: Double            // seconds on the screen-track timeline
    var end: Double              // begin == end is inert (no render); end > begin shows
    var text: String
    var centerX: Double          // normalized 0–1, top-left origin (canvas space)
    var centerY: Double
    // style
    var fontName: String
    var fontSize: Double         // fraction of CANVAS HEIGHT (export-size independent)
    var fontWeight: TextWeight   // enum (regular/medium/semibold/bold)
    var colorHex: String         // "#RRGGBB"
    var alignment: TextAlignmentH// leading/center/trailing
    var boxEnabled: Bool
    var boxHex: String
    var boxOpacity: Double       // 0–1
    var strokeWidth: Double      // fraction of font size; 0 = none
    var strokeHex: String
    var shadow: Bool
    // forward-compat
    var source: TextSource       // .manual | .systemAudio | .microphone
}
```

Added to `EditState`:

```
/// On-screen text/caption blocks. Empty = no text. Blocks MAY overlap in time
/// (unlike cameraBlocks); render/z-order is array order (later = on top).
var textBlocks: [TextBlock] = []
```

- **Additive, no schema bump.** Older bundles decode `textBlocks` as `[]`. The
  `DisplayInfo` schema and host-clock sync are untouched (architecture
  invariants hold).
- **Sizes are fractions, not pixels.** `fontSize` is a fraction of canvas
  height and `strokeWidth` a fraction of `fontSize`, so a block looks identical
  at preview size and at full export resolution — the same trick `cameraScale`
  uses for width.
- **Storage order = z-order.** Unlike `cameraBlocks` (which the model keeps
  sorted by `begin`), `textBlocks` is **never** re-sorted on store; sorting by
  `begin` happens only in a local copy for lane layout/evaluation.

## Pure math — `Studio/TextTimeline.swift`

Mirrors `CameraTimeline` (no AVFoundation, no UI, fully unit-tested), but for a
multi-instance, overlap-allowed track:

- `active(at t: Double, blocks: [TextBlock]) -> [TextBlock]` — every block with
  `begin <= t < end`, returned in **array order** (z-order preserved). This
  replaces camera's single-block `sample`.
- `add(_ blocks:, atTime:, width:, style:) -> (blocks, id)` — append a block
  `[t, t+width]` clamped only to `[0, duration]`; **no neighbor clamp** (overlap
  is legal). Appends to the end (top of z-order).
- `moveBegin` / `moveEnd` / `moveBlock` — clamp only to `[0, duration]` and
  `begin <= end`. **No non-overlap clamp.**
- `remove(_ blocks:, id:)`.
- `bringForward` / `sendBackward` / `moveToFront` / `moveToBack` — array-index
  moves (z-order).
- `subRows(_ blocks:, ...) -> [[TextBlock]]` — greedy interval packing for the
  lane: sort by `begin`, place each block in the first sub-row whose last
  block's `end <= this.begin`. Returns the sub-row buckets. Pure and testable;
  the lane caps the displayed count and scrolls past the cap. (Packing is
  display-only; it never changes storage or z-order.)

## StudioModel state — `Studio/StudioModel.swift`

Parallel to the camera-block state:

- `@Published var textBlocks: [TextBlock]`
- `@Published var selectedTextBlockID: UUID?`
- `@Published var editingTextBlockID: UUID?` (a block in active inline edit)
- Ops calling `TextTimeline`: `addTextBlock()` (at playhead, default style, 3 s),
  `removeTextBlock`, `moveTextBlock(Begin/End/Block)`, `setText`, `setTextPosition`,
  `setTextStyle(...)`, `bringTextForward` / `sendTextBack`, plus a
  `commitTextEdit()` for drag/undo coalescing (mirrors `commitBlockEdit`).
- `buildCompositorComposition()` wraps `textBlocks` into a `TextTimelineSpec`
  and hands it to the compositor (next to `CameraTimelineSpec`).
- **Selection is mutually exclusive with the camera block selection:** selecting
  a text block clears `selectedBlockID` and vice versa, so the inspector shows
  the right controls (camera PiP controls vs. text style bar).

## Compositor — `Studio/CameraCompositor.swift`

- New `TextTimelineSpec { blocks: [TextBlock] }` carried on `CompositorLayout`
  (next to `cameraTimeline`).
- In `startRequest`, after screen + camera + click rings + cursor, composite
  text **last (topmost)** so captions stay legible:
  ```
  for block in TextTimeline.active(at: now, blocks: spec.blocks) {   // array order = z
      if let img = textImage(block, canvas: layout.canvas) {
          output = img.composited(over: output)
      }
  }
  ```
- `textImage(_:canvas:)` renders a block to a `CIImage` via **Core Text /
  CGContext** (NSAttributedString → sized `CGContext` → `CGImage` → `CIImage`),
  positioned at `centerX/centerY` on the canvas. Core Text + CGContext is
  chosen deliberately over any SwiftUI/`CATextLayer`-on-main path because the
  app is built with **Command Line Tools only** (see the project's CLT SwiftUI
  overlay-crash note) and the compositor runs off the main thread.
- **Cache** rendered images keyed by `(text, style, canvasSize)`. Text is static
  within a block, so a held caption renders once and is reused every frame
  (same spirit as the camera `decorations` reuse).

## Live WYSIWYG editing overlay — `Studio/StudioWindow.swift`

The preview is an `NSViewRepresentable`-wrapped player (SwiftUI `VideoPlayer`
SIGABRTs on CLT builds — project memory). So canvas text editing is a **SwiftUI
overlay layered on top of the preview view**, not a player feature:

- The overlay maps normalized `centerX/centerY` to the preview view's current
  pixel rect (same mapping the PiP drag uses).
- Selecting a text block whose span contains the playhead shows a move handle at
  its position; **drag** updates `centerX/centerY`.
- **Double-click** → a positioned `TextField`/`TextEditor` for typing; commit
  writes `text`.
- To avoid a doubled image, the **actively-edited** block (`editingTextBlockID`)
  is suppressed in the compositor preview while its editor is open; on commit it
  un-suppresses and the baked render takes over. Export is always the compositor
  render (never the overlay).

## Timeline lane — `Studio/TextTimelineLane.swift`

A second lane stacked under the camera lane on the same time axis, cloned from
`CameraTimelineLane` with three changes:

1. **Dynamic auto-stack.** Lane height = `rowHeight * min(rows, cap) + spacing`,
   where `rows = TextTimeline.subRows(...).count`. One row when nothing overlaps;
   grows only as overlaps appear; internal vertical scroll past the cap (≈3).
2. **Overlap-allowed gestures.** Body drag / edge drag call the text ops (no
   neighbor clamp), so blocks can be dragged across each other.
3. **Content label.** Each block shows its (truncated) text. Tap selects (and
   parks selection so the style bar + canvas overlay target it); double-click
   focuses the canvas editor.

## Style bar — `Studio/StudioWindow.swift` (or a small new view)

Shown when a text block is selected: font family, size, weight, color,
background box toggle + color + opacity, alignment, stroke width + color, shadow
toggle. Each control writes through a `setTextStyle(...)` model op. Reuses the
existing inspector styling so it matches the camera controls.

## Persistence

`textBlocks` round-trips through `edit.json` exactly like `cameraBlocks`
(`StudioModel` load sorts a copy for display but stores the array verbatim to
preserve z-order). Master media files are never touched (edit-state invariant).

## Testing

Per project convention, UI/compositor glue is not unit-tested; keep the existing
45 tests green and add `swift-testing` cases for the new **pure** helpers in
`TextTimeline`:

- `active(at:)` returns all overlapping blocks, in array (z) order, with correct
  half-open `[begin, end)` boundaries.
- `add` allows overlap and clamps only to `[0, duration]`.
- `moveBegin/moveEnd/moveBlock` clamp to bounds, never to neighbors; `begin <= end`.
- `bringForward/sendBackward/moveToFront/moveToBack` array reordering.
- `subRows` greedy packing: non-overlapping → 1 row; N mutually overlapping → N
  rows; mixed → minimal rows.

Manual verification via `scripts/build-app.sh debug` + relaunch: add two
overlapping blocks, confirm both render in the preview and the export, z-order
respects array order, canvas drag/type works, lane auto-stacks then collapses,
and a bundle written with text reloads.

## Out of scope (this task)

- **Auto-generated captions** (transcription from system audio / mic) — the next
  task. This design only adds `source` and a one-line-per-block model so that
  task is purely additive.
- Word-level / karaoke timing.
- Animated text transitions (fade/slide). v1 is hard on/off within `[begin,
  end)`; a `fade` style field can be added later without model changes.
- Any change to capture, the recorder, `DisplayInfo`, or host-clock sync.
