# Text tools improvements — design

Date: 2026-06-23
Status: approved design, pending implementation plan

## Goal

Six improvements to the Studio text/caption tooling so authoring text feels
faster and gives finer control:

1. New text inherits the most-recently-edited block's style (in-memory only).
2. Allow smaller font sizes (current minimum feels too big).
3. Show font size in px in the tools.
4. Let the user resize the text box width (wrap frame) without changing font size.
5. Add an auto-wrap toggle, default on.
6. Move text editing out of the timeline-block click and on-canvas overlay into
   an inline field in the text tool group. Timeline-block click only *selects*.

## Background (current state)

- `TextBlock` (`Sources/CaptureStudio/ProjectBundle/EditState.swift:156`) stores
  `fontSize` as a **fraction of canvas height** (0.06 = 6%), position as a
  normalized center (`centerX`/`centerY`), plus style fields. It has a custom
  `init(from:)` using `decodeIfPresent` so bundles missing newer fields still
  decode with defaults — this is how new fields are added safely.
- `TextImageRenderer` (`Sources/CaptureStudio/Studio/TextImageRenderer.swift`)
  rasterizes a block with Core Text. Wrap width is **hardcoded** to
  `canvas.width * 0.9` (line 97); height is measured to fit.
- `StudioModel` exposes `renderSize: CGSize` — the composition output size used
  by the compositor. Font-size hard clamp lives in `setTextFontSize`
  (`StudioModel.swift:906`): `min(max(0.01, v), 0.5)`.
- Editing today: tapping a timeline block opens an editor
  (`beginEditingText`, `TextTimelineLane.swift`), double-clicking the canvas
  overlay also opens it (`TextCanvasOverlay.swift`), and the text input itself is
  a popover (`textEditorPopover`, `StudioWindow.swift:550`). State is split across
  `selectedTextBlockID` and `editingTextBlockID`.

## Design

### Schema additions — `TextBlock`

Add two stored fields, defaulted, added to `init`, `CodingKeys` (auto-synth), and
`init(from:)` with `decodeIfPresent`. `schemaVersion` stays 1 (back-compat is
handled by `decodeIfPresent`, identical to how `source` was added).

| Field | Type | Default | Meaning |
|-------|------|---------|---------|
| `boxWidth` | `Double` | `0.9` | Wrap-frame width as a fraction of canvas width. `0.9` reproduces today's behavior. |
| `autoWrap` | `Bool` | `true` | When on, text wraps to `boxWidth`. When off, no soft-wrapping. |

### #1 — Remember last-edited style

`StudioModel` holds an in-memory `lastTextStyle: TextBlock` (or a style snapshot),
seeded from `TextBlock()` defaults. **Not persisted** — resets each app launch /
project open (no cross-session memory, per request).

- Whenever the user edits any style/position/size/box property of the selected
  block, capture that block's properties into `lastTextStyle`. This happens at the
  central mutation points (`updateSelectedText` and the canvas move/resize paths).
  `text`, `id`, `begin`, `end` are not part of the captured style.
- `addTextBlock()` builds the new block from `lastTextStyle`: copy **all** style +
  position + `boxWidth` + `autoWrap`; set `text = ""`, fresh `id`, and a new
  `[begin, end)` at the playhead with the default duration.
- Position is inherited (per decision): new blocks land exactly where the previous
  one was and visually stack until moved. Accepted trade-off.

### #2 — Smaller minimum font size

- Lower the Size slider minimum from `0.02` to `0.005`.
- Lower the hard clamp in `setTextFontSize` from `0.01` to `0.005`.
- At a 1080-tall output, `0.005` ≈ 5–6 px.

### #3 — Font size in px

In the Size control (`StudioWindow.swift:627`), render a row of: slider + px
stepper + a `"NN px"` label.

