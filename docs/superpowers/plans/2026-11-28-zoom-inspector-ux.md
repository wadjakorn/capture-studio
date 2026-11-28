# Zoom inspector UX — design and plan

## Intent (user, 2026-11-28)

"Too many buttons, I don't know which to press first or which depend on which."
Rework the zoom + pan + overflow controls so the order of the panel is the
order of the work, and dependencies are visible where they apply. No rush; the
goal is a better UX, zoom only (other inspectors later). Approved direction:
one **Show** choice replaces Mode + "Fit the window" + "When the pointer
leaves". Zooming out below 1× stays parked.

## The panel

```
[✨ Auto zoom]              [+ Add block]     create — always available
(analysis progress + Cancel, when running)
──────────────────────────────────────────
Block 0:12 – 0:19          [Split] [Delete]   only with a block selected
                                               (else: "Select a zoom block on
1 Show                                          the timeline, or press Auto zoom.")
  [ Decide for me ▾ ]
  one line saying what the choice does
2 Zoom
  [ One level | A range ]
  one slider            /  one two-thumb slider  1.5× – 3.0×
  ☐ Make room for menus and pop-ups        (range only)
3 Motion                                    (not for "A fixed spot")
  Calm ────●──── Snappy
4 At the picture's edge                     (not for "A fixed spot")
  [ Stop at the edge | Keep the pointer centred ]
──────────────────────────────────────────
[Use these settings for all blocks]
```

Rules:

- Top to bottom = create → what the block shows → how close → how it moves →
  project-wide.
- A control that does not apply is not shown (fixed spot: no Motion / Edge /
  range). A control that applies but cannot work yet is shown **disabled with
  the reason and the way out next to it**, not as a warning at the bottom.
- Plain names: no "overflow", "sensitivity", "fit", "mode".

### Show

| Choice | Meaning | Model |
|---|---|---|
| Decide for me | The window the pointer works in; a short trip outside shows both, a long one follows the pointer | follow, `show = .auto` |
| The pointer | Follows the pointer wherever it goes | follow, `show = .pointer` |
| The window | Stays on the window; the pointer may leave the picture | follow, `show = .window` |
| Window and pointer | Zooms out enough to keep both in the picture | follow, `show = .both` |
| A fixed spot | Holds one framing you place on the canvas | manual |

"The window" and "Window and pointer" need window data: in a recording without
it they are disabled in the menu, labelled "— needs a recording made with this
version". "Decide for me" always works (without window data it is the pointer).

Choosing "The window" or "Window and pointer" sets the edge behaviour to "Stop
at the edge" and disables that control with the line "The window is kept in the
picture" — the camera cannot both hold a window and run past the edge.

### Zoom

- **One level**: the existing slider.
- **A range**: one two-thumb slider (least / most). The zoom then changes by
  itself inside the block. "Make room for menus and pop-ups" appears here; when
  the video has not been analysed it is disabled with an **Analyse video**
  button beside it (runs the analysis only — no blocks are replaced).
- "A fixed spot" has one level only, plus "Centre on the pointer here".

### Motion / edge

- Motion: the sensitivity slider, labelled Calm … Snappy, no percentage.
- At the picture's edge: Stop at the edge (= overflow off) / Keep the pointer
  centred (= overflow on; the background shows past the edge).

### Use these settings for all blocks

Copies Show, zoom range (or "one level" — not the level itself), Motion and
Edge from this block to every follow block, and makes them what new blocks and
Auto zoom use. From a fixed-spot block only Motion and Edge apply, so the
button reads "Use motion & edge settings for all blocks" there.

## Model changes (the dynamic-zoom work is still uncommitted)

- `ZoomBlock.show: ZoomShow?` — `enum ZoomShow { auto, pointer, window, both }`
  (unknown → auto). Replaces `ZoomLeave`. nil = `.auto` when the block has a
  zoom range, else `.pointer` (so every existing fixed block behaves as today).
