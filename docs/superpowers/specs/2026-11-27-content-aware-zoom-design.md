# Content-aware auto zoom — design (Phase 3)

Status: draft for review. Follows
`2026-11-27-smooth-auto-zoom-pan-design.md` (Phases 1+2, shipped on
`t3/smooth-auto-zoom-pan`). The user accepted all three parts below in
principle, including the opt-in Accessibility permission.

## Intent

Phases 1+2 frame the picture from one signal: where the pointer is. That is
often not what the viewer needs to see. A click opens a menu that hangs off to
one side; a dialog appears in the middle of the screen; text is typed into a
field the pointer left seconds ago; the page scrolls and everything changes.
The user's verdict after trying the app: the zoom has to depend on how the
content on screen moves, and the feel cannot be judged until it does.

This phase gives the planner knowledge of the content:

- **what changed on screen** (from the recorded video itself),
- **which window the user is working in** (recorded alongside the video),
- **which control was clicked and where the text caret is** (recorded only if
  the user grants Accessibility).

Each is used for the same three decisions: where to aim a shot, how far to zoom
in, and when a held frame is no longer the right one.

## Parts and order

| Part | Signal | Works on existing recordings | New permission | Order |
| --- | --- | --- | --- | --- |
| 3c | Frame differencing of `screen.mp4` | yes | none | 1st |
| 3a | Window frames | no (new recordings only) | none | 2nd |
| 3b | Clicked element + text caret | no | Accessibility, opt-in | 3rd |

3c goes first: it answers the user's actual complaint (content motion), needs
nothing new at record time, and can be judged immediately on the recordings
already on disk. Each part ships on its own; later parts add better hints to
the same pipeline and never require the earlier ones to be present.

## Non-goals

- Recognising what content *is* (OCR, object detection, ML models).
- Storing any text from the screen: window titles, element labels or values,
  typed characters. Only geometry, a role name and an app bundle identifier.
- Changing how the compositor applies zoom, or the `ZoomBlock` schema.
- Running any of this automatically. Hints are only *used* when the user
  presses "Auto zoom" or when follow blocks are rebuilt; the video analysis
  only *runs* when "Auto zoom" is pressed (see 3c).
- Camera moves triggered by content alone while the pointer is busy elsewhere.
  The pointer stays the primary subject; content only shapes the frame around
  it. (One exception: typing, where the caret is the subject — 3b.)

## Anti-goals

- A frame that leaves the pointer to chase something that changed.
- Analysis that blocks the editor, or that the user has to wait for before a
  recording can be opened or exported.
- Preview and export disagreeing: hints feed the same pure pre-pass, so both
  get the same track.
- A recording that fails or stutters because a hint could not be collected.
  Every collector is best-effort and fails silently into "no hint".

---

## Shared model: content hints

All three parts produce the same thing, so the planner and the suggester stay
pure and unit-testable and do not know where a hint came from.

```
ContentHint
  span:   time range on the master timeline
  rect:   region in source pixels (top-left origin)
  kind:   change | window | element | caret
```

`ContentHints` is the per-recording collection, with lookups by time. It is
mapped onto the cut timeline together with the cursor samples, exactly as
blocks and cursor are today (`withCollapsedTimeline`), so hints from footage
that was cut away never influence the picture.

### Use 1 — aiming a shot

Today a shot's aim is the centre of the pointer path's bounding box
(`settle`). With hints, the aim moves toward the relevant content **as far as
it can while the pointer path still fits the safe zone**:

```
target = centre of the hint rect relevant to this shot
aim.x  = clamp(target.x, pointerBox.maxX − safeW, pointerBox.minX + safeW)
aim.y  = likewise
```

If the hint rect and the pointer box both fit in the safe zone, the frame
centres on their union. If not, the pointer wins and the frame leans toward
the content. With no hint the result is exactly today's behaviour.

Which hint is relevant to a shot that starts at `tArrive`, in priority order:

1. `caret` covering the shot (typing in progress),
2. `element` from the click that follows within 1 s (the clicked control),
3. `change` beginning within 1 s after the first click in the shot, when its
   rect is smaller than the view (a menu, popover, tooltip, inline result),
