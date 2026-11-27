# Smooth Auto Zoom/Pan — Shot Planner + Auto Zoom Generator (v4)

Date: 2026-11-27
Status: Approved 2026-11-27
Revises: [2026-06-23-auto-zoom-settle-follow-design.md](2026-06-23-auto-zoom-settle-follow-design.md)
Scope: Phase 1 (camera path planner) + Phase 2 (auto-generated zoom blocks).
Phase 3 (window frames, Accessibility, frame-diff content awareness) is agreed
in principle and gets its own spec later.

## Intent

Zoomed recordings should look like a camera operator shot them: the frame
holds still, moves deliberately when the action moves, and never makes the
viewer chase it. And the user should not have to place every zoom block by
hand.

Today:

- Zoom blocks are placed manually (`StudioModel.addZoomBlock()`); nothing
  decides *when* to zoom.
- Inside a follow block, `AutoZoomTrack` waits for the cursor to rest (dwell),
  then eases the focus to it with a fixed-time critically damped spring. It is
  causal (only looks backwards), the pan time ignores distance, pan and zoom are
  independent, and nothing guarantees the cursor stays in the visible frame
  while the dwell timer runs.
- Clicks, key presses, scrolls and the cursor kind are recorded in
  `events.jsonl` but are not used for zoom.

## Goals

1. Pan motion that is comfortable to watch: hold → move → hold, with eased
   starts and stops, a bounded on-screen speed, and travel time that grows with
   distance.
2. The camera anticipates: it uses the whole recording (we render offline) so a
   move is already under way when the cursor leaves the frame, instead of
   lagging behind it.
3. Whenever the camera is holding in a follow block, the cursor is inside the
   visible frame. During a move the cursor may briefly be ahead of the camera,
   for no longer than that move.
4. Long hops zoom out a little, travel, and zoom back in, rather than sweeping
   the whole screen at full magnification.
5. One click ("Auto zoom") produces a sensible set of ordinary, editable zoom
   blocks from the events already recorded. Works on existing recordings.

## Non-goals

- New recorded data, new permissions, or analysis of `screen.mp4` (Phase 3).
- Changes to `ZoomBlock`, `EditState`, `events.jsonl`, or `meta.json` schemas.
- Changes to the compositor's zoom application (`magnify`, `recenterTarget`).
- Running auto zoom automatically when a recording opens.
- A per-project "auto zoom strength" control. Tunables are constants for now.

## Anti-goals

- Zoom pumping: zooming in and out repeatedly within a few seconds.
- A camera that drifts or twitches with small cursor movement.
- Auto zoom silently destroying blocks the user placed or tuned.
- Preview and export showing different camera paths (they match today because
  both build the track on the cut timeline; keep it that way).

## Constraints

- `AutoZoomTrack` stays a pure pre-pass: blocks + samples in, `[ZoomKeyframe]`
  out, sampled statelessly per frame. Deterministic under out-of-order frame
  requests. No AVFoundation / AppKit imports; unit-tested with swift-testing.
- `ZoomKeyframe` fields and `AutoZoomTrack.sample(at:track:)` are unchanged, so
  `CameraCompositor` is untouched.
- Must build under Command Line Tools (no `#Preview`, no dependency bumps).
- Existing projects must open and render. Their blocks keep their stored
  `scale` / `sensitivity` / `mode` / `focus` / `overflow`; the *feel* of follow
  blocks changes, which is intended.

## Approaches considered

**A. Keep the causal spring, tune it.** Add a speed cap and distance-scaled
smooth time to the existing forward pass. Smallest change, but it cannot
anticipate, and the cursor-in-frame guarantee fights the dwell timer. Rejected:
fixes symptoms, keeps the lag.

**B. Offline shot planner (chosen).** Split each follow block into shots
(a fixed frame centre held for a span) using look-ahead over the cursor path,
then join shots with closed-form eased moves. Anticipation and hold stability
come from the structure rather than from tuning a filter.

**C. Global optimisation** (L1-optimal camera paths, Grundmann et al. 2011).
Best theoretical result, but needs an LP solver and is hard to make
predictable and testable. Rejected for now: B gets the same hold/move/hold
shape with simple code.

For Phase 2, the alternatives were: generate blocks from events (chosen), or
Vision-based analysis of the video (heavier, guesses what events state
directly; deferred to Phase 3 as a fallback).

The user picked: Phases 1+2 now in one spec, Phase 3 afterwards.

---

## Phase 1 — Shot planner

