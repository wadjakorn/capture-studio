# Studio UI redesign — Screen Studio–style shell

**Date:** 2026-07-07
**Status:** Approved design, ready for implementation planning
**Scope:** View-layer refactor of the Studio editor only. No engine, model-logic,
or file-format changes.

## Problem

The Studio editor is functional but hard to use. Prioritized by the user:

1. **Layout / hierarchy** — every control lives in one dense, wrapping bottom bar
   (`StudioWindow.swift` `controlBar`, ~line 160–228). Global settings, per-object
   settings, transport, and export all share the same visual weight and reflow
   unpredictably on resize. Nothing has a fixed home.
2. **Discoverability** — icon-only, tooltip-gated controls. `slider.horizontal.3`
   appears 4+ times meaning four different style popovers; `trash` appears 4×.
   Editable properties are hidden inside popovers. Selection state is invisible.
3. **Timeline** — up to 7 thin stacked lanes with a cryptic icon gutter, a 6px
   scrubber, and lanes that appear/disappear as content changes.

## Goal

Rebuild the editor UI to mirror Screen Studio's layout (per user-supplied
screenshots): a top app bar, a canvas toolbar, a stage with a category **rail +
inspector** on the right, and a transport + timeline at the bottom. Relocate all
existing controls into this structure. Render the full shell — including tabs and
controls for features we don't have yet — using disabled **placeholders**, so the
UI looks complete and future features slot in without re-layout.

## Non-goals (explicitly out of scope this pass)

- No changes to `CameraCompositor`, `Exporter`, or any render/export logic.
- No changes to `StudioModel` state/logic, timeline-block models, crop/frame math,
  event mapping, or the `.capturestudio` format.
- **No new backend features.** Every gap is a visual placeholder only.
- **No audio-waveform rendering** — the timeline audio lane is restyled as a flat
  clip bar; real waveform drawing is a separate future feature (skipped for now).
- No multi-clip/cut, clip speed, background music, cursor smoothing, or mic DSP.

Because model logic does not move, the existing **109 tests must stay green** with
no modification. This is a pure SwiftUI view refactor.

## Architecture

### Four zones

```
┌───────────────────────────────────────────────────────────┐
│ APP BAR:  file · undo/redo · Presets(ph) · preview(ph) · Export │
├───────────────────────────────────────────────────────────┤
│ CANVAS TOOLBAR (centered):   Auto ▾   ·   Crop   ·   Mask       │
├──────────────────────────────────────┬──────┬──────────────┤
│                                       │ RAIL │  INSPECTOR    │
│              STAGE (canvas,           │  ▣   │  (tab panel   │
│              unchanged overlays)      │  ➤   │   for the     │
│              ＋ insert menu           │  👤  │   active rail │
│                                       │  💬  │   tab)        │
│                                       │  🔊  │              │
│                                       │  ⌘   │              │
│                                       │  ⑂   │              │
├──────────────────────────────────────┴──────┴──────────────┤
│ TRANSPORT:  timelines ▾ · ⏮ ▶ ⏭ · ✂ · 1× · zoom            │
├───────────────────────────────────────────────────────────┤
│ TIMELINE: ruler + lanes (restyled dark) + zoom lane          │
└───────────────────────────────────────────────────────────┘
```

1. **App bar** — filename (existing `navigationTitle`), undo/redo (placeholder —
   no undo system today), Presets (placeholder), preview/speed (placeholder),
   **Export** (relocated real export + reveal-masters).
2. **Canvas toolbar** — `Auto ▾` = camera/frame layout picker (real); `Crop` =
   reframe/aspect entry (real); `Mask` = routes to the existing shape/blur overlay
   tool, relabeled (no new feature).
3. **Stage** — the current `canvas(player:)` ZStack is reused verbatim; all
   overlays (`PlayerView`, `CameraPipOverlay`, `TextCanvasOverlay`, hit layers,
   `ReelsSafeAreaOverlay`, etc.) stay. A `＋` insert menu adds text/shape/zoom/
   camera-move/layout blocks (relocated add-block actions).
4. **Right rail + inspector** — 7 category icons; the active tab renders its panel
   inline (no popovers). See mapping below.
5. **Transport + timeline** — relocate transport (play/pause, timecode) and trim;
   keep the existing multi-lane timeline and per-lane views, restyled dark and
   thicker to match. Audio lane is a flat styled bar (no waveform).