4. none. (`window` hints do not aim; they bound — see use 3.)

### Use 2 — how far to zoom in

Generated blocks currently all use the default scale. With hints, "Auto zoom"
sets an explicit `scale` on a generated block when the content it covers has a
natural size:

```
subject = union of the block's element / caret / small-change rects and the
          pointer path, padded by 15% per side
fit     = min(view.width / subject.width, view.height / subject.height)
scale   = clamp(fit, 1.5, 3.0)
```

- A block whose subject is one small dialog zooms to that dialog.
- A block whose subject spans most of the window gets a low scale instead of
  panning back and forth at the default one.
- No usable hints → `scale` stays nil (project default), as today.

The scale is an ordinary per-block value the user can change afterwards.

### Use 3 — bounding the frame

When a `window` hint covers a shot and the window is smaller than the captured
area, the reach is clamped to the window rect grown by a margin (5% of the
view) instead of the whole content rect: the camera does not drift onto the
desktop or a neighbouring window while following the pointer inside one. If the
view is larger than the window on an axis, that axis centres on the window
(existing inverted-reach rule). The pointer leaving the window drops the bound
for that shot.

### Use 4 — when to cut a held frame short, and when to stay wide

- A **window change** (different window becomes active, or the active window
  moves/resizes by more than 5% of the view) ends the current shot: the next
  shot re-settles with the new bound, as an ordinary eased move.
- A **whole-screen change** — a `change` hint covering at least 60% of the
  source, lasting at least 0.5 s or coinciding with a window change — is a
  "show the whole picture" moment. The suggester treats it like a long scroll
  burst today: clusters do not join across it and no block covers it, so the
  zoom is out while the screen redraws.

---

## 3c — What changed on screen (frame differencing)

### What is computed

One pass over `screen.mp4` at low resolution produces a list of **change
events**: `{t0, t1, rect}` — between `t0` and `t1` the pixels inside `rect`
changed.

- Decode sequentially with `AVAssetReader`, asking the decoder for a small
  luma frame (192 px wide). The pointer is not baked into the video
  (`showsCursor = false`), so pointer movement never registers as change.
- Compare each frame with the previous analysed one on a coarse grid (cells of
  8×8 small pixels → 24 × ~14 cells). A cell is "changed" when enough of its
  pixels differ by more than a noise threshold.
- Group changed cells in time: consecutive frames with change closer than
  0.25 s belong to one event; its rect is the bounding box of the changed
  cells, in source pixels. An event that keeps going (video playing, a
  spinner) is closed after 2 s and a new one starts, so long activity does not
  become one giant rect.
- Discard events smaller than one cell lasting under two frames (caret blink,
  clock ticks) and events the bounding box of which is a thin full-width or
  full-height strip (progress bars, scrollbars).

Measured on this machine with the user's recordings (2560×1440 HEVC, 26 s and
86 s): about 245 decoded frames/s, 4–5× real time, for decode plus diff. A
10-minute recording therefore takes about 2 minutes. That is too slow to do
silently on open and fine as a one-off with progress.

### When it runs, where it is kept

- Runs when the user presses **Auto zoom** and no analysis exists yet. The
  button shows progress ("Analysing video… 42%") and can be cancelled;
  cancelling generates blocks without change hints (the Phase 2 result).
- Runs off the main actor; the editor stays usable. Nothing else waits on it.
- The result is cached in the bundle as `analysis/changes.json` with a format
  version and the video's duration and size. It is derived data: deleting it
  only costs a re-run. A missing, stale or unreadable cache means "not
  analysed yet". Duplicating a project may copy it or not — both are fine.
- Loaded with the project when present, so follow blocks use change hints on
  the next open without re-analysing.
- Trimming or cutting does not invalidate it (events are in master time).

### How it is used

- Aim (use 1, rule 3): a click followed within 1 s by a change smaller than
  the view pulls the frame toward what appeared.
- Scale (use 2): small changes that follow clicks inside a block join the
  block's subject.
