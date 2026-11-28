# Dynamic zoom inside one block — design and plan (round 1)

## Intent (from the user, 2026-11-28)

The viewer should always see what is going on without the user cutting a
recording into many small blocks and setting a scale on each.

- One block may change its zoom over time, by itself, within a **min–max
  range** the user sets (instead of one scale).
- The user decides, per block, what the block frames when the pointer leaves
  the app window: show both, follow the pointer, or stay on the window.
- The user decides what counts as content to fit: the window, what a click
  opened, and (round 2) what appeared on its own.
- Content awareness proposes: "Auto zoom" fills these settings in; the user can
  change every one of them afterwards.
- It is an option. A block with a single scale behaves exactly as today.

Round 2, not here: picking the window on the canvas; "appeared on its own".

## Model

`ZoomBlock.auto: ZoomAutoScale?` — nil = one fixed scale (today).

```swift
struct ZoomAutoScale: Codable, Equatable {
    var min: Double          // 1…6, min ≤ max
    var max: Double
    var fitWindow: Bool      // the window the block works in
    var fitReveals: Bool     // what a click opened
    var leave: ZoomLeave     // pointer outside the window
}
enum ZoomLeave: String, Codable { case auto, both, pointer, window }  // unknown → auto
```

`ZoomBlock.scale` keeps its meaning and is what an auto block uses while there
is nothing to fit (not clamped to the range, so an auto block without any
content data renders exactly like a fixed one).

## How it renders: expansion into touching pieces

`AutoZoomTrack.build` already renders touching blocks as one run: the scale
blends across their boundary, the camera makes one eased move, the zoom never
drops to 1×. So an auto block is **expanded, at build time, into touching
pieces with one explicit scale each**; nothing downstream changes.

New pure `Studio/ZoomAutoScaler.swift`:

```swift
enum ZoomAutoScaler {
    /// Blocks with every auto block replaced by its pieces, and the window
    /// spans the planner should bound to (changed only inside "show both"
    /// excursions).
    static func expand(blocks: [ZoomBlock], cursor: [CursorSample], sourceSize: CGSize,
                       config: AutoZoomConfig) -> (blocks: [ZoomBlock], windows: [WindowSpan])
}
```

Per follow block with `auto` (manual blocks are returned unchanged):

1. **Home window**: the window (by rect) under the pointer for the longest
   total time inside the block. None → no window logic.
2. **Stretches by window**: the block's time split at window-span edges. Each
   stretch is *home* or *away* (a gap or another window); adjacent away
   stretches are one **excursion**.
3. **Excursion mode** from `leave`: `auto` → `both` when the excursion lasts at
   most 4 s and the pointer comes back to the home window, else `pointer`.
4. **Subject** of a stretch:
   - home: the home window when `fitWindow`;
   - away, `pointer`: the window under the pointer when `fitWindow` (per
     window span; nothing in a gap);
   - away, `both`: home window ∪ the pointer path's box over the excursion.
     The planner's window spans are replaced by that union for the excursion,
     so the frame is held on both. If it does not fit at `min`, the excursion
     falls back to `pointer`;
   - away, `window`: the piece is a manual piece with no target (holds the
     incoming frame) at the scale before it.
5. **Reveals** (`fitReveals`): a reveal whose rect is not already inside the
   stretch's subject opens a sub-stretch from its click until 2.5 s later (or
   the next mouse-down reveal / the stretch end) with subject ∪ reveal ∪ click.
6. **Scale** of a stretch: no subject → the block's `scale ?? default`;
   else `(1 − 2·boundMargin) · min(view.w / subject.w, view.h / subject.h)`,
   clamped to `min…max`, rounded down to 0.05.
7. **Calm**: a stretch shorter than 1.5 s takes its predecessor's scale (the
   successor's if it is first); then neighbours whose scales differ by less
   than 15% become one, at the lower scale. So the zoom changes at most every
   1.5 s and only by an amount worth seeing.
8. Pieces never cross a picture break; a piece boundary on a break is fine.

`AutoZoomTrack.build` calls `expand` first and uses the returned window spans.

## Auto zoom fills it in

