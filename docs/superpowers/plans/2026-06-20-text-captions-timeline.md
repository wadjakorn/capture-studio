# Implementation plan — text / captions timeline

**Design:** [`specs/2026-06-20-text-captions-timeline-design.md`](../specs/2026-06-20-text-captions-timeline-design.md)
**Date:** 2026-06-20

Six phases, each independently buildable + verifiable. Phases 1–3 ship a working
renderer with no editing UI (drive it by adding a block programmatically) so the
hard part (model + compositing + overlap) is proven before any UI. Phases 4–6
add the timeline lane, canvas WYSIWYG editing, and the style bar.

Keep `swift build` / `swift test` green at every phase (currently 45 tests). Do
not bump the swift-testing / KeyboardShortcuts pins (CLT toolchain constraint).

---

## Phase 1 — Model + pure math + persistence (no UI)

**Goal:** `TextBlock` exists, persists, and `TextTimeline` math is unit-tested.

### Files
- `ProjectBundle/EditState.swift`
- `Studio/TextTimeline.swift` (new)
- `Tests/CaptureStudioTests/TextTimelineTests.swift` (new)

### Steps
1. Add supporting enums (Codable, with a default case for forward-compat decode):
   `TextWeight` (regular/medium/semibold/bold), `TextAlignmentH`
   (leading/center/trailing), `TextSource` (manual/systemAudio/microphone).
2. Add `struct TextBlock: Codable, Equatable, Identifiable` with the fields in
   the design. Provide a memberwise `init` with defaults (matching the
   `CameraBlock` init style) and a `static func makeDefault(at:duration:)` that
   produces the empty 3 s block centered at (0.5, 0.85) — lower-third default —
   in a readable default style (`source: .manual`).
3. Add `var textBlocks: [TextBlock] = []` to `EditState` (and to its memberwise
   `init` parameter list, matching how `cameraBlocks` is threaded). Do **not**
   bump `schemaVersion` — additive field, older bundles decode `[]`.
4. New `enum TextTimeline` (pure, mirrors `CameraTimeline`):
   - `active(at:blocks:) -> [TextBlock]` — `begin <= t < end`, preserve array order.
   - `add(_:atTime:width:style:) -> (blocks:[TextBlock], id:UUID)` — append
     `[t, min(t+width, duration)]`, clamp to `[0, duration]`, **no neighbor clamp**.
   - `moveBegin/moveEnd/moveBlock(_:id:toTime/toBegin:duration:)` — clamp to
     `[0, duration]` and `begin <= end`; no neighbor clamp.
   - `remove(_:id:)`.
   - `bringForward/sendBackward/moveToFront/moveToBack(_:id:) -> [TextBlock]`.
   - `subRows(_:) -> [[TextBlock]]` — greedy packing (sort by begin; first row
     whose last `end <= begin`).
5. Tests in `TextTimelineTests.swift` (see design "Testing"). Cover overlap
   explicitly (the camera tests assert non-overlap; these assert the opposite).

### Verify
`swift build && swift test` — new tests pass, existing 45 still green. Round-trip
an `EditState` with `textBlocks` through `JSONEncoder`/`Decoder` in a test;
decode a JSON blob with **no** `textBlocks` key and assert it yields `[]`.

---

## Phase 2 — StudioModel state + ops (no UI)

**Goal:** the model owns text blocks, mutates them through `TextTimeline`, marks
the bundle dirty, and feeds the compositor — verifiable by unit-testing the
model ops and by a temporary debug "add text" action.

### Files
- `Studio/StudioModel.swift`

### Steps
1. Add `@Published var textBlocks`, `@Published var selectedTextBlockID`,
   `@Published var editingTextBlockID`. Load `textBlocks` from `edit.json` on
   open (store verbatim — do **not** sort; z-order is array order).
2. Ops, each: mutate via `TextTimeline`, set dirty flag, trigger
   `buildCompositorComposition()` rebuild (mirror the camera-block ops at
   `StudioModel.swift:538–579`):
   - `addTextBlock()` — insert default 3 s block at `currentTime`, select it.
   - `removeTextBlock(_:)`, `moveTextBlock(_:toBegin:)`,
     `moveTextBlockBegin/End(_:toTime:)`, `commitTextEdit()`.
   - `setText(_:for:)`, `setTextPosition(_:for:)`, `setTextStyle(...)`.
   - `bringTextForward/sendTextBack/...`.
   - `selectTextBlock(_:)` — sets `selectedTextBlockID` and **clears
     `selectedBlockID`** (camera) for mutually-exclusive selection; the reverse
     in `selectBlock`.
3. Leave compositor wiring as a stub call this phase (Phase 3 fills
   `TextTimelineSpec`), or land Phase 3 immediately after.

### Verify
`swift build && swift test`. Optionally a throwaway menu/debug button that calls
`addTextBlock()` to confirm state updates (remove before commit).

---

## Phase 3 — Compositor rendering (static, no editing UI)

**Goal:** active text blocks render into the preview **and** the export, with
correct z-order and overlap. Proven before any editing UI exists.

### Files
- `Studio/CameraCompositor.swift`
- `Studio/StudioModel.swift` (`buildCompositorComposition`)

### Steps
1. Add `struct TextTimelineSpec { var blocks: [TextBlock] }`; add
   `var textTimeline: TextTimelineSpec?` to `CompositorLayout`. Populate it in
   `buildCompositorComposition()` from `model.textBlocks`.
2. In `startRequest`, after cursor (`CameraCompositor.swift:256–259`), composite
   text topmost:
   ```
   if let spec = layout.textTimeline {
       for block in TextTimeline.active(at: now, blocks: spec.blocks) {
           if let img = textImage(block, canvas: layout.canvas) {
               output = img.composited(over: output)
           }
       }
   }
   ```
   (array order = z-order; later blocks composite last = on top).