- `px = round(fontSize × renderSize.height)`.
- Stepper steps ±1 px → `fontSize = px / renderSize.height`, re-clamped.
- Guard `renderSize.height > 0`; fall back to `1080` for the conversion.
- Note: preview `renderSize` may be capped below final export resolution, so the
  px shown is the canvas-accurate value for what is drawn, not necessarily the
  exact export pixel height. This is acceptable and consistent with how the block
  is composited.

### #4 — Resizable box width (width only, auto height)

- `TextImageRenderer.measure` uses `canvas.width * block.boxWidth` as the wrap
  constraint instead of the hardcoded `0.9`. Height continues to auto-grow with
  the wrapped lines.
- The background box (when enabled) continues to hug the wrapped text — `boxWidth`
  controls the wrap frame, not the background fill.
- `TextCanvasOverlay` gains left/right drag handles. Dragging is **center-anchored
  / symmetric**: moving a side handle changes the half-width, so the block stays
  centered on `centerX`. Live updates call a new `setTextBoxWidth(_:commit:false)`;
  the gesture end commits. `boxWidth` is clamped to a sane range (e.g. `0.05…1.0`).

### #5 — Auto-wrap toggle

- A toggle in the text tool group bound to `autoWrap`, default on.
- Renderer: when `autoWrap` is true, wrap to `canvas.width * boxWidth`. When false,
  measure with `width = .greatestFiniteMagnitude` — no soft wrapping; only explicit
  `\n` breaks lines. `boxWidth` is ignored for wrapping while off.
- Overflow behavior when off (per decision): long single lines **extend naturally**
  and may exceed the canvas edges. No clipping logic.

### #6 — Inline editing in the tool group, selection-driven

- Remove the popover editor (`textEditorPopover`) and the canvas
  double-click-to-edit path.
- The text tool group renders an inline `CaptionTextEditor` bound to the selected
  block's text, shown **only when a text block is selected**, hidden otherwise.
- Timeline block tap → `selectTextBlock(id)` only (was `beginEditingText`).
- `TextCanvasOverlay` keeps: selection box, drag-to-move, and the new resize
  handles. It no longer hosts any text input.
- Editing state simplifies: drive editor visibility off `selectedTextBlockID` and
  drop `editingTextBlockID` gating from the click flow. Keep the live
  `setText(_:for:)` (commit: false) + `commitTextEdit()` on submit/blur so typing
  still coalesces into a single undo step.

## Testing

Pure-helper unit tests (swift-testing), matching the existing style:

- `TextImageRenderer` wrap width honors `boxWidth` (narrower `boxWidth` →
  more/taller wrapping for the same text).
- `autoWrap = false` produces a single line for text with no `\n` (width grows,
  height stays one line) regardless of `boxWidth`.
- `addTextBlock` inherits `lastTextStyle` (font, color, box, position, `boxWidth`,
  `autoWrap`) while resetting `text`, `id`, and the time span.
- px ↔ fraction conversion round-trips through `renderSize.height`.

## Files touched

- `Sources/CaptureStudio/ProjectBundle/EditState.swift` — `boxWidth`, `autoWrap`.
- `Sources/CaptureStudio/Studio/StudioModel.swift` — `lastTextStyle`, template in
  `addTextBlock`, lowered clamp, `setTextBoxWidth`, editing-state simplification.
- `Sources/CaptureStudio/Studio/StudioWindow.swift` — px Size row, inline editor in
  the tool group, `autoWrap` toggle, remove popover editor.
- `Sources/CaptureStudio/Studio/TextImageRenderer.swift` — `boxWidth` / `autoWrap`
  wrap logic.
- `Sources/CaptureStudio/Studio/TextCanvasOverlay.swift` — resize handles, remove
  double-click edit.
- `Sources/CaptureStudio/Studio/TextTimelineLane.swift` — tap selects (not edits).

## Out of scope

- Cross-session persistence of `lastTextStyle`.
- Per-corner / height box resizing (width only for now).
- Clipping text to the box when auto-wrap is off.