### Rail tabs → panels

Each tab is its own SwiftUI view file. Bindings point at the **existing**
`StudioModel` members — the panels are new containers around current controls.

| Tab | Real controls (relocated) | Placeholders (disabled, "Soon") |
|-----|---------------------------|----------------------------------|
| **▣ Frame** | aspect (`setCropAspect`), crop-zoom, pan (`panVideoMode`), framing window (`frameEnabled`/`frameEditMode`/`resetFrame`), background (black/blur/photo + blur amount), reels guide (`templateGuideVisible`) | wallpaper/gradient presets |
| **➤ Cursor** | show cursor (`showCursor`), click rings (`clickFeedback`) | size, smoothing, click style |
| **👤 Camera** | layout picker + layout blocks (`addLayoutBlock`/`removeLayoutBlock`), camera position/size/roundness/shape/aspect/border/shadow/rotation (the `cameraStylePopover` contents), camera-move blocks (`addBlock`/`removeBlock`) | — |
| **💬 Captions** | subtitle import/remove/style/offset (`subtitleStylePopover`), text blocks (add/style/z-order/delete + inline caption) | auto-transcription |
| **🔊 Audio** | system volume, mic volume | improve mic, stereo mode, background music |
| **⌘ Shortcuts** | — | key-overlay preview + toggle (whole tab is placeholder) |
| **⑂ Share** | export presets (`ExportPreset`), reveal masters | share targets, upload |

### Selection ↔ category coexistence

The rail holds **7 persistent global categories**. Objects that are *created* on
the timeline/canvas get **contextual inspector panels** that appear on selection,
not permanent rail tabs. Two kinds of object→panel routing:

- **Rail-backed objects** — selecting a text block, subtitle, camera-move, or
  layout block auto-switches the rail to its home tab (Captions / Camera) and the
  panel shows that block's properties.