3. `private func textImage(_ block: TextBlock, canvas: CGSize) -> CIImage?`:
   - Build an `NSAttributedString` (or Core Text run) with font (name/weight/
     `fontSize * canvas.height`), foreground color, paragraph alignment, stroke
     (`strokeWidth * fontSize`, stroke color), and shadow if enabled.
   - Measure, draw into a `CGContext` of that size (bitmap, sRGB), optionally
     fill a rounded box behind the text (`boxHex`/`boxOpacity`) with padding.
   - `CGImage` → `CIImage`, translate to the canvas position from
     `centerX/centerY` (use the same y-flip helper, `Self.flip`, the camera path
     uses). Clamp/position within the canvas.
   - **Core Text + CGContext only** — no SwiftUI, no `CATextLayer` main-thread
     dependency (CLT build + off-main compositor).
4. **Cache:** memoize by `(text, style-hash, canvasSize)`; reuse across frames
   (held caption = render once). Mirror the `decorations(for:)` reuse pattern.

### Verify
`scripts/build-app.sh debug`; relaunch. With a temporary `addTextBlock()` +
`setText`, scrub the playhead: text appears only within `[begin, end)`. Add two
**overlapping** blocks: both show; reorder and confirm top block wins. Export
(`Exporter`) and confirm the text is baked into the output file identically to
the preview.

---

## Phase 4 — Timeline lane UI (dynamic auto-stack)

**Goal:** a text track under the camera lane: add / select / drag / resize, with
overlap allowed and dynamic capped sub-rows.

### Files
- `Studio/TextTimelineLane.swift` (new, cloned from `CameraTimelineLane.swift`)
- `Studio/StudioWindow.swift` (stack the lane; add the "+ Text" button)

### Steps
1. Clone `CameraTimelineLane` → `TextTimelineLane`. Replace block ops with the
   text ops (overlap-allowed). Keep the same edge/body/scrub gesture structure
   (`CameraTimelineLane.swift:114–149`).
2. Sub-row layout: `let rows = TextTimeline.subRows(model.textBlocks)`. Lane
   height = `rowHeight * min(rows.count, cap) + spacing`. Render each block at
   its sub-row's y. Past `cap` (≈3) wrap the lane body in a vertical
   `ScrollView`. One row when nothing overlaps.
3. Block body shows truncated `block.text`. Tap → `selectTextBlock`;
   double-click → set `editingTextBlockID` (Phase 5 consumes it).
4. Add the lane to the Studio timeline column under the camera lane. Add a
   "+ Text" button that calls `addTextBlock()`.

### Verify
`build-app.sh debug` + relaunch. Add several sequential blocks → stays one row.
Drag two to overlap → lane grows to 2 rows, collapses when separated. Drag/
resize/select all work; resize permits overlap (no neighbor snap).

---

## Phase 5 — Canvas WYSIWYG editing overlay

**Goal:** position and type text where it appears on the preview.

### Files
- `Studio/StudioWindow.swift` (preview overlay layer)

### Steps
1. Add a SwiftUI overlay aligned to the preview view's rect (reuse the PiP
   normalized→pixel mapping). It is a layer **on top of** the
   `NSViewRepresentable` preview — never a `VideoPlayer` (CLT SIGABRT note).
2. For the selected text block whose span contains the playhead: show a move
   affordance at `centerX/centerY`; drag → `setTextPosition`.
3. Double-click (or `editingTextBlockID` set from the lane) → positioned
   `TextField`/`TextEditor`; commit → `setText`, clear `editingTextBlockID`.
4. While `editingTextBlockID` is set, **suppress that block in the compositor
   preview** (filter it out in `buildCompositorComposition` or pass an
   `editingTextBlockID` through the spec) to avoid a doubled image. Export is
   unaffected.

### Verify
`build-app.sh debug` + relaunch. Double-click a block's text on the canvas →
type → commit → updates in lane + preview. Drag the text → position updates and
matches the exported position. No double-render while editing.

---

## Phase 6 — Style bar

**Goal:** edit font/size/weight/color/box/alignment/stroke/shadow for the
selected block.

### Files
- `Studio/StudioWindow.swift` (or a small `TextStyleBar.swift`)

### Steps
1. When a text block is selected, show the style bar (reuse inspector styling;
   show camera PiP controls vs. text style bar based on which selection is
   active).
2. Wire each control through `setTextStyle(...)`. Color via the existing hex
   convention (`"#RRGGBB"`, as camera border uses).
3. Live-update preview on each change (model is `@Published` → compositor
   rebuild already wired).

### Verify
`build-app.sh debug` + relaunch. Change each control; preview + export reflect
it. Toggle box/stroke/shadow and confirm legibility over a busy frame.

---

## Sequencing / risk notes

- **Land 1→3 first.** They de-risk the whole feature (overlap model + off-main
  Core Text compositing + export parity) with zero UI. If anything is going to
  be hard, it's here.
- **Z-order = array order** is the easiest thing to regress: never sort
  `textBlocks` on store. Sort only local copies for lane packing / `active`.
- **Export parity:** the compositor is the single source of truth for both
  preview and export; the canvas overlay is editing chrome only. Verify a real
  exported file in Phase 3 and again in Phase 5.
- **Forward-compat checkpoint:** after Phase 3, adding many `.systemAudio` /
  `.microphone` blocks (the next task's output) should render with no code
  changes. Sanity-check by programmatically injecting a handful of sequential
  caption blocks.

## Out of scope

Auto-caption generation (transcription), word-level timing, animated text
transitions, and any capture/recorder/`DisplayInfo`/host-clock changes. See the
design doc's "Out of scope".