- `ZoomAutoScale` keeps `min`, `max`, `fitReveals`; `fitWindow` and `leave`
  are removed (older test projects' keys are ignored by the tolerant decoder).
- `ZoomAutoScaler` works from *effective settings* per follow block:
  `leave = show`, `fitWindow = show != .pointer`, range = the block's range or
  `scale…scale` for one level, `fitReveals` from the range. A block is expanded
  when it has a range **or** `show` is not `.pointer`; so "The window" and
  "Window and pointer" also work at one zoom level (same scale throughout, the
  frame held on the window / on both when both fit at that level).
- `EditState.zoomDefaultShow: ZoomShow?` beside `zoomDefaultAuto`.
- Auto zoom's follow blocks: `show = .auto` + the project's range.

## Tasks

1. Model: `ZoomShow`, `ZoomBlock.show`, slim `ZoomAutoScale`, project default.
   Tests: round trip, nil defaults, legacy keys ignored.
2. Scaler: effective settings; one-level expansion. Update `DynamicZoomTests`
   to `show:`; add: one level + The window holds the pointer; one level +
   Window and pointer holds the union when it fits, follows the pointer when it
   does not; a plain fixed block with `show == nil` is untouched.
3. Suggester / merge / apply-to-all carry `show`.
4. `StudioModel`: `selectedZoomShow` / `setZoomShow` (handles follow ↔ manual
   through the existing `setZoomMode`, forces overflow off for window / both),
   `setZoomRangeEnabled`, `analyseVideoForZoom()` split out of `runAutoZoom`.
5. Inspector rewrite + a small `RangeSlider` view (two thumbs, 0.05 steps).
6. `swift test` (Xcode + CLT), build, launch; independent code review.

## Out of scope

Other inspectors; zoom below 1×; picking the window on the canvas; fitting
content that appears without a click.

## Scrutiny outcome (2026-11-28)

Independent review against the code: fix-then-ship. These replace the text
above where they differ.

- **A range always has something to do, or says why not.** With a range the
  zoom fits the window under the pointer whatever Show is ("The pointer" + a
  range = fit each window, follow the pointer out), and the level used when
  there is nothing to fit is kept inside the range. "A range" is disabled, with
  the reason and an Analyse video button, when the recording has neither window
  data nor an analysed video.
- **Show never rewrites the edge setting.** "The window" / "Window and
  pointer" are treated as contained by the camera itself; the Edge control is
  shown disabled as "Stop at the edge" with the reason, and the user's own
  choice comes back when Show changes. With "Decide for me" + "Keep the pointer
  centred" one line says the frame is then not held to a window.
- **Motion and Edge stay for "A fixed spot"** (both act on it).
- **Show is written explicitly** the first time Show or the zoom kind is
  changed; the nil rule is only for blocks never touched.
- **Switching zoom kind keeps the picture:** range → one level takes the level
  shown at the playhead; one level → range starts from a range that contains
  the level. A fixed spot keeps its range for when it follows again.
- **"Use these settings for all blocks"** also covers blocks added later by
  hand, and "one level" can be the project's setting.
- **After Auto zoom a block is selected** (at the playhead, else the first), so
  the panel never falls back to the empty prompt. "Only this block" moves into
  the block header as **Redo this block**; the top button always means all
  blocks (confirmed when there are blocks to replace). The empty prompt names
  the next step for the state (no blocks: "Press Auto zoom, or add a block").
- Analyse video: says that follow blocks may re-frame toward what clicks open;
  a video that cannot be read shows that instead of the button.
- "The window" is described as the window the pointer spends the most time in.
- The two-thumb slider exposes two ordinary sliders to keyboard / VoiceOver.
- A test project saved with the earlier `leave` key maps onto Show when read.

**After code review.** "Use these settings for all blocks" does not spread the
edge setting of a block that holds a window (the panel is not showing it).
"Redo" keeps what the block was told to show and its zoom kind; only an
untouched block takes what Auto zoom generates. Auto zoom makes one-level
blocks when the recording has nothing to fit a range to. The level taken when
leaving a range is worked out on the cut timeline, like the preview. Two
thumbs resting together at the top of the track can be pulled apart. The older
`leave` key is moved onto the block when it is read, so it survives a save.
Accepted as is: turning a range block into a fixed spot and back keeps the
range but replaces the level it uses when there is nothing to fit.
