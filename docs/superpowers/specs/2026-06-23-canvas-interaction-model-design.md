# Canvas interaction model — design

Date: 2026-06-23
Status: approved design, pending implementation plan

## Goal

Refine how the Studio preview canvas responds to clicks, drags, and scrolls so
each input has one clear job:

1. Click an unselected text box on the canvas to select it (like a timeline tap).
2. Move/pan the reframed video only via an explicit toggle button (not an
   always-on drag).
3. When nothing is selected and pan-video mode is off, a left-drag navigates the
   canvas (pans the zoomed inspection view); timeline scrubbing moves to
   horizontal scroll.

## Background (current state)

- `StudioWindow.canvas` stacks, bottom→top: `PlayerView`, a `Color.clear` tap
  layer that deselects, `CropPanOverlay` (drag-pans the reframe whenever
  `cropPannable`), `CameraPipOverlay`, `TextCanvasOverlay` (only when a block is
  selected), `ReelsSafeAreaOverlay`. `CanvasEventCatcher` sits on top with
  `hitTest → nil`, catching trackpad scroll / pinch / middle-drag for inspection
  pan+zoom and passing clicks through.
- `cropPannable == hasReframeCanvas == (cropAspect != .original)`.
- `TextCanvasOverlay` renders only for the already-selected block, so an
  unselected box on the canvas cannot be clicked to select.
- `CanvasEventCatcher` scroll, when `canvasZoomed`, pans the inspection view on
  BOTH axes; ⌘-scroll zooms.

## Design

### New state

`StudioModel.panVideoMode: Bool` — `@Published`, default `false`, **not persisted**
(transient UI mode). Reset to `false` whenever the reframe stops being pannable
(aspect set back to original).

### Left-drag arbitration (canvas ZStack z-order, top wins)

Top→bottom:

1. `CropPanOverlay` — **mounted only while `panVideoMode`**, on top, hit-testing
   enabled. Drag pans the video/crop. Mode wins all drags in the video rect.
2. `TextCanvasOverlay` — the selected block's move/resize handles.
3. `CameraPipOverlay` — the camera PiP drag.
4. `TextSelectHitLayer` (new) — invisible tap targets for every block visible at
   the playhead; a tap selects it.
5. `CanvasNavigationLayer` (new, replaces the bare `Color.clear`) — bottom-most:
   tap deselects; left-drag pans the inspection view (no-op at fit zoom).

So: pan-video mode (if on) wins; else a selected block's handles win on the
block; else a tap on a visible box selects it; else a tap deselects and a drag
navigates.

### Click-to-select text (#1)

`TextSelectHitLayer` renders one transparent, tappable rect per block in
`TextTimeline.active(at: currentTime)`, positioned/sized like the
`TextCanvasOverlay` box (`TextImageRenderer.size` × `viewScale`, centered on the
block). Rendered in array (z) order, so for overlapping boxes the topmost is
frontmost and wins the tap (SwiftUI hit-tests front-to-back). The tap calls
`selectTextBlock(id)` — identical to a timeline tap. Active only while
`panVideoMode` is off (the pan overlay covers the video rect when on).

### Pan-video toggle (#2)

A `.button`-style `Toggle` bound to `panVideoMode` in the **reframe** tool group,
`disabled` unless `cropPannable`. Icon `hand.draw`. Setting the aspect back to a
non-pannable one resets `panVideoMode = false`.

### Timeline scrub = horizontal scroll (#3)

In `CanvasEventCatcher`'s `.scrollWheel`, decide by dominant axis:

- ⌘-scroll → zoom (unchanged).
- `|deltaX| > |deltaY|` → scrub: `seek(to: scrubbedTime(...))`. A full
  canvas-width worth of scroll spans the whole clip duration. Works at any zoom.
- else, when `canvasZoomed` → vertical inspection pan (`deltaY` only).
- else → pass the event on.

`StudioModel.scrubbedTime(from:scrollDX:viewWidth:duration:)` is a pure, clamped
function: `current - (dx / viewWidth) · duration`, clamped to `[0, duration]`.
With macOS natural scrolling, swipe-left (`dx < 0`) advances time; swipe-right
rewinds. Sign is a one-line flip if the feel is wrong.

### Left-drag inspection pan (#3, "navigation")

`CanvasNavigationLayer` adds a `DragGesture(minimumDistance: 2,
coordinateSpace: .global)` whose incremental delta drives `model.panCanvas(by:)`
(content follows the cursor), mirroring the existing middle-drag pan. Global
space avoids feedback from the inspection transform. No-op at fit zoom.

## Testing

- `StudioModel.scrubbedTime(...)` — pure: direction, proportionality, clamping at
  both ends (swift-testing unit test).
- Everything else (gesture wiring, ZStack order, the two new SwiftUI layers, the
  toggle button) is UI glue: `swift build` + manual smoke, per project
  convention.

## Files

- `Sources/CaptureStudio/Studio/StudioModel.swift` — `panVideoMode`,
  `scrubbedTime`, reset-on-aspect-change.
- `Sources/CaptureStudio/Studio/CanvasNavigationLayer.swift` (new) — tap-deselect
  + drag-pan-inspection.
- `Sources/CaptureStudio/Studio/TextSelectHitLayer.swift` (new) — click-to-select.
- `Sources/CaptureStudio/Studio/CropPanOverlay.swift` — always hit-test (now
  mounted only in pan mode).
- `Sources/CaptureStudio/Studio/StudioWindow.swift` — canvas ZStack restructure;
  reframe toggle button.
- `Sources/CaptureStudio/Studio/CanvasEventCatcher.swift` — horizontal-scroll
  scrub.
- `Tests/CaptureStudioTests/...` — `scrubbedTime` unit test.

## Out of scope

- Cycling through overlapping boxes on repeated clicks (topmost only).
- Drag-to-scrub (replaced by horizontal scroll).
- Persisting `panVideoMode` across sessions.
- Changing the trackpad pinch / ⌘-scroll zoom behavior.

## Dependency note

Two verified-but-uncommitted bug fixes (stale text-cache key; frame-aligned
caption seek; 134 tests green) sit in the working tree. They must be committed
before this work begins so task commits stay clean.