- **Contextual-only objects** — **shapes** and **zoom blocks** have no rail tab.
  They are added from their natural affordance (the **Mask** canvas tool for
  shapes; the styled **zoom lane** for zoom) and, when selected, their inspector
  panel appears contextually (replacing the active tab's panel until deselected).

Both are driven by existing `selected*BlockID` state on `StudioModel` via
`onChange`; no model changes required. With nothing selected, a rail tab shows its
global/default controls.

**Resolved routing (previously deferred):**
- **Shapes → Mask tool + contextual Shape panel.** The `Mask` canvas-toolbar
  button is the add affordance (menu: rectangle / ellipse / blur). Selecting any
  shape opens a contextual **Shape** inspector (kind, fill, outline, corner
  radius, blur style/strength). Keeps rail parity at 7; "Mask" is the entry point,
  the panel is titled "Shape" so decorative rects don't read as masks.
- **Zoom → own contextual panel via the zoom lane.** The styled timeline zoom lane
  ("Click or drag to add zoom on cursor") is the add/select affordance; selecting
  a zoom block opens a contextual **Zoom** inspector (scale, sensitivity,
  overflow). Mirrors Screen Studio's timeline-driven zoom exactly; not folded into
  the Camera tab.

### Placeholder pattern

A single reusable modifier/wrapper, e.g. `.comingSoon()`, renders a control at
normal styling but `.disabled(true)` with a small "Soon" tag and a tooltip. Used
for every gap so placeholders read as intentional, never broken. One helper, one
consistent look.

### File split (addresses the 1405-line `StudioWindow.swift`)

Split the monolith as part of this refactor:

```
Studio/
  StudioView.swift            // shell: zones, layout, load states (small)
  StudioAppBar.swift          // top bar
  StudioCanvasToolbar.swift   // Auto / Crop / Mask
  StudioTransportBar.swift    // transport + trim + zoom controls
  Inspector/
    InspectorRail.swift       // the 7-icon rail + active-tab state
    FrameInspector.swift
    CursorInspector.swift
    CameraInspector.swift     // absorbs cameraStylePopover
    CaptionsInspector.swift   // absorbs subtitle + text popovers
    AudioInspector.swift
    ShortcutsInspector.swift  // placeholder tab
    ShareInspector.swift      // export
    ShapeInspector.swift      // contextual (absorbs shapeStylePopover); via Mask tool
    ZoomInspector.swift       // contextual (absorbs zoomStylePopover); via zoom lane
  InspectorPlaceholder.swift  // .comingSoon() helper + shared style rows
```

Shared helpers currently private to `StudioView` (`styleSlider`, `textColorRow`,
`borderColorControls`, `volumeSlider`, popover height plumbing) move to a shared
file so each inspector can use them. The `canvas(player:)` stage view and the
timeline lane wiring move into `StudioView`/timeline files unchanged.

## Data flow

Unchanged. Every panel binds to the same `StudioModel` published members it does
today. The only new view state is:
- active rail tab (enum, `@State` on the shell)
- auto-switch-on-selection wiring (`onChange` of `selected*BlockID`)

No new model, no persistence changes, no format changes.

## Error handling

Inherits current behavior: `.loading` / `.failed` / `.ready` load states unchanged;
export lock (`isExporting` disabling + `StudioWindowCloseGuard`) reapplied to the
new layout (rail + inspector + timeline disabled during export; app-bar Export/Stop
group stays live).

## Testing

- Existing 109 tests must pass unchanged (no model logic moved).
- `swift build` clean.
- Manual verification checklist: every relocated control reachable and functional;
  export lock still disables the editor; selection auto-switches tabs; placeholders
  are disabled and labeled.

## Control-migration checklist (nothing may be dropped)

Every control in today's `StudioWindow.swift` maps to a new home. Implementation
must account for each row.

- [ ] Play/pause + timecode (`transportControls`) → Transport bar
- [ ] Set In / Set Out / reset trim / apply trim / trim range (`trimControls`) → Transport bar
- [ ] Reveal masters in Finder (`outputControls`) → Share tab
- [ ] Export menu / progress / cancel / done / failed (`exportControls`) → App bar Export
- [ ] System volume slider (`audioControls`) → Audio tab
- [ ] Mic volume slider (`audioControls`) → Audio tab
- [ ] Reframe aspect menu (`reframeControls`) → Frame tab (+ Crop toolbar entry)
- [ ] Pan-video toggle → Frame tab
- [ ] Reels safe-area toggle → Frame tab
- [ ] Framing-window enable / edit-mode / reset → Frame tab
- [ ] Crop-zoom slider → Frame tab
- [ ] Background menu (black/blur/photo) + blur amount + delete photo (`backgroundControls`) → Frame tab
- [ ] Layout picker (`cameraControls`) → Camera tab (+ Auto toolbar entry)
- [ ] Add / remove layout block → Camera tab
- [ ] Camera style popover (zoom, shape, aspect, corner radius, border, border color, shadow, rotation) → Camera tab
- [ ] Add / remove camera-move block → Camera tab
- [ ] Add text block, text style popover, z-order, delete, inline caption editor (`textControls`) → Captions tab
- [ ] Add shape (rect/ellipse/blur), shape style popover, z-order, delete (`shapeControls`) → Mask canvas tool (add) + contextual Shape inspector (edit)
- [ ] Add zoom block, zoom style popover (scale, sensitivity, overflow), delete (`zoomControls`) → zoom lane (add/select) + contextual Zoom inspector (edit)
- [ ] Subtitle import / style popover / offset / remove (`subtitleControls`) → Captions tab
- [ ] Show cursor + click feedback toggles (`cursorControls`) → Cursor tab
- [ ] Canvas zoom badge / reset (`zoomBadge`) → stays on stage (unchanged)
- [ ] Deselect-on-tap / Esc handling → stays on shell (unchanged)
- [ ] Export lock (`isExporting`) → reapplied to new zones

## Placeholder inventory (render disabled, "Soon")

- App bar: Presets, preview toggle, speed/quality, undo/redo
- Frame tab: wallpaper/gradient backgrounds
- Cursor tab: size, smoothing, click style
- Audio tab: improve mic audio, stereo mode, background music (genres + tracks)
- Shortcuts tab: entire tab (key-overlay preview + enable toggle)
- Share tab: share/upload targets

## Risks

- **Large view rewrite.** Mitigated by the migration checklist — every existing
  control has a named destination; nothing is invented or dropped.
- **Behavior drift.** Bindings must be rewired verbatim. Verify each control still
  mutates the same `StudioModel` member.
- **Export-lock regression.** Re-verify the editor locks during export in the new
  layout, and the Stop control stays reachable.
```