- Stay wide (use 4): whole-screen changes split clusters.
- Old recordings and recordings without window/element data get all of the
  above from the video alone.

### Risks

- Compression noise or subtle animation reading as change → thresholds are
  constants tuned on the user's recordings; unit tests use synthetic luma
  frames. A recording with constant motion (video playback) yields mostly
  large events, which the "smaller than the view" rule ignores for aiming.
- Variable frame rate: frames exist only when the screen changed, so decoding
  cost follows activity, not duration. The estimate above is from real
  recordings, not a worst case; a full-motion 60 fps recording takes longer.

---

## 3a — Which window (recorded at capture time)

### What is recorded

A new optional bundle file `windows.jsonl`, written at finalize like
`events.jsonl`, with the same time base (`t` relative to the screen track's
`sessionStartHostTime`). One line whenever the active window or its frame
changes:

```
{"t": 12.3456, "id": 4821, "app": "com.apple.Safari",
 "x": 120, "y": 80, "w": 1440, "h": 900}
```

- Source: `CGWindowListCopyWindowInfo(.optionOnScreenOnly, …)` filtered to
  layer 0 and the frontmost application's pid; the first match is the active
  window. Bounds are global screen points, top-left origin — the same space as
  `events.jsonl`, so `DisplayInfo` maps them into source pixels unchanged
  (including area capture's shifted origin).
- Sampled at 4 Hz on the existing tracker cadence and once more on every mouse
  down; a line is written only when something changed. Typical recordings add
  tens of lines.
- No window titles. No new permission: bounds, layer and owner pid are
  available with the Screen Recording permission the app already has.
- Capture Studio's own chrome is never the "active window" for this purpose:
  windows not registered in `CaptureContentWindows` are skipped, matching what
  is visible in `screen.mp4`.
- Camera-main recordings write no file. `DisplayInfo`, `events.jsonl` and
  `meta.json` are untouched; older app versions ignore the extra file.

### How it is used

- Bound (use 3) and shot boundary on window change (use 4).
- Scale (use 2): when the active window is much smaller than the captured
  area (a dialog, a small utility window), the window rect joins the block's
  subject, so the block zooms to fit the window.
- A window change coinciding with a whole-screen change confirms "stay wide".

---

## 3b — Which control, and where the caret is (opt-in Accessibility)

### Permission and consent

- A new optional permission, **Accessibility**, off by default. Settings gets
  a toggle "Smarter auto zoom" with one sentence on what is read (the position
  and type of the control under a click and the position of the text cursor;
  never text content) and a button to open the system pane.
- Nothing prompts during recording. Without the permission, or with the toggle
  off, recording is exactly as today and no element data is written.
- It joins the existing permission UI as an optional row; it never blocks a
  recording or appears in the "fix before recording" path.
- No entitlement is needed for Accessibility API use under Hardened Runtime;
  verify on a notarized build before shipping (RELEASING.md checklist item).

### What is recorded

A new optional bundle file `elements.jsonl`, same time base:

```
{"t": 12.40, "k": "click", "role": "AXButton",   "x":…, "y":…, "w":…, "h":…}
{"t": 15.02, "k": "focus", "role": "AXTextArea", "x":…, "y":…, "w":…, "h":…}
{"t": 15.31, "k": "caret", "x":…, "y":…, "w":…, "h":…}
```

- `click`: on mouse down, the element at the pointer
  (`AXUIElementCopyElementAtPosition`) → its role and frame.
- `focus`: when typing starts (first key after a pause), the focused element's
  role and frame.
- `caret`: while typing, at most 5 Hz, the bounds of the insertion point
  (`AXSelectedTextRange` → `AXBoundsForRange`), when the app exposes it.
- Role names and rectangles only. No titles, values, labels, selected text or
  key identities.
- Accessibility calls can stall on an unresponsive app. They run off the main
  actor on a serial queue with a short messaging timeout (0.1 s); a slow or
  failed query is dropped. Queries are never queued up: if one is still
  running, the next is skipped. The 60 Hz pointer sampler is never delayed.

### How it is used

- Aim (use 1): the clicked element's rect is the best hint for a click; the
  frame leans to include the whole control, not just the point clicked.
- Typing: today a long typing burst becomes a manual block aimed at the last
  click within 10 s. With element data it aims at the focused field's rect.
  When the field is larger than the view (an editor, a document), the block
  stays a follow block and the **caret replaces the pointer** as the followed
  position for the duration of the burst, so the frame follows the text being
  written.
- Scale (use 2): element and field rects join the block's subject.
- Typing detection no longer depends on Input Monitoring alone: `caret` /
  `focus` lines mark typing even when key events were not granted.

---

## Architecture

```
Record time                          Studio
───────────                          ──────
EventTracker  ── events.jsonl ─────┐
WindowTracker ── windows.jsonl ────┤→ ContentHints (pure) ─┬→ AutoZoomSuggester
ElementTracker ─ elements.jsonl ───┤                       │    (scale, splits,
                                   │                       │     typing target)
screen.mp4 ─→ ChangeAnalyzer ──────┘                       └→ ZoomShotPlanner
              (async, cached in                                 (aim, reach,
               analysis/changes.json)                            shot boundaries)
```

- `ContentHints`, the hint-to-aim / scale / bound rules, and the grouping of
  changed cells into events are pure functions with unit tests (synthetic
  hints, synthetic luma grids).
- `ChangeAnalyzer` (AVFoundation) and the two trackers (AppKit / CoreGraphics /
  Accessibility) are thin glue around those pure parts, in line with the
  existing "capture/UI glue is not unit-tested" rule.
- `AutoZoomConfig` gains the hints; `AutoZoomTrack.build` stays a pure
  function of blocks + cursor + config.

## Invariants to keep

- Cursor not baked in; host-clock sync; region-relative `DisplayInfo`;
  recording chrome never captured — all untouched.
- New bundle files are optional and additive; every reader treats a missing or
  malformed file as empty.
- CLT build stays green; no new dependencies.

## Decisions taken here (object if you disagree)

1. Order 3c → 3a → 3b, each mergeable on its own.
2. Video analysis runs on the "Auto zoom" press, not on open, and is cached in
   the bundle.
3. The pointer always stays in frame; content only leans the frame, except for
   the caret during typing.
4. Window and element data go in two new files rather than new `events.jsonl`
   line kinds, so older builds and existing decoders are unaffected.
5. No text of any kind is recorded, and Accessibility is opt-in from Settings
   with no prompt during recording.
6. Hints set an explicit per-block scale on generated blocks (1.5×–3.0×).

## Success criteria

1. On an existing recording, after "Auto zoom": a click that opens a menu or
   popover yields a frame that contains both the click point and what opened,
   when both fit.
2. A page navigation / app switch / long redraw is shown un-zoomed.
3. Blocks around a small dialog are zoomed in further than blocks spanning a
   whole window.
4. With no hints available (analysis cancelled, old bundle without files) the
   result is identical to the Phase 2 output — verified by a test.
5. The pointer is never outside the hard margin because of a hint.
6. Analysis of a 10-minute 1440p recording finishes in a few minutes, shows
   progress, can be cancelled, and the editor stays responsive meanwhile.
7. A second "Auto zoom" on the same project does not re-analyse.
8. (3a) In a new recording of a small window on a large display, the follow
   camera stays on that window.
9. (3b) With Accessibility granted, typing in a large editor is followed line
   by line; without it, nothing changes and nothing extra is written.
10. Recording performance and the 60 Hz pointer track are unaffected by the
    new trackers.

## Left to the builder

- Thresholds for the diff (noise level, cell size, grouping gaps) — tune on
  the user's recordings.
- Exact shape of the cache file and the progress UI.
- Type and file names.
- Whether analysis reads the whole file or only stretches around activity.

## Revision — 3c as built (2026-11-27)

An independent scrutiny of the 3c plan changed several rules before
implementation. Where this section and the text above disagree, this section
is what the code does.

- **Reveals are paired in master time.** "What a click opened" is computed once
  from clicks and change events on the master timeline; only the click time is
  remapped onto the cut timeline. A click is never paired with a change from
  the other side of a cut.
- **Change events are spatial as well as temporal.** Change in separate places
  at the same time stays separate (a spinner does not merge with a menu), and
  every open event is closed at each mouse-down so that what a click causes is
  not merged with a hover highlight before it.
- **Leaning keeps slack.** A leaned shot keeps the pointer path inside 60% of
  the safe zone, and a lean smaller than 5% of the view is not made, so pointer
  jitter cannot push it straight back out. The lean target is first limited to
  where the view centre can actually go.
- **Which reveal:** the reveals of clicks from 0.5 s before to 2 s after the
  moment a shot settles, that fit the view at the block's scale, united while
  the union still fits.
- **Whole-screen redraw:** an event covering at least 60% of the picture, at
  any length; during continuous motion only the first of a chain counts. It
  becomes a one-second wall that starts one zoom-out ramp after the redraw, so
  the zoom is still in while the click that caused it happens. A redraw inside
  a drag or a typing burst is ignored.
- **Scale:** one value per run (touching blocks never differ), only when the
  run contains a reveal: the largest scale at which every reveal fits together
  with its click, padded 15% per side, clamped to 1.5×–3.0× and rounded to
  0.05. "Only this block" keeps the replaced block's scale when it had one.
- **Cache:** `analysis/changes.json`, valid when its format version and the
  video file's byte size match. Never written into a bundle that is no longer
  on disk.
- **Editing during analysis:** if the zoom blocks changed while the video was
  being analysed, generation is skipped rather than overwriting that work.
- **Undo:** hints are not part of the edit history. Undoing an Auto zoom
  restores the blocks; follow blocks keep leaning toward revealed content.

## Revision — 3a as built (2026-11-28)

The 3a plan was scrutinised before implementation and the code reviewed after.
Where this section and the text above disagree, this section is what the code
does.

- **Which window:** the topmost ordinary window *under the pointer*, not the
  front application's first window — the bound only matters for the window the
  pointer is in, and a completion list or popover elsewhere must not take it.
  Sampled ten times a second and shortly after each mouse-down, off the main
  thread. `windows.jsonl` holds time, window number and frame only (no owning
  app, no title); a window outside the captured area is written as "none".
- **Usable windows:** one that is at least a quarter inside the picture, covers
  less than 85% of it, and stays put for a second. A window being dragged, or
  one the pointer only passes over, bounds nothing.
- **Bound (use 3):** shots are found from the pointer exactly as before. The
  window only limits where a shot's frame may sit: inside the window, widened
  by whatever the pointer does outside it during that shot and by the revealed
  content the shot leans toward, plus 7% of the view. A pointer nowhere near
  the window is not held to it. Overflow blocks are never bound.
- **Window change (use 4):** no re-settling. A change during a held shot
  re-frames it with one eased move, and only when the frame would shift by at
  least 2% of the view.
- **Scale (use 2):** when every click of a run (not counting the one that
  opened the window) is inside a window small enough to fill the frame at 1.5×
  or more, the run gets the scale at which that window and its margin fit,
  rounded down. A typing block in such a window holds the window's framing
  rather than the click point.
- **Not done:** window changes as "stay wide" walls (a whole-screen redraw
  already is one); bounding manual blocks the user aimed.

## Revision — dynamic zoom inside one block (2026-11-28)

Asked for after trying 3a; design, rules and review outcome are in
`docs/superpowers/plans/2026-11-28-dynamic-zoom-block.md`. In short: a follow
block can be set to an auto zoom range (least / most zoom) instead of one
scale. The block then changes its zoom by itself to fit the window it works in
and what clicks open, and the user chooses what happens when the pointer
leaves that window (show both, follow the pointer, stay on the window, or let
the app decide). "Auto zoom" makes its follow blocks this way; every setting
can be changed afterwards. This replaces "one scale per run" as the default
for generated blocks. Round 2 (not built): picking the window on the canvas,
and fitting content that appears without a click. 3b follows after that.