Generated follow blocks get `auto = (min 1.5, max 3.0, fitWindow, fitReveals,
leave .auto)`; generated typing (manual) blocks get none. The run's single
generated `scale` stays as the base. "Only this block" on a block the user set
to a fixed scale (own `scale`, no `auto`) keeps it fixed; otherwise the
replaced block's `auto` wins over the generated one.

## UI (Zoom inspector, follow mode)

- "Zoom" segmented: Fixed | Auto.
- Auto: "Min" and "Max" sliders (1…6; moving one past the other drags it
  along); toggles "Fit the window", "Fit what a click opens"; picker "When the
  pointer leaves the window": Auto / Show both / Follow pointer / Stay on window.
- The existing Zoom slider stays; in Auto its caption reads "Used when there is
  nothing to fit".
- Captions say when a setting has no data to work with (no `windows.jsonl`: the
  window options do nothing; video not analysed: press Auto zoom once).

`StudioModel`: `selectedZoomAuto`, `setZoomAuto(_:)` (live),
`commitZoomEdit()` on slider end; splitting a block copies `auto`.

## Tasks

1. Model + codec (`EditState`), tests: round trip, missing key → nil, unknown
   `leave` → auto.
2. `ZoomAutoScaler` with tests: no auto → unchanged; no data → one piece at the
   base scale and a track equal to the fixed block's; home window fit; large
   window → clamped to `min`; excursion brief → both (union subject, spans
   overridden) / long → pointer; `leave` forced each way; `window` → manual
   piece; reveal outside the subject → sub-stretch; calm rules; breaks.
3. Wire into `AutoZoomTrack.build`; track tests: scale differs between a
   dialog stretch and a large-window stretch inside one block; pointer inside
   the view at every keyframe of a "both" excursion.
4. Suggester + merge rules, tests.
5. Model accessors + inspector UI.
6. `swift test` (Xcode + CLT), build and launch, independent code review.

## Out of scope

Round 2 items; a custom scale curve editor; changing how two user blocks with
different scales blend.

## Scrutiny outcome (2026-11-28)

Reviewed against the code before implementation; these rules replace the text
above where they differ.

- **Scale changes are eased.** A boundary between two pieces of an auto block
  blends in log space with a smoothstep, over `max(0.4 s, 1.5 · ramp ·
  octaves)`; boundaries between user blocks keep the short linear blend. A
  boundary on a picture cut steps with the picture.
- **A subject that cannot fit at the least zoom is no subject** — the block's
  base scale applies (an ordinary large window does not drag the zoom down to
  the minimum).
- **Reveals only ever zoom out** from the scale a stretch already has.
- **Windows are told apart by window number** (`WindowSpan.id`), so a window
  that was moved is still home. A gap in the data during which the pointer
  stays inside the home window is home. A tie for home goes to the first.
- **"Stay on the window" is not a manual piece**: the block keeps following,
  with the pointer treated as staying inside the window for the trip.
- **Calm:** a piece under 1.5 s takes its predecessor's scale; a zoom-in
  between two wider framings must last 3 s; scales within 15% become one, the
  lower. "Show both" holds the frame on both only when the final scale still
  fits them.
- **Touching auto blocks with the same settings are planned as one**, so a
  split changes nothing by itself.
- **Typing blocks** made by Auto zoom take the scale the auto pieces around
  them take in the same window.
- **Editor:** in Auto the single Zoom slider is hidden; switching an auto
  block to Manual keeps the scale shown at the playhead; "Apply to all blocks"
  copies the auto settings and makes them what Auto zoom uses from then on.
- Overflow blocks get the scale but are never held to a window.

**After code review.** Zoom-out is eased before a piece boundary and zoom-in
after it, so the wider framing is the one shown while the camera travels. The
blend length is limited by how long the scale stays the same either side (not
by where the user split the block). A zoom-in at the very start or end of a
block is kept (only one between two wider framings must last 3 s). Scales
merge only while the whole merged run stays within 15%. The range starts at
1.1×. "Apply to all blocks" copies auto settings from a follow block to follow
blocks only. Turning an auto block into a manual one keeps the scale of the
piece under the playhead.