Replaces the follow model inside `AutoZoomTrack.build`. The run structure
(touching blocks form a run; scale ramps in at run start and out at run end;
`blendedTarget` across internal boundaries; `rampFor`) is unchanged.

### Terms

- **Content rect**: the part of the source the picture can show, in source
  pixels: the reframe crop (`cropRectInSource`) when one applies, else the full
  source.
- **View size**: how much source fits in the framing region at scale 1
  (region size ÷ placement scale). With a framing window it is smaller than
  the content rect; in a letterboxed fit it can be larger on one axis.
- **View**: what is visible at scale `s`. Half-extent per axis:
  `h(s) = viewSize / (2·s)`.
- **Reach**: where the view centre may go. Contained mode: the content rect
  inset by `h` (an axis where the view is larger than the content collapses to
  the content's midpoint, i.e. no panning on that axis). Overflow mode: the
  full source. This mirrors the compositor's cover clamp, which keeps the
  scaled content covering the region.
- **Frame-width**: distances are measured in units of the view size at the
  block's held scale (per axis), so limits mean the same on screen at any zoom.
- **Safe zone**: the view shrunk about its centre by `safeFrac`. A cursor
  inside it needs no camera move.
- **Hard margin**: the view shrunk by a fixed 0.92.

### New inputs

`AutoZoomConfig` gains:

- `viewSize: CGSize?` and `contentRect: CGRect?` (nil = full source for both).
  `StudioModel` derives them from the same crop / fit / framing-window values
  it gives the compositor. Crop and frame edits therefore change the planned
  path; the track is already rebuilt on every such edit.
- `discontinuities: [Double]` (default empty): times on the track's timeline
  where the picture cuts (see Cuts below).

Cursor samples are clamped before planning: to the content rect in contained
mode, to the full source in overflow mode. A pointer on another display or
outside the crop pulls the camera only to the edge. Sampling never
interpolates across a discontinuity: just before a cut the cursor is where it
was, just after it is where the new footage has it.

### Step 1 — Shots (per follow block)

Walk the cursor samples forward at `config.step`:

1. The first shot is centred on the cursor at the block start (or carried in
   from the previous block in the run).
2. Find `tExit`: the first time the cursor leaves the current shot's safe zone
   and does not return within `flickGrace`. A flick that returns in time is
   ignored, unless it crosses the hard margin, which always counts as an exit.
3. Find `tArrive`: the first time at or after `tExit` when the cursor's speed
   drops below `vRest`, or `tExit + maxTransit`, whichever comes first. This
   skips the cursor's flight so the new frame is placed where it lands, not
   where it was passing through.
4. The next shot's centre is the centre of the bounding box of the cursor path
   from `tArrive` onward, extended for as long as that box still fits inside
   one safe zone.
5. Repeat from 2 (from `tArrive`) until the block ends.

A cursor that sweeps without resting produces a chain of shots: a fast sweep
gives overlapping moves (Step 2) that merge into one glide; a slow sweep gives
a hold, a short move, a hold.

Each shot centre is clamped to the reach. The safe-zone logic keeps using the
unclamped aim, so a cursor parked near a screen edge does not keep re-triggering
moves the picture cannot make. This also removes today's dead travel near
edges, where the focus moves but the picture cannot.

A discontinuity always ends the current shot; the next shot starts at it.

### Step 2 — Moves

Each change of shot centre `Δᵢ` becomes a move of duration `Dᵢ` centred on
`tᵢ`:

```
dNorm = |Δᵢ| in frame-widths (at the held scale)
Dᵢ    = clamp(dNorm / vPref, dMin, dMax)
tᵢ    = midpoint of [tExit, tArrive], delayed as needed (see below)
```

The focus path is the closed-form sum

```
focus(t) = c₀ + Σᵢ Δᵢ · S((t − tᵢ) / Dᵢ)
S(u)     = 0 for u ≤ −½, 1 for u ≥ ½, minimum-jerk 10x³ − 15x⁴ + 6x⁵ with x = u + ½
```

- A move starts before the cursor has left (anticipation) and has zero
  velocity and acceleration at both ends.
- Anticipation is limited: the move is delayed until the cursor stays inside
  the hard margin of the moving view at every instant up to `tExit`. A cursor
  resting before a long hop (the moment of a click) is therefore never pushed
  out of frame by the camera leaving early. In the limit the move starts at
  `tExit`.
- Overlapping moves add linearly; a new target arriving mid-move needs no
  special case.
- The path is a pure function of `t`: stateless, and continuous across block
  boundaries in a run.

Special placements:

- **Follow ↔ manual seams.** The move sits wholly inside the manual block: it
  starts at the boundary when entering manual, and ends at the boundary when
  leaving it. Follow blocks therefore keep Goal 3, and a manual block holds its
  target except for one move at each end. If the manual block is shorter than
  the two moves, both are shortened proportionally to fit.
- **Manual → manual** seams are centred on the boundary.
- **Follow → follow** seams (a split with a different scale): the aim carries
  over; if the new block's reach moves the centre, that is a move centred on
  the boundary.
- **Discontinuities.** The move at a cut is instantaneous (`D = 0`): the camera
  cuts with the picture. No other move may span a discontinuity; a move that
  would is shortened to stop at it, and if that leaves it shorter than `dMin`
  it is folded into the cut itself.

Manual blocks contribute one shot at their stored target; with no stored target
they hold the incoming centre (clamped to their own reach).

The path is defined by the sequence of centres, and every change of centre has
a move, so the focus always ends exactly on the current shot's centre.

### Step 3 — Zoom dip on long hops

`vPref` is chosen so an uncapped move never exceeds `vMax` on screen. Only a
move whose duration was capped at `dMax` can, and only such a move dips: the
magnification drops during it just enough to hold the peak on-screen speed at
`vMax`:

```
peak on-screen speed of a minimum-jerk move = 1.875 · dNorm / D
dipScale = clamp(sHold · vMax · dMax / (1.875 · dNorm), min(sHold, 1.1), sHold)
scale(t) = sHold − (sHold − dipScale) · bump((t − tᵢ) / Dᵢ)
```

`bump` is a smooth 0→1→0 curve over the move (zero slope at both ends and at
the peak). The dip never reaches scale 1 (floor 1.1), so the recentred frame
never snaps. Moves shortened by a seam or a cut do not dip. The keyframe
`weight` is not dipped, so the focus stays centred.

With these values a dip starts at hops of about 1.9 frame-widths, which a
contained 2× zoom cannot produce (its reach is one frame-width); dips appear
at higher zoom or in overflow mode.

This is a simplified form of van Wijk & Nuij's zoom-out/pan/zoom-in path. The
full hyperbolic solution is not used because it does not compose when moves
overlap (the limitation Reach & North describe).

### Sensitivity mapping

The existing per-block "Follow sensitivity" slider (0…1) keeps its meaning
(low = calm, high = snappy) and now drives:

| Knob | s = 0 | s = 1 | Meaning |
|---|---|---|---|
| `safeFrac` | 0.80 | 0.25 | bigger safe zone = fewer moves |
| `vPref` (frame-widths/s) | 0.7 | 1.3 | preferred travel speed |
| `flickGrace` (s) | 0.50 | 0.10 | how long a stray excursion is ignored |

Constants: `dMin` 0.35 s, `dMax` 1.4 s, `vMax` 2.5 frame-widths/s, `vRest` 0.3
frame-widths/s, `maxTransit` 0.8 s, hard margin 0.92. All are first-pass values
to tune against real recordings.

`tuning(_:)` (deadzone/dwell/smoothing), `restRadiusFrac`, and `smoothDamp` are
removed. `rampFor` is unchanged.

### Cuts

Preview and export both build the track inside `withCollapsedTimeline`, from
blocks and cursor samples already rebased onto the cut timeline. That stays.
On that timeline a cut inside a zoom block shows up as the cursor teleporting.
`StudioModel` passes the collapsed cut times as `discontinuities` so the
planner cuts the camera there instead of gliding across footage that was never
adjacent.

`seedManualFocus` (switching a block to manual) samples the track to seed the
target. It must build the track the same way the preview does (on the cut
timeline, with discontinuities) so the seeded point matches what is on screen.

### Files

- `Studio/AutoZoom.swift` — planner replaces the follow pass. Split the planner
  into its own file (e.g. `Studio/ZoomShotPlanner.swift`) if `AutoZoom.swift`
  would otherwise grow past a readable size.
- `Studio/StudioModel.swift` — pass `viewSize`, `contentRect` and `discontinuities`.
- `Studio/Inspector/ZoomInspector.swift` — help text for the sensitivity slider
  if the wording no longer fits.

---

## Phase 2 — Auto zoom generator

A pure function that turns recorded activity into zoom blocks. The Phase 1
planner does all the panning inside them, so the generator only decides *when*
to be zoomed in and, occasionally, how far.

```
AutoZoomSuggester.suggest(activity:, cursorSamples:, span:, sourceSize:,
                          cuts:, config:) -> [ZoomBlock]   // master timeline
```

`span` is the time range to generate for: the whole recording, or one block's
`[begin, end]`. Only activity inside it is used and every result lies inside it.

### Activity extraction

`CursorOverlay.samples` reads only `pos` and `down`. Add an extraction (same
coordinate mapping) that also yields:

- **Clicks**: `down` events inside the source bounds.
- **Drags**: a `down`→`up` pair whose distance exceeds a small threshold; kept
  as its bounding box.
- **Typing bursts**: runs of `key` events with gaps ≤ 1 s and at least 3 keys,
  ignoring keys pressed with cmd/ctrl (shortcuts, not typing). Only timestamps
  and modifiers are read. Absent when Input Monitoring was not granted; the
  generator then works from pointer activity alone.
- **Scroll bursts**: runs of `scroll` events with gaps ≤ 0.3 s.

Events outside the source bounds (another display) or inside a cut range are
ignored.

### Rules

Clustering and sizing run on the cut timeline (activity times mapped through
the cuts, activity inside a cut dropped), so two clicks that are adjacent for
the viewer are adjacent for the generator. The resulting spans are mapped back
to the master timeline, where blocks are stored. `preRoll` = ramp-in time + 0.2 s, so the zoom has landed just before the first
action. `postHold` = 1.2 s. `minWide` = 1.0 s is the shortest un-zoomed gap
worth showing.

1. **Cluster in time.** Consecutive clicks, drags and typing bursts join one
   cluster while the gap between them is ≤ `joinGap`, defined as
   `postHold + preRoll + minWide` (about 2.9 s at the default ramp). Anything
   closer would leave an un-zoomed gap shorter than `minWide`, i.e. pumping.
   This is the only merge rule.
2. **Scroll splits.** A scroll burst of 0.5 s or longer always splits a
   cluster, whatever the gap: scrolling means the viewer needs the whole page.
   The earlier run ends at the scroll start (its `postHold` is cut short) and
   the later run may not begin before the scroll ends.
3. **One run per cluster.** `begin = first.t − preRoll`,
   `end = last.t + postHold`, both subject to rule 2 and clamped to
   `[0, duration]`. A run shorter than ramp-in + ramp-out + 1.0 s is extended
   to that length where rule 2 and its neighbours allow, and dropped where
   they do not. Runs never overlap, and two runs that would end up less than
   `minWide` apart with no splitting scroll between them are merged.
4. **Typing.** Within a run, a typing burst of 1.0 s or longer becomes its own
   touching block in `.manual` mode, focused on the last click before the burst
   if it was within 10 s, else on the cursor position at the burst start. The
   frame then holds on the text field while the pointer wanders. Shorter bursts
   and the rest of the run are `.follow`.
5. Stretches with no clicks, drags or typing get no block.

Generated blocks leave `scale`, `sensitivity` and `overflow` nil. Choosing a
scale from the content is Phase 3, where window and element bounds make it
reliable.

### UI and model

- `ZoomInspector`: an "Auto zoom" button next to "Add zoom", disabled only
  without cursor data (same rule and help text pattern as "Add zoom").
- `StudioModel.generateAutoZoom(scope:)` with two scopes:
  - **All**: generate for the whole recording and replace every zoom block.
  - **This block**: generate only from activity inside the selected block's
    span and replace just that block. Results are clamped to the span, so
    neighbouring blocks are never touched or overlapped.
- Choosing the scope:
  - No existing blocks → "All" runs immediately, no prompt.
  - Blocks exist → the button asks which scope: "All blocks" (states how many
    will be replaced) or "Only this block" (offered only when a zoom block is
    selected), plus Cancel.
- Either scope is applied through the same path as other block edits, so it is
  one undo step and is persisted.
- No usable activity in the scope → leave blocks untouched and tell the user
  nothing was found.
- Not licence-gated (same as "Add zoom").

### Files

- `Studio/AutoZoomSuggester.swift` (new, pure).
- `Studio/CursorOverlay.swift` or a sibling — activity extraction.
- `Studio/StudioModel.swift` — load activity alongside cursor/click samples,
  `generateAutoZoom()`.
- `Studio/Inspector/ZoomInspector.swift` — button + confirmation.

---

## Testing

Pure unit tests (swift-testing). `AutoZoomTrackTests` is rewritten for the shot
model; `ZoomRampContinuityTests` and `RecenterTargetTests` must keep passing
unchanged.

Planner:

- Cursor still, or moving inside the safe zone → focus constant.
- A flick out and back within `flickGrace` → no move; one that crosses the hard
  margin → a move.
- Cursor relocates and stays → exactly one move; it starts before the cursor
  exits the safe zone; velocity is zero at both ends.
- Move duration grows with distance and stays within `[dMin, dMax]`.
- Peak focus speed for a single move ≤ 1.875 · distance / D (minimum-jerk
  bound).
- Property: on generated cursor paths, the cursor is inside the hard margin at
  every keyframe of a follow block where no move is in progress and the
  envelope is 1.
- A new shot is centred where the cursor lands, not on its flight path.
- A hop whose capped duration would exceed `vMax` dips the scale and returns to
  the held scale; a shorter hop does not dip; dip depth grows with distance;
  the dipped scale never goes below 1.1.
- A cursor resting before a long hop stays inside the hard margin until it
  starts to leave.
- Contained mode: shot centres never leave the reach, including with an offset
  content rect, a view smaller than the content (framing window), and a view
  larger than the content on one axis (letterbox: no pan on that axis).
- Cursor samples outside the content rect do not pull the focus past its edge.
- After any sequence of blocks in a run, the focus equals the current shot's
  centre once its move has finished (no accumulated offset).
- Manual block holds its target outside its two seam moves; no seam move
  extends into a neighbouring follow block; a short manual block still reaches
  its target.
- At a discontinuity the focus steps instantly, no move spans it, and cursor
  samples that are not aligned to the step do not produce a glide or a dip.
- Track is continuous (no jump larger than a small bound between adjacent
  keyframes) across blocks in a run, except at discontinuities.
- Kept from today: empty blocks/samples, scale outside blocks is 1, per-block
  scale override, weight behaviour, overflow flag propagation.

Generator:

- No activity → no blocks.
- One click → one block of minimum length whose ramp-in completes before the
  click.
- Clicks within `joinGap` → one block; farther apart → two, with at least
  `minWide` un-zoomed between them (including when a minimum-length extension
  would otherwise close the gap).
- Two clicks separated only by a cut cluster as one run.
- A scroll burst ≥ 0.5 s splits a cluster even when the clicks around it are
  within `joinGap`; no block covers the scroll.
- A typing burst ≥ 1.0 s → manual block focused on the preceding click; a
  shorter one stays follow.
- Events inside cuts or outside the source are ignored.
- Output never overlaps, is sorted, and lies within the requested span.
- Span limited to one block: activity outside is ignored and other blocks are
  unchanged after applying.

Verify under CLT before merging:
`DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test`.

Feel is verified by hand on real recordings: a click-heavy UI demo, a typing
session, and a recording with long cursor travel at 2.5×.

## Decisions confirmed by the user

- "Auto zoom" runs only when the button is pressed.
- Re-running offers "All blocks" or "Only this block".

## Decisions made by the author (user reviewed, no objection)

2. No legacy follow mode: existing projects get the new planner.
3. No marker distinguishes generated blocks from hand-placed ones.
4. Sustained scrolling ends a zoom rather than holding it.
5. Typing bursts hold a fixed frame (manual block) instead of following the
   pointer.
6. The zoom dip is the simplified form above, not the full van Wijk–Nuij path.
7. All numeric constants are first-pass and expected to be tuned.
8. During a fast hop the cursor may leave the frame until the camera arrives;
   the in-frame guarantee applies while the camera is holding.
9. Follow↔manual transitions happen inside the manual block.
10. Generated blocks always use the default scale; content-fitted scale waits
    for Phase 3.
11. A reframe crop or framing-window edit changes the planned camera path.

## Left to the builder

- Internal structure of the planner and how shots/moves are represented.
- Exact `bump` curve.
- Where the activity extraction lives and its type names.
- Wording of button labels, help text, and the "nothing found" message.
- How the confirmation is presented (alert vs. popover), following the
  existing Studio patterns.

## Phase 3 (later, separate spec)

- 3a: record window frames + frontmost app → fit-to-window scale, window
  change as a shot boundary.
- 3b: opt-in Accessibility → fit to the clicked element, follow the text caret.
- 3c: frame differencing on `screen.mp4` → find the region that changed after
  a click; fallback for old recordings and when 3b is not granted.

## References

- van Wijk & Nuij, "Smooth and efficient zooming and panning" (InfoVis 2003);
  d3 `interpolateZoom`.
- Reach & North, "Smooth, Efficient, and Interruptible Zooming and Panning"
  (2018).
- Grundmann, Kwatra, Essa, "Auto-directed video stabilization with robust L1
  optimal camera paths" (CVPR 2011).
- Screen Studio auto-zoom guide; Reframed and Screenize READMEs (behavioural
  reference only).
