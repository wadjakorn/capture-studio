# Studio camera + text control-bar restructure — design

Date: 2026-06-20
Status: approved (design)

## Goal

Tidy the Studio control bar: separate global camera *style config* from camera
*motion actions*, fix the dead global camera on/off toggle, and make the text
tools consistent + non-clipping. Pure editor-UI work — no capture, no schema,
no motion-math changes.

## Scope

### In
- Fix the global camera show/hide toggle so it actually hides/shows the camera
  in the canvas and hides the camera timeline lane (block data preserved).
- Restructure camera controls into three units: on/off toggle, one style
  dropdown, one motion action group.
- Move the camera feed-zoom slider into the style dropdown.
- Text tools: add a `+` affordance to the add-text button; always show the text
  style dropdown (disabled when no block selected); fix the text style popover
  horizontal overflow.

### Out (explicitly not in this change)
- No change to `CameraTimeline.sample` easing / motion math.
- No persistence / `EditState` schema change (`CameraBlock.visible` already exists).
- No new camera shapes / aspects / zoom ranges.
- No timeline drag-behavior redesign.
- The per-block eye visibility toggle is **removed**, replaced by a hide-insert
  action (behavior change, accepted).

## Current behavior (for reference)

- `StudioModel.buildVideoComposition` computes
  `cameraShown = cameraTrackID != nil && (cameraVisible || cameraHasTimeline)`.
  When blocks exist, `cameraHasTimeline` forces the camera on, so toggling
  `cameraVisible` does nothing. The camera lane row is gated on
  `cameraHasTimeline` alone, also ignoring the toggle.
- `cameraStylePopover` bundles style config (shape/rotate/aspect/corner/border/
  shadow) together with a "Camera motion" section (add / delete / per-block eye
  toggle).
- The camera feed-zoom slider lives inline in the toolbar, only shown while
  `cameraVisible`.
- Text add button is icon-only (`textformat`); the text style dropdown button is
  shown only `if selectedTextBlock != nil`; the text style popover is
  `frame(width: 248)` and clips its content horizontally (swatch rows exceed the
  content width, cutting the first letters of "Size" / "Color" / "Outline").

## Design

### 1. Camera toggle fix

- `buildVideoComposition`: `cameraShown = cameraTrackID != nil && cameraVisible`
  (drop `|| cameraHasTimeline`).
- `showsCameraOverlay`: add `guard cameraVisible else { return false }` so the
  interactive PiP box also hides.
- New computed `var showsCameraTimeline: Bool { cameraVisible && cameraHasTimeline }`.
  The camera lane row in `StudioView.controlBar` gates on it instead of
  `cameraHasTimeline`.
- Net: OFF → camera gone from canvas, lane hidden, blocks retained; ON → restored.
  No data loss, re-toggle is symmetric.

### 2. Camera controls layout

`cameraControls` becomes three units inside the existing camera tool group:

1. `video.circle` on/off toggle — always enabled (the fix above).
2. **Style dropdown** (`slider.horizontal.3` button → popover) — disabled when
   camera is off. Popover = the old `cameraStylePopover` minus its "Camera
   motion" section, plus the zoom slider moved in. Contents: zoom, shape, rotate,
   aspect (rectangle only), corner radius (rectangle only), border (+ color when
   > 0), shadow (+ radius when on).
3. **Action group** (inline buttons) — disabled when camera is off:
   - **Add move** — always enabled. Calls existing `addBlock()` (inserts a
     visible block at the playhead, auto-placed to avoid overlap).
   - **Delete** — enabled only when a camera block is selected. Calls
     `removeBlock(selectedBlockID)`.
   - **Hide** — always visible; disabled when the playhead sits strictly inside
     an existing block (`begin <= t < end`). Calls new `addHideBlock()`, which
     inserts a `visible=false` block at the playhead.

Per the "Show but disabled" decision, when the camera is toggled off the style
dropdown and the whole action group stay visible but disabled; only the on/off
toggle remains live.

### 3. StudioModel additions

- `var blockAtPlayhead: CameraBlock? { cameraBlocks.first { $0.begin <= currentTime && currentTime < $0.end } }`
- `func addHideBlock()` — mirror `addBlock()` but force the placement opacity to
  0 so `CameraTimeline.add` produces a `visible=false` block:
  ```
  let t = min(max(currentTime, 0), duration)
  var p = sampledCameraState(at: t); p.opacity = 0
  let added = CameraTimeline.add(cameraBlocks, atTime: t,
                                 width: Self.defaultBlockWidth,
                                 duration: duration, placement: p)
  setBlocks(added.blocks, select: added.id)
  ```
- The per-block `toggleBlockVisible` may remain on the model (harmless) but is no
  longer wired to the UI.

### 4. Text controls

- Add-text button icon → `text.badge.plus`.
- Text style dropdown button: always rendered, `.disabled(selectedTextBlock == nil)`.
- Text style popover overflow fix: the popover content is wider than its 248pt
  frame because the color-swatch rows (8 swatches + spacing + ColorPicker ≈ 226pt
  vs ~220pt available) overflow and the frame center-clips. Fix by widening the
  popover and letting swatch rows wrap (reuse `FlowLayout`) so every label and
  swatch renders within the frame.

## Testing

- UI glue stays untested per project convention.
- Pure logic is already covered: `CameraTimeline.add` overlap behavior is
  unit-tested. Optionally add a small model-level check that `addHideBlock`
  produces a `visible == false` block; keep minimal.
- Manual verification: build app, open a recording, confirm (a) toggle hides
  both canvas camera and lane and restores them, (b) style dropdown holds zoom +
  all style config, (c) Add move / Delete (selection-gated) / Hide
  (overlap-gated) behave as specified, (d) text add button shows `+`, text style
  dropdown is always present and disabled with no selection, (e) the text style
  popover no longer clips its labels.

## Files touched

- `Sources/CaptureStudio/Studio/StudioModel.swift` — toggle/overlay/lane gating,
  `blockAtPlayhead`, `addHideBlock`.
- `Sources/CaptureStudio/Studio/StudioWindow.swift` — camera controls split,
  zoom into dropdown, action group, text button + dropdown + popover overflow.
